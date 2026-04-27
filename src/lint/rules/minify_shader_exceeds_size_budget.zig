//! `minify/shader-exceeds-size-budget` — flag a module whose estimated
//! minified byte size exceeds a user-supplied budget.
//!
//! Module-level advisory. Opt-in via the standard `Linter.RuleOverride`
//! `options.maxBytes` shape (`["warn", { "maxBytes": 8192 }]`). With no
//! `maxBytes` the rule is a no-op — there is no defensible default
//! because reasonable budgets vary by orders of magnitude across
//! projects, and a default that fires on normal projects is annoying
//! while a default high enough to never trigger is useless.
//!
//! The size estimate runs `MinifyEstimator.estimate(...)` once per
//! invocation. The diagnostic anchors at the first declaration's name
//! span (mirrors `minify/dead-code-kept` / `minify/long-entry-point-name`
//! placement) so editors have a stable squiggle target. When the module
//! has zero declarations we fall back to `(0..0)` rather than
//! suppressing the diagnostic — a 0-decl module that exceeds a 0-byte
//! budget should still surface to the user.
//!
//! LSP-side wiring of `maxBytes` (a `minifyLints.budgetBytes` JSON knob)
//! is intentionally deferred to Phase 6 alongside the total-size code
//! lens — see §18 entry 16 of the design plan. Until then, only callers
//! constructing `Linter.Options` directly (CLI lint via `wgslender.json`,
//! the Zig API, `wgslender lint --rule ...=...` flags) can fire the rule.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");
const Ast = @import("../../Ast.zig");
const MinifyEstimator = @import("../../MinifyEstimator.zig");

pub const rule = Rule{
    .meta = .{
        .id = "minify/shader-exceeds-size-budget",
        .code = "M0500",
        .default_severity = .hint,
        .description = "Estimated minified shader size exceeds the configured `maxBytes` budget. Pass `[\"warn\", { \"maxBytes\": N }]` to opt in — the rule is a no-op without a budget.",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/minify-shader-exceeds-size-budget.md",
        .category = .performance,
    },
    .run = run,
};

fn run(ctx: *Context) error{OutOfMemory}!void {
    const max = readMaxBytes(ctx) orelse return;

    // Estimator wants `*Ast.Module` because it mutates `is_live` (DCE) and
    // re-runs symbol-usage accounting in place. The Linter's contract
    // already allows `requires_dce` rules to mutate the same flag, so the
    // const-cast is consistent with the rest of the lint framework.
    const result = MinifyEstimator.estimate(
        ctx.arena,
        @constCast(ctx.module),
        .{},
    ) catch return;

    if (result.total_min <= max) return;

    const range = firstDeclNameRange(ctx);
    const msg = try ctx.fmt(
        "minified shader is {d} bytes; exceeds configured budget of {d} bytes",
        .{ result.total_min, max },
    );
    ctx.report(.{
        .message = msg,
        .range = range,
    });
}

/// Read `options.maxBytes` (non-negative integer). Returns null when the
/// option is missing or malformed — the rule then no-ops, matching the
/// "opt-in via threshold" contract.
fn readMaxBytes(ctx: *const Context) ?u32 {
    const opts = ctx.options orelse return null;
    if (opts != .object) return null;
    const v = opts.object.get("maxBytes") orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

/// Anchor span: the first declaration that carries a name. Falls back to
/// `(0..0)` when the module has no declarations or only unnamed ones
/// (`const_assert`), so a budget violation always produces a usable
/// diagnostic location.
fn firstDeclNameRange(ctx: *const Context) Diagnostic.Range {
    for (ctx.module.declarations.items) |decl| {
        const name_ref = decl.nameRef();
        if (!name_ref.isValid()) continue;
        const sym = ctx.module.symbols.items[name_ref.index()];
        if (sym.original_name.len == 0) continue;
        const start = sym.loc;
        const end = start + @as(u32, @intCast(sym.original_name.len));
        return ctx.makeRange(start, end);
    }
    return ctx.makeRange(0, 0);
}
