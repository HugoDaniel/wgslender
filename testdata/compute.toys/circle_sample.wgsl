fn sdCircle(p: vec2f, r: f32) -> f32 {
    return length(p) - r;
}

@compute @workgroup_size(16, 16)
fn main_image(@builtin(global_invocation_id) id: vec3u) {
    // Viewport resolution (in pixels)
    let screen_size = textureDimensions(screen);

    // Prevent overdraw for workgroups on the edge of the viewport
    if (id.x >= screen_size.x || id.y >= screen_size.y) { return; }

    // Pixel coordinates (centre of pixel, origin at bottom left)
    let fragCoord = vec2f(f32(id.x) + .5, f32(screen_size.y - id.y) - .5);

    let ratio: f32 = f32(screen_size.x) / f32(screen_size.y);
    // Normalised pixel coordinates (from 0 to 1)
    let uv = (fragCoord * 2.0 - vec2f(f32(screen_size.x), f32(screen_size.y))) / f32(screen_size.y);

    // Time varying pixel colour
    var col = .5 + .5 * cos(time.elapsed + uv.xyx + vec3f(0.,2.,4.));

    // Convert from gamma-encoded to linear colour space
    col = pow(col, vec3f(2.2));

    if (sdCircle(uv, 0.2) > 0.0) {
        let s = 1.0;
        col = textureSampleLevel(channel0, bilinear, (uv + vec2(ratio * s, ratio * s)) / (ratio * s * 2.0), 0.0).xyz;
    }

    // Output to screen (linear colour space)
    textureStore(screen, id.xy, vec4f(col, 1.));
}
