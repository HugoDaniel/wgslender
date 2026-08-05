//! Completion: produce candidate items for `@`, `.`, and global trigger
//! contexts. Owns the static lists of WGSL builtin type names and
//! attribute names.

const std = @import("std");
const wgslender = @import("wgslender");

const Handler = @import("../Handler.zig");
const NodeAtOffset = @import("node_at_offset.zig");
const Position = Handler.Position;
const Builtins = wgslender.Builtins;
const Lexer = wgslender.Lexer;
const Ast = wgslender.Ast;

pub const CompletionItem = struct {
    label: []const u8,
    kind: CompletionKind,
    detail: []const u8 = "",
};

pub const CompletionKind = enum(u8) {
    variable,
    function,
    struct_type,
    field,
    keyword,
    builtin,
    type_name,
    attribute,
};

// The predeclared type-name inventory lives in `Predeclared.zig` (shared
// with the Parser/Validator). Completion offers the full set,
// including `texture_external`.
const wgsl_type_names = wgslender.Predeclared.all_type_names;

const wgsl_attributes = [_][]const u8{
    "align",    "binding",     "builtin",   "compute",
    "const",    "diagnostic",  "fragment",  "group",
    "id",       "interpolate", "invariant", "location",
    "must_use", "size",        "vertex",    "workgroup_size",
};

pub fn computeCompletion(handler: *Handler, uri: []const u8, position: Position) ![]CompletionItem {
    const doc = handler.documents.getPtr(uri) orelse return &.{};
    const source = doc.source;
    const offset: u32 = @intCast(Handler.lspPositionToOffset(source, position) orelse return &.{});

    // Check trigger context
    if (offset > 0 and source[offset - 1] == '@') {
        return attributeCompletion(handler);
    }

    if (offset > 0 and source[offset - 1] == '.') {
        return memberCompletion(handler, uri, source, offset);
    }

    return generalCompletion(handler, uri, offset);
}

fn attributeCompletion(handler: *Handler) ![]CompletionItem {
    const items = try handler.gpa.alloc(CompletionItem, wgsl_attributes.len);
    for (wgsl_attributes, 0..) |attr, i| {
        items[i] = .{ .label = attr, .kind = .attribute };
    }
    return items;
}

fn memberCompletion(handler: *Handler, uri: []const u8, source: []const u8, dot_offset: u32) ![]CompletionItem {
    // Find the identifier before the dot
    var start = dot_offset - 1;
    if (start > 0 and source[start] == '.') start -= 1; // skip the dot
    while (start > 0 and (std.ascii.isAlphanumeric(source[start - 1]) or source[start - 1] == '_')) start -= 1;
    const base_name = source[start .. dot_offset - 1];
    if (base_name.len == 0) return &.{};

    // Try to resolve the base type via analysis
    const analysis = handler.analyzeDocument(uri) catch return &.{};
    const module = analysis.module orelse return &.{};

    // Resolve the base identifier's type. The AST knows which declaration
    // is actually visible here, so a shadowed local resolves correctly —
    // but only when the base identifier survived parsing.
    var base_type: ?wgslender.Types.Type = null;
    switch (NodeAtOffset.find(module, start)) {
        .ident => |id| {
            if (id.ref.isValid()) base_type = analysis.symbol_types.get(id.ref.index());
        },
        else => {},
    }

    // Fall back to a whole-module name match. This is load-bearing, not
    // vestigial: the state completion actually fires in is `p.` with
    // nothing after the dot, and error recovery drops that whole statement
    // — so the AST has no node at this offset at all. The name match can
    // pick the wrong same-named symbol, but wrong fields beat no fields.
    if (base_type == null) {
        for (module.symbols.items, 0..) |sym, idx| {
            if (std.mem.eql(u8, sym.original_name, base_name)) {
                base_type = analysis.symbol_types.get(@intCast(idx));
                break;
            }
        }
    }

    if (base_type) |bt| {
        switch (bt) {
            .@"struct" => |st| {
                const items = try handler.gpa.alloc(CompletionItem, st.fields.len);
                for (st.fields, 0..) |field, i| {
                    items[i] = .{ .label = field.name, .kind = .field, .detail = field.typ.string() };
                }
                return items;
            },
            .vector => {
                // Vector swizzle components
                const swizzles = [_][]const u8{ "x", "y", "z", "w", "r", "g", "b", "a" };
                const items = try handler.gpa.alloc(CompletionItem, swizzles.len);
                for (swizzles, 0..) |s, i| {
                    items[i] = .{ .label = s, .kind = .field };
                }
                return items;
            },
            else => {},
        }
    }

    return &.{};
}

