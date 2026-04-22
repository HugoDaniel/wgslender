// @test: types/let-var-no-annotation-concretize
// @expect-valid
// Unannotated `let`, `var`, and function-scope `const` all get `.concrete`
// pushed into the initializer — they validate and the cache records the
// default concrete type (verified separately in expectation_test.zig).

fn f() -> f32 {
    let a = 1;           // abstract-int → i32
    let b = 1.0;         // abstract-float → f32
    var c = 1;
    var d = 1.0;
    const e = 1 + 2;     // function-scope const concretizes to i32
    return b + d + f32(a) + f32(c) + f32(e);
}

@compute @workgroup_size(1)
fn main() { let _r = f(); }
