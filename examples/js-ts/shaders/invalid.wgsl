// Parses cleanly, fails semantic analysis: the name has no declaration.
fn main() -> f32 {
  return undeclared_variable;
}
