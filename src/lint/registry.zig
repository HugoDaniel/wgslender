//! Compile-time registry of every built-in lint rule.
//!
//! Adding a rule: implement it under `src/lint/rules/<rule>.zig` exporting a
//! `pub const rule: Rule = ...` and add an entry to `all` below. That's it
//! — the Linter will pick it up on the next build.

const Rule = @import("Rule.zig");

const no_unused_vars = @import("rules/no_unused_vars.zig");
const no_dead_code = @import("rules/no_dead_code.zig");
const no_unused_binding = @import("rules/no_unused_binding.zig");
const naming_convention = @import("rules/naming_convention.zig");
const require_entry_point_attrs = @import("rules/require_entry_point_attrs.zig");
const consistent_binding_annotations = @import("rules/consistent_binding_annotations.zig");
const no_magic_numbers = @import("rules/no_magic_numbers.zig");
const no_large_local_arrays = @import("rules/no_large_local_arrays.zig");

/// Every lint rule the linter knows about. Declaration order is the order
/// rules execute in per-file; rules may depend on module-wide analysis but
/// must not depend on other rules' diagnostics.
pub const all = [_]Rule{
    no_unused_vars.rule,
    no_dead_code.rule,
    no_unused_binding.rule,
    naming_convention.rule,
    require_entry_point_attrs.rule,
    consistent_binding_annotations.rule,
    no_magic_numbers.rule,
    no_large_local_arrays.rule,
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
