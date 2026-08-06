// @test: errors/declarations/recursive-struct-var
// @expect-error E0104 "recursively"
// A var of a recursive struct type must still terminate. Phase 2.5 diagnoses
// the cycle but leaves it in the type graph, and the atomics walk behind var
// validation used to recurse through it until the stack ran out.

struct P {
    a : P,
}

var<private> v : P;
