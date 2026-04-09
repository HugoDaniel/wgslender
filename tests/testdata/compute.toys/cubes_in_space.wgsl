/**
 * Creates 3 pseudo-random numbers (vec3f) in the interval [0, 1]
 * from a 3D cell ID (vec3f).
 */
fn hash3(p: vec3f) -> vec3f {
    var p3 = fract(p * vec3f(0.1031, 0.1030, 0.0973));
    p3 = p3 + dot(p3, p3.yzx + 19.19);
    return fract(vec3f(p3.x + p3.y, p3.y + p3.z, p3.z + p3.x) * p3.zxy);
}

fn rot2D(a: f32) -> mat2x2<f32> {
    let s: f32 = sin(a);
    let c: f32 = cos(a);

    return mat2x2(c, -s, s, c);
}

fn sdBox(p: vec3f, b: vec3f) -> f32 {
  let q = abs(p) - b;
  return length(max(q, vec3f(0.0))) + min(max(q.x, max(q.y, q.z)), 0.0);
}

fn sdSphere(p: vec3<f32>, r: f32) -> f32 {
    return length(p) - r;
}

fn map(p: vec3<f32>) -> f32 {
    
    let grid_size = 10.0; 
    let p_scaled = p / grid_size;
    
    let cell_id = floor(p_scaled);
    var q = fract(p_scaled) - 0.5; 
    
    // --- MUDANÇA AQUI ---
    // O 'HIT_THRESHOLD' em 'main_image' é 0.01.
    // (0.01 / grid_size) = 0.001.
    // Esta é a nossa distância mínima segura ("chão") no espaço local
    // para garantir que uma fronteira de célula NUNCA seja confundida com um "hit".
    let LOCAL_SAFE_DIST = 0.001;
    
    // Calcula a distância à fronteira, mas NUNCA a deixa ser menor que LOCAL_SAFE_DIST
    let d_cell_boundary_local = max(-sdBox(q, vec3f(0.5)), LOCAL_SAFE_DIST);
    
    // --- Fim da Mudança ---

    let h = hash3(cell_id);
    
    // Célula vazia? Retorna APENAS a distância segura da fronteira.
    if (h.z > 0.95) {
        return d_cell_boundary_local * grid_size;
    }
    
    // Célula com estrela
    let offset = (h.x - 0.5) * 0.9;
    let size = 0.005; //  + h.y * 0.015;
    // let d_star_local = sdSphere(q - vec3f(offset, 0.0, 0.0), size);
    let d_star_local = sdSphere(q, size);

    // Retorna o mínimo entre a estrela e a fronteira segura
    let d_local = min(d_star_local, d_cell_boundary_local);
    
    return d_star_local * grid_size;
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

    let cam_speed = 15.0;
    let fov = 1.0; // 100.0 * (sin(time.elapsed * 0.2) + 1.0) / 2.0;
    let ro = vec3f(0, 0, -3.0 + time.elapsed * cam_speed);
    let rd = normalize(vec3f(uv * fov, 1));
    var t = 0.0; // total distance traveled
    var col = vec3<f32>(0); // starts at black
    let surface_color = vec3f(1.0, 0.9, 0.8) * 1.5; // > 1.0 to be brighter
    let glow_color = vec3f(1.0, 0.4, 0.1); // orange 

    // Raymarching
    for (var i: i32 = 0; i < 80; i++) {
        var p = ro + rd * t; // position along the ray
        var d = map(p); // current distance to the scene

        // accumulate volumetric glow
        // add a bit of glowing color at each step
        // the exp() function gives a soft falloff
        // adjust the values 0.03 (density) and 2.0 (speed of falloff)
        let density = 0.01;
        let falloffSpeed = 50.0;
        col += glow_color * density * exp(-d * falloffSpeed);

        // did the ray hit the surface?
        if (d < 0.001) {
            // hit, add the surface color to the accumulation
            // its important to add "col +=" so that the accumulated glow can be added.
            col += surface_color;
            break;
        }

        t += d;

        // Stop marching if distance is too far away
        if ( d > 100.0) {
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

