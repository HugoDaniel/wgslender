// Bridge file for validation test data.
// @embedFile resolves paths relative to this file's directory (tests/).
// Used by tests/validation_test.zig via the "validation_data" module import.

// --- types/ ---
pub const @"types/struct_basic" = @embedFile("testdata/validation/types/struct_basic.wgsl");
pub const @"types/array_basic" = @embedFile("testdata/validation/types/array_basic.wgsl");
pub const @"types/entry_point_compute" = @embedFile("testdata/validation/types/entry_point_compute.wgsl");
pub const @"types/entry_point_vertex" = @embedFile("testdata/validation/types/entry_point_vertex.wgsl");
pub const @"types/entry_point_fragment" = @embedFile("testdata/validation/types/entry_point_fragment.wgsl");
pub const @"types/switch_valid" = @embedFile("testdata/validation/types/switch_valid.wgsl");
pub const @"types/matrix_valid" = @embedFile("testdata/validation/types/matrix_valid.wgsl");
pub const @"types/incr_decr_valid" = @embedFile("testdata/validation/types/incr_decr_valid.wgsl");
pub const @"types/vector_constructors_valid" = @embedFile("testdata/validation/types/vector_constructors_valid.wgsl");
pub const @"types/matrix_constructors_valid" = @embedFile("testdata/validation/types/matrix_constructors_valid.wgsl");

// --- declarations/ ---
pub const @"declarations/let_basic" = @embedFile("testdata/validation/declarations/let_basic.wgsl");
pub const @"declarations/const_basic" = @embedFile("testdata/validation/declarations/const_basic.wgsl");
pub const @"declarations/uniform_storage" = @embedFile("testdata/validation/declarations/uniform_storage.wgsl");
pub const @"declarations/var_basic" = @embedFile("testdata/validation/declarations/var_basic.wgsl");
pub const @"declarations/const_assert_valid" = @embedFile("testdata/validation/declarations/const_assert_valid.wgsl");
pub const @"declarations/override_valid" = @embedFile("testdata/validation/declarations/override_valid.wgsl");
pub const @"declarations/atomic_valid" = @embedFile("testdata/validation/declarations/atomic_valid.wgsl");
pub const @"declarations/const_propagation" = @embedFile("testdata/validation/declarations/const_propagation.wgsl");
pub const @"declarations/const_propagation_chain" = @embedFile("testdata/validation/declarations/const_propagation_chain.wgsl");
pub const @"declarations/const_propagation_negated" = @embedFile("testdata/validation/declarations/const_propagation_negated.wgsl");
pub const @"declarations/const_propagation_workgroup_size" = @embedFile("testdata/validation/declarations/const_propagation_workgroup_size.wgsl");
pub const @"declarations/const_switch_cases" = @embedFile("testdata/validation/declarations/const_switch_cases.wgsl");
pub const @"declarations/diagnostic_valid" = @embedFile("testdata/validation/declarations/diagnostic_valid.wgsl");
pub const @"declarations/f16_with_enable" = @embedFile("testdata/validation/declarations/f16_with_enable.wgsl");
pub const @"declarations/override_workgroup_size" = @embedFile("testdata/validation/declarations/override_workgroup_size.wgsl");
pub const @"declarations/const_assert_true" = @embedFile("testdata/validation/declarations/const_assert_true.wgsl");

// --- uniformity/ ---
// Green pins committed in Block U0; U1's three reds registered next; U2's four
// reds + one valid twin; U3's two reds + two valid twins registered below —
// each block registers its own reds (reds-first per block; suite stays green
// between blocks).
pub const @"uniformity/barrier_uniform" = @embedFile("testdata/validation/uniformity/barrier_uniform.wgsl");
pub const @"uniformity/derivatives_uniform" = @embedFile("testdata/validation/uniformity/derivatives_uniform.wgsl");
pub const @"uniformity/barrier_non_uniform_if" = @embedFile("testdata/validation/uniformity/barrier_non_uniform_if.wgsl");
pub const @"uniformity/barrier_after_balanced_if" = @embedFile("testdata/validation/uniformity/barrier_after_balanced_if.wgsl");
// Block U1 reds — symbol-grounded sources kill the name matching.
pub const @"uniformity/renamed_param_barrier" = @embedFile("testdata/validation/uniformity/renamed_param_barrier.wgsl");
pub const @"uniformity/user_var_named_position" = @embedFile("testdata/validation/uniformity/user_var_named_position.wgsl");
pub const @"uniformity/texture_dimensions_condition" = @embedFile("testdata/validation/uniformity/texture_dimensions_condition.wgsl");
// Block U2 reds — intra-function dataflow (values, behaviors, reconvergence).
pub const @"uniformity/let_propagation_barrier" = @embedFile("testdata/validation/uniformity/let_propagation_barrier.wgsl");
pub const @"uniformity/storage_load_condition" = @embedFile("testdata/validation/uniformity/storage_load_condition.wgsl");
pub const @"uniformity/workgroup_load_condition" = @embedFile("testdata/validation/uniformity/workgroup_load_condition.wgsl");
pub const @"uniformity/divergent_return_barrier" = @embedFile("testdata/validation/uniformity/divergent_return_barrier.wgsl");
// Block U2 valid twin — a uniform-buffer load in a condition stays valid.
pub const @"uniformity/uniform_load_condition" = @embedFile("testdata/validation/uniformity/uniform_load_condition.wgsl");
// Block U3 reds — cross-function summaries (callee-side + value-side taint).
pub const @"uniformity/helper_barrier_non_uniform_call" = @embedFile("testdata/validation/uniformity/helper_barrier_non_uniform_call.wgsl");
pub const @"uniformity/helper_returns_non_uniform" = @embedFile("testdata/validation/uniformity/helper_returns_non_uniform.wgsl");
// Block U3 valid twins — a helper's barrier/return is only tainted under a
// non-uniform call site / argument.
pub const @"uniformity/helper_barrier_uniform_call" = @embedFile("testdata/validation/uniformity/helper_barrier_uniform_call.wgsl");
pub const @"uniformity/helper_returns_uniform" = @embedFile("testdata/validation/uniformity/helper_returns_uniform.wgsl");
// Block U4 reds — source `diagnostic(...)` controls now suppress E0700: a
// module-scope directive and a function-scope `@diagnostic` attribute.
pub const @"uniformity/directive_off_derivative" = @embedFile("testdata/validation/uniformity/directive_off_derivative.wgsl");
pub const @"uniformity/fn_attr_off_derivative" = @embedFile("testdata/validation/uniformity/fn_attr_off_derivative.wgsl");

