//! `minify/dead-code-kept` — flag declarations that survive `use_count > 0`
//! only because some other (also-dead) declaration references them.
//!
//! Mirrors the shape of `no-dead-code` (W0002) but at hint severity inside
//! the minify pack — DCE will drop these symbols from the minified output,
//! but their declaration text still costs source bytes (and unminified
//! `--no-dce` builds keep them entirely). Library mode (no entry points)
//! is silenced because DCE conservatively marks every symbol live, leaving
//! no "dead" set against which to flag.
//!
//! See `no-dead-code` for the correctness-flavoured equivalent. The two
//! rules can co-fire on the same decl when both packs are extended; that's
//! by design — they say different things at different severities.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");

pub const rule = Rule{
    .meta = .{
        .id = "minify/dead-code-kept",
        .code = "M0200",
        .default_severity = .hint,
        .description = "Declarations referenced only by other unreachable declarations — DCE drops them in the minified output, but the source text still costs bytes.",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/minify-dead-code-kept.md",
        .category = .performance,
        .requires_dce = true,
    },
    .run = run,
};

fn run(ctx: *Context) error{OutOfMemory}!void {
    const module = ctx.module;

    // Library mode: DCE marks everything live, so there's no dead chain to
    // flag. Skip identically to `no-dead-code`.
    var has_entry_points = false;
    for (module.symbols.items) |sym| {
        if (sym.flags.is_entry_point) {
            has_entry_points = true;
            break;
        }
    }
    if (!has_entry_points) return;

    for (module.symbols.items) |sym| {
        if (sym.flags.is_live) continue;
        // Never-referenced symbols belong to `no-unused-vars` /
        // `minify/unused-const` — this rule only fires when something
        // *is* keeping the dead decl alive in source.
        if (sym.use_count == 0) continue;
        if (sym.original_name.len == 0) continue;
        if (sym.flags.is_entry_point) continue;
        if (sym.flags.is_external_binding) continue;

        switch (sym.kind) {
            .function, .@"struct", .@"const", .let, .@"var", .override => {},
            else => continue,
        }

        const name_len: u32 = @intCast(sym.original_name.len);
        const end = sym.loc + name_len;
        const msg = try ctx.fmt(
            "'{s}' is referenced only from unreachable declarations — DCE will drop it, but the source text still ships",
            .{sym.original_name},
        );
        ctx.report(.{
            .message = msg,
            .range = ctx.makeRange(sym.loc, end),
        });
    }
}