/// The symbols a cursor can actually name, beyond the module-level ones.
///
/// WGSL has no hoisting and no block-scoped globals, so this is exactly:
/// the enclosing function's parameters, plus every `let`/`var` declared in
/// an enclosing block at a position textually before the cursor. Empty at
/// module level.
const VisibleLocals = struct {
    set: std.AutoHashMapUnmanaged(u32, void) = .empty,

    fn deinit(self: *VisibleLocals, gpa: std.mem.Allocator) void {
        self.set.deinit(gpa);
    }

    fn contains(self: *const VisibleLocals, idx: u32) bool {
        return self.set.contains(idx);
    }

    fn add(self: *VisibleLocals, gpa: std.mem.Allocator, ref: Ast.SymbolIndex) void {
        if (!ref.isValid()) return;
        self.set.put(gpa, ref.index(), {}) catch {};
    }

    fn collect(gpa: std.mem.Allocator, module: *const Ast.Module, offset: u32) VisibleLocals {
        var self: VisibleLocals = .{};
        for (module.declarations.items) |decl| {
            const f = switch (decl) {
                .function => |f| f,
                else => continue,
            };
            const body = f.body orelse continue;
            if (!spanContains(body.span, offset)) continue;

            // A parameter is in scope for the whole body.
            for (f.parameters.items) |param| self.add(gpa, param.name);
            self.collectFromCompound(gpa, body, offset);
            break;
        }
        return self;
    }

    fn collectFromCompound(self: *VisibleLocals, gpa: std.mem.Allocator, compound: *const Ast.CompoundStmt, offset: u32) void {
        for (compound.stmts.items) |stmt| self.collectFromStmt(gpa, stmt, offset);
    }

    fn collectFromStmt(self: *VisibleLocals, gpa: std.mem.Allocator, stmt: Ast.Stmt, offset: u32) void {
        switch (stmt) {
            // A declaration is visible only from its own position onward.
            // One after the cursor has `start > offset`, so this also stops
            // statements in already-passed sibling blocks from leaking in.
            .decl => |d| {
                if (d.decl.declSpan().start <= offset) self.add(gpa, d.decl.nameRef());
            },
            .compound => |c| self.descend(gpa, c, offset),
            .@"if" => |i| {
                self.descend(gpa, i.body, offset);
                if (i.else_branch) |eb| self.collectFromStmt(gpa, eb, offset);
            },
            .@"for" => |f| {
                if (!spanContains(f.body.span, offset)) return;
                // `init_stmt` is a bare Stmt, not a CompoundStmt — its
                // declaration would be missed by the descent alone.
                if (f.init_stmt) |init_s| self.collectFromStmt(gpa, init_s, offset);
                self.collectFromCompound(gpa, f.body, offset);
            },
            .@"while" => |w| self.descend(gpa, w.body, offset),
            .loop => |l| {
                self.descend(gpa, l.body, offset);
                // `continuing` runs after the body, so the body's
                // declarations are all in scope there.
                if (l.continuing) |cont| {
                    if (spanContains(cont.span, offset)) {
                        self.collectFromCompound(gpa, l.body, offset);
                        self.collectFromCompound(gpa, cont, offset);
                    }
                }
            },
            .@"switch" => |s| {
                for (s.cases.items) |case| self.descend(gpa, case.body, offset);
            },
            else => {},
        }
    }

    fn descend(self: *VisibleLocals, gpa: std.mem.Allocator, compound: *const Ast.CompoundStmt, offset: u32) void {
        if (!spanContains(compound.span, offset)) return;
        self.collectFromCompound(gpa, compound, offset);
    }
};

fn spanContains(span: Ast.Span, offset: u32) bool {
    return !span.isEmpty() and offset >= span.start and offset < span.end;
}

/// Symbol indices declared by a top-level declaration. Everything else of
/// `let`/`var`/`parameter` kind belongs to some function body.
fn collectModuleLevel(gpa: std.mem.Allocator, module: *const Ast.Module) std.AutoHashMapUnmanaged(u32, void) {
    var set: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (module.declarations.items) |decl| {
        const ref = decl.nameRef();
        if (ref.isValid()) set.put(gpa, ref.index(), {}) catch {};
    }
    return set;
}

fn generalCompletion(handler: *Handler, uri: []const u8, offset: u32) ![]CompletionItem {
    var items: std.ArrayList(CompletionItem) = .empty;
    defer items.deinit(handler.gpa);

    // Module-level symbols from analysis, plus whatever locals are in scope
    // at the cursor.
    if (handler.analyzeDocument(uri)) |analysis| {
        if (analysis.module) |module| {
            var visible = VisibleLocals.collect(handler.gpa, module, offset);
            defer visible.deinit(handler.gpa);
            var module_level = collectModuleLevel(handler.gpa, module);
            defer module_level.deinit(handler.gpa);

            for (module.symbols.items, 0..) |sym, idx| {
                if (sym.original_name.len == 0) continue;
                const kind: CompletionKind = switch (sym.kind) {
                    .function => .function,
                    .@"struct" => .struct_type,
                    .parameter, .let, .@"var" => blk: {
                        // Module-scope `var`s stay visible everywhere;
                        // function-local names only where they're in scope.
                        const i: u32 = @intCast(idx);
                        if (!module_level.contains(i) and !visible.contains(i)) continue;
                        break :blk .variable;
                    },
                    .@"const", .override => .variable,
                    else => continue,
                };
                const detail = if (analysis.symbol_types.get(@intCast(idx))) |t| t.string() else "";
                try items.append(handler.gpa, .{ .label = sym.original_name, .kind = kind, .detail = detail });
            }
        }
    } else |_| {}

    // Builtin functions
    for (Builtins.names()) |name| {
        try items.append(handler.gpa, .{ .label = name, .kind = .builtin });
    }

    // Keywords
    for (Lexer.keywords_map.keys()) |kw| {
        try items.append(handler.gpa, .{ .label = kw, .kind = .keyword });
    }

    // Built-in type names
    for (&wgsl_type_names) |tn| {
        try items.append(handler.gpa, .{ .label = tn, .kind = .type_name });
    }

    return try handler.gpa.dupe(CompletionItem, items.items);
}
