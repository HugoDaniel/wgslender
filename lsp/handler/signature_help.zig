//! Signature Help: when the cursor sits inside a function call's
//! argument list, return the function's signature label and the
//! active parameter index based on comma count to the cursor.

const std = @import("std");
const wgslender = @import("wgslender");

const Handler = @import("../Handler.zig");
const hover = @import("hover.zig");
const Position = Handler.Position;
const Builtins = wgslender.Builtins;

pub const SignatureInfo = struct {
    label: []const u8,
    parameters: []const []const u8,
    active_parameter: u32,
};

/// What an unresolved `Ast.Type` can be spelled as. Only reached when the
/// validator produced no `Types.Function` for the callee — otherwise the
/// resolved rendering wins, and it has no `"?"` cases.
fn astTypeString(typ: wgslender.Ast.Type) []const u8 {
    return switch (typ) {
        .ident => |t| t.name,
        .vec => |t| t.shorthand,
        .mat => |t| t.shorthand,
        else => "?",
    };
}

pub fn computeSignatureHelp(handler: *Handler, uri: []const u8, position: Position) !?SignatureInfo {
    const doc = handler.documents.getPtr(uri) orelse return null;
    const source = doc.source;
    const offset: u32 = @intCast(Handler.lspPositionToOffset(source, position) orelse return null);

    // Scan backward to find enclosing '(' and the function name before it
    var paren_depth: i32 = 0;
    var comma_count: u32 = 0;
    var i: u32 = offset;
    while (i > 0) {
        i -= 1;
        const c = source[i];
        if (c == ')') {
            paren_depth += 1;
        } else if (c == '(') {
            if (paren_depth == 0) break; // found the enclosing '('
            paren_depth -= 1;
        } else if (c == ',' and paren_depth == 0) {
            comma_count += 1;
        }
    } else {
        return null; // no enclosing '('
    }

    // i now points to '('. Find the function name before it.
    if (i == 0) return null;
    var name_end = i;
    // Skip whitespace between name and '('
    while (name_end > 0 and source[name_end - 1] == ' ') name_end -= 1;
    if (name_end == 0) return null;
    var name_start = name_end;
    while (name_start > 0 and (std.ascii.isAlphanumeric(source[name_start - 1]) or source[name_start - 1] == '_')) name_start -= 1;
    const func_name = source[name_start..name_end];
    if (func_name.len == 0) return null;

    // Check if it's a builtin. `Builtins.lookup` already hands back the row's
    // `doc`, so the WGSL-spec signature is right there — no second lookup.
    if (Builtins.lookup(func_name)) |builtin| {
        if (builtin.doc.signature.len > 0) {
            return .{
                .label = try handler.gpa.dupe(u8, builtin.doc.signature),
                .parameters = &.{},
                .active_parameter = comma_count,
            };
        }
        // Defensive only: `src/Builtins.zig`'s "every row carries overloads and
        // documentation" invariant test asserts every signature is non-empty.
        var buf: [256]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{s}({d}..{d} args)", .{ func_name, builtin.min_args, builtin.max_args }) catch return null;
        return .{
            .label = try handler.gpa.dupe(u8, label),
            .parameters = &.{},
            .active_parameter = comma_count,
        };
    }

    // Check if it's a user-defined function
    const analysis = try handler.analyzeDocument(uri);
    const module = analysis.module orelse return null;
    for (module.declarations.items) |decl| {
        switch (decl) {
            .function => |f| {
                if (!f.name.isValid()) continue;
                const sym = module.symbols.items[f.name.index()];
                if (!std.mem.eql(u8, sym.original_name, func_name)) continue;

                // Parameter names are ours either way — `formatFunctionSignature`
                // returns only the label.
                const param_names = try handler.gpa.alloc([]const u8, f.parameters.items.len);
                errdefer handler.gpa.free(param_names);
                for (f.parameters.items, 0..) |param, pi| {
                    // An unbound parameter symbol has an invalid index — guard
                    // before indexing rather than reading out of bounds.
                    param_names[pi] = if (param.name.isValid())
                        module.symbols.items[param.name.index()].original_name
                    else
                        "_";
                }

                // Preferred: the validator-resolved signature, which spells out
                // pointers, textures, samplers and arrays that raw `Ast.Type`
                // renders as "?".
                var sig_buf: [1024]u8 = undefined;
                if (analysis.symbol_types.get(f.name.index())) |t| {
                    if (t == .function) {
                        if (hover.formatFunctionSignature(&sig_buf, module, f.name, t.function)) |sig| {
                            return .{
                                .label = try handler.gpa.dupe(u8, sig),
                                .parameters = param_names,
                                .active_parameter = comma_count,
                            };
                        }
                    }
                }

                // Fallback for when the type didn't resolve (parse errors) —
                // render what the AST alone can spell.
                var buf: [512]u8 = undefined;
                var pos_in_buf: usize = 0;
                const header = std.fmt.bufPrint(&buf, "fn {s}(", .{func_name}) catch return null;
                pos_in_buf = header.len;

                for (f.parameters.items, 0..) |param, pi| {
                    if (pi > 0) {
                        const sep = std.fmt.bufPrint(buf[pos_in_buf..], ", ", .{}) catch return null;
                        pos_in_buf += sep.len;
                    }
                    const p_str = astTypeString(param.typ);
                    const fld = std.fmt.bufPrint(buf[pos_in_buf..], "{s}: {s}", .{ param_names[pi], p_str }) catch return null;
                    pos_in_buf += fld.len;
                }

                const tail_str = if (f.return_type) |rt|
                    std.fmt.bufPrint(buf[pos_in_buf..], ") -> {s}", .{astTypeString(rt)}) catch return null
                else
                    std.fmt.bufPrint(buf[pos_in_buf..], ")", .{}) catch return null;
                pos_in_buf += tail_str.len;

                return .{
                    .label = try handler.gpa.dupe(u8, buf[0..pos_in_buf]),
                    .parameters = param_names,
                    .active_parameter = comma_count,
                };
            },
            else => {},
        }
    }

    return null;
}
