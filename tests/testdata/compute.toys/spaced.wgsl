// A palette function for nice gradients (iquilezles.org)
fn palette(t: f32) -> vec3f {
    let a = vec3f(0.5, 0.5, 0.5);
    let b = vec3f(0.5, 0.5, 0.5);
    let c = vec3f(1.0, 1.0, 1.0);
    let d = vec3f(0.263, 0.416, 0.557); // Iridescent colors
    return a + b * cos(6.28318 * (c * t + d));
}

fn hash3(p: vec3f) -> vec3f {
    var p_no_zero = p + vec3f(12.34, 56.78, 90.12); 
    var p3 = fract(p_no_zero * vec3f(0.1031, 0.1030, 0.0973));
    p3 = p3 + dot(p3, p3.yzx + 19.19);
    return fract(vec3f(p3.x + p3.y, p3.y + p3.z, p3.z + p3.x) * p3.zxy);
}

fn rot2D(a: f32) -> mat2x2<f32> {
    let s: f32 = sin(a);
    let c: f32 = cos(a);
    return mat2x2(c, -s, s, c);
}

fn sdSphere(p: vec3<f32>, r: f32) -> f32 {
    return length(p) - r;
}

fn map(p_in: vec3<f32>) -> f32 {
    var p = p_in;
    
    // !!! UPGRADE 1: Space Bending
    // Twist the world based on Z distance to create a vortex tunnel
    let twist = custom.twist * 0.1;
    p = vec3f(p.xy * rot2D(p.z * 0.05 * sin(twist * 0.5)), p.z);

    let gridSize = 8.0; 
    let cell_id = vec3<i32>(floor(p / gridSize));

    // Hash for random properties per cell
    let h = hash3(vec3f(f32(cell_id.x), f32(cell_id.y), f32(cell_id.z)) + 1337.0);
    
    // Density check
    let density = 1.0; 
    if (h.x >= density) { return 0.9; }

    var q = (p / gridSize);
    q = fract(q) - 0.5;

    // !!! UPGRADE 2: Audio Reactive Jitter
    // Use custom.viz to make the jitter more violent on the beat
    let bounce_energy = (pow(sin(4.0 * time.elapsed), 4.0) + 1.0) / 2.0;
    // We add custom.viz to the bounce magnitude
    let audio_kick = custom.viz * 0.4; 
    
    let jitter = (h.yzx - vec3f(0.5)) * mix(0.1, 0.3 + audio_kick, bounce_energy);
    let local = (vec3f(q) + jitter);

    // !!! UPGRADE 3: Audio Reactive Size
    // Base radius varies by hash, but we ADD audio power to it
    // When bass hits, spheres get fatter
    let r = mix(0.05, 0.12, h.z) + (custom.viz * 0.15); 
    
    let sphere = sdSphere(local, r);
    return sphere * gridSize;
}

@compute @workgroup_size(16, 16)
fn main_image(@builtin(global_invocation_id) id: vec3u) {
    let screen_size = textureDimensions(screen);
    if (id.x >= screen_size.x || id.y >= screen_size.y) { return; }

    let fragCoord = vec2f(f32(id.x) + .5, f32(screen_size.y - id.y) - .5);
    var uv = (fragCoord * 2.0 - vec2f(f32(screen_size.x), f32(screen_size.y))) / f32(screen_size.y);

    // !!! UPGRADE 4: Camera Juice
    // Rotate camera slightly with time for a "barrel roll" feeling
    let twist = custom.twist;
    uv = uv * rot2D(twist * 0.1);

    // Speed increases slightly with audio intensity
    let speed = 8.0; //  + (custom.viz * 10.0);
    
    // FOV kicks when audio hits (Zoom effect)
    let fov = 0.6 - (custom.viz * 0.2); 

    let ro = vec3f(0, 0, -3 + time.elapsed * speed);
    let rd = normalize(vec3f(uv * fov, 1.0));
    
    var t = 0.0; 
    var col = vec3<f32>(0); 
    
    // !!! UPGRADE 5: Better Raymarching Loop
    // Fixed iterations. Don't use viz for iterations (causes flickering artifacts)
    // 64 is usually enough for a grid like this
    for (var i: i32 = 0; i < 80; i++) {
        var p = ro + rd * t; 
        var d = map(p); 

        // !!! UPGRADE 6: Palette Glow
        // Instead of constant orange, we generate color based on Z-depth
        // This makes distant spheres a different color than close ones
        let depth_color = palette(p.z * 0.04 + time.elapsed * 0.2);
        
        // Audio boosts the glow density
        let density = 0.008 + (custom.viz * 0.01);
        let falloffSpeed = 8.0; // Looser falloff for more bloom
        
        col += depth_color * density * exp(-d * falloffSpeed);

        if (d < 0.001) {
            // When we hit a surface, we add a burst of white + the palette color
            col += depth_color * 2.0; 
            break;
        }

        t += d * 0.7 * (1.0 - custom.viz); // 0.7 is safer to prevent artifacts
        if (t > 150.0) { break; } // Shorter draw distance hides the "end" of the world
    }

    // Tonemapping
    col = col / (col + 1.0); 
    col = pow(col, vec3f(1.0 / 2.2));
    
    // !!! UPGRADE 7: Vignette
    // Darkens the corners to focus the eye
    let dist_center = length(uv);
    col *= 1.0 - dist_center * 0.5;

    textureStore(screen, id.xy, vec4f(col, 1.));
}
