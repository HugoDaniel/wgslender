//! Compile-time tunable limits shared across the pipeline.
//!
//! All limits live here so adversarial input can't blow the call stack:
//! every recursive descent in the parser and every depth-tracked walker in
//! the validator clamps against one of these constants and emits a
//! `nesting_too_deep` diagnostic instead of crashing.
//!
//! Values are deliberately generous relative to hand-written WGSL — real
//! shaders rarely nest beyond ~10 levels — but tight enough that hitting
//! the limit signals pathological input rather than a real program.

const std = @import("std");

/// Maximum recursive depth of `Parser.parseExpression`. Each parenthesized
/// sub-expression, call argument, index, and template argument consumes one
/// slot. Mirrors `Validator`'s own expression-walk limit so well-formed
/// programs that the parser accepts also survive type checking.
pub const max_parser_expr_depth: u16 = 256;

/// Maximum recursive depth of `Parser.parseStatement`. Each compound block,
/// `if` arm, `for`/`while`/`loop` body, and `switch` case consumes one
/// slot. Aligned with `Validator`'s `max_stmt_depth` so the parser never
/// builds a tree the validator would later refuse on depth grounds.
pub const max_parser_stmt_depth: u16 = 127;

/// Maximum recursive depth of `Parser.parseType`. Bounds nested generics
/// like `array<vec3<atomic<u32>>>`. The WGSL grammar permits arbitrary
/// nesting; 64 covers every sane shader and any deeper input is almost
/// certainly machine-generated or malicious.
pub const max_parser_type_depth: u16 = 64;

comptime {
    std.debug.assert(max_parser_expr_depth > 0);
    std.debug.assert(max_parser_stmt_depth > 0);
    std.debug.assert(max_parser_type_depth > 0);
    std.debug.assert(max_parser_expr_depth < (1 << 20));
    std.debug.assert(max_parser_stmt_depth < (1 << 20));
    std.debug.assert(max_parser_type_depth < (1 << 20));
}
