// @test: builtins/array-length
// @expect-valid
// @spec-ref: 17.14 "Array Built-in Functions"
// arrayLength via declarative overload (Phase 3e migration target).

@group(0) @binding(0) var<storage, read>       data : array<f32>;
@group(0) @binding(1) var<storage, read_write> rw   : array<vec4u>;

struct S {
    x : f32,
    y : array<u32>,
}
@group(0) @binding(2) var<storage, read> s : S;

@compute @workgroup_size(1)
fn main() {
    let n1 : u32 = arrayLength(&data);
    let n2 : u32 = arrayLength(&rw);
    let n3 : u32 = arrayLength(&s.y);
}
