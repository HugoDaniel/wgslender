//! Compile-time registry of every built-in lint rule.
//!
//! Adding a rule: implement it under `src/lint/rules/<rule>.zig` exporting a
//! `pub const rule: Rule = ...` and add an entry to `all` below. That's it
//! — the Linter will pick it up on the next build.

const Rule = @import("Rule.zig");

const no_unused_vars = @import("rules/no_unused_vars.zig");

/// Every lint rule the linter knows about. Declaration order is the order
/// rules execute in per-file; rules may depend on module-wide analysis but
/// must not depend on other rules' diagnostics.
pub const all = [_]Rule{
    no_unused_vars.rule,
};

/// Look up a rule by its public id (e.g. `"no-unused-vars"`).
pub fn byId(id: []const u8) ?*const Rule {
    const std = @import("std");
    for (&all) |*r| {
        if (std.mem.eql(u8, r.meta.id, id)) return r;
    }
    return null;
}

/// Look up a rule by its diagnostic code (e.g. `"W0001"`).
pub fn byCode(code: []const u8) ?*const Rule {
    const std = @import("std");
    for (&all) |*r| {
        if (std.mem.eql(u8, r.meta.code, code)) return r;
    }
    return null;
}
