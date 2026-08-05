//! Code Lens: emit reference counts, binding summaries, workgroup
//! sizes, and the module-level total-size lens that links to
//! `wgslender.showMinifiedOutput`.

const std = @import("std");
const wgslender = @import("wgslender");

const Handler = @import("../Handler.zig");
const Range = Handler.Range;
const Ast = wgslender.Ast;
const Edits = wgslender.Edits;

pub const CodeLensInfo = struct {
    range: Range,
    title: []const u8,
    /// Optional command to invoke when the lens is clicked. Existing
    /// reference / binding / workgroup lenses leave this null and surface
    /// as plain title-only lenses (`command = ""` in the LSP wire shape).
    /// The total-size lens sets it to `wgslender.showMinifiedOutput`.
    command: ?[]const u8 = null,
    /// JSON arguments forwarded to the command. Owned by the same
    /// allocator as `title`; `freeCodeLens` releases both. The
    /// individual `std.json.Value` entries are leaf values that own
    /// no further allocations (we only stamp `.string` URIs today),
    /// so freeing the slice is sufficient.
    arguments: ?[]std.json.Value = null,
};

pub fn freeCodeLens(gpa: std.mem.Allocator, lenses: []const CodeLensInfo) void {
    for (lenses) |l| {
        gpa.free(l.title);
        if (l.arguments) |args| {
            for (args) |arg| switch (arg) {
                .string => |s| gpa.free(s),
                else => {},
            };
            gpa.free(args);
        }
    }
    gpa.free(lenses);
}

pub fn computeCodeLens(handler: *Handler, uri: []const u8) ![]CodeLensInfo {
    const analysis = handler.analyzeDocument(uri) catch return &.{};
    const module = analysis.module orelse return &.{};
    const source = module.source;

    // One line index for the request: this loop converts one offset per
    // result, and `Handler.offsetRangeToLspRange` scans from byte 0.
    var pm = try Handler.PositionMapper.init(handler.gpa, source);
    defer pm.deinit(handler.gpa);

    var lenses: std.ArrayList(CodeLensInfo) = .empty;
    defer lenses.deinit(handler.gpa);

    for (module.declarations.items) |decl| {
        const name_ref = decl.nameRef();
        if (!name_ref.isValid()) continue;
        const sym = module.symbols.items[name_ref.index()];

        // Only show code lens for functions and structs
        switch (decl) {
            .function, .@"struct" => {},
            else => continue,
        }

        // Count references (use the shared library reference collector)
        const refs = Edits.findReferences(handler.gpa, module, name_ref, false) catch continue;
        defer handler.gpa.free(refs);

        const range = pm.range(sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len))) orelse continue;
        var buf: [64]u8 = undefined;
        const title = std.fmt.bufPrint(&buf, "{d} reference{s}", .{ refs.len, if (refs.len == 1) "" else "s" }) catch continue;
        try lenses.append(handler.gpa, .{
            .range = range,
            .title = try handler.gpa.dupe(u8, title),
        });
    }

    // Add binding summary and workgroup size lenses for entry points.
    // `binding_summary` is the shared template; each lens gets its own
    // duped copy so the caller can free `l.title` uniformly without
    // double-freeing across entry points (and without leaking when the
    // module has bindings but no entry points consume the template).
    const binding_summary = collectBindingSummary(handler.gpa, module);
    defer if (binding_summary) |s| handler.gpa.free(s);
    for (module.declarations.items) |decl| {
        switch (decl) {
            .function => |f| {
                if (!f.name.isValid()) continue;
                const sym = module.symbols.items[f.name.index()];
                if (!sym.flags.is_entry_point) continue;
                const range = pm.range(sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len))) orelse continue;

                if (binding_summary) |summary| {
                    const title = try handler.gpa.dupe(u8, summary);
                    try lenses.append(handler.gpa, .{ .range = range, .title = title });
                }

                // Workgroup size for compute shaders
                if (getWorkgroupSize(f, &analysis.const_values, module)) |wg| {
                    var wg_buf: [64]u8 = undefined;
                    const wg_title = std.fmt.bufPrint(&wg_buf, "workgroup: {d}x{d}x{d}", .{ wg[0], wg[1], wg[2] }) catch continue;
                    try lenses.append(handler.gpa, .{
                        .range = range,
                        .title = try handler.gpa.dupe(u8, wg_title),
                    });
                }
            },
            else => {},
        }
    }

    // Phase 6: module-level total-size lens. Only when the resolved
    // mode requests the total (insights / strict, with the
    // `totalSize` sub-switch on by default — matches the inlay-hints
    // gating). Estimator runs in a scratch arena so its hash maps don't
    // outlive this call; we copy out only the four u32s and the click
    // command into the returned lens.
    if (handler.effectiveMinifyFor(uri).insights.total_size) {
        appendTotalSizeLens(handler, uri, source, &lenses) catch |err| switch (err) {
            error.OutOfMemory => return err,
        };
    }

    return try handler.gpa.dupe(CodeLensInfo, lenses.items);
}

