//! `no-unused-binding` — flag `@group/@binding` declarations that are
//! never referenced by any shader code.
//!
//! These declarations consume a bind group layout slot on the host side
//! (WebGPU pipeline layout must match the shader's declared bindings),
//! so an unused external binding often indicates either (a) the host
//! code sets up a binding the shader never reads, or (b) a removed use
//! in the shader was forgotten about.
//!
//! Preserves the shape of the hand-coded LSP `appendUnusedBindingWarnings`:
//! same W0003 code, same filter, same message.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");

pub const rule = Rule{
    .meta = .{
        .id = "no-unused-binding",
        .code = Diagnostic.Code.lint_no_unused_binding,
        .default_severity = .warning,
        .description = "Report @group/@binding variables that are declared but never referenced",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/no-unused-binding.md",
        .category = .correctness,
    },
    .run = run,
};

fn run(ctx: *Context) error{OutOfMemory}!void {
    for (ctx.module.symbols.items) |sym| {
        if (!sym.flags.is_external_binding) continue;
        if (sym.use_count > 0) continue;
        if (sym.original_name.len == 0) continue;

        const name_len: u32 = @intCast(sym.original_name.len);
        const end = sym.loc + name_len;
        const msg = try ctx.fmt(
            "binding variable '{s}' is declared but never used — it will consume a bind group layout slot",
            .{sym.original_name},
        );
        ctx.report(.{
            .message = msg,
            .range = ctx.makeRange(sym.loc, end),
        });
    }
}
