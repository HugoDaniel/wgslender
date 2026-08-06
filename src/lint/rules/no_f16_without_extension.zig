//! `no-f16-without-extension` — flag use of the `f16` type or `h`-suffixed
//! literal when the module doesn't declare `enable f16;` at the top.
//!
//! WGSL makes `f16` an extension (§3.3). Tooling that pipes shaders
//! through Tint or a browser will reject a shader that references `f16`
//! without the enable directive — but the wgslender Validator is
//! permissive by design, so this slip lands in production as a runtime
//! failure unless linted.
//!
//! Autofix inserts `enable f16;` at the very top of the source. Running
//! `--fix` is enough to make a f16-using shader portable.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");
const Ast = @import("../../Ast.zig");

pub const rule = Rule{
    .meta = .{
        .id = "no-f16-without-extension",
        .code = Diagnostic.Code.lint_no_f16_without_extension,
        .default_severity = .warning,
        .description = "Report f16 usage in a module that does not `enable f16;`",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/no-f16-without-extension.md",
        .category = .portability,
        .fixable = true,
    },
    .run = run,
};

fn run(ctx: *Context) error{OutOfMemory}!void {
    if (hasF16Enable(ctx.module)) return;

    // Walk every decl looking for an f16 type occurrence or h-suffixed
    // literal. First hit wins — multiple flags would just add noise since
    // the remedy (enable directive) is a single edit.
    if (try firstF16Site(ctx)) |site| {
        const fix = try ctx.arena.create(Diagnostic.Fix);
        fix.* = .{
            .range = ctx.makeRange(0, 0),
            .text = "enable f16;\n",
        };
        const msg = try ctx.fmt(
            "'f16' requires 'enable f16;' directive at the top of the module",
            .{},
        );
        ctx.report(.{
            .message = msg,
            .range = ctx.makeRange(site.start, site.end),
            .fix = fix,
        });
    }
}

fn hasF16Enable(module: *const Ast.Module) bool {
    for (module.directives.items) |dir| switch (dir) {
        .enable => |e| for (e.features.items) |f| {
            if (std.mem.eql(u8, f, "f16")) return true;
        },
        .requires => |r| for (r.features.items) |f| {
            if (std.mem.eql(u8, f, "f16")) return true;
        },
        else => {},
    };
    return false;
}

const Site = struct { start: u32, end: u32 };

fn firstF16Site(ctx: *Context) error{OutOfMemory}!?Site {
    for (ctx.module.declarations.items) |decl| {
        if (try siteInDecl(ctx, decl)) |s| return s;
    }
    return null;
}

fn siteInDecl(ctx: *Context, decl: Ast.Decl) error{OutOfMemory}!?Site {
    switch (decl) {
        .@"const" => |d| {
            if (d.typ) |t| if (siteInType(t)) |s| return s;
            if (d.initializer) |e| if (siteInExpr(ctx, e)) |s| return s;
        },
        .override => |d| {
            if (d.typ) |t| if (siteInType(t)) |s| return s;
            if (d.initializer) |e| if (siteInExpr(ctx, e)) |s| return s;
        },
        .@"var" => |d| {
            if (d.typ) |t| if (siteInType(t)) |s| return s;
            if (d.initializer) |e| if (siteInExpr(ctx, e)) |s| return s;
        },
        .let => |d| {
            if (d.typ) |t| if (siteInType(t)) |s| return s;
            if (d.initializer) |e| if (siteInExpr(ctx, e)) |s| return s;
        },
        .function => |fd| {
            for (fd.parameters.items) |p| if (siteInType(p.typ)) |s| return s;
            if (fd.return_type) |t| if (siteInType(t)) |s| return s;
            if (fd.body) |body| if (try siteInCompound(ctx, body)) |s| return s;
        },
        .@"struct" => |d| for (d.members.items) |m| {
            if (siteInType(m.typ)) |s| return s;
        },
        .alias => |d| if (siteInType(d.typ)) |s| return s,
        .const_assert => |d| if (siteInExpr(ctx, d.expr)) |s| return s,
    }
    return null;
}

fn siteInCompound(ctx: *Context, c: *Ast.CompoundStmt) error{OutOfMemory}!?Site {
    for (c.stmts.items) |stmt| if (try siteInStmt(ctx, stmt)) |s| return s;
    return null;
}