/// Phase 6 — append the module-level total-size code lens.
///
/// Title shape: `"<src> B → <min> B min → <gz> B gz"`, with a
/// ` (over budget)` suffix when an `Effective.budget_bytes` is set
/// and the estimator's `total_min` exceeds it. ASCII-only badge for
/// client renderer portability (see plan §"Decisions resolved").
///
/// Click target: `wgslender.showMinifiedOutput`, with `[uri]` as the
/// argument. The command produces the actual minified text via
/// `Minifier.minify`; the lens itself only relies on the cheap
/// estimator.
fn appendTotalSizeLens(
    handler: *Handler,
    uri: []const u8,
    source: [:0]const u8,
    lenses: *std.ArrayList(CodeLensInfo),
) !void {
    // Phase 7 — read through the per-document cache. The first
    // codeLens / inlayHint / minify-lint pass after a parse-version
    // bump pays the estimator cost; subsequent ones in the same
    // version return the same pointer.
    const result = handler.getMinifyEstimate(uri, handler.estimatorOptionsFor(uri)) catch return;

    const eff = handler.effectiveMinifyFor(uri);
    const original: u32 = @intCast(source.len);
    const over_budget: bool = if (eff.budget_bytes) |b| result.total_min > b else false;

    var buf: [128]u8 = undefined;
    const title = if (over_budget)
        std.fmt.bufPrint(
            &buf,
            "{d} B \u{2192} {d} B min \u{2192} {d} B gz (over budget)",
            .{ original, result.total_min, result.total_gz },
        ) catch return
    else
        std.fmt.bufPrint(
            &buf,
            "{d} B \u{2192} {d} B min \u{2192} {d} B gz",
            .{ original, result.total_min, result.total_gz },
        ) catch return;

    const title_dup = try handler.gpa.dupe(u8, title);
    errdefer handler.gpa.free(title_dup);

    const uri_dup = try handler.gpa.dupe(u8, uri);
    errdefer handler.gpa.free(uri_dup);

    const args = try handler.gpa.alloc(std.json.Value, 1);
    errdefer handler.gpa.free(args);
    args[0] = .{ .string = uri_dup };

    try lenses.append(handler.gpa, .{
        .range = .{
            .start = .{ .line = 0, .character = 0 },
            .end = .{ .line = 0, .character = 0 },
        },
        .title = title_dup,
        .command = "wgslender.showMinifiedOutput",
        .arguments = args,
    });
}

