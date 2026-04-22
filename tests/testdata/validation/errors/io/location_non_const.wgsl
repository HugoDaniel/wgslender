// @test: errors/io/location-non-const
// @expect-error E0404 "@location argument must be a const-expression"
// spec-ref: §11.1 location

override my_loc : u32 = 0u;

@fragment
fn main(@location(my_loc) x : vec4<f32>) -> @location(0) vec4<f32> {
    return x;
}
