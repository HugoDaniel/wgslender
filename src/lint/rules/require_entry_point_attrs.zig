//! `require-entry-point-attrs` — every `@compute` function must also have
//! `@workgroup_size(x, y, z)`; `@vertex` / `@fragment` entry points are
//! reported without additional attribute requirements in v1.
//!
//! The WGSL validator already rejects `@compute` without `@workgroup_size`,
//! but the diagnostic there is an error. This lint rule exists so packs
//! that want to enforce the attribute independently (e.g. for projects
//! that extend the WGSL grammar before running through an intermediate
//! that strips annotations) have a warning-level switch.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");
const Ast = @import("../../Ast.zig");

pub const rule = Rule{
    .meta = .{
        .id = "require-entry-point-attrs",
        .code = Diagnostic.Code.lint_require_entry_point_attrs,
        .default_severity = .@"error",
        .description = "Ensure @compute entry points declare @workgroup_size",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/require-entry-point-attrs.md",
        .category = .portability,
    },
    .run = run,
};

fn run(ctx: *Context) error{OutOfMemory}!void {
    for (ctx.module.declarations.items) |decl| switch (decl) {
        .function => |fd| try checkFunction(ctx, fd),
        else => {},
    };
}

fn checkFunction(ctx: *Context, fd: *Ast.FunctionDecl) error{OutOfMemory}!void {
    var compute_idx: ?usize = null;
    var has_workgroup_size = false;
    for (fd.attributes.items, 0..) |attr, i| {
        if (std.mem.eql(u8, attr.name, "compute")) {
            compute_idx = i;
        } else if (std.mem.eql(u8, attr.name, "workgroup_size")) {
            has_workgroup_size = true;
        }
    }
    const ci = compute_idx orelse return;
    if (has_workgroup_size) return;

    // Point at the @compute attribute itself — that's what the user would
    // add @workgroup_size next to.
    const msg = try ctx.fmt(
        "@compute entry point is missing @workgroup_size — add `@workgroup_size(x, y, z)` alongside @compute",
        .{},
    );
    const compute_attr = fd.attributes.items[ci];
    // Prefer the parser-populated span; fall back to the attribute's loc
    // plus the literal length when CstLower hasn't filled span in.
    const end: u32 = if (compute_attr.span.end > compute_attr.loc)
        compute_attr.span.end
    else
        compute_attr.loc + @as(u32, @intCast("@compute".len));
    ctx.report(.{
        .message = msg,
        .range = ctx.makeRange(compute_attr.loc, end),
    });
}
