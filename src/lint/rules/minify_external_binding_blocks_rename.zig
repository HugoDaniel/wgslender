//! `minify/external-binding-blocks-rename` — flag `@group/@binding`
//! variables whose original name leaks through the renamer because the
//! API contract pins it.
//!
//! By default `wgslender` preserves the source name of every external
//! binding (and emits a `let` alias if the renamer rewrites the body)
//! so host code that looked up a binding by name still works after
//! minification. The author can opt in to renaming via
//! `--mangle-external-bindings` once the host side is ready, but that
//! flag is CLI-only and therefore invisible at LSP edit time. This rule
//! makes the cost visible: every long binding name is shipped bytes
//! that could be reduced to a single character with the right flag.
//!
//! Phase 5b will gate this rule on the resolved
//! `effective_minify.mangle_external_bindings` so the hint disappears
//! once the user has opted in. For now the field doesn't exist; the
//! rule fires unconditionally on any external binding so the surface is
//! at least visible.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");

pub const rule = Rule{
    .meta = .{
        .id = "minify/external-binding-blocks-rename",
        .code = "M0100",
        .default_severity = .hint,
        .description = "External bindings are kept as-is by the renamer to preserve the host-side API. Long names ship verbatim — pass --mangle-external-bindings (after coordinating with the host) or shorten the source name.",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/minify-external-binding-blocks-rename.md",
        .category = .performance,
    },
    .run = run,
};

fn run(ctx: *Context) error{OutOfMemory}!void {
    for (ctx.module.symbols.items) |sym| {
        if (!sym.flags.is_external_binding) continue;
        if (sym.original_name.len == 0) continue;

        const name_len: u32 = @intCast(sym.original_name.len);
        const end = sym.loc + name_len;
        const msg = try ctx.fmt(
            "external binding '{s}' is preserved by the renamer — its full name ships in the minified output unless --mangle-external-bindings is set",
            .{sym.original_name},
        );
        ctx.report(.{
            .message = msg,
            .range = ctx.makeRange(sym.loc, end),
        });
    }
}
