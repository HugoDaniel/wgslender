//! Call graph + resource attribution for reflect results.
//!
//! This is the `call graph ↔ everything` seam of `Reflect.zig`. Two passes,
//! driven from `Reflect.reflect`:
//!
//!   1. `buildCallGraph` walks every user function body once, recording each
//!      `FunctionInfo`'s direct `var<>` resources, `@override` refs, and
//!      outgoing call edges — and stamps bidirectional `relations` on the
//!      bindings paired by texture-sampling builtins.
//!   2. `propagateEntryReachability` BFS's from each entry point through the
//!      call edges, marking reachable functions `in_use` and unioning their
//!      direct resources/overrides into the entry point's transitive lists.
//!
//! Everything else here is private plumbing. The public data structs it fills
//! (`ReflectResult`, `FunctionInfo`, `BindingInfo`) and the three symbol
//! helpers it reuses live in `Reflect.zig`, which stays the façade.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../Ast.zig");
const Reflect = @import("../Reflect.zig");

const ReflectResult = Reflect.ReflectResult;
const FunctionInfo = Reflect.FunctionInfo;
const BindingInfo = Reflect.BindingInfo;

const getSymbolName = Reflect.getSymbolName;
const getSymbolLoc = Reflect.getSymbolLoc;
const spanInfoFromAst = Reflect.spanInfoFromAst;

/// Builtins that take a texture as `args[0]` and a sampler as `args[1]`.
/// Used to pair textures with their samplers across function bodies.
const sampler_pair_builtins = std.StaticStringMap(void).initComptime(.{
    .{ "textureSample", {} },
    .{ "textureSampleBias", {} },
    .{ "textureSampleCompare", {} },
    .{ "textureSampleCompareLevel", {} },
    .{ "textureSampleGrad", {} },
    .{ "textureSampleLevel", {} },
    .{ "textureGather", {} },
    .{ "textureGatherCompare", {} },
});

/// Walk every user-defined function body once. Populates
/// `result.functions` with one entry per `FunctionDecl`, recording:
///   • direct `var<>` references → `direct_resources`
///   • direct `@override` references → `direct_overrides`
///   • outgoing function calls → `calls`
/// Texture-sampling builtin calls additionally stamp the matching
/// `BindingInfo.relations` lists bidirectionally.
pub fn buildCallGraph(arena: Allocator, module: *Ast.Module, result: *ReflectResult) Allocator.Error!void {
    for (module.declarations.items) |decl| switch (decl) {
        .function => |fn_decl| {
            var info = FunctionInfo{
                .name = getSymbolName(fn_decl.name, module.symbols.items),
                .name_offset = getSymbolLoc(fn_decl.name, module.symbols.items),
                .decl_span = spanInfoFromAst(fn_decl.decl_span),
            };
            if (fn_decl.body) |body| {
                try walkBody(arena, module, body, &info, result);
            }
            try result.functions.append(arena, info);
        },
        else => {},
    };
}

fn walkBody(
    arena: Allocator,
    module: *Ast.Module,
    body: *Ast.CompoundStmt,
    info: *FunctionInfo,
    result: *ReflectResult,
) Allocator.Error!void {
    for (body.stmts.items) |stmt| {
        try walkStmt(arena, module, stmt, info, result);
    }
}

fn walkStmt(
    arena: Allocator,
    module: *Ast.Module,
    stmt: Ast.Stmt,
    info: *FunctionInfo,
    result: *ReflectResult,
) Allocator.Error!void {
    switch (stmt) {
        .compound => |s| try walkBody(arena, module, s, info, result),
        .@"return" => |s| if (s.value) |v| try walkExpr(arena, module, v, info, result),
        .@"if" => |s| {
            try walkExpr(arena, module, s.condition, info, result);
            try walkBody(arena, module, s.body, info, result);
            if (s.else_branch) |e| try walkStmt(arena, module, e, info, result);
        },
        .@"switch" => |s| {
            try walkExpr(arena, module, s.expr, info, result);
            for (s.cases.items) |c| {
                for (c.selectors.items) |sel| try walkExpr(arena, module, sel, info, result);
                try walkBody(arena, module, c.body, info, result);
            }
        },
        .@"for" => |s| {
            if (s.init_stmt) |i| try walkStmt(arena, module, i, info, result);
            if (s.condition) |c| try walkExpr(arena, module, c, info, result);
            if (s.update) |u| try walkStmt(arena, module, u, info, result);
            try walkBody(arena, module, s.body, info, result);
        },
        .@"while" => |s| {
            try walkExpr(arena, module, s.condition, info, result);
            try walkBody(arena, module, s.body, info, result);
        },
        .loop => |s| {
            try walkBody(arena, module, s.body, info, result);
            if (s.continuing) |c| try walkBody(arena, module, c, info, result);
        },
        .break_if => |s| try walkExpr(arena, module, s.condition, info, result),
        .assign => |s| {
            try walkExpr(arena, module, s.left, info, result);
            try walkExpr(arena, module, s.right, info, result);
        },
        // TODO(block-2): attribute resources named by the phony RHS.
        .phony => {},
        .incr_decr => |s| try walkExpr(arena, module, s.expr, info, result),
        .call => |s| {
            // CallStmt wraps a CallExpr directly.
            try walkExpr(arena, module, .{ .call = s.call }, info, result);
        },
        .decl => |s| try walkDeclStmt(arena, module, s, info, result),
        .@"break", .@"continue", .discard => {},
    }
}