fn siteInStmt(ctx: *Context, stmt: Ast.Stmt) error{OutOfMemory}!?Site {
    switch (stmt) {
        .compound => |s| return try siteInCompound(ctx, s),
        .@"return" => |s| if (s.value) |v| return siteInExpr(ctx, v),
        .@"if" => |s| {
            if (siteInExpr(ctx, s.condition)) |x| return x;
            if (try siteInCompound(ctx, s.body)) |x| return x;
            if (s.else_branch) |eb| return try siteInStmt(ctx, eb);
        },
        .@"switch" => |s| {
            if (siteInExpr(ctx, s.expr)) |x| return x;
            for (s.cases.items) |case| {
                for (case.selectors.items) |sel| if (siteInExpr(ctx, sel)) |x| return x;
                if (try siteInCompound(ctx, case.body)) |x| return x;
            }
        },
        .@"for" => |s| {
            if (s.init_stmt) |is| if (try siteInStmt(ctx, is)) |x| return x;
            if (s.condition) |c| if (siteInExpr(ctx, c)) |x| return x;
            if (s.update) |u| if (try siteInStmt(ctx, u)) |x| return x;
            if (try siteInCompound(ctx, s.body)) |x| return x;
        },
        .@"while" => |s| {
            if (siteInExpr(ctx, s.condition)) |x| return x;
            if (try siteInCompound(ctx, s.body)) |x| return x;
        },
        .loop => |s| {
            if (try siteInCompound(ctx, s.body)) |x| return x;
            if (s.continuing) |cc| if (try siteInCompound(ctx, cc)) |x| return x;
        },
        .break_if => |s| return siteInExpr(ctx, s.condition),
        .assign => |s| {
            if (siteInExpr(ctx, s.left)) |x| return x;
            if (siteInExpr(ctx, s.right)) |x| return x;
        },
        .phony => |s| return siteInExpr(ctx, s.expr),
        .incr_decr => |s| return siteInExpr(ctx, s.expr),
        .call => |s| {
            if (s.call.func) |f| if (siteInExpr(ctx, f)) |x| return x;
            for (s.call.args.items) |a| if (siteInExpr(ctx, a)) |x| return x;
        },
        .decl => |s| return try siteInDecl(ctx, s.decl),
        .@"break", .@"continue", .discard => {},
    }
    return null;
}

fn siteInExpr(ctx: *Context, root: Ast.Expr) ?Site {
    _ = ctx;
    var stack_buf: [64]Ast.Expr = undefined;
    var top: usize = 1;
    stack_buf[0] = root;
    while (top > 0) {
        top -= 1;
        const e = stack_buf[top];
        switch (e) {
            .literal => |l| if (isF16Literal(l.value)) {
                return .{ .start = l.loc, .end = l.loc + @as(u32, @intCast(l.value.len)) };
            },
            .ident => |i| if (std.mem.eql(u8, i.name, "f16")) {
                // `f16(x)` call-constructor surfaces as `ident("f16")` as the
                // call's func child.
                return .{ .start = i.loc, .end = i.loc + 3 };
            },
            .binary => |b| {
                if (top + 2 > stack_buf.len) return null;
                stack_buf[top] = b.left;
                stack_buf[top + 1] = b.right;
                top += 2;
            },
            .unary => |u| {
                if (top >= stack_buf.len) return null;
                stack_buf[top] = u.operand;
                top += 1;
            },
            .call => |c| {
                if (c.func) |f| {
                    if (top >= stack_buf.len) return null;
                    stack_buf[top] = f;
                    top += 1;
                }
                for (c.args.items) |a| {
                    if (top >= stack_buf.len) return null;
                    stack_buf[top] = a;
                    top += 1;
                }
                if (c.template_type) |t| if (siteInType(t)) |x| return x;
            },
            .index => |i| {
                if (top + 2 > stack_buf.len) return null;
                stack_buf[top] = i.base;
                stack_buf[top + 1] = i.idx;
                top += 2;
            },
            .member => |m| {
                if (top >= stack_buf.len) return null;
                stack_buf[top] = m.base;
                top += 1;
            },
            .paren => |p| {
                if (top >= stack_buf.len) return null;
                stack_buf[top] = p.expr;
                top += 1;
            },
        }
    }
    return null;
}

fn isF16Literal(v: []const u8) bool {
    if (v.len < 2) return false;
    return v[v.len - 1] == 'h';
}

fn siteInType(t: Ast.Type) ?Site {
    return switch (t) {
        .ident => |i| if (std.mem.eql(u8, i.name, "f16")) .{
            .start = i.loc,
            .end = i.loc + 3,
        } else null,
        .vec => |v| blk: {
            if (std.mem.eql(u8, v.shorthand, "vec2h") or std.mem.eql(u8, v.shorthand, "vec3h") or std.mem.eql(u8, v.shorthand, "vec4h")) {
                break :blk .{ .start = v.loc, .end = v.loc + @as(u32, @intCast(v.shorthand.len)) };
            }
            if (v.elem_type) |et| break :blk siteInType(et);
            break :blk null;
        },
        .mat => |m| blk: {
            if (std.mem.endsWith(u8, m.shorthand, "h")) {
                break :blk .{ .start = m.loc, .end = m.loc + @as(u32, @intCast(m.shorthand.len)) };
            }
            if (m.elem_type) |et| break :blk siteInType(et);
            break :blk null;
        },
        .array => |a| if (a.elem_type) |et| siteInType(et) else null,
        .ptr => |p| siteInType(p.elem_type),
        .atomic => |a| siteInType(a.elem_type),
        else => null,
    };
}
