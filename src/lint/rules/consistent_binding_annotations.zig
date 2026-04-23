//! `consistent-binding-annotations` — module-scope `var` declarations that
//! address shared hardware resources (uniforms, storage buffers, textures,
//! samplers) must have both `@group(N)` and `@binding(M)` attributes so
//! they can be bound at runtime. Missing either one means the shader
//! silently can't be used with a standard pipeline layout.
//!
//! The WGSL validator already rejects certain combinations, but some
//! cases (a texture without any attributes, for instance) can slip through
//! parse and validate and only break at pipeline creation time. This rule
//! is the pre-flight check.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");
const Ast = @import("../../Ast.zig");

pub const rule = Rule{
    .meta = .{
        .id = "consistent-binding-annotations",
        .code = Diagnostic.Code.lint_consistent_binding_annotations,
        .default_severity = .warning,
        .description = "Require both @group and @binding on module-scope resource vars (uniform / storage / texture / sampler)",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/consistent-binding-annotations.md",
        .category = .portability,
    },
    .run = run,
};

fn run(ctx: *Context) error{OutOfMemory}!void {
    for (ctx.module.declarations.items) |decl| switch (decl) {
        .@"var" => |vd| try checkVar(ctx, vd),
        else => {},
    };
}

fn checkVar(ctx: *Context, vd: *Ast.VarDecl) error{OutOfMemory}!void {
    // Only module-scope resource vars are relevant. `function`/`private`/
    // `workgroup` address spaces don't need @group/@binding.
    const needs_bindings = switch (vd.address_space) {
        .uniform, .storage => true,
        .none => isResourceType(vd.typ), // textures/samplers have .none address space
        else => false,
    };
    if (!needs_bindings) return;

    var has_group = false;
    var has_binding = false;
    var first_attr_loc: u32 = 0;
    var first_attr_end: u32 = 0;
    for (vd.attributes.items, 0..) |attr, idx| {
        if (idx == 0) {
            first_attr_loc = attr.loc;
            first_attr_end = if (attr.span.end > attr.loc) attr.span.end else attr.loc + 1;
        }
        if (std.mem.eql(u8, attr.name, "group")) has_group = true;
        if (std.mem.eql(u8, attr.name, "binding")) has_binding = true;
    }
    if (has_group and has_binding) return;

    const missing = if (!has_group and !has_binding)
        "@group and @binding"
    else if (!has_group)
        "@group"
    else
        "@binding";

    const msg = try ctx.fmt(
        "resource var is missing {s} — module-scope {s} requires both @group(N) and @binding(M)",
        .{ missing, addressSpaceLabel(vd) },
    );

    // Point at the declaration's name if we don't have an attribute to anchor on.
    const range = if (first_attr_end > first_attr_loc)
        ctx.makeRange(first_attr_loc, first_attr_end)
    else blk: {
        if (!vd.name.isValid()) return;
        const sym = ctx.module.symbols.items[vd.name.index()];
        const name_end = sym.loc + @as(u32, @intCast(sym.original_name.len));
        break :blk ctx.makeRange(sym.loc, name_end);
    };
    ctx.report(.{ .message = msg, .range = range });
}

fn isResourceType(t: ?Ast.Type) bool {
    const ty = t orelse return false;
    return switch (ty) {
        .texture, .sampler => true,
        else => false,
    };
}

fn addressSpaceLabel(vd: *const Ast.VarDecl) []const u8 {
    return switch (vd.address_space) {
        .uniform => "uniform vars",
        .storage => "storage vars",
        .none => "textures and samplers",
        else => "resource vars",
    };
}
