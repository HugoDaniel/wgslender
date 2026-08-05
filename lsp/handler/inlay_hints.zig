//! Inlay Hints: emit type, parameter-name, const-value, and minify-size
//! hints inline with the source. The minify-size lane reads the
//! per-document estimator cache for cross-feature reuse.

const std = @import("std");
const wgslender = @import("wgslender");

const Handler = @import("../Handler.zig");
const Position = Handler.Position;
const Range = Handler.Range;
const Ast = wgslender.Ast;
const MinifySettings = wgslender.MinifySettings;

pub const InlayHintInfo = struct {
    position: Position,
    label: []const u8,
    kind: enum { type_hint, parameter_hint, const_value_hint, minify_size },
    /// For struct types: the definition range so the hint label is clickable/hoverable.
    def_range: ?Range = null,
    /// Optional human-readable tooltip rendered on hover. Used by minify-size
    /// hints to disclose that the byte count is approximate.
    tooltip: ?[]const u8 = null,
};

pub fn computeInlayHints(handler: *Handler, uri: []const u8, range: Range) ![]InlayHintInfo {
    if (!handler.inlayHintsEnabled()) return &.{};
    const analysis = handler.analyzeDocument(uri) catch return &.{};
    const module = analysis.module orelse return &.{};
    const source = module.source;
    // Use the analysis arena for label strings so they share lifetime with type strings
    const label_alloc = if (analysis._arena) |*a| a.allocator() else handler.gpa;

    // One line index for the request: this pass converts one offset per
    // hint, and `Handler.offsetToLspPosition` scans from byte 0.
    var pm = try Handler.PositionMapper.init(handler.gpa, source);
    defer pm.deinit(handler.gpa);

    const range_start = pm.offsetOf(range.start) orelse 0;
    const range_end = pm.offsetOf(range.end) orelse source.len;

    var hints: std.ArrayList(InlayHintInfo) = .empty;
    defer hints.deinit(handler.gpa);

    for (module.declarations.items) |decl| {
        try collectInlayHintsFromDecl(handler, module, analysis, label_alloc, &pm, decl, range_start, range_end, &hints);
    }

    if (analysis.valid) {
        try collectMinifyHints(handler, uri, module, label_alloc, source, &pm, &hints);
    }

    return try handler.gpa.dupe(InlayHintInfo, hints.items);
}

/// Tooltip attached to every minify-size hint. Discloses that the number is
/// an estimate produced without running a full minify pass.
const minify_hint_tooltip: []const u8 =
    "approximate minified byte size — estimated from the symbol table; " ++
    "the true size may differ slightly until you run a full minify.";

/// Emit byte-size inlay hints when the document's effective minifier-mode is
/// `insights` or `strict`. Hints land at three positions:
///
///   * module-level total at `{0,0}` (gated on `insights.total_size`);
///   * per-function hints at the closing `}` of the function body
///     (gated on `insights.function_size`);
///   * per-non-function-decl hints at the trailing `;` (gated on
///     `insights.decl_size`).
///
/// Labels honour the resolved `insights.format` (`delta`, `bytes`, `both`)
/// and roll over from `B` to `KB` once the formatted value reaches 1024.
fn collectMinifyHints(
    handler: *Handler,
    uri: []const u8,
    module: *const wgslender.Ast.Module,
    label_alloc: std.mem.Allocator,
    source: [:0]const u8,
    pm: *const Handler.PositionMapper,
    hints: *std.ArrayList(InlayHintInfo),
) std.mem.Allocator.Error!void {
    const eff = handler.effectiveMinifyFor(uri);
    if (!eff.insightsActive()) return;

    // Phase 7: shared per-document cache. The first inlay-hint /
    // code-lens / lint-rule call after a parse-version bump pays the
    // estimator cost; every subsequent call within the same version
    // returns the same pointer. `module` is still consumed below for
    // its declarations list — the cache only replaces the estimator's
    // arena, not the caller's traversal.
    const cached = handler.getMinifyEstimate(uri, handler.estimatorOptionsFor(uri)) catch return;
    const result = cached;

    if (eff.insights.total_size) {
        const original: u32 = @intCast(source.len);
        const label = formatMinifyLabel(label_alloc, original, result.total_min, eff.insights.format) catch return;
        try hints.append(handler.gpa, .{
            .position = .{ .line = 0, .character = 0 },
            .label = label,
            .kind = .minify_size,
            .tooltip = minify_hint_tooltip,
        });
    }

    for (module.declarations.items) |decl| {
        const name_ref = decl.nameRef();
        if (!name_ref.isValid()) continue;

        const is_function = decl == .function;
        if (is_function and !eff.insights.function_size) continue;
        if (!is_function and !eff.insights.decl_size) continue;

        const estimated: u32 = if (is_function)
            (result.per_function.get(name_ref) orelse continue).min
        else
            (result.per_decl.get(name_ref) orelse continue).min;

        const span = decl.declSpan();
        if (span.end == 0 or span.end > source.len) continue;
        const original = span.end - span.start;
        const pos = pm.position(span.end) orelse continue;

        const label = formatMinifyLabel(label_alloc, original, estimated, eff.insights.format) catch continue;
        try hints.append(handler.gpa, .{
            .position = pos,
            .label = label,
            .kind = .minify_size,
            .tooltip = minify_hint_tooltip,
        });
    }
}

