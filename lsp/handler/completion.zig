//! Completion: produce candidate items for `@`, `.`, and global trigger
//! contexts. Owns the static lists of WGSL builtin type names and
//! attribute names.

const std = @import("std");
const wgslender = @import("wgslender");
const build_options = @import("build_options");

const Handler = @import("../Handler.zig");
const PngineContext = @import("pngine_context.zig");
const NodeAtOffset = @import("node_at_offset.zig");
const Position = Handler.Position;
const Builtins = wgslender.Builtins;
const Lexer = wgslender.Lexer;
const Ast = wgslender.Ast;

const pngine_support = build_options.pngine_support;

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
    // Project members answer from every containing root's assembled unit
    // (pngine-shaders phase 04, Task 4). A standalone document — and a
    // member whose root cannot honestly map this position — keeps the
    // original single-document path byte-for-byte.
    if (comptime pngine_support) {
        const contexts = try PngineContext.contextsForCompletion(handler, uri, position);
        defer Handler.freeContexts(handler, contexts);
        if (contexts.len > 0 and contexts[0].isComposed()) {
            return composedCompletion(handler, contexts, position);
        }
    }
    return standaloneCompletion(handler, uri, position);
}

/// Complete at a position in a part-addressed document (an inline `:code`
/// part). Only the label/kind/detail items exist — `CompletionItem` has no
/// location field, so no URI is attached; a virtual-document request goes
/// through `computeCompletion` with the virtual URI instead.
pub fn computeCompletionForPart(
    handler: *Handler,
    part: PngineContext.OriginKey,
    position: Position,
) ![]CompletionItem {
    if (comptime pngine_support) {
        const contexts = try PngineContext.contextsForPartCompletion(handler, part, position);
        defer Handler.freeContexts(handler, contexts);
        if (contexts.len == 0) return &.{};
        return composedCompletion(handler, contexts, position);
    } else {
        return error.PngineUnsupported;
    }
}

fn standaloneCompletion(handler: *Handler, uri: []const u8, position: Position) ![]CompletionItem {
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

/// Completion for one or more composed contexts. The trigger and cursor are
/// read from the request document's own text; the payload is assembled per
/// root. `position` may sit one byte past the part text (a just-typed
/// trailing `@`/`.`), in which case the contexts anchored on the previous
/// author byte but the trigger offset is still the real cursor.
fn composedCompletion(
    handler: *Handler,
    contexts: []Handler.RequestContext,
    position: Position,
) ![]CompletionItem {
    std.debug.assert(contexts.len > 0);

    var author = try PngineContext.authorText(handler, &contexts[0]);
    defer author.deinit(handler.gpa);
    const source = author.text;
    const offset_usize = Handler.lspPositionToOffset(source, position) orelse return &.{};
    if (offset_usize > std.math.maxInt(u32)) return &.{};
    const offset: u32 = @intCast(offset_usize);

    if (offset > 0 and source[offset - 1] == '@') {
        return attributeCompletion(handler);
    }
    if (offset > 0 and source[offset - 1] == '.') {
        return composedMemberCompletion(handler, contexts, source, offset);
    }
    return composedGeneralCompletion(handler, contexts);
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
            // A tombstone can shadow the active declaration by name; its
            // type entry no longer exists (analysis runs on the active AST),
            // so matching it would return no fields at all.
            if (sym.flags.is_retired) continue;
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
                return swizzleCompletion(handler);
            },
            else => {},
        }
    }

    return &.{};
}

fn swizzleCompletion(handler: *Handler) ![]CompletionItem {
    const swizzles = [_][]const u8{ "x", "y", "z", "w", "r", "g", "b", "a" };
    const items = try handler.gpa.alloc(CompletionItem, swizzles.len);
    for (swizzles, 0..) |s, i| {
        items[i] = .{ .label = s, .kind = .field };
    }
    return items;
}

