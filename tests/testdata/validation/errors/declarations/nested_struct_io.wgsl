// @test: errors/declarations/nested-struct-io
// @expect-error E0602 "cannot be a struct type"
// Entry point I/O struct members must not be struct types

struct Inner {
    x: f32,
}

struct Output {
    @location(0) nested: Inner,
    @builtin(position) pos: vec4f,
}

@vertex
fn main() -> Output {
    return Output();
}
