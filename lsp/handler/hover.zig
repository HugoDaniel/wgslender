//! Hover: build the markdown content shown when the cursor lingers
//! over a symbol, type, or expression.

const std = @import("std");
const wgslender = @import("wgslender");

const Handler = @import("../Handler.zig");
const NodeAtOffset = @import("node_at_offset.zig");
const Position = Handler.Position;
const Range = Handler.Range;
const Ast = wgslender.Ast;
const Builtins = wgslender.Builtins;

pub const HoverResult = struct {
    contents: []const u8,
    range: Range,
};

pub const DocumentHighlight = struct {
    range: Range,
    kind: HighlightKind,
};

pub const HighlightKind = enum(u8) {
    text = 1,
    read = 2,
    write = 3,
};

pub fn computeHover(handler: *Handler, uri: []const u8, position: Position) !?HoverResult {
    const doc = handler.documents.getPtr(uri) orelse return null;
    const source = doc.source;
    const offset: u32 = @intCast(Handler.lspPositionToOffset(source, position) orelse return null);
    const analysis = try handler.analyzeDocument(uri);
    const module = analysis.module orelse return null;

    const node = NodeAtOffset.find(module, offset);
    var buf: [1024]u8 = undefined;
    switch (node) {
        .ident => |id| {
            if (!id.ref.isValid()) {
                // Check if this is a builtin function name
                if (Builtins.lookup(id.name)) |builtin| {
                    const contents = try formatBuiltinHover(handler, &buf, id.name, builtin);
                    return .{
                        .contents = contents,
                        .range = Handler.offsetRangeToLspRange(source, id.loc, id.loc + @as(u32, @intCast(id.name.len))) orelse return null,
                    };
                }
                return null;
            }
            const sym = module.symbols.items[id.ref.index()];
            const kind_str = @tagName(sym.kind);
            const contents: []const u8 = blk: {
                if (analysis.symbol_types.get(id.ref.index())) |t| {
                    // For functions, show full signature
                    if (t == .function) {
                        if (formatFunctionSignature(&buf, module, id.ref, t.function)) |sig| {
                            break :blk try handler.gpa.dupe(u8, sig);
                        }
                    }
                    const type_str = t.string();
                    // For consts, show value if known
                    if (sym.kind == .@"const") {
                        if (analysis.const_values.get(id.ref.index())) |val| {
                            const len = (std.fmt.bufPrint(&buf, "({s}) {s}: {s} = {d}", .{ kind_str, id.name, type_str, val }) catch return null).len;
                            break :blk try handler.gpa.dupe(u8, buf[0..len]);
                        }
                    }
                    const len = (std.fmt.bufPrint(&buf, "({s}) {s}: {s}", .{ kind_str, id.name, type_str }) catch return null).len;
                    break :blk try handler.gpa.dupe(u8, buf[0..len]);
                }
                const len = (std.fmt.bufPrint(&buf, "({s}) {s}: unknown", .{ kind_str, id.name }) catch return null).len;
                break :blk try handler.gpa.dupe(u8, buf[0..len]);
            };
            return .{
                .contents = contents,
                .range = Handler.offsetRangeToLspRange(source, id.loc, id.loc + @as(u32, @intCast(id.name.len))) orelse return null,
            };
        },
        .decl_name => |dn| {
            if (!dn.sym_idx.isValid()) return null;
            const sym = module.symbols.items[dn.sym_idx.index()];
            const kind_str = @tagName(sym.kind);
            const contents: []const u8 = blk: {
                if (analysis.symbol_types.get(dn.sym_idx.index())) |t| {
                    // For functions, show full signature
                    if (t == .function) {
                        if (formatFunctionSignature(&buf, module, dn.sym_idx, t.function)) |sig| {
                            break :blk try handler.gpa.dupe(u8, sig);
                        }
                    }
                    const type_str = t.string();
                    // For consts, show value if known
                    if (sym.kind == .@"const") {
                        if (analysis.const_values.get(dn.sym_idx.index())) |val| {
                            const len = (std.fmt.bufPrint(&buf, "({s}) {s}: {s} = {d}", .{ kind_str, sym.original_name, type_str, val }) catch return null).len;
                            break :blk try handler.gpa.dupe(u8, buf[0..len]);
                        }
                    }
                    const len = (std.fmt.bufPrint(&buf, "({s}) {s}: {s}", .{ kind_str, sym.original_name, type_str }) catch return null).len;
                    break :blk try handler.gpa.dupe(u8, buf[0..len]);
                }
                const len = (std.fmt.bufPrint(&buf, "({s}) {s}", .{ kind_str, sym.original_name }) catch return null).len;
                break :blk try handler.gpa.dupe(u8, buf[0..len]);
            };
            return .{
                .contents = contents,
                .range = Handler.offsetRangeToLspRange(source, dn.loc, dn.loc + @as(u32, @intCast(sym.original_name.len))) orelse return null,
            };
        },
        .type_ref => |tr| {
            if (analysis.struct_types.get(tr.name)) |st| {
                const contents = try formatStructLayout(handler.gpa, tr.name, st);
                return .{
                    .contents = contents,
                    .range = Handler.offsetRangeToLspRange(source, tr.loc, tr.loc + @as(u32, @intCast(tr.name.len))) orelse return null,
                };
            }
            return null;
        },
        .member_access => |ma| {
            // Try to resolve the base expression's type and show field type
            const contents: []const u8 = blk: {
                const base_sym_idx = resolveExprSymbol(ma.base) orelse break :blk try handler.gpa.dupe(u8, ma.member);
                if (!base_sym_idx.isValid()) break :blk try handler.gpa.dupe(u8, ma.member);
                const base_type = analysis.symbol_types.get(base_sym_idx.index()) orelse break :blk try handler.gpa.dupe(u8, ma.member);
                // Dereference pointers/references to get the underlying type
                const resolved: wgslender.Types.Type = switch (base_type) {
                    .reference => |r| r.element,
                    .pointer => |p| p.element,
                    else => base_type,
                };
                switch (resolved) {
                    .@"struct" => |st| {
                        if (st.getField(ma.member)) |field| {
                            const len = (std.fmt.bufPrint(&buf, "(field) {s}: {s}", .{ ma.member, field.typ.string() }) catch break :blk try handler.gpa.dupe(u8, ma.member)).len;
                            break :blk try handler.gpa.dupe(u8, buf[0..len]);
                        }
                    },
                    .vector => |v| {
                        if (ma.member.len == 1) {
                            const len = (std.fmt.bufPrint(&buf, "(swizzle) {s}: {s}", .{ ma.member, v.element.string() }) catch break :blk try handler.gpa.dupe(u8, ma.member)).len;
                            break :blk try handler.gpa.dupe(u8, buf[0..len]);
                        }
                    },
                    else => {},
                }
                break :blk try handler.gpa.dupe(u8, ma.member);
            };
            return .{
                .contents = contents,
                .range = Handler.offsetRangeToLspRange(source, ma.loc, ma.loc + @as(u32, @intCast(ma.member.len))) orelse return null,
            };
        },
        .binary_expr => |be| {
            // Show const-evaluated result and/or expression type
            var parts: [2][]const u8 = undefined;
            var part_count: usize = 0;

            // Try to show the type of the expression (key on operator loc)
            if (analysis.expr_types.get(be.loc)) |info| {
                const type_str = info.typ.string();
                const formatted = std.fmt.bufPrint(&buf, "**{s}**", .{type_str}) catch "";
                if (formatted.len > 0) {
                    parts[part_count] = try handler.gpa.dupe(u8, formatted);
                    part_count += 1;
                }
            }

            // Try to show const-evaluated result
            if (Handler.resolveConstExpr(be.expr, &analysis.const_values)) |val| {
                var val_buf: [64]u8 = undefined;
                const val_str = std.fmt.bufPrint(&val_buf, "= {d}", .{val}) catch "";
                if (val_str.len > 0) {
                    parts[part_count] = try handler.gpa.dupe(u8, val_str);
                    part_count += 1;
                }
            }

            if (part_count == 0) return null;

            // Join parts with newline
            if (part_count == 2) {
                const combined = try std.fmt.allocPrint(handler.gpa, "{s}\n\n{s}", .{ parts[0], parts[1] });
                handler.gpa.free(parts[0]);
                handler.gpa.free(parts[1]);
                return .{
                    .contents = combined,
                    .range = Handler.offsetRangeToLspRange(source, be.loc, be.loc + be.op_len) orelse return null,
                };
            }
            return .{
                .contents = parts[0],
                .range = Handler.offsetRangeToLspRange(source, be.loc, be.loc + be.op_len) orelse return null,
            };
        },
        .none => return null,
    }
}

