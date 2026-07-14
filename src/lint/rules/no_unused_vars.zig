//! `no-unused-vars` — report module-scope and local declarations that are
//! never referenced.
//!
//! This rule supersedes the hand-coded `Handler.appendUnusedWarnings`
//! previously in `lsp/Handler.zig`. The code (`W0001`), message shape, and
//! filtering rules are preserved byte-for-byte so the LSP and existing
//! editor integrations remain unchanged after the refactor in Slice 2.
//!
//! Filtering mirrors the original hand-coded pass:
//!   * `use_count > 0` → the symbol is referenced; not a warning.
//!   * Entry points, API-facing, and `@group/@binding` externals are
//!     excluded (the caller wants those kept even if unreferenced).
//!   * Parameters are excluded — function signatures are typically
//!     part of a contract the author can't change.
//!   * Only `function`, `const`, `let`, `var`, `override` kinds are
//!     reported. `struct`, `alias`, `member`, `builtin`, `unbound`
//!     intentionally skipped.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");

pub const rule = Rule{
    .meta = .{
        .id = "no-unused-vars",
        .code = Diagnostic.Code.lint_no_unused_vars,
        .default_severity = .warning,
        .description = "Report variables, constants, and functions that are declared but never referenced",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/no-unused-vars.md",
        .category = .correctness,
    },
    .run = run,
};

fn run(ctx: *Context) error{OutOfMemory}!void {
    for (ctx.module.symbols.items, 0..) |sym, i| {
        if (!ctx.isUnusedReportable(@intCast(i))) continue;
        const name_len: u32 = @intCast(sym.original_name.len);
        const end = sym.loc + name_len;
        const msg = try ctx.fmt(Diagnostic.Message.unused_symbol, .{sym.original_name});
        ctx.report(.{
            .message = msg,
            .range = ctx.makeRange(sym.loc, end),
            .data = .{ .unused_symbol = sym.original_name },
        });
    }
}