/// Collect a one-line summary of all @group/@binding declarations in the module.
fn collectBindingSummary(gpa: std.mem.Allocator, module: *const Ast.Module) ?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var scratch: [128]u8 = undefined;
    var count: usize = 0;

    for (module.declarations.items) |decl| {
        switch (decl) {
            .@"var" => |v| {
                if (!v.name.isValid()) continue;

                // Extract group and binding from attributes
                var group: ?i32 = null;
                var binding: ?i32 = null;
                for (v.attributes.items) |attr| {
                    if (std.mem.eql(u8, attr.name, "group")) {
                        group = getIntArg(attr);
                    } else if (std.mem.eql(u8, attr.name, "binding")) {
                        binding = getIntArg(attr);
                    }
                }

                if (group != null and binding != null) {
                    if (count > 0) out.appendSlice(gpa, " | ") catch {};
                    // Show address space for uniform/storage, or type name for sampler/texture
                    const type_label: []const u8 = if (v.address_space != .none)
                        v.address_space.string()
                    else if (v.typ) |typ| switch (typ) {
                        .sampler => "sampler",
                        .texture => "texture",
                        .ident => |t| t.name,
                        else => "var",
                    } else "var";
                    const entry = std.fmt.bufPrint(&scratch, "@group({d}) @binding({d}) {s}", .{ group.?, binding.?, type_label }) catch continue;
                    out.appendSlice(gpa, entry) catch {};
                    count += 1;
                }
            },
            else => {},
        }
    }

    if (count == 0) return null;
    return gpa.dupe(u8, out.items) catch null;
}

/// Extract @workgroup_size(X, Y, Z) from a function's attributes.
/// Resolves const references via const_values when available.
/// Needs the module to resolve unbound ident refs by name lookup.
fn getWorkgroupSize(f: *const Ast.FunctionDecl, const_values: *const std.AutoHashMapUnmanaged(u32, i64), module: *const Ast.Module) ?[3]u32 {
    for (f.attributes.items) |attr| {
        if (std.mem.eql(u8, attr.name, "workgroup_size")) {
            var sizes = [3]u32{ 1, 1, 1 };
            for (attr.args.items, 0..) |arg, i| {
                if (i >= 3) break;
                sizes[i] = resolveConstIntExpr(arg, const_values, module) orelse 1;
            }
            return sizes;
        }
    }
    return null;
}

/// Resolve a const-evaluable expression to a u32 value.
/// Handles literals and const identifier references via the const_values map.
/// Falls back to name-based lookup in the module when ident refs are unbound
/// (e.g., in attribute arguments which don't go through the parser's bind pass).
fn resolveConstIntExpr(expr: Ast.Expr, const_values: *const std.AutoHashMapUnmanaged(u32, i64), module: *const Ast.Module) ?u32 {
    return resolveConstIntExprDepth(expr, const_values, module, 0);
}

