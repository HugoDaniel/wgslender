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

// --- uniformity/ ---
pub const @"uniformity/barrier_uniform" = @embedFile("testdata/validation/uniformity/barrier_uniform.wgsl");
pub const @"uniformity/derivatives_uniform" = @embedFile("testdata/validation/uniformity/derivatives_uniform.wgsl");

// --- builtins/ ---
pub const @"builtins/vector_math" = @embedFile("testdata/validation/builtins/vector_math.wgsl");
pub const @"builtins/math_basic" = @embedFile("testdata/validation/builtins/math_basic.wgsl");
pub const @"builtins/atomic_ops" = @embedFile("testdata/validation/builtins/atomic_ops.wgsl");
pub const @"builtins/texture_sample" = @embedFile("testdata/validation/builtins/texture_sample.wgsl");

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

// --- errors/control_flow/ ---
pub const @"errors/control_flow/discard_outside_fragment" = @embedFile("testdata/validation/errors/control_flow/discard_outside_fragment.wgsl");
pub const @"errors/control_flow/continue_outside_loop" = @embedFile("testdata/validation/errors/control_flow/continue_outside_loop.wgsl");
pub const @"errors/control_flow/discard_in_vertex" = @embedFile("testdata/validation/errors/control_flow/discard_in_vertex.wgsl");
pub const @"errors/control_flow/break_outside_loop" = @embedFile("testdata/validation/errors/control_flow/break_outside_loop.wgsl");
pub const @"errors/control_flow/break_in_function" = @embedFile("testdata/validation/errors/control_flow/break_in_function.wgsl");
pub const @"errors/control_flow/continue_in_if" = @embedFile("testdata/validation/errors/control_flow/continue_in_if.wgsl");
pub const @"errors/control_flow/unreachable_after_return" = @embedFile("testdata/validation/errors/control_flow/unreachable_after_return.wgsl");
