//! Asserts every diagnostic code maps to a non-empty WGSL spec reference.
//!
//! Roadmap item 9 ("Spec references on more errors"): only uniformity
//! errors used to populate `spec_ref`. After Phase A of the diagnostics
//! roadmap TDD plan, every `E0xxx` / `W0xxx` code auto-populates
//! `spec_ref` via `Diagnostic.specRefFor`, so the LSP can surface
//! `spec_url` and the formatter can print `[WGSL spec section ...]`.

const std = @import("std");
const wgslender = @import("wgslender");

const Diagnostic = wgslender.Diagnostic;

const all_codes = [_][]const u8{
    Diagnostic.Code.unexpected_token,
    Diagnostic.Code.unterminated_string,
    Diagnostic.Code.invalid_number,
    Diagnostic.Code.reserved_word,
    Diagnostic.Code.undefined_symbol,
    Diagnostic.Code.duplicate_symbol,
    Diagnostic.Code.use_before_decl,
    Diagnostic.Code.recursive_function,
    Diagnostic.Code.recursive_type,
    Diagnostic.Code.type_mismatch,
    Diagnostic.Code.invalid_operand,
    Diagnostic.Code.invalid_arg_count,
    Diagnostic.Code.invalid_arg_type,
    Diagnostic.Code.not_callable,
    Diagnostic.Code.not_indexable,
    Diagnostic.Code.no_such_member,
    Diagnostic.Code.invalid_return,
    Diagnostic.Code.missing_return,
    Diagnostic.Code.invalid_conversion,
    Diagnostic.Code.invalid_assignment,
    Diagnostic.Code.index_out_of_bounds,
    Diagnostic.Code.must_use_ignored,
    Diagnostic.Code.missing_initializer,
    Diagnostic.Code.invalid_initializer,
    Diagnostic.Code.invalid_const_expr,
    Diagnostic.Code.invalid_override,
    Diagnostic.Code.invalid_address_space,
    Diagnostic.Code.invalid_access_mode,
    Diagnostic.Code.duplicate_case_selector,
    Diagnostic.Code.missing_default_case,
    Diagnostic.Code.invalid_atomic_type,
    Diagnostic.Code.invalid_matrix_element,
    Diagnostic.Code.empty_struct,
    Diagnostic.Code.invalid_override_id,
    Diagnostic.Code.duplicate_override_id,
    Diagnostic.Code.invalid_array_count,
    Diagnostic.Code.invalid_float_literal,
    Diagnostic.Code.expression_not_const,
    Diagnostic.Code.division_by_zero,
    Diagnostic.Code.integer_overflow,
    Diagnostic.Code.invalid_attribute,
    Diagnostic.Code.duplicate_attribute,
    Diagnostic.Code.missing_attribute,
    Diagnostic.Code.invalid_builtin,
    Diagnostic.Code.invalid_location,
    Diagnostic.Code.invalid_interpolation,
    Diagnostic.Code.missing_interpolation,
    Diagnostic.Code.break_outside_loop,
    Diagnostic.Code.continue_outside_loop,
    Diagnostic.Code.discard_outside_fragment,
    Diagnostic.Code.unreachable_code,
    Diagnostic.Code.nesting_too_deep,
    Diagnostic.Code.infinite_loop,
    Diagnostic.Code.return_in_continuing,
    Diagnostic.Code.invalid_entry_point,
    Diagnostic.Code.missing_entry_point,
    Diagnostic.Code.invalid_shader_io,
    Diagnostic.Code.entry_point_called,
    Diagnostic.Code.non_uniform_derivative,
    Diagnostic.Code.non_uniform_barrier,
    Diagnostic.Code.non_uniform_texture,
    Diagnostic.Code.non_uniform_subgroup,
    Diagnostic.Code.invalid_workgroup_var,
    Diagnostic.Code.invalid_storage_var,
    Diagnostic.Code.invalid_uniform_var,
    Diagnostic.Code.missing_binding,
    Diagnostic.Code.duplicate_binding,
    Diagnostic.Code.opaque_in_struct,
    Diagnostic.Code.runtime_array_not_last,
    Diagnostic.Code.const_assert_failed,
    Diagnostic.Code.feature_not_enabled,
    Diagnostic.Code.unknown_feature,
    Diagnostic.Code.invalid_diagnostic_rule,
    Diagnostic.Code.invalid_diagnostic_severity,
    Diagnostic.Code.shadowing,
    Diagnostic.Code.redundant_cast,
};