// --- builtins/ ---
pub const @"builtins/vector_math" = @embedFile("testdata/validation/builtins/vector_math.wgsl");
pub const @"builtins/math_basic" = @embedFile("testdata/validation/builtins/math_basic.wgsl");
pub const @"builtins/atomic_ops" = @embedFile("testdata/validation/builtins/atomic_ops.wgsl");
pub const @"builtins/texture_sample" = @embedFile("testdata/validation/builtins/texture_sample.wgsl");
pub const @"builtins/must_use_consumed" = @embedFile("testdata/validation/builtins/must_use_consumed.wgsl");
// Phase 3e — atomicStore / arrayLength / barriers migration coverage.
pub const @"builtins/atomic_store" = @embedFile("testdata/validation/builtins/atomic_store.wgsl");
pub const @"builtins/atomic_store_wrong_value" = @embedFile("testdata/validation/builtins/atomic_store_wrong_value.wgsl");
pub const @"builtins/atomic_store_non_atomic" = @embedFile("testdata/validation/builtins/atomic_store_non_atomic.wgsl");
pub const @"builtins/atomic_store_wrong_signed_value" = @embedFile("testdata/validation/builtins/atomic_store_wrong_signed_value.wgsl");
pub const @"builtins/array_length" = @embedFile("testdata/validation/builtins/array_length.wgsl");
pub const @"builtins/array_length_sized" = @embedFile("testdata/validation/builtins/array_length_sized.wgsl");
pub const @"builtins/array_length_workgroup" = @embedFile("testdata/validation/builtins/array_length_workgroup.wgsl");
pub const @"builtins/array_length_non_array" = @embedFile("testdata/validation/builtins/array_length_non_array.wgsl");
pub const @"builtins/barriers" = @embedFile("testdata/validation/builtins/barriers.wgsl");
pub const @"builtins/barriers_wrong_arity" = @embedFile("testdata/validation/builtins/barriers_wrong_arity.wgsl");

// --- types/ (new) ---
pub const @"types/index_bounds_valid" = @embedFile("testdata/validation/types/index_bounds_valid.wgsl");
pub const @"types/interpolate_valid" = @embedFile("testdata/validation/types/interpolate_valid.wgsl");
pub const @"types/float_literals_valid" = @embedFile("testdata/validation/types/float_literals_valid.wgsl");
pub const @"types/nesting_deep_valid" = @embedFile("testdata/validation/types/nesting_deep_valid.wgsl");
pub const @"types/shadowing_none" = @embedFile("testdata/validation/types/shadowing_none.wgsl");
pub const @"types/shadowing_param" = @embedFile("testdata/validation/types/shadowing_param.wgsl");
pub const @"types/shadowing_let" = @embedFile("testdata/validation/types/shadowing_let.wgsl");
pub const @"types/loop_with_break" = @embedFile("testdata/validation/types/loop_with_break.wgsl");
pub const @"types/loop_with_break_if" = @embedFile("testdata/validation/types/loop_with_break_if.wgsl");
pub const @"types/loop_infinite_warning" = @embedFile("testdata/validation/types/loop_infinite_warning.wgsl");
pub const @"types/division_valid" = @embedFile("testdata/validation/types/division_valid.wgsl");
pub const @"types/pointer_param_valid" = @embedFile("testdata/validation/types/pointer_param_valid.wgsl");
pub const @"types/entry_point_no_call" = @embedFile("testdata/validation/types/entry_point_no_call.wgsl");

