//! `no-large-local-arrays` — warn when a local `var` or `let` is declared
//! as an `array<T, N>` with N above a threshold (default 1024).
//!
//! Local arrays live in the function address space. Most backends spill
//! to registers / private memory aggressively, so even moderately sized
//! local arrays cause performance cliffs. The fix is usually to:
//!   * Move the data to `workgroup` memory (shared across invocations).
//!   * Move it to a `storage` buffer (if it's genuinely large and
//!     invocation-specific).
//!   * Confirm the size is right — a `1024`-element local was rarely
//!     intentional.
//!
//! Threshold defaults to 1024 and will be configurable via
//! `["warn", { "maxSize": 256 }]` in Slice 4 once option parsing lands.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");
const Ast = @import("../../Ast.zig");

pub const rule = Rule{
    .meta = .{
        .id = "no-large-local-arrays",
        .code = Diagnostic.Code.lint_no_large_local_arrays,
        .default_severity = .warning,
        .description = "Report function-scope array declarations that exceed a size threshold (default 1024)",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/no-large-local-arrays.md",
        .category = .performance,
    },
    .run = run,
};

const DEFAULT_MAX_SIZE: u64 = 1024;

fn run(ctx: *Context) error{OutOfMemory}!void {
    const threshold = readThreshold(ctx);
    for (ctx.module.declarations.items) |decl| switch (decl) {
        .function => |fd| if (fd.body) |body| try walkCompound(ctx, body, threshold),
        else => {},
    };
}

fn readThreshold(ctx: *const Context) u64 {
    const opts = ctx.options orelse return DEFAULT_MAX_SIZE;
    if (opts != .object) return DEFAULT_MAX_SIZE;
    const v = opts.object.get("maxSize") orelse return DEFAULT_MAX_SIZE;
    return switch (v) {
        .integer => |i| if (i > 0) @intCast(i) else DEFAULT_MAX_SIZE,
        else => DEFAULT_MAX_SIZE,
    };
}

fn walkCompound(ctx: *Context, c: *Ast.CompoundStmt, threshold: u64) error{OutOfMemory}!void {
    for (c.stmts.items) |stmt| try walkStmt(ctx, stmt, threshold);
}

fn walkStmt(ctx: *Context, stmt: Ast.Stmt, threshold: u64) error{OutOfMemory}!void {
    switch (stmt) {
        .compound => |s| try walkCompound(ctx, s, threshold),
        .@"if" => |s| {
            try walkCompound(ctx, s.body, threshold);
            if (s.else_branch) |eb| try walkStmt(ctx, eb, threshold);
        },
        .@"switch" => |s| for (s.cases.items) |c| try walkCompound(ctx, c.body, threshold),
        .@"for" => |s| {
            if (s.init_stmt) |is| try walkStmt(ctx, is, threshold);
            try walkCompound(ctx, s.body, threshold);
        },
        .@"while" => |s| try walkCompound(ctx, s.body, threshold),
        .loop => |s| {
            try walkCompound(ctx, s.body, threshold);
            if (s.continuing) |cc| try walkCompound(ctx, cc, threshold);
        },
        .decl => |s| try checkDecl(ctx, s.decl, threshold),
        else => {},
    }
}

fn checkDecl(ctx: *Context, decl: Ast.Decl, threshold: u64) error{OutOfMemory}!void {
    const ty = switch (decl) {
        .@"var" => |d| d.typ,
        .let => |d| d.typ,
        else => return,
    };
    const typ = ty orelse return;
    const array = switch (typ) {
        .array => |a| a,
        else => return,
    };
    const size_expr = array.size orelse return;

    // Try to read a literal integer size. We intentionally don't evaluate
    // `const` expressions — if the user writes `array<f32, TILE_SIZE>`,
    // we trust the naming and don't flag it. Magic-numbers rule complains
    // about raw sizes anyway.
    const n = literalU64(size_expr) orelse return;
    if (n <= threshold) return;

    const name_ref = switch (decl) {
        .@"var" => |d| d.name,
        .let => |d| d.name,
        else => return,
    };
    if (!name_ref.isValid()) return;
    const sym = ctx.module.symbols.items[name_ref.index()];
    const name_end = sym.loc + @as(u32, @intCast(sym.original_name.len));

    const msg = try ctx.fmt(
        "local array '{s}' has size {d} (>{d}) — consider workgroup or storage memory instead",
        .{ sym.original_name, n, threshold },
    );
    ctx.report(.{
        .message = msg,
        .range = ctx.makeRange(sym.loc, name_end),
    });
}

fn literalU64(e: Ast.Expr) ?u64 {
    return switch (e) {
        .literal => |lit| parseU64(lit.value),
        .paren => |p| literalU64(p.expr),
        else => null,
    };
}

fn parseU64(v: []const u8) ?u64 {
    if (v.len == 0) return null;
    const trimmed = blk: {
        const last = v[v.len - 1];
        break :blk if (last == 'u' or last == 'i') v[0 .. v.len - 1] else v;
    };
    // Only whole-number integer literals count as a size here.
    for (trimmed) |c| if (c < '0' or c > '9') return null;
    return std.fmt.parseInt(u64, trimmed, 10) catch null;
}
