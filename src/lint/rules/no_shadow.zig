//! `no-shadow` — flag a variable declaration that reuses the name of
//! a symbol visible in an enclosing scope. Shadowing compiles fine in
//! WGSL but makes readers track which binding is meant at every use
//! site, and it hides bugs where a refactor dropped the outer
//! reference but the inner one now silently wins.
//!
//! We walk the scope tree bottom-up. For each named member in a
//! non-root scope, we ask every ancestor scope whether the same name
//! is declared; the nearest ancestor hit is reported as the related
//! location.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");
const Ast = @import("../../Ast.zig");

pub const rule = Rule{
    .meta = .{
        .id = "no-shadow",
        .code = Diagnostic.Code.lint_no_shadow,
        .default_severity = .warning,
        .description = "Report a declaration whose name shadows a symbol from an enclosing scope",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/no-shadow.md",
        .category = .suspicious,
    },
    .run = run,
};

fn run(ctx: *Context) error{OutOfMemory}!void {
    try walkScope(ctx, ctx.module.scope);
}

fn walkScope(ctx: *Context, scope: *Ast.Scope) error{OutOfMemory}!void {
    if (scope.parent != null) try checkScope(ctx, scope);
    for (scope.children.items) |child| try walkScope(ctx, child);
}

fn checkScope(ctx: *Context, scope: *Ast.Scope) error{OutOfMemory}!void {
    var it = scope.members.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!entry.value_ptr.ref.isValid()) continue;

        const outer = findInAncestors(scope.parent, name) orelse continue;
        const sym_idx = entry.value_ptr.ref.index();
        if (sym_idx >= ctx.module.symbols.items.len) continue;
        const sym = ctx.module.symbols.items[sym_idx];
        if (sym.flags.is_builtin) continue;
        if (sym.original_name.len == 0) continue;

        const outer_sym = ctx.module.symbols.items[outer.index()];
        if (outer_sym.flags.is_builtin) continue;

        const name_end = sym.loc + @as(u32, @intCast(sym.original_name.len));
        const outer_end = outer_sym.loc + @as(u32, @intCast(outer_sym.original_name.len));
        const related = try ctx.arena.alloc(Diagnostic.RelatedInfo, 1);
        related[0] = .{
            .range = ctx.makeRange(outer_sym.loc, outer_end),
            .message = "shadowed declaration",
        };

        const msg = try ctx.fmt(
            "'{s}' shadows a declaration from an enclosing scope",
            .{sym.original_name},
        );
        ctx.report(.{
            .message = msg,
            .range = ctx.makeRange(sym.loc, name_end),
            .related = related,
        });
    }
}

fn findInAncestors(start: ?*Ast.Scope, name: []const u8) ?Ast.SymbolIndex {
    var cur = start;
    while (cur) |scope| : (cur = scope.parent) {
        if (scope.members.get(name)) |m| if (m.ref.isValid()) return m.ref;
    }
    return null;
}