fn walkDeclStmt(
    arena: Allocator,
    module: *Ast.Module,
    s: *Ast.DeclStmt,
    info: *FunctionInfo,
    result: *ReflectResult,
) Allocator.Error!void {
    switch (s.decl) {
        .@"const" => |d| if (d.initializer) |e| try walkExpr(arena, module, e, info, result),
        .let => |d| if (d.initializer) |e| try walkExpr(arena, module, e, info, result),
        .@"var" => |d| if (d.initializer) |e| try walkExpr(arena, module, e, info, result),
        else => {},
    }
}

fn walkExpr(
    arena: Allocator,
    module: *Ast.Module,
    expr: Ast.Expr,
    info: *FunctionInfo,
    result: *ReflectResult,
) Allocator.Error!void {
    switch (expr) {
        .literal => {},
        .ident => |id| try recordIdent(arena, module, id, info, result),
        .paren => |p| try walkExpr(arena, module, p.expr, info, result),
        .unary => |u| try walkExpr(arena, module, u.operand, info, result),
        .binary => |b| {
            try walkExpr(arena, module, b.left, info, result);
            try walkExpr(arena, module, b.right, info, result);
        },
        .member => |m| try walkExpr(arena, module, m.base, info, result),
        .index => |ix| {
            try walkExpr(arena, module, ix.base, info, result);
            try walkExpr(arena, module, ix.idx, info, result);
        },
        .call => |c| {
            // Callee — record outgoing call if it resolves to a user fn.
            if (c.func) |f| switch (f) {
                .ident => |id| try recordCallee(arena, module, id, c, info, result),
                else => try walkExpr(arena, module, f, info, result),
            };
            for (c.args.items) |arg| try walkExpr(arena, module, arg, info, result);
        },
    }
}

/// Is this symbol one of the `@group/@binding` declarations that were
/// already extracted into `result.bindings`?
///
/// Matching on the declaration's byte offset — not its name — is what keeps
/// a function-local `var` that shadows a binding out of the resource list:
/// same name, different declaration site, different `loc`.
///
/// The obvious-looking predicate, `sym.flags.is_external_binding`, is the
/// wrong one and was the source of a real bug: the parser sets that flag
/// from the *address space* (`uniform`/`storage` only, `Parser.zig`), so
/// every texture and sampler failed it and no entry point ever listed one.
/// Widening the flag was not an option — it also drives rename policy, the
/// validator and five lint rules. Deferring to the extracted bindings makes
/// "is a resource" mean "is a binding we reported", which is the property
/// callers actually rely on.
fn isBindingSymbol(sym: *const Ast.Symbol, result: *const ReflectResult) bool {
    for (result.bindings.items) |b| {
        if (b.name_offset == sym.loc) return true;
    }
    return false;
}

fn recordIdent(
    arena: Allocator,
    module: *Ast.Module,
    id: *Ast.IdentExpr,
    info: *FunctionInfo,
    result: *const ReflectResult,
) Allocator.Error!void {
    if (!id.ref.isValid()) return;
    const idx = id.ref.index();
    if (idx >= module.symbols.items.len) return;
    const sym = &module.symbols.items[idx];
    switch (sym.kind) {
        .@"var" => {
            // Only module-scope `@group/@binding var<>` declarations are
            // resources. `private`/`workgroup` module vars and every
            // function-local `var` share this `kind` and must not appear.
            if (isBindingSymbol(sym, result)) {
                try appendUnique(arena, &info.direct_resources, sym.original_name);
            }
        },
        .override => try appendUnique(arena, &info.direct_overrides, sym.original_name),
        else => {},
    }
}

