//! Shared binding-preservation check for the minifier and compiler suites.
//!
//! `expectBindingsPreserved` is the load-bearing proof that a renamer kept
//! every reference pointing at the same symbol: minify `source` under
//! `options`, re-parse the output, and require the normalised
//! identifier-reference sequences to be equal. It lives here, beside
//! `parse_ok.zig`, so `collision_test.zig` and `compile_text_test.zig` share
//! exactly one implementation.
//!
//! `expectBindingsPreservedText` is the same comparison for a caller that
//! already holds the output text — the compiler's `minifiedText` seam — so
//! the decoded wasm can be pinned against the source without a runtime.

const std = @import("std");
const wgslender = @import("wgslender");
const parse_ok = @import("parse_ok.zig");
const Ast = wgslender.Ast;

/// One identifier reference, normalised so source and minified output compare
/// without sharing a symbol table.
const BindingRef = union(enum) {
    /// Declared inside the function whose body contains this reference
    /// (parameter or local), identified by declaration ordinal.
    local: u32,
    /// Module-scope declaration, identified by index into `module.declarations`.
    global: usize,
    /// Builtins, struct members and unresolved names — nothing renames them,
    /// so the name itself is the identity.
    other: []const u8,
};

fn bindingEqual(a: BindingRef, b: BindingRef) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .local => |x| x == b.local,
        .global => |x| x == b.global,
        .other => |x| std.mem.eql(u8, x, b.other),
    };
}

/// Document-order binding recorder. `on_decl` numbers a function's parameters
/// and records the type names in its signature; `on_stmt` numbers every
/// declaration statement — a `for` initialiser included, because
/// `MultiVisitor` walks `init_stmt` — and records the type name of a typed
/// `let`/`var`; `on_expr` records every `.ident`. Ordinals restart at each
/// function, so `local(n)` is a position in its own function's declaration
/// order.
const BindingWalk = struct {
    arena: std.mem.Allocator,
    module: *const Ast.Module,
    refs: std.ArrayList(BindingRef) = .empty,
    /// Symbol index -> ordinal, for the function currently being walked.
    locals: std.AutoHashMapUnmanaged(u32, u32) = .{},
    next_ordinal: u32 = 0,

    fn onDecl(ctx: *anyopaque, decl: Ast.Decl) std.mem.Allocator.Error!void {
        const self: *BindingWalk = @ptrCast(@alignCast(ctx));
        if (decl != .function) return;
        const func = decl.function;
        self.next_ordinal = 0;
        for (func.parameters.items) |param| {
            if (param.name.isValid()) {
                try self.locals.put(self.arena, param.name.index(), self.next_ordinal);
                self.next_ordinal += 1;
            }
            try self.recordType(param.typ);
        }
        if (func.return_type) |ret| try self.recordType(ret);
    }

    fn onStmt(ctx: *anyopaque, stmt: Ast.Stmt) std.mem.Allocator.Error!void {
        const self: *BindingWalk = @ptrCast(@alignCast(ctx));
        if (stmt != .decl) return;
        const ref = stmt.decl.decl.nameRef();
        if (ref.isValid()) {
            try self.locals.put(self.arena, ref.index(), self.next_ordinal);
            self.next_ordinal += 1;
        }
        switch (stmt.decl.decl) {
            // A module-scope `const` cannot appear as a statement; the typed
            // local declarations are the ones whose type is a live reference.
            .let => |d| if (d.typ) |t| try self.recordType(t),
            .@"var" => |d| if (d.typ) |t| try self.recordType(t),
            else => {},
        }
    }

    fn onExpr(ctx: *anyopaque, expr: Ast.Expr) std.mem.Allocator.Error!void {
        const self: *BindingWalk = @ptrCast(@alignCast(ctx));
        if (expr != .ident) return;
        try self.recordRef(expr.ident.ref, expr.ident.name);
    }

    fn recordType(self: *BindingWalk, typ: Ast.Type) std.mem.Allocator.Error!void {
        switch (typ) {
            .ident => |t| try self.recordRef(t.ref, t.name),
            .vec => |t| if (t.elem_type) |inner| try self.recordType(inner),
            .mat => |t| if (t.elem_type) |inner| try self.recordType(inner),
            .array => |t| if (t.elem_type) |inner| try self.recordType(inner),
            .ptr => |t| try self.recordType(t.elem_type),
            .atomic => |t| try self.recordType(t.elem_type),
            .sampler, .texture => {},
        }
    }

    fn recordRef(self: *BindingWalk, ref: Ast.SymbolIndex, fallback_name: []const u8) std.mem.Allocator.Error!void {
        if (ref.isValid()) {
            if (self.locals.get(ref.index())) |ordinal| {
                try self.refs.append(self.arena, .{ .local = ordinal });
                return;
            }
            if (ref.index() < self.module.symbols.items.len) {
                const sym = self.module.symbols.items[ref.index()];
                if (self.module.scope.members.get(sym.original_name)) |member| {
                    if (member.ref == ref) {
                        for (self.module.declarations.items, 0..) |decl, i| {
                            if (decl.nameRef() == ref) {
                                try self.refs.append(self.arena, .{ .global = i });
                                return;
                            }
                        }
                    }
                }
                if (sym.original_name.len > 0) {
                    try self.refs.append(self.arena, .{ .other = sym.original_name });
                    return;
                }
            }
        }
        try self.refs.append(self.arena, .{ .other = fallback_name });
    }
};