/// Member completion across every containing root. Each context first
/// resolves the base through the mapped AST/symbol. Only when error
/// recovery dropped the statement does the name fallback run — and then it
/// considers active, visible symbols only, requires one compatible type per
/// root, and requires the roots to agree on that type's fields. A
/// disagreement returns no fields at all; picking the first root's symbol
/// is never an option (N30).
fn composedMemberCompletion(
    handler: *Handler,
    contexts: []Handler.RequestContext,
    source: []const u8,
    dot_offset: u32,
) ![]CompletionItem {
    // Find the identifier before the dot, exactly as the standalone path.
    var start = dot_offset - 1;
    if (start > 0 and source[start] == '.') start -= 1; // skip the dot
    while (start > 0 and (std.ascii.isAlphanumeric(source[start - 1]) or source[start - 1] == '_')) start -= 1;
    const base_name = source[start .. dot_offset - 1];
    if (base_name.len == 0) return &.{};

    var fields: ?*const wgslender.Types.Struct = null;
    var swizzle = false;
    var non_member = false;
    var conflict = false;

    for (contexts) |*context| {
        const analysis = PngineContext.analysisFor(handler, context) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        const module = analysis.module orelse continue;

        var base_type: ?wgslender.Types.Type = null;
        var visible = VisibleLocals.collect(handler.gpa, module, context.assembled_offset);
        defer visible.deinit(handler.gpa);
        var module_level = collectModuleLevel(handler.gpa, module);
        defer module_level.deinit(handler.gpa);

        if (PngineContext.assembledOffsetFor(context, start)) |assembled_start| {
            switch (NodeAtOffset.find(module, assembled_start)) {
                .ident => |id| {
                    // The AST binding is authoritative when it survived
                    // parsing; error recovery otherwise leaves no node here
                    // and the restricted name fallback below answers.
                    if (id.ref.isValid()) {
                        base_type = analysis.symbol_types.get(id.ref.index());
                    }
                },
                else => {},
            }
        }

        if (base_type == null) {
            switch (fallbackMemberBase(analysis, module, base_name, &visible, &module_level)) {
                .type => |typ| base_type = typ,
                .none => continue,
                .ambiguous => {
                    conflict = true;
                    continue;
                },
            }
        }
        const resolved = base_type.?;
        switch (resolved) {
            .@"struct" => |st| {
                if (swizzle or non_member) {
                    conflict = true;
                    continue;
                }
                if (fields) |previous| {
                    if (!structFieldsCompatible(previous, st)) conflict = true;
                } else {
                    fields = st;
                }
            },
            .vector => {
                if (fields != null or non_member) conflict = true;
                swizzle = true;
            },
            else => {
                // A root that names a non-member-bearing type disagrees
                // with one that names fields; a lone such answer is simply
                // empty, as in the standalone path.
                if (fields != null or swizzle) conflict = true;
                non_member = true;
            },
        }
    }

    if (conflict) return &.{};
    if (fields) |st| return structFieldCompletion(handler, st);
    if (swizzle) return swizzleCompletion(handler);
    return &.{};
}

const MemberBase = union(enum) {
    type: wgslender.Types.Type,
    none,
    ambiguous,
};