/// Format a single byte-size inlay-hint label. The shape is driven by
/// `format`:
///
///   * `delta`  → `"-NN B"` (savings = original − estimated; never negative
///     in practice, but a `+NN B` shape is used if the estimate is somehow
///     larger than the source);
///   * `bytes`  → `"NN B"` (the post-minify estimate);
///   * `both`   → `"NN B (-NN B)"` (estimate then savings).
///
/// Sub-1024 byte values render as `"NN B"`. Values ≥ 1024 roll over to a
/// one-decimal-place `"X.Y KB"` form.
pub fn formatMinifyLabel(
    arena: std.mem.Allocator,
    original: u32,
    estimated: u32,
    format: MinifySettings.InsightsFormat,
) std.mem.Allocator.Error![]u8 {
    const delta_signed: i64 = @as(i64, original) - @as(i64, estimated);
    const delta_abs: u64 = if (delta_signed < 0) @intCast(-delta_signed) else @intCast(delta_signed);
    const delta_sign: u8 = if (delta_signed < 0) '+' else '-';

    var bytes_buf: [32]u8 = undefined;
    var delta_buf: [32]u8 = undefined;
    const bytes_str = formatSize(&bytes_buf, estimated);
    const delta_str = formatSize(&delta_buf, delta_abs);

    return switch (format) {
        .delta => std.fmt.allocPrint(arena, "{c}{s}", .{ delta_sign, delta_str }),
        .bytes => arena.dupe(u8, bytes_str),
        .both => std.fmt.allocPrint(arena, "{s} ({c}{s})", .{ bytes_str, delta_sign, delta_str }),
    };
}

/// Format `size` as `"NN B"` for sub-1024 values or `"X.Y KB"` for larger
/// ones. Writes into `buf` (≥ 32 bytes is plenty) and returns the slice.
fn formatSize(buf: []u8, size: u64) []u8 {
    if (size < 1024) {
        return std.fmt.bufPrint(buf, "{d} B", .{size}) catch unreachable;
    }
    const tenths = (size * 10 + 512) / 1024;
    const whole = tenths / 10;
    const frac = tenths % 10;
    return std.fmt.bufPrint(buf, "{d}.{d} KB", .{ whole, frac }) catch unreachable;
}

