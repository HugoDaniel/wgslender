// @test: errors/declarations/let-without-init
// @expect-error E0001 "expected ="
// Let declarations require an initializer (parse error)

@fragment
fn main() {
    let x : i32;  // Error: let requires initializer
}
