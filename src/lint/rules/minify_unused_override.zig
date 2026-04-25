//! `minify/unused-override` — flag `override` declarations whose
//! `use_count == 0`.
//!
//! Pipeline override constants (`override foo: u32 = 8;` plus optional
//! `@id(N)`) have a small but real footprint after minification: the
//! identifier survives renaming because the host runtime sets the value,
//! and the `override` keyword + initializer still ship. An unused one is
//! pure dead weight in size-sensitive builds (demoscene / intro shaders).
//!
//! See `minify_unused_const.zig` for the symmetric correctness/minify
//! split — the broader `no-unused-vars` rule covers the same shape at
//! warning severity, this rule is hint-level and only fires when the
//! author opts into `@wgslender/minify`.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");

pub const rule = Rule{
    .meta = .{
        .id = "minify/unused-override",
        .code = "M0202",
        .default_severity = .hint,
        .description = "Override declarations with `use_count == 0` ship bytes the host can never reach — drop the override or wire it into a function body.",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/minify-unused-override.md",
        .category = .performance,
    },
    .run = run,
};

fn run(ctx: *Context) error{OutOfMemory}!void {
    for (ctx.module.symbols.items) |sym| {
        if (sym.kind != .override) continue;
        if (sym.use_count > 0) continue;
        if (sym.original_name.len == 0) continue;
        if (sym.flags.is_external_binding) continue;

        const name_len: u32 = @intCast(sym.original_name.len);
        const end = sym.loc + name_len;
        const msg = try ctx.fmt(
            "override '{s}' is never referenced — its declaration text still ships in the minified output",
            .{sym.original_name},
        );
        ctx.report(.{
            .message = msg,
            .range = ctx.makeRange(sym.loc, end),
        });
    }
}
