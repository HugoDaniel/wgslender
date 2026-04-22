// @test: types/let-nested-expectation-dispatch
// @expect-valid
// Nested expectation dispatch: outer `.concrete` on the `let` initializer
// must not bleed through to the shift RHS (which carries `.integer_scalar`)
// or the index (same). If it bled, the u32 RHS or the integer index would
// be misreported. This compiles cleanly because each context computes its
// own expectation.

var<private> arr: array<u32, 8>;

fn f() -> u32 {
    let a = 1u << 2u;      // outer .concrete; shift RHS .integer_scalar
    let b = arr[0u];       // outer .concrete; index .integer_scalar
    return a + b;
}

@compute @workgroup_size(1)
fn main() { let _r = f(); }