/// Resolve an expression to its underlying SymbolIndex (walks through parens and member bases).
fn resolveExprSymbol(expr: Ast.Expr) ?Ast.SymbolIndex {
    return switch (expr) {
        .ident => |e| e.ref,
        .paren => |e| resolveExprSymbol(e.expr),
        .index => |e| resolveExprSymbol(e.base),
        else => null,
    };
}

/// Format a function signature with parameter names and resolved types.
fn formatFunctionSignature(buf: *[1024]u8, module: *const Ast.Module, sym_idx: Ast.SymbolIndex, fn_type: *const wgslender.Types.Function) ?[]const u8 {
    // Find the FunctionDecl matching this symbol
    const func_decl = for (module.declarations.items) |decl| {
        switch (decl) {
            .function => |f| {
                if (f.name == sym_idx) break f;
            },
            else => {},
        }
    } else return null;

    const sym = module.symbols.items[sym_idx.index()];
    var pos: usize = 0;
    const header = std.fmt.bufPrint(buf, "fn {s}(", .{sym.original_name}) catch return null;
    pos = header.len;

    for (func_decl.parameters.items, 0..) |param, pi| {
        if (pi > 0) {
            const sep = std.fmt.bufPrint(buf[pos..], ", ", .{}) catch return null;
            pos += sep.len;
        }
        const p_name = module.symbols.items[param.name.index()].original_name;
        const p_type_str = if (pi < fn_type.parameters.len) fn_type.parameters[pi].string() else "?";
        const p = std.fmt.bufPrint(buf[pos..], "{s}: {s}", .{ p_name, p_type_str }) catch return null;
        pos += p.len;
    }

    if (fn_type.return_type) |rt| {
        const ret = std.fmt.bufPrint(buf[pos..], ") -> {s}", .{rt.string()}) catch return null;
        pos += ret.len;
    } else {
        const tail = std.fmt.bufPrint(buf[pos..], ")", .{}) catch return null;
        pos += tail.len;
    }
    return buf[0..pos];
}