// --- expressions/binary/mul/ ---
pub const @"expressions/binary/mul/vec3_mat3x3_f32" = @embedFile("testdata/validation/expressions/binary/mul/vec3_mat3x3_f32.wgsl");
pub const @"expressions/binary/mul/mat3x3_vec3_f32" = @embedFile("testdata/validation/expressions/binary/mul/mat3x3_vec3_f32.wgsl");
pub const @"expressions/binary/mul/mat4x4_vec4_f32" = @embedFile("testdata/validation/expressions/binary/mul/mat4x4_vec4_f32.wgsl");
pub const @"expressions/binary/mul/scalar_vec3_f32" = @embedFile("testdata/validation/expressions/binary/mul/scalar_vec3_f32.wgsl");
pub const @"expressions/binary/mul/mat_mat_f32" = @embedFile("testdata/validation/expressions/binary/mul/mat_mat_f32.wgsl");
pub const @"expressions/binary/mul/vec_vec_f32" = @embedFile("testdata/validation/expressions/binary/mul/vec_vec_f32.wgsl");
pub const @"expressions/binary/mul/vec3_scalar_f32" = @embedFile("testdata/validation/expressions/binary/mul/vec3_scalar_f32.wgsl");
pub const @"expressions/binary/mul/mat_scalar_f32" = @embedFile("testdata/validation/expressions/binary/mul/mat_scalar_f32.wgsl");

// --- expressions/binary/add/ ---
pub const @"expressions/binary/add/scalar_scalar_i32" = @embedFile("testdata/validation/expressions/binary/add/scalar_scalar_i32.wgsl");
pub const @"expressions/binary/add/vec_vec_f32" = @embedFile("testdata/validation/expressions/binary/add/vec_vec_f32.wgsl");
pub const @"expressions/binary/add/scalar_scalar_f32" = @embedFile("testdata/validation/expressions/binary/add/scalar_scalar_f32.wgsl");

// --- errors/calls/ ---
pub const @"errors/calls/builtin_wrong_args" = @embedFile("testdata/validation/errors/calls/builtin_wrong_args.wgsl");
pub const @"errors/calls/too_many_args" = @embedFile("testdata/validation/errors/calls/too_many_args.wgsl");
pub const @"errors/calls/arg_type_mismatch" = @embedFile("testdata/validation/errors/calls/arg_type_mismatch.wgsl");
pub const @"errors/calls/too_few_args" = @embedFile("testdata/validation/errors/calls/too_few_args.wgsl");
pub const @"errors/calls/not_callable" = @embedFile("testdata/validation/errors/calls/not_callable.wgsl");
pub const @"errors/calls/vec_constructor_wrong_count" = @embedFile("testdata/validation/errors/calls/vec_constructor_wrong_count.wgsl");
pub const @"errors/calls/mat_constructor_wrong_count" = @embedFile("testdata/validation/errors/calls/mat_constructor_wrong_count.wgsl");
pub const @"errors/calls/scalar_constructor_too_many" = @embedFile("testdata/validation/errors/calls/scalar_constructor_too_many.wgsl");
pub const @"errors/calls/vec_constructor_type_mismatch" = @embedFile("testdata/validation/errors/calls/vec_constructor_type_mismatch.wgsl");
pub const @"errors/calls/must_use_ignored" = @embedFile("testdata/validation/errors/calls/must_use_ignored.wgsl");
pub const @"errors/calls/must_use_sin" = @embedFile("testdata/validation/errors/calls/must_use_sin.wgsl");
pub const @"errors/calls/must_use_dot" = @embedFile("testdata/validation/errors/calls/must_use_dot.wgsl");
pub const @"errors/calls/must_use_max" = @embedFile("testdata/validation/errors/calls/must_use_max.wgsl");
pub const @"errors/calls/entry_point_called" = @embedFile("testdata/validation/errors/calls/entry_point_called.wgsl");

// --- errors/types/ ---
pub const @"errors/types/let_initializer_mismatch" = @embedFile("testdata/validation/errors/types/let_initializer_mismatch.wgsl");
pub const @"errors/types/if_condition_not_bool" = @embedFile("testdata/validation/errors/types/if_condition_not_bool.wgsl");
pub const @"errors/types/for_condition_not_bool" = @embedFile("testdata/validation/errors/types/for_condition_not_bool.wgsl");
pub const @"errors/types/assign_type_mismatch" = @embedFile("testdata/validation/errors/types/assign_type_mismatch.wgsl");
pub const @"errors/types/return_type_mismatch" = @embedFile("testdata/validation/errors/types/return_type_mismatch.wgsl");
pub const @"errors/types/while_condition_not_bool" = @embedFile("testdata/validation/errors/types/while_condition_not_bool.wgsl");
pub const @"errors/types/var_initializer_mismatch" = @embedFile("testdata/validation/errors/types/var_initializer_mismatch.wgsl");
pub const @"errors/types/switch_duplicate_case" = @embedFile("testdata/validation/errors/types/switch_duplicate_case.wgsl");
pub const @"errors/types/switch_missing_default" = @embedFile("testdata/validation/errors/types/switch_missing_default.wgsl");
pub const @"errors/types/incr_decr_non_concrete" = @embedFile("testdata/validation/errors/types/incr_decr_non_concrete.wgsl");
pub const @"errors/types/index_out_of_bounds" = @embedFile("testdata/validation/errors/types/index_out_of_bounds.wgsl");
pub const @"errors/types/index_out_of_bounds_const" = @embedFile("testdata/validation/errors/types/index_out_of_bounds_const.wgsl");
pub const @"errors/types/index_out_of_bounds_vector" = @embedFile("testdata/validation/errors/types/index_out_of_bounds_vector.wgsl");
pub const @"errors/types/index_negative" = @embedFile("testdata/validation/errors/types/index_negative.wgsl");
pub const @"errors/types/index_out_of_bounds_matrix" = @embedFile("testdata/validation/errors/types/index_out_of_bounds_matrix.wgsl");
pub const @"errors/types/index_out_of_bounds_zero" = @embedFile("testdata/validation/errors/types/index_out_of_bounds_zero.wgsl");
pub const @"errors/types/index_out_of_bounds_const_idx" = @embedFile("testdata/validation/errors/types/index_out_of_bounds_const_idx.wgsl");
pub const @"errors/types/index_out_of_bounds_vec4" = @embedFile("testdata/validation/errors/types/index_out_of_bounds_vec4.wgsl");
pub const @"errors/types/missing_interpolation" = @embedFile("testdata/validation/errors/types/missing_interpolation.wgsl");
pub const @"errors/types/interpolate_integer_linear" = @embedFile("testdata/validation/errors/types/interpolate_integer_linear.wgsl");
pub const @"errors/types/interpolate_flat_sample" = @embedFile("testdata/validation/errors/types/interpolate_flat_sample.wgsl");
pub const @"errors/types/interpolate_perspective_first" = @embedFile("testdata/validation/errors/types/interpolate_perspective_first.wgsl");
pub const @"errors/types/interpolate_invalid_type" = @embedFile("testdata/validation/errors/types/interpolate_invalid_type.wgsl");
pub const @"errors/types/interpolate_linear_first" = @embedFile("testdata/validation/errors/types/interpolate_linear_first.wgsl");
pub const @"errors/types/interpolate_linear_either" = @embedFile("testdata/validation/errors/types/interpolate_linear_either.wgsl");
pub const @"errors/types/interpolate_perspective_either" = @embedFile("testdata/validation/errors/types/interpolate_perspective_either.wgsl");
pub const @"errors/types/switch_duplicate_const_case" = @embedFile("testdata/validation/errors/types/switch_duplicate_const_case.wgsl");

