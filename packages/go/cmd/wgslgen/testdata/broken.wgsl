// Parses, but does not type-check: undeclared_variable is never declared.
// Minification is perfectly happy with it, which is the whole reason the
// generator validates.

@compute @workgroup_size(1)
fn main() {
    let x: f32 = undeclared_variable;
    _ = x;
}
