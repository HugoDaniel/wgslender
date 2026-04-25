//! `minify/external-binding-blocks-rename` — flag `@group/@binding`
//! variables whose original name leaks through the renamer because the
//! API contract pins it.
//!
//! By default `wgslender` preserves the source name of every external
//! binding (and emits a `let` alias if the renamer rewrites the body)
//! so host code that looked up a binding by name still works after
//! minification. The author can opt in to renaming via
//! `--mangle-external-bindings` once the host side is ready; this rule
//! makes the cost visible until they do.
//!
//! Gating: when `ctx.options.mangleExternalBindings == true`, the user
//! has already opted into renaming and the hint is just noise — skip.
//! The LSP synthesizes that option from the resolved
//! `MinifySettings.Effective.mangle_external_bindings` field; CLI lint
//! invocations can pass the same option via the standard
//! `Linter.RuleOverride.options` JSON shape.

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
    if (mangleExternalBindings(ctx)) return;

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

fn mangleExternalBindings(ctx: *const Context) bool {
    const opts = ctx.options orelse return false;
    if (opts != .object) return false;
    const v = opts.object.get("mangleExternalBindings") orelse return false;
    return v == .bool and v.bool;
}
