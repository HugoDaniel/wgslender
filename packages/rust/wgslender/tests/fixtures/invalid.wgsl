// Parses, but does not type-check: `undeclared_variable` is never declared.
// The UI golden pins how the macro renders this diagnostic.

@compute @workgroup_size(1)
fn main() {
    let x = undeclared_variable;
}