// --- errors/declarations/ ---
pub const @"errors/declarations/const_without_init" = @embedFile("testdata/validation/errors/declarations/const_without_init.wgsl");
pub const @"errors/declarations/missing_group" = @embedFile("testdata/validation/errors/declarations/missing_group.wgsl");
pub const @"errors/declarations/let_without_init" = @embedFile("testdata/validation/errors/declarations/let_without_init.wgsl");
pub const @"errors/declarations/missing_binding" = @embedFile("testdata/validation/errors/declarations/missing_binding.wgsl");
pub const @"errors/declarations/storage_write_only" = @embedFile("testdata/validation/errors/declarations/storage_write_only.wgsl");
pub const @"errors/declarations/empty_struct" = @embedFile("testdata/validation/errors/declarations/empty_struct.wgsl");
pub const @"errors/declarations/duplicate_struct_member" = @embedFile("testdata/validation/errors/declarations/duplicate_struct_member.wgsl");
pub const @"errors/declarations/recursive_struct" = @embedFile("testdata/validation/errors/declarations/recursive_struct.wgsl");
pub const @"errors/declarations/override_id_out_of_range" = @embedFile("testdata/validation/errors/declarations/override_id_out_of_range.wgsl");
pub const @"errors/declarations/override_id_duplicate" = @embedFile("testdata/validation/errors/declarations/override_id_duplicate.wgsl");
pub const @"errors/declarations/array_size_zero" = @embedFile("testdata/validation/errors/declarations/array_size_zero.wgsl");
pub const @"errors/declarations/atomic_invalid_type" = @embedFile("testdata/validation/errors/declarations/atomic_invalid_type.wgsl");
pub const @"errors/declarations/matrix_invalid_element" = @embedFile("testdata/validation/errors/declarations/matrix_invalid_element.wgsl");
pub const @"errors/declarations/duplicate_var" = @embedFile("testdata/validation/errors/declarations/duplicate_var.wgsl");
pub const @"errors/declarations/duplicate_fn" = @embedFile("testdata/validation/errors/declarations/duplicate_fn.wgsl");
pub const @"errors/declarations/duplicate_binding" = @embedFile("testdata/validation/errors/declarations/duplicate_binding.wgsl");
pub const @"errors/declarations/duplicate_attribute" = @embedFile("testdata/validation/errors/declarations/duplicate_attribute.wgsl");
pub const @"errors/declarations/align_not_power_of_2" = @embedFile("testdata/validation/errors/declarations/align_not_power_of_2.wgsl");
pub const @"errors/declarations/size_too_small" = @embedFile("testdata/validation/errors/declarations/size_too_small.wgsl");
pub const @"errors/declarations/duplicate_location" = @embedFile("testdata/validation/errors/declarations/duplicate_location.wgsl");
pub const @"errors/declarations/missing_io_attr" = @embedFile("testdata/validation/errors/declarations/missing_io_attr.wgsl");
pub const @"errors/declarations/const_assert_non_bool" = @embedFile("testdata/validation/errors/declarations/const_assert_non_bool.wgsl");
pub const @"errors/declarations/f16_without_enable" = @embedFile("testdata/validation/errors/declarations/f16_without_enable.wgsl");
pub const @"errors/declarations/f16_literal_without_enable" = @embedFile("testdata/validation/errors/declarations/f16_literal_without_enable.wgsl");
pub const @"errors/declarations/f16_vec_without_enable" = @embedFile("testdata/validation/errors/declarations/f16_vec_without_enable.wgsl");
pub const @"errors/declarations/unknown_enable_feature" = @embedFile("testdata/validation/errors/declarations/unknown_enable_feature.wgsl");
pub const @"errors/declarations/runtime_workgroup_size" = @embedFile("testdata/validation/errors/declarations/runtime_workgroup_size.wgsl");
pub const @"errors/declarations/var_in_workgroup_size" = @embedFile("testdata/validation/errors/declarations/var_in_workgroup_size.wgsl");
pub const @"errors/declarations/runtime_array_size" = @embedFile("testdata/validation/errors/declarations/runtime_array_size.wgsl");
pub const @"errors/declarations/float_literal_overflow" = @embedFile("testdata/validation/errors/declarations/float_literal_overflow.wgsl");
pub const @"errors/declarations/float_literal_overflow_h" = @embedFile("testdata/validation/errors/declarations/float_literal_overflow_h.wgsl");
pub const @"errors/declarations/diagnostic_invalid_severity" = @embedFile("testdata/validation/errors/declarations/diagnostic_invalid_severity.wgsl");
pub const @"errors/declarations/pointer_param_storage" = @embedFile("testdata/validation/errors/declarations/pointer_param_storage.wgsl");
pub const @"errors/declarations/runtime_array_not_last" = @embedFile("testdata/validation/errors/declarations/runtime_array_not_last.wgsl");
pub const @"errors/declarations/opaque_in_struct" = @embedFile("testdata/validation/errors/declarations/opaque_in_struct.wgsl");
pub const @"errors/declarations/workgroup_size_zero" = @embedFile("testdata/validation/errors/declarations/workgroup_size_zero.wgsl");
pub const @"errors/declarations/invariant_not_position" = @embedFile("testdata/validation/errors/declarations/invariant_not_position.wgsl");
pub const @"errors/declarations/location_on_compute" = @embedFile("testdata/validation/errors/declarations/location_on_compute.wgsl");
pub const @"errors/declarations/builtin_on_module_private_var" = @embedFile("testdata/validation/errors/declarations/builtin_on_module_private_var.wgsl");
pub const @"errors/declarations/builtin_on_module_workgroup_var" = @embedFile("testdata/validation/errors/declarations/builtin_on_module_workgroup_var.wgsl");
pub const @"errors/declarations/builtin_on_module_storage_var" = @embedFile("testdata/validation/errors/declarations/builtin_on_module_storage_var.wgsl");
pub const @"errors/declarations/location_on_module_private_var" = @embedFile("testdata/validation/errors/declarations/location_on_module_private_var.wgsl");
pub const @"errors/declarations/location_on_module_uniform_var" = @embedFile("testdata/validation/errors/declarations/location_on_module_uniform_var.wgsl");
pub const @"errors/declarations/builtin_on_override" = @embedFile("testdata/validation/errors/declarations/builtin_on_override.wgsl");
pub const @"errors/declarations/location_on_override" = @embedFile("testdata/validation/errors/declarations/location_on_override.wgsl");
pub const @"errors/declarations/builtin_unknown_name_on_module_var" = @embedFile("testdata/validation/errors/declarations/builtin_unknown_name_on_module_var.wgsl");
pub const @"errors/declarations/const_assert_false" = @embedFile("testdata/validation/errors/declarations/const_assert_false.wgsl");
pub const @"errors/declarations/atomic_wrong_space" = @embedFile("testdata/validation/errors/declarations/atomic_wrong_space.wgsl");
pub const @"errors/declarations/nested_struct_io" = @embedFile("testdata/validation/errors/declarations/nested_struct_io.wgsl");
pub const @"errors/declarations/non_constructible_param" = @embedFile("testdata/validation/errors/declarations/non_constructible_param.wgsl");
pub const @"errors/declarations/duplicate_builtin_io" = @embedFile("testdata/validation/errors/declarations/duplicate_builtin_io.wgsl");
pub const @"errors/declarations/location_and_builtin" = @embedFile("testdata/validation/errors/declarations/location_and_builtin.wgsl");
pub const @"errors/declarations/nested_runtime_array_struct" = @embedFile("testdata/validation/errors/declarations/nested_runtime_array_struct.wgsl");