fn collectInlayHintsFromDecl(
    handler: *Handler,
    module: *const Ast.Module,
    analysis: *const wgslender.Validator.AnalysisResult,
    label_alloc: std.mem.Allocator,
    pm: *const Handler.PositionMapper,
    decl: Ast.Decl,
    range_start: usize,
    range_end: usize,
    hints: *std.ArrayList(InlayHintInfo),
) std.mem.Allocator.Error!void {
    switch (decl) {
        .let => |l| {
            if (l.typ == null) { // No explicit type annotation
                if (l.name.isValid()) {
                    const sym = module.symbols.items[l.name.index()];
                    if (sym.loc >= range_start and sym.loc < range_end) {
                        if (analysis.symbol_types.get(l.name.index())) |typ| {
                            const pos = pm.position(sym.loc + @as(u32, @intCast(sym.original_name.len))) orelse return;
                            try hints.append(handler.gpa, .{
                                .position = pos,
                                .label = typ.string(),
                                .kind = .type_hint,
                                .def_range = structDefRange(module, pm, typ),
                            });
                        }
                    }
                }
            }
            // Collect array size hints from type annotation
            if (l.typ) |typ| try collectArraySizeHints(handler, &analysis.const_values, label_alloc, pm, typ, range_start, range_end, hints);
            // Collect expression type hints from initializer
            if (l.initializer) |init_expr| try collectExprTypeHints(handler, module, &analysis.expr_types, pm, init_expr, range_start, range_end, hints, 0);
        },
        .@"var" => |v| {
            // Collect array size hints from type annotation
            if (v.typ) |typ| try collectArraySizeHints(handler, &analysis.const_values, label_alloc, pm, typ, range_start, range_end, hints);
            // Collect expression type hints from initializer
            if (v.initializer) |init_expr| try collectExprTypeHints(handler, module, &analysis.expr_types, pm, init_expr, range_start, range_end, hints, 0);
        },
        .@"const" => |c| {
            // Collect array size hints from type annotation
            if (c.typ) |typ| try collectArraySizeHints(handler, &analysis.const_values, label_alloc, pm, typ, range_start, range_end, hints);
            // Collect expression type hints from initializer
            if (c.initializer) |init_expr| try collectExprTypeHints(handler, module, &analysis.expr_types, pm, init_expr, range_start, range_end, hints, 0);
        },
        .function => |f| {
            if (f.body) |body| {
                for (body.stmts.items) |stmt| {
                    try collectInlayHintsFromStmt(handler, module, analysis, label_alloc, pm, stmt, range_start, range_end, hints);
                }
            }
        },
        else => {},
    }
}

fn collectInlayHintsFromStmt(
    handler: *Handler,
    module: *const Ast.Module,
    analysis: *const wgslender.Validator.AnalysisResult,
    label_alloc: std.mem.Allocator,
    pm: *const Handler.PositionMapper,
    stmt: Ast.Stmt,
    range_start: usize,
    range_end: usize,
    hints: *std.ArrayList(InlayHintInfo),
) std.mem.Allocator.Error!void {
    switch (stmt) {
        .decl => |d| try collectInlayHintsFromDecl(handler, module, analysis, label_alloc, pm, d.decl, range_start, range_end, hints),
        .compound => |c| {
            for (c.stmts.items) |s| {
                try collectInlayHintsFromStmt(handler, module, analysis, label_alloc, pm, s, range_start, range_end, hints);
            }
        },
        .@"if" => |i| {
            try collectInlayHintsFromStmt(handler, module, analysis, label_alloc, pm, .{ .compound = i.body }, range_start, range_end, hints);
            if (i.else_branch) |eb| try collectInlayHintsFromStmt(handler, module, analysis, label_alloc, pm, eb, range_start, range_end, hints);
        },
        .@"for" => |f| {
            if (f.init_stmt) |init_s| try collectInlayHintsFromStmt(handler, module, analysis, label_alloc, pm, init_s, range_start, range_end, hints);
            try collectInlayHintsFromStmt(handler, module, analysis, label_alloc, pm, .{ .compound = f.body }, range_start, range_end, hints);
        },
        .@"while" => |w| try collectInlayHintsFromStmt(handler, module, analysis, label_alloc, pm, .{ .compound = w.body }, range_start, range_end, hints),
        .loop => |l| {
            try collectInlayHintsFromStmt(handler, module, analysis, label_alloc, pm, .{ .compound = l.body }, range_start, range_end, hints);
            if (l.continuing) |cont| try collectInlayHintsFromStmt(handler, module, analysis, label_alloc, pm, .{ .compound = cont }, range_start, range_end, hints);
        },
        .assign => |a| {
            try collectExprTypeHints(handler, module, &analysis.expr_types, pm, a.right, range_start, range_end, hints, 0);
        },
        .@"return" => |r| {
            if (r.value) |v| try collectExprTypeHints(handler, module, &analysis.expr_types, pm, v, range_start, range_end, hints, 0);
        },
        .call => |c| {
            try collectExprTypeHints(handler, module, &analysis.expr_types, pm, .{ .call = c.call }, range_start, range_end, hints, 0);
        },
        else => {},
    }
}

