//! `naming-convention` — enforce a naming style for user-declared symbols.
//!
//! Default convention: `snake_case` (matches WGSL's own builtins like
//! `textureSample`... actually those are camelCase; but user-facing
//! convention in published WGSL is inconsistent — so this rule just
//! asserts whatever convention the user picked and catches drift).
//!
//! Heuristic (the only sensible one without a full-blown parser for the
//! regex option ESLint uses):
//!   * `snake_case`  → all lowercase, digits and underscores, no uppercase.
//!   * `camelCase`   → starts lowercase, no underscores (digits allowed).
//!   * `PascalCase`  → starts uppercase, no underscores (digits allowed).
//!   * `SCREAMING_SNAKE_CASE` → all uppercase, digits/underscores only.
//!
//! Convention is selected per-kind:
//!   * functions / vars / parameters → camelCase (WGSL spec-y style).
//!   * const / override → SCREAMING_SNAKE_CASE.
//!   * struct / alias → PascalCase.
//!
//! Rule authors asked for a style-pack rule, so this ships opinionated
//! defaults. Later slices can lift these into config options.

const std = @import("std");

const Rule = @import("../Rule.zig");
const Context = @import("../Context.zig");
const Diagnostic = @import("../../Diagnostic.zig");

pub const rule = Rule{
    .meta = .{
        .id = "naming-convention",
        .code = Diagnostic.Code.lint_naming_convention,
        .default_severity = .warning,
        .description = "Enforce per-kind naming conventions (camelCase for functions/vars, PascalCase for types, SCREAMING_SNAKE_CASE for consts)",
        .docs_url = "https://github.com/hugoam/wgslender/blob/main/docs/rules/naming-convention.md",
        .category = .style,
    },
    .run = run,
};

const Convention = enum {
    camel_case,
    pascal_case,
    screaming_snake,

    fn label(self: Convention) []const u8 {
        return switch (self) {
            .camel_case => "camelCase",
            .pascal_case => "PascalCase",
            .screaming_snake => "SCREAMING_SNAKE_CASE",
        };
    }

    fn matches(self: Convention, name: []const u8) bool {
        if (name.len == 0) return true; // empty names never flagged
        if (std.mem.startsWith(u8, name, "_")) return true; // leading `_` opt-out
        return switch (self) {
            .camel_case => isCamelCase(name),
            .pascal_case => isPascalCase(name),
            .screaming_snake => isScreamingSnake(name),
        };
    }
};

fn isAsciiLowerAlpha(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

fn isAsciiUpperAlpha(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isCamelCase(name: []const u8) bool {
    if (!isAsciiLowerAlpha(name[0])) return false;
    for (name) |c| {
        if (c == '_') return false;
        if (!isAsciiLowerAlpha(c) and !isAsciiUpperAlpha(c) and !isDigit(c)) return false;
    }
    return true;
}

fn isPascalCase(name: []const u8) bool {
    if (!isAsciiUpperAlpha(name[0])) return false;
    for (name) |c| {
        if (c == '_') return false;
        if (!isAsciiLowerAlpha(c) and !isAsciiUpperAlpha(c) and !isDigit(c)) return false;
    }
    return true;
}

fn isScreamingSnake(name: []const u8) bool {
    if (isAsciiLowerAlpha(name[0])) return false;
    for (name) |c| {
        if (isAsciiLowerAlpha(c)) return false;
        if (!isAsciiUpperAlpha(c) and !isDigit(c) and c != '_') return false;
    }
    return true;
}

fn conventionForKind(kind_tag: anytype) ?Convention {
    // Accepts `Ast.Symbol.Kind` (avoid circular import via @import).
    return switch (kind_tag) {
        .function, .@"var", .let, .parameter => .camel_case,
        .@"const", .override => .screaming_snake,
        .@"struct", .alias => .pascal_case,
        else => null,
    };
}

fn run(ctx: *Context) error{OutOfMemory}!void {
    for (ctx.module.symbols.items) |sym| {
        if (sym.original_name.len == 0) continue;
        if (sym.flags.is_builtin) continue;
        if (sym.flags.is_entry_point) continue;
        if (sym.flags.is_api_facing) continue;
        if (sym.flags.is_external_binding) continue;

        const conv = conventionForKind(sym.kind) orelse continue;
        if (conv.matches(sym.original_name)) continue;

        const name_len: u32 = @intCast(sym.original_name.len);
        const end = sym.loc + name_len;
        const msg = try ctx.fmt(
            "'{s}' does not follow the {s} naming convention expected for {s}",
            .{ sym.original_name, conv.label(), kindLabel(sym.kind) },
        );
        ctx.report(.{
            .message = msg,
            .range = ctx.makeRange(sym.loc, end),
        });
    }
}

fn kindLabel(kind: anytype) []const u8 {
    return switch (kind) {
        .function => "functions",
        .@"var" => "variables",
        .let => "let bindings",
        .parameter => "parameters",
        .@"const" => "constants",
        .override => "overrides",
        .@"struct" => "structs",
        .alias => "type aliases",
        else => "symbols",
    };
}