/// The error-recovery fallback: the base identifier did not survive
/// parsing, so the module's active symbols carrying that name are the only
/// evidence left. A visible local wins; module-scope candidates must agree
/// on one member-bearing type. Incompatible active candidates make the
/// answer ambiguous rather than order-dependent.
fn fallbackMemberBase(
    analysis: *const wgslender.Validator.AnalysisResult,
    module: *const Ast.Module,
    base_name: []const u8,
    visible: *const VisibleLocals,
    module_level: *const std.AutoHashMapUnmanaged(u32, void),
) MemberBase {
    var chosen: ?wgslender.Types.Type = null;
    var chosen_is_local = false;
    var ambiguous = false;

    for (module.symbols.items, 0..) |sym, idx| {
        // Tombstones share names with active replacement declarations and
        // no longer have a type; they are never candidates.
        if (sym.flags.is_retired) continue;
        if (!std.mem.eql(u8, sym.original_name, base_name)) continue;

        const symbol_index: u32 = @intCast(idx);
        const is_local = switch (sym.kind) {
            .parameter, .let, .@"var" => !module_level.contains(symbol_index),
            else => false,
        };
        if (is_local and !visible.contains(symbol_index)) continue;

        const type_info = analysis.symbol_types.get(symbol_index);
        if (is_local) {
            const member_bearing = if (type_info) |typ| switch (typ) {
                .@"struct", .vector => true,
                else => false,
            } else false;
            if (!member_bearing) {
                // A visible local shadows an outer name even when it cannot
                // yield fields. Falling through to a module declaration
                // would complete a name the cursor cannot see.
                chosen = null;
                chosen_is_local = true;
                ambiguous = false;
                continue;
            }
            const typ = type_info.?;
            // A visible local shadows every module-scope name.
            if (chosen_is_local) {
                if (chosen == null or !memberTypeCompatible(chosen.?, typ)) ambiguous = true;
            } else {
                chosen = typ;
                chosen_is_local = true;
                ambiguous = false;
            }
            continue;
        }
        if (chosen_is_local) continue;

        const typ = type_info orelse continue;
        switch (typ) {
            .@"struct", .vector => {},
            else => continue,
        }
        if (chosen) |existing| {
            if (!memberTypeCompatible(existing, typ)) ambiguous = true;
        } else {
            chosen = typ;
        }
    }

    if (ambiguous) return .ambiguous;
    if (chosen) |typ| return .{ .type = typ };
    return .none;
}

/// Two roots may name the same struct while defining different fields (a
/// root-supplied hole). The name alone is not enough for a member answer.
fn memberTypeCompatible(a: wgslender.Types.Type, b: wgslender.Types.Type) bool {
    if (!a.eql(b)) return false;
    return switch (a) {
        .@"struct" => |sa| switch (b) {
            .@"struct" => |sb| structFieldsCompatible(sa, sb),
            else => false,
        },
        else => true,
    };
}

fn structFieldsCompatible(a: *const wgslender.Types.Struct, b: *const wgslender.Types.Struct) bool {
    if (a.fields.len != b.fields.len) return false;
    for (a.fields, b.fields) |left, right| {
        if (!std.mem.eql(u8, left.name, right.name)) return false;
        if (!left.typ.eql(right.typ)) return false;
    }
    return true;
}

fn structFieldCompletion(handler: *Handler, st: *const wgslender.Types.Struct) ![]CompletionItem {
    const items = try handler.gpa.alloc(CompletionItem, st.fields.len);
    for (st.fields, 0..) |field, i| {
        items[i] = .{ .label = field.name, .kind = .field, .detail = field.typ.string() };
    }
    return items;
}

const ScopedItem = struct {
    label: []const u8,
    kind: CompletionKind,
    detail: []const u8,
};

const MergedItem = struct {
    label: []const u8,
    kind: CompletionKind,
    detail: []const u8,
    /// Two roots (or two active declarations) disagree on this label's
    /// kind or non-empty type detail. The label is then not offered at all
    /// rather than resolved by root/document order.
    conflict: bool = false,
};

fn findMerged(items: []MergedItem, label: []const u8) ?*MergedItem {
    for (items) |*item| {
        if (std.mem.eql(u8, item.label, label)) return item;
    }
    return null;
}

/// Merge one completion group by label. Empty details are unknown and
/// compatible with anything; two different non-empty details conflict.
/// `shadowed_len` is the number of entries already owned by a higher
/// priority group (visible locals): labels in that prefix are not duplicated
/// or replaced by this group.
fn mergeScopedItems(
    gpa: std.mem.Allocator,
    merged: *std.ArrayList(MergedItem),
    items: []const ScopedItem,
    shadowed_len: usize,
) !void {
    for (items) |item| {
        if (findMerged(merged.items[0..shadowed_len], item.label) != null) continue;
        if (findMerged(merged.items, item.label)) |existing| {
            if (existing.conflict) continue;
            if (existing.kind != item.kind) {
                existing.conflict = true;
                continue;
            }
            if (item.detail.len == 0) continue;
            if (existing.detail.len == 0) {
                existing.detail = item.detail;
            } else if (!std.mem.eql(u8, existing.detail, item.detail)) {
                existing.conflict = true;
            }
            continue;
        }
        try merged.append(gpa, .{ .label = item.label, .kind = item.kind, .detail = item.detail });
    }
}

