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
const no_unreachable = @import("rules/no_unreachable.zig");
const no_constant_condition = @import("rules/no_constant_condition.zig");
const for_direction = @import("rules/for_direction.zig");
const no_duplicate_case = @import("rules/no_duplicate_case.zig");
const no_self_assign = @import("rules/no_self_assign.zig");
const no_redundant_casts = @import("rules/no_redundant_casts.zig");
const prefer_mix = @import("rules/prefer_mix.zig");
const no_f16_without_extension = @import("rules/no_f16_without_extension.zig");
const prefer_let_over_var = @import("rules/prefer_let_over_var.zig");
const no_empty = @import("rules/no_empty.zig");
const no_useless_return = @import("rules/no_useless_return.zig");
const no_lonely_if = @import("rules/no_lonely_if.zig");
const no_shadow = @import("rules/no_shadow.zig");

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
    no_unreachable.rule,
    no_constant_condition.rule,
    for_direction.rule,
    no_duplicate_case.rule,
    no_self_assign.rule,
    no_redundant_casts.rule,
    prefer_mix.rule,
    no_f16_without_extension.rule,
    prefer_let_over_var.rule,
    no_empty.rule,
    no_useless_return.rule,
    no_lonely_if.rule,
    no_shadow.rule,
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