// --- errors/types/ (new batch) ---
pub const @"errors/types/assign_to_let" = @embedFile("testdata/validation/errors/types/assign_to_let.wgsl");
pub const @"errors/types/assign_to_param" = @embedFile("testdata/validation/errors/types/assign_to_param.wgsl");
pub const @"errors/types/swizzle_duplicate_assign" = @embedFile("testdata/validation/errors/types/swizzle_duplicate_assign.wgsl");

// --- errors/operations/ (new batch) ---
pub const @"errors/operations/shift_exceeds_width" = @embedFile("testdata/validation/errors/operations/shift_exceeds_width.wgsl");

// --- errors/operations/ ---
pub const @"errors/operations/mul_incompatible_types" = @embedFile("testdata/validation/errors/operations/mul_incompatible_types.wgsl");
pub const @"errors/operations/member_access_invalid" = @embedFile("testdata/validation/errors/operations/member_access_invalid.wgsl");
pub const @"errors/operations/not_on_int" = @embedFile("testdata/validation/errors/operations/not_on_int.wgsl");
pub const @"errors/operations/index_non_indexable" = @embedFile("testdata/validation/errors/operations/index_non_indexable.wgsl");
pub const @"errors/operations/bitwise_on_float" = @embedFile("testdata/validation/errors/operations/bitwise_on_float.wgsl");
pub const @"errors/operations/mod_incompatible_types" = @embedFile("testdata/validation/errors/operations/mod_incompatible_types.wgsl");
pub const @"errors/operations/logical_on_int" = @embedFile("testdata/validation/errors/operations/logical_on_int.wgsl");
pub const @"errors/operations/add_incompatible_types" = @embedFile("testdata/validation/errors/operations/add_incompatible_types.wgsl");
pub const @"errors/operations/div_incompatible_types" = @embedFile("testdata/validation/errors/operations/div_incompatible_types.wgsl");
pub const @"errors/operations/sub_incompatible_types" = @embedFile("testdata/validation/errors/operations/sub_incompatible_types.wgsl");
pub const @"errors/operations/negate_bool" = @embedFile("testdata/validation/errors/operations/negate_bool.wgsl");
pub const @"errors/types/runtime_array_value" = @embedFile("testdata/validation/errors/types/runtime_array_value.wgsl");
pub const @"errors/types/invalid_conversion" = @embedFile("testdata/validation/errors/types/invalid_conversion.wgsl");
pub const @"errors/operations/swizzle_mixed_groups" = @embedFile("testdata/validation/errors/operations/swizzle_mixed_groups.wgsl");
pub const @"errors/operations/swizzle_out_of_bounds" = @embedFile("testdata/validation/errors/operations/swizzle_out_of_bounds.wgsl");
pub const @"errors/operations/division_by_zero" = @embedFile("testdata/validation/errors/operations/division_by_zero.wgsl");
pub const @"errors/operations/division_by_zero_const" = @embedFile("testdata/validation/errors/operations/division_by_zero_const.wgsl");
pub const @"errors/operations/modulo_by_zero" = @embedFile("testdata/validation/errors/operations/modulo_by_zero.wgsl");

