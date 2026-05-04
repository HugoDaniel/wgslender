//! `minify/unused-const` — flag `const` declarations whose `use_count == 0`.
//!
//! Bytes in an unused `const` round-trip through the lexer / parser / DCE
//! and cost real shipping size only if the user passes `--no-dce`, but the
//! minifier-mode hint surface is the right place to nudge the author
//! before the build pipeline silently drops the symbol — and the LSP
//! makes that nudge happen as the const is being typed.
//!
//! Note: the broader `no-unused-vars` (W0001) rule also covers `.const`.
//! That rule is correctness-flavoured (referenced from
//! `@wgslender/recommended` at warning severity); this one is
//! minify-flavoured (a hint-level signal, only enabled when the author
//! opts into `@wgslender/minify`). They can both fire on the same decl
//! and that's by design — they say different things.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");

pub const rule = Rule{
    .meta = .{
        .id = "minify/unused-const",
        .code = "M0201",
        .default_severity = .hint,
        .description = "Const declarations with `use_count == 0` cost shipping bytes once minified — the symbol survives DCE only if some other declaration references it.",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/minify-unused-const.md",
        .category = .performance,
    },
    .run = run,
};

fn run(ctx: *Context) error{OutOfMemory}!void {
    for (ctx.module.symbols.items, 0..) |sym, i| {
        if (sym.kind != .@"const") continue;
        if (ctx.useCount(@intCast(i)) > 0) continue;
        if (sym.original_name.len == 0) continue;
        if (sym.flags.is_external_binding) continue;

        const name_len: u32 = @intCast(sym.original_name.len);
        const end = sym.loc + name_len;
        const msg = try ctx.fmt(
            "const '{s}' is never referenced — it will not appear in the minified output, but its declaration text still costs source bytes",
            .{sym.original_name},
        );
        ctx.report(.{
            .message = msg,
            .range = ctx.makeRange(sym.loc, end),
        });
    }
}