fn resolveConstIntExprDepth(expr: Ast.Expr, const_values: *const std.AutoHashMapUnmanaged(u32, i64), module: *const Ast.Module, depth: u32) ?u32 {
    if (depth > 32) return null;
    switch (expr) {
        .literal => |lit| {
            var val_str = lit.value;
            if (val_str.len > 0 and (val_str[val_str.len - 1] == 'i' or val_str[val_str.len - 1] == 'u')) {
                val_str = val_str[0 .. val_str.len - 1];
            }
            const val = std.fmt.parseInt(i64, val_str, 0) catch return null;
            if (val >= 0 and val <= std.math.maxInt(u32)) return @intCast(val);
            return null;
        },
        .ident => |ident| {
            // Try direct ref lookup first (bound idents)
            if (ident.ref.isValid()) {
                if (const_values.get(ident.ref.index())) |val| {
                    if (val >= 0 and val <= std.math.maxInt(u32)) return @intCast(val);
                }
            }
            // Fallback: look up by name in module symbols (for unbound attribute args)
            for (module.symbols.items, 0..) |sym, idx| {
                if (sym.kind == .@"const" and std.mem.eql(u8, sym.original_name, ident.name)) {
                    if (const_values.get(@intCast(idx))) |val| {
                        if (val >= 0 and val <= std.math.maxInt(u32)) return @intCast(val);
                    }
                    break;
                }
            }
            return null;
        },
        .paren => |p| return resolveConstIntExprDepth(p.expr, const_values, module, depth + 1),
        .unary => |u| {
            if (u.op == .neg) {
                // Negative values aren't valid for workgroup sizes etc., but resolve anyway
                return null;
            }
            return null;
        },
        .binary => |b| {
            const l = resolveConstIntExprDepth(b.left, const_values, module, depth + 1) orelse return null;
            const r = resolveConstIntExprDepth(b.right, const_values, module, depth + 1) orelse return null;
            const li: i64 = @intCast(l);
            const ri: i64 = @intCast(r);
            const result: i64 = switch (b.op) {
                .add => li +| ri,
                .sub => li -| ri,
                .mul => li *| ri,
                .div => if (ri != 0) @divTrunc(li, ri) else return null,
                .mod => if (ri != 0) @mod(li, ri) else return null,
                .shl => if (ri >= 0 and ri < 64) li << @intCast(ri) else return null,
                .shr => if (ri >= 0 and ri < 64) li >> @intCast(ri) else return null,
                .@"and" => li & ri,
                .@"or" => li | ri,
                .xor => li ^ ri,
                else => return null,
            };
            if (result >= 0 and result <= std.math.maxInt(u32)) return @intCast(result);
            return null;
        },
        else => return null,
    }
}

/// Resolve a const-evaluable expression to an i64 value for display purposes.
/// Handles literals, const ident refs, parens, negation, and binary arithmetic.
pub fn resolveConstExpr(expr: Ast.Expr, const_values: *const std.AutoHashMapUnmanaged(u32, i64)) ?i64 {
    return resolveConstExprDepth(expr, const_values, 0);
}

fn resolveConstExprDepth(expr: Ast.Expr, const_values: *const std.AutoHashMapUnmanaged(u32, i64), depth: u32) ?i64 {
    if (depth > 32) return null;
    return switch (expr) {
        .literal => |lit| {
            var val_str = lit.value;
            if (val_str.len == 0) return @as(i64, 0);
            if (val_str.len > 0 and (val_str[val_str.len - 1] == 'i' or val_str[val_str.len - 1] == 'u')) {
                val_str = val_str[0 .. val_str.len - 1];
            }
            return std.fmt.parseInt(i64, val_str, 0) catch null;
        },
        .ident => |ident| {
            if (ident.ref.isValid()) return const_values.get(ident.ref.index());
            return null;
        },
        .paren => |p| resolveConstExprDepth(p.expr, const_values, depth + 1),
        .unary => |u| {
            const val = resolveConstExprDepth(u.operand, const_values, depth + 1) orelse return null;
            return switch (u.op) {
                .neg => 0 -| val,
                .bit_not => ~val,
                else => null,
            };
        },
        .binary => |b| {
            const l = resolveConstExprDepth(b.left, const_values, depth + 1) orelse return null;
            const r = resolveConstExprDepth(b.right, const_values, depth + 1) orelse return null;
            return switch (b.op) {
                .add => l +| r,
                .sub => l -| r,
                .mul => l *| r,
                .div => if (r != 0) @divTrunc(l, r) else null,
                .mod => if (r != 0) @mod(l, r) else null,
                .shl => if (r >= 0 and r < 64) l << @intCast(r) else null,
                .shr => if (r >= 0 and r < 64) l >> @intCast(r) else null,
                .@"and" => l & r,
                .@"or" => l | r,
                .xor => l ^ r,
                else => null,
            };
        },
        else => null,
    };
}

/// Extract an integer value from the first argument of an attribute.
fn getIntArg(attr: Ast.Attribute) ?i32 {
    if (attr.args.items.len == 0) return null;
    switch (attr.args.items[0]) {
        .literal => |lit| return std.fmt.parseInt(i32, lit.value, 10) catch null,
        else => return null,
    }
}