/// General completion over every containing root. `VisibleLocals` is
/// collected per root at that root's assembled offset — the symbol indices
/// are root-local and the offsets differ with assembly order. Locals merge
/// first so a visible local shadows a library name with one label.
fn composedGeneralCompletion(handler: *Handler, contexts: []Handler.RequestContext) ![]CompletionItem {
    var locals: std.ArrayList(ScopedItem) = .empty;
    defer locals.deinit(handler.gpa);
    var globals: std.ArrayList(ScopedItem) = .empty;
    defer globals.deinit(handler.gpa);

    for (contexts) |*context| {
        const analysis = PngineContext.analysisFor(handler, context) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        const module = analysis.module orelse continue;

        var visible = VisibleLocals.collect(handler.gpa, module, context.assembled_offset);
        defer visible.deinit(handler.gpa);
        var module_level = collectModuleLevel(handler.gpa, module);
        defer module_level.deinit(handler.gpa);

        for (module.symbols.items, 0..) |sym, idx| {
            // Detached declarations are not visible at any cursor.
            if (sym.flags.is_retired) continue;
            if (sym.original_name.len == 0) continue;

            const symbol_index: u32 = @intCast(idx);
            const detail = if (analysis.symbol_types.get(symbol_index)) |t| t.string() else "";
            const label = sym.original_name;

            switch (sym.kind) {
                .function => try globals.append(handler.gpa, .{ .label = label, .kind = .function, .detail = detail }),
                .@"struct" => try globals.append(handler.gpa, .{ .label = label, .kind = .struct_type, .detail = detail }),
                .parameter, .let, .@"var" => {
                    // Module-scope `var`s stay visible everywhere;
                    // function-local names only where they're in scope at
                    // this root's assembled cursor offset.
                    if (module_level.contains(symbol_index)) {
                        try globals.append(handler.gpa, .{ .label = label, .kind = .variable, .detail = detail });
                    } else if (visible.contains(symbol_index)) {
                        try locals.append(handler.gpa, .{ .label = label, .kind = .variable, .detail = detail });
                    }
                },
                .@"const", .override => try globals.append(handler.gpa, .{ .label = label, .kind = .variable, .detail = detail }),
                else => {},
            }
        }
    }

    var merged: std.ArrayList(MergedItem) = .empty;
    defer merged.deinit(handler.gpa);
    try mergeScopedItems(handler.gpa, &merged, locals.items, 0);
    const local_labels = merged.items.len;
    try mergeScopedItems(handler.gpa, &merged, globals.items, local_labels);

    var items: std.ArrayList(CompletionItem) = .empty;
    defer items.deinit(handler.gpa);
    for (merged.items) |entry| {
        if (entry.conflict) continue;
        try items.append(handler.gpa, .{ .label = entry.label, .kind = entry.kind, .detail = entry.detail });
    }
    try appendStaticCompletions(handler, &items);
    return try handler.gpa.dupe(CompletionItem, items.items);
}

/// The standalone inventories every completion path ends with, in the same
/// order and with the same kinds/details.
fn appendStaticCompletions(handler: *Handler, items: *std.ArrayList(CompletionItem)) !void {
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
                // Detached declarations are not visible at any cursor.
                if (sym.flags.is_retired) continue;
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

    // Builtin functions, keywords, and built-in type names — shared with
    // the composed path so the inventories cannot drift.
    try appendStaticCompletions(handler, &items);

    return try handler.gpa.dupe(CompletionItem, items.items);
}
