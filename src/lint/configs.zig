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

pub const performance = Config{
    .name = "@wgslender/performance",
    .rules = &.{
        .{ .id = "no-redundant-casts", .severity = .warning },
        .{ .id = "prefer-mix", .severity = .warning },
        .{ .id = "no-large-local-arrays", .severity = .warning },
        .{ .id = "prefer-workgroup-shared", .severity = .warning },
    },
};

pub const portability = Config{
    .name = "@wgslender/portability",
    .rules = &.{
        .{ .id = "no-f16-without-extension", .severity = .@"error" },
        .{ .id = "require-entry-point-attrs", .severity = .@"error" },
        .{ .id = "consistent-binding-annotations", .severity = .warning },
    },
};

pub const all = [_]*const Config{
    &recommended,
    &performance,
    &portability,
};

pub fn byName(name: []const u8) ?*const Config {
    for (all) |cfg| {
        if (std.mem.eql(u8, cfg.name, name)) return cfg;
    }
    return null;
}
