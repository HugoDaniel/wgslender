//! `minify/long-entry-point-name` — flag entry-point function names that
//! exceed a configurable byte threshold.
//!
//! Entry points are pinned by the host: the JS / wgpu API looks them up
//! by name when wiring up the pipeline, so the renamer keeps the original
//! identifier no matter how aggressive `--mangle-external-bindings` gets.
//! That means every byte beyond the threshold is shipping bytes the
//! minifier cannot recover. The default threshold is **8** — `main`,
//! `frag`, `vertex`, `fragMain`, `compute_` all pass; `computeKernelMain`
//! does not.
//!
//! Configurable via the standard `Linter.RuleOverride.options` shape:
//! `["warn", { "max": 4 }]` flips the threshold. Mirrors `max-params`
//! and `max-lines-per-function`'s knob.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");

pub const rule = Rule{
    .meta = .{
        .id = "minify/long-entry-point-name",
        .code = "M0101",
        .default_severity = .hint,
        .description = "Entry-point function names ship verbatim to the host (the API looks them up by name); every byte beyond the configured threshold (default 8) is unrecoverable size. Override the limit with `[\"warn\", { \"max\": N }]`.",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/minify-long-entry-point-name.md",
        .category = .performance,
    },
    .run = run,
};

const DEFAULT_MAX: u32 = 8;

fn run(ctx: *Context) error{OutOfMemory}!void {
    const max = readMax(ctx);
    for (ctx.module.symbols.items) |sym| {
        if (sym.kind != .function) continue;
        if (!sym.flags.is_entry_point) continue;
        if (sym.original_name.len == 0) continue;

        const name_len: u32 = @intCast(sym.original_name.len);
        if (name_len <= max) continue;

        const end = sym.loc + name_len;
        const msg = try ctx.fmt(
            "entry-point '{s}' is {d} chars; the host pins this name through the renamer, so every byte beyond {d} is unrecoverable size",
            .{ sym.original_name, name_len, max },
        );
        ctx.report(.{
            .message = msg,
            .range = ctx.makeRange(sym.loc, end),
        });
    }
}

fn readMax(ctx: *const Context) u32 {
    const opts = ctx.options orelse return DEFAULT_MAX;
    if (opts != .object) return DEFAULT_MAX;
    const v = opts.object.get("max") orelse return DEFAULT_MAX;
    return switch (v) {
        .integer => |i| if (i > 0) @intCast(i) else DEFAULT_MAX,
        else => DEFAULT_MAX,
    };
}