/// Walk a type expression looking for array types with non-literal const size expressions.
/// Emits const_value_hint inlay hints showing the evaluated array size.
/// Labels are allocated from `label_alloc` (typically the analysis arena) so they share
/// the same lifetime as type hint labels and don't need separate freeing.
fn collectArraySizeHints(
    handler: *Handler,
    const_values: *const std.AutoHashMapUnmanaged(u32, i64),
    label_alloc: std.mem.Allocator,
    pm: *const Handler.PositionMapper,
    typ: Ast.Type,
    range_start: usize,
    range_end: usize,
    hints: *std.ArrayList(InlayHintInfo),
) std.mem.Allocator.Error!void {
    switch (typ) {
        .array => |arr| {
            if (arr.size) |size_expr| {
                // Only hint when size is not a plain literal (value already visible)
                switch (size_expr) {
                    .literal => {},
                    else => {
                        if (Handler.resolveConstExpr(size_expr, const_values)) |val| {
                            const end_offset = exprEndOffset(size_expr);
                            if (end_offset >= range_start and end_offset <= range_end) {
                                const pos = pm.position(end_offset) orelse return;
                                var buf: [32]u8 = undefined;
                                const label = std.fmt.bufPrint(&buf, " = {d}", .{val}) catch return;
                                try hints.append(handler.gpa, .{
                                    .position = pos,
                                    .label = try label_alloc.dupe(u8, label),
                                    .kind = .const_value_hint,
                                });
                            }
                        }
                    },
                }
            }
            // Recurse into element type
            if (arr.elem_type) |et| try collectArraySizeHints(handler, const_values, label_alloc, pm, et, range_start, range_end, hints);
        },
        .vec => |v| {
            if (v.elem_type) |et| try collectArraySizeHints(handler, const_values, label_alloc, pm, et, range_start, range_end, hints);
        },
        .mat => |m| {
            if (m.elem_type) |et| try collectArraySizeHints(handler, const_values, label_alloc, pm, et, range_start, range_end, hints);
        },
        .ptr => |p| try collectArraySizeHints(handler, const_values, label_alloc, pm, p.elem_type, range_start, range_end, hints),
        .atomic => |a| try collectArraySizeHints(handler, const_values, label_alloc, pm, a.elem_type, range_start, range_end, hints),
        else => {},
    }
}

/// Compute the byte offset just past the end of an expression.
/// Simplified version of Validator.exprSpan for use in the handler.
fn exprEndOffset(expr: Ast.Expr) u32 {
    return switch (expr) {
        .ident => |e| e.loc +| @as(u32, @intCast(e.name.len)),
        .literal => |e| e.loc +| @as(u32, @intCast(e.value.len)),
        .binary => |e| exprEndOffset(e.right),
        .unary => |e| exprEndOffset(e.operand),
        .call => |e| if (e.end_loc > 0) e.end_loc else e.loc +| 1,
        .index => |e| if (e.end_loc > 0) e.end_loc else e.loc +| 1,
        .member => |e| e.loc +| 1 +| @as(u32, @intCast(e.member_name.len)),
        .paren => |e| exprEndOffset(e.expr),
    };
}

