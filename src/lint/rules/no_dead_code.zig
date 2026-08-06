//! `no-dead-code` — flag declarations that are referenced from other
//! declarations but unreachable from any entry point.
//!
//! Requires DCE (`Dce.mark`) so `Symbol.is_live` is populated. When no
//! entry points are declared (library mode), DCE conservatively marks
//! everything live and this rule emits nothing — there's no "dead" root
//! to measure against.
//!
//! Shares its base filter with the LSP `appendDeadCodeWarnings` hint pass
//! via `AnalysisResult.isDeadCodeReportable` (gated on `hasEntryPoints`)
//! and its wording via `Diagnostic.Message.dead_code`, so the two surfaces
//! can never diverge on what counts as dead or how it reads. This rule
//! layers one extra suppression on top (unused-function body locals, see
//! below); the LSP hint pass reports every match.
//!
//! That suppression asks `AnalysisResult.isUnusedReportable` — the same
//! predicate `no-unused-vars` reports from — instead of re-deriving "is
//! this function unused". It used to re-derive it, which meant two copies
//! of one rule's definition, and the copy tested two flags that a function
//! symbol never carries.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");
const Ast = @import("../../Ast.zig");

pub const rule = Rule{
    .meta = .{
        .id = "no-dead-code",
        .code = Diagnostic.Code.lint_no_dead_code,
        .default_severity = .warning,
        .description = "Report declarations referenced only by other unreachable declarations — they compile but have no runtime effect",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/no-dead-code.md",
        .category = .correctness,
        .requires_dce = true,
    },
    .run = run,
};

fn run(ctx: *Context) error{OutOfMemory}!void {
    const module = ctx.module;

    // Library mode (no entry points) → DCE conservatively marks every
    // symbol live, so there is no "dead" set to flag. Skip entirely.
    if (!ctx.hasEntryPoints()) return;

    // Map every function-local symbol to the symbol index of its
    // enclosing function. Used below to suppress redundant W0002s on
    // locals whose enclosing function is itself flagged by W0001.
    var enclosing_fn: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer enclosing_fn.deinit(ctx.arena);
    try buildEnclosingFnMap(ctx.arena, module, &enclosing_fn);

    for (module.symbols.items, 0..) |sym, i| {
        if (!ctx.isDeadCodeReportable(@intCast(i))) continue;

        // Suppress noise: if this symbol's enclosing function is itself
        // about to be flagged by no-unused-vars (W0001), the user only
        // needs the one diagnostic on the function name. Module-scope
        // dead chains still fire — those pinpoint distinct dead decls
        // worth cleaning up individually.
        //
        // Ask the shared predicate rather than re-deriving it. The
        // question here is precisely "will no-unused-vars report this
        // function?", and no_unused_vars.zig answers it with this same
        // call — so the two cannot drift into disagreeing about which
        // diagnostic the user gets.
        if (enclosing_fn.get(@intCast(i))) |fn_idx| {
            if (ctx.isUnusedReportable(fn_idx)) continue;
        }

        const name_len: u32 = @intCast(sym.original_name.len);
        const end = sym.loc + name_len;
        const msg = try ctx.fmt(Diagnostic.Message.dead_code, .{sym.original_name});
        ctx.report(.{
            .message = msg,
            .range = ctx.makeRange(sym.loc, end),
        });
    }
}

/// Map every symbol declared inside a top-level function's body (or
/// parameter list) to that function's symbol index. We rely on byte-
/// offset containment rather than a scope back-pointer because the AST
/// carries no such pointer. Functions can't nest in WGSL, so flat
/// iteration is sufficient.
fn buildEnclosingFnMap(
    arena: Allocator,
    module: *const Ast.Module,
    out: *std.AutoHashMapUnmanaged(u32, u32),
) error{OutOfMemory}!void {
    std.debug.assert(out.count() == 0);

    for (module.declarations.items) |decl| switch (decl) {
        .function => |fd| {
            if (!fd.name.isValid()) continue;
            const fn_idx = fd.name.index();

            for (fd.parameters.items) |p| {
                if (!p.name.isValid()) continue;
                try out.put(arena, p.name.index(), fn_idx);
            }

            const body = fd.body orelse continue;
            const body_start = body.span.start;
            const body_end = body.span.end;
            if (body_end <= body_start) continue;

            for (module.symbols.items, 0..) |sym, i| {
                if (sym.loc <= body_start) continue;
                if (sym.loc >= body_end) continue;
                try out.put(arena, @intCast(i), fn_idx);
            }
        },
        else => {},
    };

    std.debug.assert(out.count() <= module.symbols.items.len);
}