// --- errors/symbols/ ---
pub const @"errors/symbols/undefined_variable" = @embedFile("testdata/validation/errors/symbols/undefined_variable.wgsl");
pub const @"errors/symbols/undefined_variable_expr" = @embedFile("testdata/validation/errors/symbols/undefined_variable_expr.wgsl");
pub const @"errors/symbols/var_different_scope" = @embedFile("testdata/validation/errors/symbols/var_different_scope.wgsl");
pub const @"errors/symbols/undefined_function" = @embedFile("testdata/validation/errors/symbols/undefined_function.wgsl");
pub const @"errors/symbols/undefined_type" = @embedFile("testdata/validation/errors/symbols/undefined_type.wgsl");
pub const @"errors/symbols/var_out_of_scope" = @embedFile("testdata/validation/errors/symbols/var_out_of_scope.wgsl");
pub const @"errors/symbols/reserved_word_var" = @embedFile("testdata/validation/errors/symbols/reserved_word_var.wgsl");
pub const @"errors/symbols/reserved_word_fn" = @embedFile("testdata/validation/errors/symbols/reserved_word_fn.wgsl");
pub const @"errors/symbols/reserved_word_param" = @embedFile("testdata/validation/errors/symbols/reserved_word_param.wgsl");
pub const @"errors/symbols/double_underscore" = @embedFile("testdata/validation/errors/symbols/double_underscore.wgsl");
pub const @"errors/symbols/use_before_decl_var" = @embedFile("testdata/validation/errors/symbols/use_before_decl_var.wgsl");
pub const @"errors/symbols/use_before_decl_let" = @embedFile("testdata/validation/errors/symbols/use_before_decl_let.wgsl");
pub const @"errors/symbols/recursive_fn_direct" = @embedFile("testdata/validation/errors/symbols/recursive_fn_direct.wgsl");
pub const @"errors/symbols/recursive_fn_indirect" = @embedFile("testdata/validation/errors/symbols/recursive_fn_indirect.wgsl");