fn recordCallee(
    arena: Allocator,
    module: *Ast.Module,
    id: *Ast.IdentExpr,
    call: *Ast.CallExpr,
    info: *FunctionInfo,
    result: *ReflectResult,
) Allocator.Error!void {
    if (!id.ref.isValid()) {
        // Texture sampling builtins resolve via name when ref is unset.
        try maybeRecordTextureSamplerPair(arena, module, id.name, call, result);
        return;
    }
    const idx = id.ref.index();
    if (idx >= module.symbols.items.len) return;
    const sym = &module.symbols.items[idx];
    switch (sym.kind) {
        .function => try appendUnique(arena, &info.calls, sym.original_name),
        .builtin => try maybeRecordTextureSamplerPair(arena, module, id.name, call, result),
        else => {},
    }
}

/// When `name` is a texture-sampling builtin and `args[0..2]` resolve
/// to bindings, record the (texture, sampler) pair on both bindings'
/// `relations` lists.
fn maybeRecordTextureSamplerPair(
    arena: Allocator,
    module: *Ast.Module,
    name: []const u8,
    call: *Ast.CallExpr,
    result: *ReflectResult,
) Allocator.Error!void {
    if (!sampler_pair_builtins.has(name)) return;
    if (call.args.items.len < 2) return;
    const tex_idx = identArgSymIdx(call.args.items[0]) orelse return;
    const samp_idx = identArgSymIdx(call.args.items[1]) orelse return;
    const tex_name = symbolName(module, tex_idx) orelse return;
    const samp_name = symbolName(module, samp_idx) orelse return;

    var tex_binding: ?*BindingInfo = null;
    var samp_binding: ?*BindingInfo = null;
    for (result.bindings.items) |*b| {
        if (std.mem.eql(u8, b.name, tex_name)) tex_binding = b;
        if (std.mem.eql(u8, b.name, samp_name)) samp_binding = b;
    }
    if (tex_binding) |tb| try appendUnique(arena, &tb.relations, samp_name);
    if (samp_binding) |sb| try appendUnique(arena, &sb.relations, tex_name);
}

fn identArgSymIdx(arg: Ast.Expr) ?u32 {
    if (arg != .ident) return null;
    const id = arg.ident;
    if (!id.ref.isValid()) return null;
    return id.ref.index();
}

fn symbolName(module: *Ast.Module, idx: u32) ?[]const u8 {
    if (idx >= module.symbols.items.len) return null;
    return module.symbols.items[idx].original_name;
}

fn appendUnique(arena: Allocator, list: *std.ArrayList([]const u8), name: []const u8) Allocator.Error!void {
    if (name.len == 0) return;
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try list.append(arena, name);
}

/// BFS from each entry point through `FunctionInfo.calls`. Marks every
/// reachable function `in_use = true`, unions `direct_resources` /
/// `direct_overrides` into the entry point's transitive lists.
pub fn propagateEntryReachability(arena: Allocator, result: *ReflectResult) Allocator.Error!void {
    if (result.functions.items.len == 0) return;

    // Index functions by name for O(1) call edge lookup.
    var by_name: std.StringHashMapUnmanaged(u32) = .empty;
    defer by_name.deinit(arena);
    for (result.functions.items, 0..) |*f, i| {
        try by_name.put(arena, f.name, @intCast(i));
    }

    for (result.entry_points.items) |*ep| {
        const start_idx = by_name.get(ep.name) orelse continue;
        var visited = try arena.alloc(bool, result.functions.items.len);
        defer arena.free(visited);
        @memset(visited, false);

        var queue: std.ArrayList(u32) = .empty;
        defer queue.deinit(arena);
        try queue.append(arena, start_idx);
        visited[start_idx] = true;

        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const fi = queue.items[head];
            const f = &result.functions.items[fi];
            f.in_use = true;
            for (f.direct_resources.items) |r| try appendUnique(arena, &ep.resources, r);
            for (f.direct_overrides.items) |o| try appendUnique(arena, &ep.overrides, o);
            for (f.calls.items) |callee| {
                if (by_name.get(callee)) |ci| {
                    if (!visited[ci]) {
                        visited[ci] = true;
                        try queue.append(arena, ci);
                    }
                }
            }
        }
    }
}
