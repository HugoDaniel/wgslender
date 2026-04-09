/**
 * Creates 3 pseudo-random numbers (vec3f) in the interval [0, 1]
 * from a 3D cell ID (vec3f).
 */
fn hash3(p: vec3f) -> vec3f {
    // add a constant vector to "break" the axis symetry
    // any non-integer number will do
    var p_no_zero = p + vec3f(12.34, 56.78, 90.12); 
    
    var p3 = fract(p_no_zero * vec3f(0.1031, 0.1030, 0.0973));
    p3 = p3 + dot(p3, p3.yzx + 19.19);
    return fract(vec3f(p3.x + p3.y, p3.y + p3.z, p3.z + p3.x) * p3.zxy);}

fn rot2D(a: f32) -> mat2x2<f32> {
    let s: f32 = sin(a);
    let c: f32 = cos(a);

    return mat2x2(c, -s, s, c);
}

fn sdSphere(p: vec3<f32>, r: f32) -> f32 {
    return length(p) - r;
}

fn nebulaDensity(p: vec3f) -> f32 {
    // Create 3D noise using your hash function
    let scale1 = 0.05;
    let scale2 = 0.1;
    let scale3 = 0.2;
    
    let n1 = hash3(p * scale1).x;
    let n2 = hash3(p * scale2 + vec3f(100.0)).x;
    let n3 = hash3(p * scale3 + vec3f(200.0)).x;
    
    // Combine octaves
    var density = n1 * 0.5 + n2 * 0.3 + n3 * 0.2;
    
    // Create pockets of nebula
    density = smoothstep(0.4, 0.7, density);
    
    return density;
}

fn map(p: vec3<f32>) -> f32 {
    let gridSize = 10.0;
    let cell_id = vec3<i32>(floor(p / gridSize));
    
    // let h = hash3(vec3f(f32(cell_id.x), f32(cell_id.y), f32(cell_id.z)) + 1337.0);
    let h = hash3(vec3f(f32(cell_id.x) * 7.1, f32(cell_id.y) * 11.3, f32(cell_id.z) * 13.7));
    let density = 0.3;

    if (h.x >= density) {
        // Empty cell - just return a fixed safe distance
        // This allows the ray to step through empty space efficiently
        return gridSize * 0.5; // Half a cell size - safe and fast
    }

    // Sphere calculation remains the same
    var q = (p / gridSize);
    q = fract(q) - 0.5;
    let jitter = (h.yzx - vec3f(0.5)) * 0.666;
    let local = (vec3f(q) + jitter);
    let r = mix(0.004, 0.010, h.z);
    
    let sphere = sdSphere(local, r);
    return sphere * gridSize;
}

@compute @workgroup_size(16, 16)
fn main_image(@builtin(global_invocation_id) id: vec3u) {
    // Viewport resolution (in pixels)
    let screen_size = textureDimensions(screen);

    // Prevent overdraw for workgroups on the edge of the viewport
    if (id.x >= screen_size.x || id.y >= screen_size.y) { return; }

    // Pixel coordinates (centre of pixel, origin at bottom left)
    let fragCoord = vec2f(f32(id.x) + .5, f32(screen_size.y - id.y) - .5);
    
    // Normalised pixel coordinates (from 0 to 1)
    let uv = (fragCoord * 2.0 - vec2f(f32(screen_size.x), f32(screen_size.y))) / f32(screen_size.y);

    let speed = 5.0 + custom.speed * 100.0;

    let fov = 0.20; // 100.0 * (sin(time.elapsed * 0.2) + 1.0) / 2.0;
    let ro = vec3f(0, 0, -3 + time.elapsed * speed);
    let rd = normalize(vec3f(uv * fov, 1));
    var t = 0.0; // total distance traveled
    var col = vec3<f32>(0); // starts at black
    let surface_color = vec3f(1.0, 0.9, 0.8) * 1.5; // > 1.0 to be brighter
    let glow_color = vec3f(1.0, 0.4, 0.1); // orange 

    // Raymarching
    let steps: i32 = 180;
    let stars_at = f32(steps) - 1.0;
    for (var i: i32 = 0; i < steps; i++) {
        var p = ro + rd * t;
        var d = map(p);
        
        // Calculate fog/fade based on distance
        let fog_start = 100.0;
        let fog_end = 150.0;
        let fog = 1.0 - smoothstep(fog_start, fog_end, t);
        
        if (d < 1.0) {
            let density = 0.03;
            let falloffSpeed = 30.0;
            col += glow_color * density * exp(-d * falloffSpeed) * fog;
        }
        
        if (d < 0.001) {
            col += surface_color * fog;
            break;
        }

        t += d;

        if (t > stars_at) {
            // Add some background stars or cosmic dust
            let bg_noise = hash3(normalize(vec3f(uv, 1)) * 100.0).x;
            if (bg_noise > 0.998) {
                col += surface_color * (bg_noise - 0.998) * 50.0;
            }
            break;
        }
        if (t > 1000.0) {
            break;
        }
    }

    // tonemapping and gamma correction

    // 'col' is in linear light space and can become very bright (HDR)
    // this simple tonemapping prevents values > 1.0 to be blown out to pure white
    col = col / (col + 1.0); // (Reinhard tonemapping)

    // gamma correction (Linear -> sRGB/Gamma space)
    col = pow(col, vec3f(1.0 / 2.2));

    // Output to screen (linear colour space)
    textureStore(screen, id.xy, vec4f(col, 1.));
}

