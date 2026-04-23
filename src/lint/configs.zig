//! Built-in shareable configs.
//!
//! Users reference these by name via the `extends` field in
//! `wgslender.json`:
//!
//! ```json
//! {
//!   "extends": ["@wgslender/recommended"],
//!   "rules": { "no-unused-vars": "error" }
//! }
//! ```
//!
//! Later entries in `extends` override earlier ones; the user-provided
//! `rules` block takes precedence over every extended config.

const std = @import("std");
const Diagnostic = @import("../Diagnostic.zig");

pub const RuleEntry = struct {
    id: []const u8,
    severity: Diagnostic.Severity,
};

pub const Config = struct {
    name: []const u8,
    rules: []const RuleEntry,
};

pub const recommended = Config{
    .name = "@wgslender/recommended",
    .rules = &.{
        .{ .id = "no-unused-vars", .severity = .warning },
        .{ .id = "no-dead-code", .severity = .warning },
        .{ .id = "no-unused-binding", .severity = .warning },
    },
};

pub const style = Config{
    .name = "@wgslender/style",
    .rules = &.{
        .{ .id = "naming-convention", .severity = .warning },
    },
};

pub const performance = Config{
    .name = "@wgslender/performance",
    .rules = &.{
        .{ .id = "no-large-local-arrays", .severity = .warning },
    },
};

pub const portability = Config{
    .name = "@wgslender/portability",
    .rules = &.{
        .{ .id = "require-entry-point-attrs", .severity = .@"error" },
        .{ .id = "consistent-binding-annotations", .severity = .warning },
    },
};

/// "Opt-in strictness" meta-pack: everything except rules that are
/// typically noisy (no-magic-numbers). Useful for CI gates on new
/// projects.
pub const strict = Config{
    .name = "@wgslender/strict",
    .rules = &.{
        .{ .id = "no-unused-vars", .severity = .@"error" },
        .{ .id = "no-dead-code", .severity = .@"error" },
        .{ .id = "no-unused-binding", .severity = .@"error" },
        .{ .id = "naming-convention", .severity = .warning },
        .{ .id = "no-large-local-arrays", .severity = .warning },
        .{ .id = "require-entry-point-attrs", .severity = .@"error" },
        .{ .id = "consistent-binding-annotations", .severity = .@"error" },
    },
};

pub const all = [_]*const Config{
    &recommended,
    &style,
    &performance,
    &portability,
    &strict,
};

pub fn byName(name: []const u8) ?*const Config {
    for (all) |cfg| {
        if (std.mem.eql(u8, cfg.name, name)) return cfg;
    }
    return null;
}