/// Collect expression type hints for interesting sub-expressions.
/// Only emits hints for binary ops (non-comparison), function calls (non-constructors),
/// member access, and indexing operations within the visible range.
fn collectExprTypeHints(
    handler: *Handler,
    module: *const Ast.Module,
    expr_types: *const std.AutoHashMapUnmanaged(u32, wgslender.Validator.ExprTypeInfo),
    pm: *const Handler.PositionMapper,
    expr: Ast.Expr,
    range_start: usize,
    range_end: usize,
    hints: *std.ArrayList(InlayHintInfo),
    depth: u32,
) std.mem.Allocator.Error!void {
    if (depth > 8) return;

    // Look up by expression-specific loc (operator for binary, open-paren
    // for call, dot for member, bracket for index) — matches Validator keys.
    const key: ?u32 = switch (expr) {
        .binary => |e| e.loc,
        .call => |e| e.loc,
        .index => |e| e.loc,
        .member => |e| e.loc,
        else => null,
    };
    if (key) |k| {
        if (k >= range_start and k < range_end) {
            if (expr_types.get(k)) |info| {
                if (shouldShowExprHint(expr, info.typ)) {
                    if (info.end_offset >= range_start and info.end_offset <= range_end) {
                        const pos = pm.position(info.end_offset) orelse return;
                        // Deduplicate: skip if a type hint already exists at
                        // this position (nested expressions sharing an end).
                        var duplicate = false;
                        for (hints.items) |h| {
                            if (h.kind == .type_hint and
                                h.position.line == pos.line and
                                h.position.character == pos.character)
                            {
                                duplicate = true;
                                break;
                            }
                        }
                        if (!duplicate) {
                            try hints.append(handler.gpa, .{
                                .position = pos,
                                .label = info.typ.string(),
                                .kind = .type_hint,
                                .def_range = structDefRange(module, pm, info.typ),
                            });
                        }
                    }
                }
            }
        }
    }

    // Recurse into sub-expressions
    switch (expr) {
        .binary => |e| {
            try collectExprTypeHints(handler, module, expr_types, pm, e.left, range_start, range_end, hints, depth + 1);
            try collectExprTypeHints(handler, module, expr_types, pm, e.right, range_start, range_end, hints, depth + 1);
        },
        .call => |e| {
            for (e.args.items) |arg| {
                try collectExprTypeHints(handler, module, expr_types, pm, arg, range_start, range_end, hints, depth + 1);
            }
        },
        .index => |e| {
            try collectExprTypeHints(handler, module, expr_types, pm, e.base, range_start, range_end, hints, depth + 1);
        },
        .member => |e| {
            try collectExprTypeHints(handler, module, expr_types, pm, e.base, range_start, range_end, hints, depth + 1);
        },
        .paren => |e| {
            try collectExprTypeHints(handler, module, expr_types, pm, e.expr, range_start, range_end, hints, depth + 1);
        },
        else => {},
    }
}

fn shouldShowExprHint(expr: Ast.Expr, typ: wgslender.Types.Type) bool {
    switch (expr) {
        .binary => |e| {
            // Skip comparison/logical operators — result is always bool, obvious
            switch (e.op) {
                .eq, .ne, .lt, .le, .gt, .ge, .logical_and, .logical_or => return false,
                else => {},
            }
        },
        .call => |e| {
            // Skip type constructors where the type is written in the syntax
            if (e.template_type != null) return false;
        },
        .member, .index => {},
        else => return false,
    }
    // Skip void
    if (typ == .void_type) return false;
    return true;
}

/// If `typ` is a struct, return the LSP range of its declaration name.
fn structDefRange(module: *const Ast.Module, pm: *const Handler.PositionMapper, typ: wgslender.Types.Type) ?Range {
    const name = switch (typ) {
        .@"struct" => |s| s.name,
        else => return null,
    };
    for (module.symbols.items) |sym| {
        if (sym.kind == .@"struct" and std.mem.eql(u8, sym.original_name, name)) {
            return pm.range(sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len)));
        }
    }
    return null;
}