// --- errors/io/ (entry-point I/O: builtin stage/direction, builtin type, @location type) ---
pub const @"errors/io/frag_output_builtin_position" = @embedFile("testdata/validation/errors/io/frag_output_builtin_position.wgsl");
pub const @"errors/io/vertex_output_builtin_vertex_index" = @embedFile("testdata/validation/errors/io/vertex_output_builtin_vertex_index.wgsl");
pub const @"errors/io/frag_input_struct_vertex_index" = @embedFile("testdata/validation/errors/io/frag_input_struct_vertex_index.wgsl");
pub const @"errors/io/frag_output_struct_vertex_index" = @embedFile("testdata/validation/errors/io/frag_output_struct_vertex_index.wgsl");
pub const @"errors/io/vertex_input_frag_depth" = @embedFile("testdata/validation/errors/io/vertex_input_frag_depth.wgsl");
pub const @"errors/io/builtin_position_wrong_type_vec3" = @embedFile("testdata/validation/errors/io/builtin_position_wrong_type_vec3.wgsl");
pub const @"errors/io/builtin_position_wrong_type_vec4i" = @embedFile("testdata/validation/errors/io/builtin_position_wrong_type_vec4i.wgsl");
pub const @"errors/io/builtin_frag_depth_wrong_type_vec4" = @embedFile("testdata/validation/errors/io/builtin_frag_depth_wrong_type_vec4.wgsl");
pub const @"errors/io/builtin_sample_mask_wrong_type_f32" = @embedFile("testdata/validation/errors/io/builtin_sample_mask_wrong_type_f32.wgsl");
pub const @"errors/io/builtin_vertex_index_wrong_type_i32" = @embedFile("testdata/validation/errors/io/builtin_vertex_index_wrong_type_i32.wgsl");
pub const @"errors/io/builtin_front_facing_wrong_type_u32" = @embedFile("testdata/validation/errors/io/builtin_front_facing_wrong_type_u32.wgsl");
pub const @"errors/io/builtin_local_invocation_id_wrong_type" = @embedFile("testdata/validation/errors/io/builtin_local_invocation_id_wrong_type.wgsl");
pub const @"errors/io/builtin_global_invocation_id_wrong_element" = @embedFile("testdata/validation/errors/io/builtin_global_invocation_id_wrong_element.wgsl");
pub const @"errors/io/builtin_workgroup_id_vec4" = @embedFile("testdata/validation/errors/io/builtin_workgroup_id_vec4.wgsl");
pub const @"errors/io/builtin_clip_distances_too_many" = @embedFile("testdata/validation/errors/io/builtin_clip_distances_too_many.wgsl");
pub const @"errors/io/builtin_clip_distances_wrong_element" = @embedFile("testdata/validation/errors/io/builtin_clip_distances_wrong_element.wgsl");
pub const @"errors/io/location_matrix" = @embedFile("testdata/validation/errors/io/location_matrix.wgsl");
pub const @"errors/io/location_struct" = @embedFile("testdata/validation/errors/io/location_struct.wgsl");
pub const @"errors/io/location_bool" = @embedFile("testdata/validation/errors/io/location_bool.wgsl");
pub const @"errors/io/location_array" = @embedFile("testdata/validation/errors/io/location_array.wgsl");
pub const @"errors/io/location_on_compute_input_struct_member" = @embedFile("testdata/validation/errors/io/location_on_compute_input_struct_member.wgsl");
pub const @"errors/io/workgroup_size_on_vertex" = @embedFile("testdata/validation/errors/io/workgroup_size_on_vertex.wgsl");
pub const @"errors/io/workgroup_size_on_fragment" = @embedFile("testdata/validation/errors/io/workgroup_size_on_fragment.wgsl");
pub const @"errors/io/workgroup_size_on_non_entry" = @embedFile("testdata/validation/errors/io/workgroup_size_on_non_entry.wgsl");
pub const @"errors/io/invariant_on_direct_return_non_position" = @embedFile("testdata/validation/errors/io/invariant_on_direct_return_non_position.wgsl");
pub const @"errors/io/blend_src_on_vertex_output" = @embedFile("testdata/validation/errors/io/blend_src_on_vertex_output.wgsl");
pub const @"errors/io/blend_src_without_location" = @embedFile("testdata/validation/errors/io/blend_src_without_location.wgsl");
pub const @"errors/io/blend_src_invalid_value" = @embedFile("testdata/validation/errors/io/blend_src_invalid_value.wgsl");
pub const @"errors/io/blend_src_unpaired" = @embedFile("testdata/validation/errors/io/blend_src_unpaired.wgsl");
pub const @"errors/io/blend_src_type_mismatch" = @embedFile("testdata/validation/errors/io/blend_src_type_mismatch.wgsl");
pub const @"errors/io/blend_src_on_input" = @embedFile("testdata/validation/errors/io/blend_src_on_input.wgsl");
pub const @"errors/io/builtin_on_non_entry_function_param" = @embedFile("testdata/validation/errors/io/builtin_on_non_entry_function_param.wgsl");
pub const @"errors/io/builtin_position_on_non_entry_function_return" = @embedFile("testdata/validation/errors/io/builtin_position_on_non_entry_function_return.wgsl");
pub const @"errors/io/builtin_frag_depth_on_non_entry_function_return" = @embedFile("testdata/validation/errors/io/builtin_frag_depth_on_non_entry_function_return.wgsl");
pub const @"errors/io/builtin_vertex_index_on_non_entry_function_return" = @embedFile("testdata/validation/errors/io/builtin_vertex_index_on_non_entry_function_return.wgsl");
pub const @"errors/io/location_on_non_entry_function_return" = @embedFile("testdata/validation/errors/io/location_on_non_entry_function_return.wgsl");
pub const @"errors/io/location_and_builtin_on_non_entry_function_return" = @embedFile("testdata/validation/errors/io/location_and_builtin_on_non_entry_function_return.wgsl");
pub const @"errors/io/builtin_on_helper_called_from_entry_point" = @embedFile("testdata/validation/errors/io/builtin_on_helper_called_from_entry_point.wgsl");
pub const @"errors/io/location_negative" = @embedFile("testdata/validation/errors/io/location_negative.wgsl");
pub const @"errors/io/location_non_const" = @embedFile("testdata/validation/errors/io/location_non_const.wgsl");
pub const @"errors/io/compute_output_builtin" = @embedFile("testdata/validation/errors/io/compute_output_builtin.wgsl");
pub const @"errors/io/builtin_frag_depth_wrong_type_f16" = @embedFile("testdata/validation/errors/io/builtin_frag_depth_wrong_type_f16.wgsl");
pub const @"errors/io/builtin_sample_mask_wrong_type_i32" = @embedFile("testdata/validation/errors/io/builtin_sample_mask_wrong_type_i32.wgsl");
pub const @"errors/io/builtin_local_invocation_index_wrong_type" = @embedFile("testdata/validation/errors/io/builtin_local_invocation_index_wrong_type.wgsl");
pub const @"errors/io/location_atomic" = @embedFile("testdata/validation/errors/io/location_atomic.wgsl");
pub const @"errors/io/duplicate_location_across_param_and_struct" = @embedFile("testdata/validation/errors/io/duplicate_location_across_param_and_struct.wgsl");
pub const @"errors/io/blend_src_non_numeric" = @embedFile("testdata/validation/errors/io/blend_src_non_numeric.wgsl");
pub const @"errors/io/interpolate_on_direct_return" = @embedFile("testdata/validation/errors/io/interpolate_on_direct_return.wgsl");

