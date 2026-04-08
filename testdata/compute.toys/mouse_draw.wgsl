// Example: Mouse drawing shader for compute.toys
// Uses mouse input and pass buffers for persistence

fn drawCircle(center: vec2f, radius: f32, uv: vec2f) -> f32 {
    return smoothstep(radius + 0.01, radius - 0.01, length(uv - center));
}

@compute @workgroup_size(16, 16)
fn main_image(@builtin(global_invocation_id) id: vec3u) {
    let screen_size = textureDimensions(screen);
    if (id.x >= screen_size.x || id.y >= screen_size.y) { return; }

    // Normalized coordinates
    let uv = vec2f(f32(id.x), f32(id.y)) / vec2f(f32(screen_size.x), f32(screen_size.y));

    // Get previous frame
    var col = passLoad(0, vec2i(id.xy), 0).rgb;

    // Fade over time
    col *= 0.99;

    // Draw at mouse position when clicked
    if (mouse.click > 0) {
        let mouseUV = vec2f(f32(mouse.pos.x), f32(screen_size.y - mouse.pos.y)) /
                      vec2f(f32(screen_size.x), f32(screen_size.y));
        let brushSize = 0.02 * mouse.zoom;
        let brush = drawCircle(mouseUV, brushSize, uv);

        // Color based on time
        let brushColor = vec3f(
            sin(time.elapsed * 2.0) * 0.5 + 0.5,
            cos(time.elapsed * 3.0) * 0.5 + 0.5,
            sin(time.elapsed * 5.0) * 0.5 + 0.5
        );

        col = mix(col, brushColor, brush);
    }

    // Store to pass buffer for next frame
    passStore(0, vec2i(id.xy), vec4f(col, 1.0));

    // Output to screen
    textureStore(screen, id.xy, vec4f(col, 1.0));
}
