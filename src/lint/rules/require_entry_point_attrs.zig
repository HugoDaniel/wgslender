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
    var is_compute = false;
    var has_workgroup_size = false;
    var compute_loc: u32 = 0;
    for (fd.attributes.items) |attr| {
        if (std.mem.eql(u8, attr.name, "compute")) {
            is_compute = true;
            compute_loc = attr.loc;
        } else if (std.mem.eql(u8, attr.name, "workgroup_size")) {
            has_workgroup_size = true;
        }
    }
    if (!is_compute or has_workgroup_size) return;

    // Point at the @compute attribute itself — that's what the user would
    // add @workgroup_size next to.
    const msg = try ctx.fmt(
        "@compute entry point is missing @workgroup_size — add `@workgroup_size(x, y, z)` alongside @compute",
        .{},
    );
    // @compute is typically 8 characters (`@compute`), but attributes
    // may have varying span if arguments follow. Use the attribute's
    // span if populated, otherwise a fixed length guess.
    const end: u32 = if (fd.attributes.items.len > 0 and fd.attributes.items[0].span.end > compute_loc)
        fd.attributes.items[0].span.end
    else
        compute_loc + @as(u32, @intCast("@compute".len));
    ctx.report(.{
        .message = msg,
        .range = ctx.makeRange(compute_loc, end),
    });
}