// --- types/ entry-point I/O (valid) ---
pub const @"types/entry_point_vertex_inputs" = @embedFile("testdata/validation/types/entry_point_vertex_inputs.wgsl");
pub const @"types/entry_point_vertex_clip_distances" = @embedFile("testdata/validation/types/entry_point_vertex_clip_distances.wgsl");
pub const @"types/entry_point_fragment_all_inputs" = @embedFile("testdata/validation/types/entry_point_fragment_all_inputs.wgsl");
pub const @"types/entry_point_fragment_frag_depth" = @embedFile("testdata/validation/types/entry_point_fragment_frag_depth.wgsl");
pub const @"types/entry_point_fragment_sample_mask_out" = @embedFile("testdata/validation/types/entry_point_fragment_sample_mask_out.wgsl");
pub const @"types/entry_point_compute_all_builtins" = @embedFile("testdata/validation/types/entry_point_compute_all_builtins.wgsl");
pub const @"types/entry_point_fragment_blend_src" = @embedFile("testdata/validation/types/entry_point_fragment_blend_src.wgsl");
pub const @"types/entry_point_fragment_multi_location" = @embedFile("testdata/validation/types/entry_point_fragment_multi_location.wgsl");
pub const @"types/entry_point_location_f16" = @embedFile("testdata/validation/types/entry_point_location_f16.wgsl");

// --- errors/control_flow/ ---
pub const @"errors/control_flow/discard_outside_fragment" = @embedFile("testdata/validation/errors/control_flow/discard_outside_fragment.wgsl");
pub const @"errors/control_flow/continue_outside_loop" = @embedFile("testdata/validation/errors/control_flow/continue_outside_loop.wgsl");
pub const @"errors/control_flow/discard_in_vertex" = @embedFile("testdata/validation/errors/control_flow/discard_in_vertex.wgsl");
pub const @"errors/control_flow/break_outside_loop" = @embedFile("testdata/validation/errors/control_flow/break_outside_loop.wgsl");
pub const @"errors/control_flow/break_in_function" = @embedFile("testdata/validation/errors/control_flow/break_in_function.wgsl");
pub const @"errors/control_flow/continue_in_if" = @embedFile("testdata/validation/errors/control_flow/continue_in_if.wgsl");
pub const @"errors/control_flow/unreachable_after_return" = @embedFile("testdata/validation/errors/control_flow/unreachable_after_return.wgsl");

// --- expectation pushdown: .integer_scalar / .concrete ---
// Fixtures added alongside the validator change that wires `.integer_scalar`
// at array-index / shift-RHS and `.concrete` at unannotated decl initializers.
pub const @"types/index_integer_types_valid" = @embedFile("testdata/validation/types/index_integer_types_valid.wgsl");
pub const @"types/let_var_no_annotation_concretize" = @embedFile("testdata/validation/types/let_var_no_annotation_concretize.wgsl");
pub const @"types/let_nested_expectation_dispatch" = @embedFile("testdata/validation/types/let_nested_expectation_dispatch.wgsl");
pub const @"expressions/binary/shift_integer_rhs_valid" = @embedFile("testdata/validation/expressions/binary/shift_integer_rhs_valid.wgsl");
pub const @"errors/types/index_float_literal" = @embedFile("testdata/validation/errors/types/index_float_literal.wgsl");
pub const @"errors/types/index_f32_var" = @embedFile("testdata/validation/errors/types/index_f32_var.wgsl");
pub const @"errors/types/index_bool" = @embedFile("testdata/validation/errors/types/index_bool.wgsl");
pub const @"errors/types/index_vector" = @embedFile("testdata/validation/errors/types/index_vector.wgsl");
pub const @"errors/types/index_inner_binary_float" = @embedFile("testdata/validation/errors/types/index_inner_binary_float.wgsl");
pub const @"errors/operations/shift_rhs_float" = @embedFile("testdata/validation/errors/operations/shift_rhs_float.wgsl");
pub const @"errors/operations/shift_rhs_f32" = @embedFile("testdata/validation/errors/operations/shift_rhs_f32.wgsl");
pub const @"errors/operations/shift_rhs_bool" = @embedFile("testdata/validation/errors/operations/shift_rhs_bool.wgsl");
pub const @"errors/operations/shift_rhs_vector" = @embedFile("testdata/validation/errors/operations/shift_rhs_vector.wgsl");
pub const @"errors/operations/shift_rhs_i32_requires_u32" = @embedFile("testdata/validation/errors/operations/shift_rhs_i32_requires_u32.wgsl");
pub const @"errors/operations/shift_lhs_float" = @embedFile("testdata/validation/errors/operations/shift_lhs_float.wgsl");
