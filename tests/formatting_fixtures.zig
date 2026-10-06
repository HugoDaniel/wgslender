//! Shared inputs for the formatting suites.
//!
//! The LSP handler's `textDocument/formatting` and the plain
//! `format(source)` export must agree byte-for-byte on every one of these;
//! keeping them in one module means the handler's tests and the parity
//! goldens cannot drift apart.

/// "formatting: produces output"
pub const produces_output: [:0]const u8 = "fn   f()   {   }";
/// "formatting: multi-line source"
pub const multi_line: [:0]const u8 =
    \\struct  S  {  x:  f32  }
    \\fn   f(s:S)->f32{return   s.x;}
;
/// "formatting: empty source"
pub const empty: [:0]const u8 = "";
/// "formatting: valid shader formats cleanly"
pub const valid_shader: [:0]const u8 = "@compute @workgroup_size(1) fn main() { let x: f32 = 1.0; }";
/// "formatting: preserves declarations unreachable from entry points"
pub const preserves_unreachable: [:0]const u8 =
    \\fn helper_unused(x: f32) -> f32 { return x * 2.0; }
    \\@compute @workgroup_size(1) fn main() { let a = 1.0; _ = a; }
;
/// "formatting: preserves struct content"
pub const preserves_struct: [:0]const u8 = "struct Vertex { position: vec3f, normal: vec3f }";
/// "formatting: parse error returns null"
pub const parse_error: [:0]const u8 = "fn { invalid }";

/// Every fixture the parser accepts: formatting must produce text for each.
pub const clean = [_][:0]const u8{
    produces_output,
    multi_line,
    empty,
    valid_shader,
    preserves_unreachable,
    preserves_struct,
};