/// Walks `module` once through `MultiVisitor` in document order and returns
/// the normalised reference sequence.
fn bindingSequence(arena: std.mem.Allocator, module: *const Ast.Module) ![]const BindingRef {
    const walk = try arena.create(BindingWalk);
    walk.* = .{ .arena = arena, .module = module };
    const listener: wgslender.MultiVisitor.Listener = .{
        .ctx = @ptrCast(walk),
        .on_decl = &BindingWalk.onDecl,
        .on_stmt = &BindingWalk.onStmt,
        .on_expr = &BindingWalk.onExpr,
    };
    try wgslender.MultiVisitor.walk(arena, module, &.{listener});
    return walk.refs.items;
}

fn printBindingWindow(refs: []const BindingRef, at: usize) void {
    const start = at -| 4;
    const end = @min(refs.len, at + 5);
    for (refs[start..end], start..) |ref, i| {
        if (i == at) std.debug.print(" <<<", .{});
        switch (ref) {
            .local => |ordinal| std.debug.print(" local({d})", .{ordinal}),
            .global => |index| std.debug.print(" global({d})", .{index}),
            .other => |name| std.debug.print(" other({s})", .{name}),
        }
    }
    std.debug.print("\n", .{});
}

/// The load-bearing binding check: minify `source` under `options`, re-parse
/// the output, and require the normalised reference sequences to be equal.
///
/// `minify_syntax`, `tree_shaking` and `sort_declarations` are forced off.
/// Sorting moves declaration order and nothing else — the wrapper is built
/// from the unsorted module and the sorted print reads the same renamer — so
/// proving the unsorted variant proves the sorted one. With all three off the
/// printer preserves every declaration and every reference in document order,
/// which is what makes the sequences directly comparable.
///
/// On failure this prints both sequences around the first divergence and the
/// minified text; callers add the fixture and config name.
pub fn expectBindingsPreserved(
    arena: std.mem.Allocator,
    source: [:0]const u8,
    options: wgslender.Minifier.Options,
) !void {
    var effective = options;
    effective.minify_syntax = false;
    effective.tree_shaking = false;
    effective.sort_declarations = false;

    const result = try wgslender.minifyWithOptions(arena, source, effective);
    try std.testing.expect(result.errors.len == 0);
    const minified = try arena.dupeZ(u8, result.code);
    try expectBindingsPreservedText(arena, source, minified, options);
}

/// The same comparison for output the caller already holds, e.g.
/// `Compiler.minifiedText`: both sides are parsed and their binding
/// structures must match. `options` is context for the failure report only.
pub fn expectBindingsPreservedText(
    arena: std.mem.Allocator,
    source: [:0]const u8,
    output: [:0]const u8,
    options: ?wgslender.Minifier.Options,
) !void {
    const source_module = try parse_ok.parseOk(arena, source);
    const output_module = try parse_ok.parseOk(arena, output);

    const expected = try bindingSequence(arena, source_module);
    const actual = try bindingSequence(arena, output_module);

    var mismatch: ?usize = null;
    const common = @min(expected.len, actual.len);
    for (expected[0..common], actual[0..common], 0..) |want, got, i| {
        if (!bindingEqual(want, got)) {
            mismatch = i;
            break;
        }
    }
    if (mismatch == null and expected.len != actual.len) mismatch = common;
    const at = mismatch orelse return;

    std.debug.print(
        "binding structure not preserved: source has {d} reference(s), output {d}; first divergence at #{d}\n",
        .{ expected.len, actual.len, at },
    );
    if (options) |opts| {
        std.debug.print(
            "options: scope_local_rename={} sort_declarations={} mangle_external_bindings={} keep_names={d}\n",
            .{
                opts.scope_local_rename,
                opts.sort_declarations,
                opts.mangle_external_bindings,
                opts.keep_names.len,
            },
        );
    }
    std.debug.print("source:", .{});
    printBindingWindow(expected, at);
    std.debug.print("output:", .{});
    printBindingWindow(actual, at);
    std.debug.print("minified output:\n{s}\n", .{output});
    return error.BindingsNotPreserved;
}