test "specRefFor: every known code has a non-empty spec_ref" {
    for (all_codes) |code| {
        const ref = Diagnostic.specRefFor(code);
        if (ref.len == 0) {
            std.debug.print("\nspec_ref empty for code {s}\n", .{code});
            return error.TestUnexpectedResult;
        }
    }
}

test "specRefFor: unknown code returns empty" {
    try std.testing.expectEqualStrings("", Diagnostic.specRefFor("Z9999"));
    try std.testing.expectEqualStrings("", Diagnostic.specRefFor(""));
}

test "add: auto-populates spec_ref when code is set and spec_ref is empty" {
    var d = try Diagnostic.init(std.testing.allocator, "");
    defer d.deinit(std.testing.allocator);

    d.addErrorWithCode(std.testing.allocator, 0, Diagnostic.Code.type_mismatch, "mismatch");
    try std.testing.expect(d.items().len == 1);
    try std.testing.expect(d.items()[0].spec_ref.len > 0);
}

test "add: preserves explicit spec_ref set by caller" {
    var d = try Diagnostic.init(std.testing.allocator, "");
    defer d.deinit(std.testing.allocator);

    d.add(std.testing.allocator, .{
        .severity = .@"error",
        .code = Diagnostic.Code.non_uniform_derivative,
        .message = "uniformity",
        .spec_ref = "custom-override",
    });
    try std.testing.expectEqualStrings("custom-override", d.items()[0].spec_ref);
}

test "add: leaves spec_ref empty when no code is set" {
    var d = try Diagnostic.init(std.testing.allocator, "");
    defer d.deinit(std.testing.allocator);

    d.addError(std.testing.allocator, 0, "raw error without code");
    try std.testing.expectEqualStrings("", d.items()[0].spec_ref);
}

// -------------------------------------------------------------------------
// End-to-end: real WGSL sources produce diagnostics with populated spec_ref
// -------------------------------------------------------------------------

fn expectAllDiagsHaveSpecRef(source: [:0]const u8) !void {
    var r = try wgslender.validateWithOptions(std.testing.allocator, source, .{});
    defer r.deinit();

    for (r.diagnostics.items()) |d| {
        if (d.code.len == 0) continue; // raw errors without codes are allowed
        if (d.spec_ref.len == 0) {
            std.debug.print(
                "\ndiag {s} at {d}:{d} has code but empty spec_ref: {s}\n",
                .{ d.code, d.range.start.line, d.range.start.column, d.message },
            );
            return error.TestUnexpectedResult;
        }
    }
}

test "e2e: undefined symbol has spec_ref" {
    try expectAllDiagsHaveSpecRef(
        \\fn main() { let y = x; }
    );
}

test "e2e: type mismatch has spec_ref" {
    try expectAllDiagsHaveSpecRef(
        \\fn main() { let a: i32 = 1.5; }
    );
}

test "e2e: invalid entry point has spec_ref" {
    try expectAllDiagsHaveSpecRef(
        \\@vertex fn main(x: f32) {}
    );
}

test "e2e: break outside loop has spec_ref" {
    try expectAllDiagsHaveSpecRef(
        \\fn main() { break; }
    );
}

test "e2e: duplicate binding has spec_ref" {
    try expectAllDiagsHaveSpecRef(
        \\@group(0) @binding(0) var<uniform> a: f32;
        \\@group(0) @binding(0) var<uniform> b: f32;
    );
}

test "e2e: unknown enable feature has spec_ref" {
    try expectAllDiagsHaveSpecRef(
        \\enable not_a_real_feature;
    );
}