/// Format a hover tooltip for a builtin function, with spec documentation.
fn formatBuiltinHover(handler: *Handler, buf: *[1024]u8, name: []const u8, builtin: Builtins.Builtin) ![]const u8 {
    var pos: usize = 0;

    // Signature from doc table, or fallback to name
    if (Builtins.doc(name)) |d| {
        const sig = std.fmt.bufPrint(buf, "{s}", .{d.signature}) catch return try handler.gpa.dupe(u8, name);
        pos = sig.len;

        // Type constraint
        if (d.type_constraint.len > 0) {
            const tc = std.fmt.bufPrint(buf[pos..], "\n  {s}", .{d.type_constraint}) catch return try handler.gpa.dupe(u8, buf[0..pos]);
            pos += tc.len;
        }

        // Description
        const desc = std.fmt.bufPrint(buf[pos..], "\n\n{s}", .{d.description}) catch return try handler.gpa.dupe(u8, buf[0..pos]);
        pos += desc.len;
    } else {
        const header = std.fmt.bufPrint(buf, "(builtin) {s}", .{name}) catch return try handler.gpa.dupe(u8, name);
        pos = header.len;
    }

    // Metadata line: category + evaluation stage
    const kind_str = @tagName(builtin.kind);
    const stage_str: []const u8 = switch (builtin.stage) {
        .const_eval => "const-evaluable",
        .runtime => "runtime",
        .override => "override-evaluable",
    };
    const meta = std.fmt.bufPrint(buf[pos..], "\n\n({s}) {s}", .{ kind_str, stage_str }) catch return try handler.gpa.dupe(u8, buf[0..pos]);
    pos += meta.len;

    // Uniformity warning
    if (builtin.requiresUniform()) {
        const warn = std.fmt.bufPrint(buf[pos..], " | requires uniform control flow", .{}) catch return try handler.gpa.dupe(u8, buf[0..pos]);
        pos += warn.len;
    }

    return try handler.gpa.dupe(u8, buf[0..pos]);
}

/// Format a struct type with per-field byte offsets, sizes, and padding gaps.
fn formatStructLayout(gpa: std.mem.Allocator, name: []const u8, st: *wgslender.Types.Struct) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var scratch: [256]u8 = undefined;

    // Header: struct Name (size: NB, align: MB)
    const header = std.fmt.bufPrint(&scratch, "struct {s} (size: {d}B, align: {d}B)", .{ name, st.size_bytes, st.align_bytes }) catch return try gpa.dupe(u8, name);
    try out.appendSlice(gpa, header);

    for (st.fields, 0..) |field, fi| {
        const field_size = field.typ.size();
        const field_align = field.typ.alignment();

        // Check for padding before this field
        if (fi > 0) {
            const prev = st.fields[fi - 1];
            const prev_end = prev.offset + prev.typ.size();
            if (field.offset > prev_end) {
                const padding = field.offset - prev_end;
                const pad_line = std.fmt.bufPrint(&scratch, "\n  @{d}  [{d}B padding]", .{ prev_end, padding }) catch continue;
                try out.appendSlice(gpa, pad_line);
            }
        }

        // Field line
        const fld_line = std.fmt.bufPrint(&scratch, "\n  @{d}  {s}: {s}  ({d}B, align {d})", .{ field.offset, field.name, field.typ.string(), field_size, field_align }) catch continue;
        try out.appendSlice(gpa, fld_line);
    }

    // Trailing padding
    if (st.fields.len > 0) {
        const last = st.fields[st.fields.len - 1];
        const last_end = last.offset + last.typ.size();
        if (st.size_bytes > last_end) {
            const trailing = st.size_bytes - last_end;
            const trail_line = std.fmt.bufPrint(&scratch, "\n  @{d}  [{d}B padding]", .{ last_end, trailing }) catch "";
            try out.appendSlice(gpa, trail_line);
        }
    }

    return try gpa.dupe(u8, out.items);
}
