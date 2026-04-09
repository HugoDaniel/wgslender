// --- Begin import: constants ---
const PI: f32 = 3.14159265359;
const AWAY: f32 = 1e10;
const BOX_SIZE = vec2f(0.2);

// --- End import: constants ---

// --- Begin import: transform2D ---
struct Transform2D {
  pos: vec2f,      // World position
  angle: f32,      // Rotation in RADIANS
  scale: vec2f,    // 2D scale factors
  anchor: vec2f,   // Rotation anchor
};

const NO_TRANSFORM = Transform2D(vec2f(0.0), 0.0, vec2f(1.0), vec2f(0.0));

fn transform_to_local(uv: vec2f, xform: Transform2D) -> vec2f {
  var p = uv - xform.pos;
  let c = cos(xform.angle);
  let s = sin(xform.angle);
  p = vec2f(c * p.x + s * p.y, -s * p.x + c * p.y);
  p -= xform.anchor;
  p /= xform.scale;
  return p;
}

fn scale_sdf_distance(dist: f32, xform: Transform2D) -> f32 {
  if (abs(xform.scale.x - xform.scale.y) < 0.001) {
    return dist * xform.scale.x;
  }
  let ratio = max(xform.scale.x, xform.scale.y) / min(xform.scale.x, xform.scale.y);
  if (ratio < 2.0) {
    return dist * (2.0 / (1.0 / xform.scale.x + 1.0 / xform.scale.y));
  }
  return dist * min(xform.scale.x, xform.scale.y);
}

fn mixTransform(a: Transform2D, b: Transform2D, t: f32) -> Transform2D {
    var result: Transform2D;
    result.pos = mix(a.pos, b.pos, t);
    result.scale = mix(a.scale, b.scale, t);
    result.anchor = mix(a.anchor, b.anchor, t);
    result.angle = mix(a.angle, b.angle, t);
    return result;
}

fn pixelate_uv(uv: vec2f, grid_size: f32) -> vec2f {
    return (floor(uv * grid_size) + 0.5) / grid_size;
}

fn dots_uv(uv: vec2f, grid_size: f32, radius: f32) -> f32 {
    let local_uv = fract(uv * grid_size) - 0.5;
    
    return length(local_uv) - radius;
}

// --- End import: transform2D ---

// --- Begin import: primitives ---
// Smooth minimum for SDF blending
fn smin(a: f32, b: f32, k: f32) -> f32 {
  if (k <= 0.0) {
    return min(a, b);
  }
  let h = max(k - abs(a - b), 0.0) / k;
  return min(a, b) - h * h * k * 0.25;
}

fn circle(p: vec2f, c: vec2f, r: f32) -> f32 {
    return distance(p, c) - r;
}

fn transformedCircle(p: vec2f, r: f32, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    let raw_dist = circle(q, vec2f(0.0), r);

    return scale_sdf_distance(raw_dist, transform);
}


fn box(p: vec2f, b: vec2f) -> f32 {
  let d = abs(p) - b;
  return length(max(d, vec2f(0.0))) + min(max(d.x, d.y), 0.0);
}

fn tri(p: vec2<f32>, p0: vec2<f32>, p1: vec2<f32>, p2: vec2<f32>) -> f32 {
    let e0 = p1 - p0; let e1 = p2 - p1; let e2 = p0 - p2;
    let v0 = p - p0; let v1 = p - p1; let v2 = p - p2;
    let pq0 = v0 - e0 * clamp(dot(v0, e0) / dot(e0, e0), 0.0f, 1.0f);
    let pq1 = v1 - e1 * clamp(dot(v1, e1) / dot(e1, e1), 0.0f, 1.0f);
    let pq2 = v2 - e2 * clamp(dot(v2, e2) / dot(e2, e2), 0.0f, 1.0f);
    let s = sign(e0.x * e2.y - e0.y * e2.x);
    let d0 = vec2<f32>(dot(pq0, pq0), s * (v0.x * e0.y - v0.y * e0.x));
    let d1 = vec2<f32>(dot(pq1, pq1), s * (v1.x * e1.y - v1.y * e1.x));
    let d2 = vec2<f32>(dot(pq2, pq2), s * (v2.x * e2.y - v2.y * e2.x));
    let d = min(min(d0, d1), d2);
    return -sqrt(d.x) * sign(d.y);
}

fn transformedTri(p: vec2f, p0: vec2<f32>, p1: vec2<f32>, p2: vec2<f32>, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    let raw_dist = tri(q, p0, p1, p2);

    return scale_sdf_distance(raw_dist, transform);
}

fn parallelogram(p_in: vec2<f32>, wi: f32, he: f32, sk: f32) -> f32 {
    let e = vec2<f32>(sk, he);
    var p = p_in;
    if (p.y < 0.0f) { p = -p; }
    var w = p - e; w.x = w.x - clamp(w.x, -wi, wi);
    var d = vec2<f32>(dot(w, w), -w.y);
    let s = p.x * e.y - p.y * e.x;
    if (s < 0.0f) { p = -p; }
    var v = p - vec2<f32>(wi, 0.0f);
    v = v - e * clamp(dot(v, e) / dot(e, e), -1.0f, 1.0f);
    d = min(d, vec2<f32>(dot(v, v), wi * he - abs(s)));
    return sqrt(d.x) * sign(-d.y);
}

fn segment(p: vec2f, a: vec2f, b: vec2f, r: f32) -> f32 {
    let ba = b - a;
    let pa = p - a;
    let h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

fn transformedBox(p: vec2f, b: vec2f, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    let raw_dist = box(q, b);
    return scale_sdf_distance(raw_dist, transform);
}

fn transformedParallelogram(p: vec2f, wi: f32, he: f32, sk: f32, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    let raw_dist = parallelogram(q, wi, he, sk);
    return scale_sdf_distance(raw_dist, transform);
}


// 1. Define the constant for array size (must match the input array size)
const N: u32 = 6u;

fn sixPolygon(p: vec2f, v: array<vec2f, N>) -> f32 {
    // 2. Variable declarations
    // 'var' is mutable, 'let' is immutable.
    // We use explicit 'u' suffixes for unsigned integers used in indexing.
    
    // Initial distance to the first vertex
    var d = dot(p - v[0], p - v[0]);
    var s = 1.0;
    
    // Initialize j to the last element (N-1)
    var j = N - 1u;

    // 3. Loop Structure
    // Note: The "j=i, i++" GLSL logic is split. 
    // j is updated at the very bottom of the loop.
    for (var i = 0u; i < N; i++) {
        
        let e = v[j] - v[i];
        let w = p - v[i];

        // 4. Distance to segment calculation
        // clamp, dot, and min are standard built-ins in WGSL
        let b = w - e * clamp(dot(w, e) / dot(e, e), 0.0, 1.0);
        d = min(d, dot(b, b));

        // 5. Winding number logic
        // We construct a vec3<bool> explicitly.
        let cond = vec3<bool>(
            p.y >= v[i].y,
            (p.y < v[j].y),
            (e.x * w.y > e.y * w.x)
        );

        // 6. Boolean Logic
        // all() works on vec3<bool>. 
        // !cond negates the vector component-wise (equivalent to not(cond)).
        if (all(cond) || all(!cond)) {
            s = -s;
        }

        // 7. Update j for the next iteration (replacing the comma operator)
        j = i;
    }

    return s * sqrt(d);
}


// --- End import: primitives ---

// --- Begin import: beats ---

const BPM = 170.0;
const BEAT_SECS = BPM * f32(0.016666666666666666); // 1/60
// Returns 0.0 if beat < start
// Returns 1.0 if beat > end
// Returns 0.0->1.0 in between
fn progress(beat: f32, start: f32, end: f32) -> f32 {
    return clamp((beat - start) / (end - start), 0.0, 1.0);
}

fn easing(v: vec4f, end: f32, t: f32) -> f32 {
    let start = v.x;
    let easingId = u32(v.y + 0.5); // Round to nearest int
    
    // Parameters extracted for clarity
    let p1 = v.z; 
    let p2 = v.w;

    var factor = t; // Default: Linear

    switch easingId {
        case 1u: {
            // ID 1: Linear with Sine offset
            // p1 = Frequency (Speed of oscillation)
            // p2 = Amplitude (Size of the wave)
            // Useful for: Shaking effects, wobbling intensity, or electrical flickering.
            // Note: Does not guarantee landing exactly at 1.0 if t=1.0, unless p2 is 0.
            factor = t + (sin(t * p1) * p2);
        }
        case 2u: {
            // ID 2: Smoothstep
            // Standard smooth start and end. 
            // Params ignored.
            factor = smoothstep(0.0, 1.0, t);
        }
        default: {
            // Fallback: Linear
            factor = t;
        }
    }

    return mix(start, end, factor);
}

// sin, smoothstep, easing param1, easing param2) 
// vec4(v, id easing )
fn bar4(beat: f32, b1: vec4f, b2: vec4f, b3: vec4f, b4: vec4f) -> f32 {
    // 1. Determine where we are in the 4-beat cycle (0.0 to 3.999...)
    let barPosition = beat % 4.0;
    
    // 2. Identify the specific beat index (0, 1, 2, or 3)
    let beatIndex = u32(barPosition);
    
    // 3. Extract local time 't' for the current beat (0.0 to 1.0)
    let t = fract(barPosition);

    var currentConfig: vec4f;
    var nextTarget: f32;

    switch beatIndex {
        case 0u: {
            // Beat 1: Animate from b1 to b2
            currentConfig = b1;
            nextTarget = b2.x; // The start value of the next beat is our target
        }
        case 1u: {
            // Beat 2: Animate from b2 to b3
            currentConfig = b2;
            nextTarget = b3.x;
        }
        case 2u: {
            // Beat 3: Animate from b3 to b4
            currentConfig = b3;
            nextTarget = b4.x;
        }
        case 3u: {
            // Beat 4: Animate from b4 back to b1 (Looping)
            currentConfig = b4;
            nextTarget = b1.x; // Closing the loop
        }
        default: {
            // Fallback
            currentConfig = b1;
            nextTarget = b1.x;
        }
    }

    // Delegate the actual math to our previously defined easing function
    return easing(currentConfig, nextTarget, t);
}


// --- End import: beats ---

// --- Begin import: tangram ---
const square_col = vec3<f32>(0.773, 0.561, 0.702);
const bigtri1_col = vec3<f32>(0.502, 0.749, 0.239);
const bigtri2_col = vec3<f32>(0.494, 0.325, 0.545);
const midtri_col = vec3<f32>(0.439, 0.573, 0.235);
const smalltri1_col = vec3<f32>(0.604, 0.137, 0.443);
const smalltri2_col = vec3<f32>(0.012, 0.522, 0.298);
const parallelogram_col = vec3<f32>(0.133, 0.655, 0.420);

struct TangramPiece {
    type_id: u32,  // 0: big tri, 1: medium tri, 2: small tri, 3: square, 4: parallelogram
    color: vec3f,
    transform: Transform2D,
}

const pieces: array<TangramPiece, 7> = array(
    TangramPiece(0u, square_col, Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0))),
    TangramPiece(1u, bigtri1_col, Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0))),
    TangramPiece(2u, bigtri2_col, Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0))),
    TangramPiece(3u, midtri_col, Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0))),
    TangramPiece(4u, smalltri1_col, Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0))),
    TangramPiece(5u, smalltri2_col, Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0))),
    TangramPiece(6u, parallelogram_col, Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0))),
);

const state_closed: array<Transform2D, 7> = array(
    Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.0, 0.0), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
);

const NO_SCALE = vec2f(1.0);
const NO_ANCHOR = vec2f();

const opened1: array<vec3f, 7> = array(
    vec3f(-0.25, 0.0, -PI * 0.25), // (x, y, rot)
    vec3f(0.0, 0.8, -0.18), // (x, y, rot)
    vec3f(-0.8, 0.3, -0.18),
    vec3f(0.6, -0.6, 0.33),
    vec3f(0.5, 0.2, 0.1),
    vec3f(-0.83, -0.2, -0.22),
    vec3f(-0.6, -0.5, 0.15)
);
const opened2: array<vec3f, 7> = array(
vec3f(0.8299, -0.2971, -0.6524),
vec3f(0.0603, -0.2038, -0.3624),
vec3f(-0.2295, 0.3802, -0.7075),
vec3f(-0.8291, -0.1798, -0.2569),
vec3f(-0.5892, -0.4718, 0.0468),
vec3f(-0.1378, -0.9420, 0.9490),
vec3f(0.2372, -0.8925, -0.5848)
);
const opened3: array<vec3f, 7> = array(
vec3f(0.5866, -0.0731, 0.3487),
vec3f(0.2497, 0.0812, 0.5356),
vec3f(-0.9578, 0.5864, -0.9372),
vec3f(0.2719, -0.8279, -0.2967),
vec3f(0.9875, 0.6842, -0.8199),
vec3f(0.0591, 0.1690, 0.7445),
vec3f(0.8652, 0.7285, 0.9075)
);
const opened4: array<vec3f, 7> = array(
vec3f(0.7298, -0.1844, -0.8829),
vec3f(-0.6386, 0.2373, 0.6857),
vec3f(0.4874, 0.6762, -0.2665),
vec3f(0.0187, 0.7647, 0.7766),
vec3f(-0.0020, 0.4670, 0.5772),
vec3f(0.4625, 0.9333, 0.4251),
vec3f(-0.5837, -0.3241, -0.4141)
);
const opened5: array<vec3f, 7> = array(
vec3f(0.4641, -0.9143, -0.5553),
vec3f(0.3456, 0.3496, 0.6253),
vec3f(-0.1729, -0.9265, 0.5243),
vec3f(-0.9456, 0.2857, 0.9052),
vec3f(-0.4753, -0.9353, -0.4513),
vec3f(-0.6442, -0.0122, 0.4895),
vec3f(-0.2449, 0.7356, -0.5364),
);
const opened6: array<vec3f, 7> = array(
vec3f(-0.5494, 0.1209, -0.3446),
vec3f(0.6194, 0.1650, -0.3516),
vec3f(0.3084, -0.9546, 0.6568),
vec3f(0.6092, -0.7844, 0.4603),
vec3f(-0.2424, 0.5443, 0.3551),
vec3f(0.0452, 0.9335, 0.1202),
vec3f(-0.9766, 0.9581, 0.9510)
);
const opened7: array<vec3f, 7> = array(
vec3f(0.9790, -0.5485, 0.6795),
vec3f(-0.0338, -0.6303, 0.5231),
vec3f(-0.8277, 0.0536, -0.6659),
vec3f(-0.1872, 0.1918, -0.3223),
vec3f(0.8099, -0.7996, 0.6587),
vec3f(0.5825, -0.7581, -0.3017),
vec3f(-0.3753, -0.5009, -0.4534)
);


const state_opened1: array<Transform2D, 7> = array(
    Transform2D(4.0 * opened1[0].xy, 2.0 * PI * opened1[0].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened1[1].xy, 2.0 * PI * opened1[1].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened1[2].xy, 2.0 * PI * opened1[2].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened1[3].xy, 2.0 * PI * opened1[3].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened1[4].xy, 2.0 * PI * opened1[4].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened1[5].xy, 2.0 * PI * opened1[5].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened1[6].xy, 2.0 * PI * opened1[6].z, NO_SCALE, NO_ANCHOR),
);

const state_opened2: array<Transform2D, 7> = array(
    Transform2D(4.0 * opened2[0].xy, 2.0 * PI * opened2[0].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened2[1].xy, 2.0 * PI * opened2[1].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened2[2].xy, 2.0 * PI * opened2[2].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened2[3].xy, 2.0 * PI * opened2[3].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened2[4].xy, 2.0 * PI * opened2[4].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened2[5].xy, 2.0 * PI * opened2[5].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened2[6].xy, 2.0 * PI * opened2[6].z, NO_SCALE, NO_ANCHOR),
);

const state_opened3: array<Transform2D, 7> = array(
    Transform2D(4.0 * opened3[0].xy, 2.0 * PI * opened3[0].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened3[1].xy, 2.0 * PI * opened3[1].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened3[2].xy, 2.0 * PI * opened3[2].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened3[3].xy, 2.0 * PI * opened3[3].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened3[4].xy, 2.0 * PI * opened3[4].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened3[5].xy, 2.0 * PI * opened3[5].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened3[6].xy, 2.0 * PI * opened3[6].z, NO_SCALE, NO_ANCHOR),
);

const state_opened4: array<Transform2D, 7> = array(
    Transform2D(4.0 * opened4[0].xy, 2.0 * PI * opened4[0].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened4[1].xy, 2.0 * PI * opened4[1].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened4[2].xy, 2.0 * PI * opened4[2].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened4[3].xy, 2.0 * PI * opened4[3].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened4[4].xy, 2.0 * PI * opened4[4].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened4[5].xy, 2.0 * PI * opened4[5].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened4[6].xy, 2.0 * PI * opened4[6].z, NO_SCALE, NO_ANCHOR),
);

const state_opened5: array<Transform2D, 7> = array(
    Transform2D(4.0 * opened5[0].xy, 2.0 * PI * opened5[0].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened5[1].xy, 2.0 * PI * opened5[1].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened5[2].xy, 2.0 * PI * opened5[2].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened5[3].xy, 2.0 * PI * opened5[3].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened5[4].xy, 2.0 * PI * opened5[4].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened5[5].xy, 2.0 * PI * opened5[5].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened5[6].xy, 2.0 * PI * opened5[6].z, NO_SCALE, NO_ANCHOR),
);

const state_opened6: array<Transform2D, 7> = array(
    Transform2D(4.0 * opened6[0].xy, 2.0 * PI * opened6[0].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened6[1].xy, 2.0 * PI * opened6[1].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened6[2].xy, 2.0 * PI * opened6[2].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened6[3].xy, 2.0 * PI * opened6[3].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened6[4].xy, 2.0 * PI * opened6[4].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened6[5].xy, 2.0 * PI * opened6[5].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened6[6].xy, 2.0 * PI * opened6[6].z, NO_SCALE, NO_ANCHOR),
);

const state_opened7: array<Transform2D, 7> = array(
    Transform2D(4.0 * opened7[0].xy, 2.0 * PI * opened7[0].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened7[1].xy, 2.0 * PI * opened7[1].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened7[2].xy, 2.0 * PI * opened7[2].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened7[3].xy, 2.0 * PI * opened7[3].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened7[4].xy, 2.0 * PI * opened7[4].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened7[5].xy, 2.0 * PI * opened7[5].z, NO_SCALE, NO_ANCHOR),
    Transform2D(4.0 * opened7[6].xy, 2.0 * PI * opened7[6].z, NO_SCALE, NO_ANCHOR),
);



const state_cat1: array<Transform2D, 7> = array(
    Transform2D(vec2<f32>(0.7, 0.79), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>( -0.5, 0.0), -PI * 0.5, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-0.5, -1.41), PI * 1.25, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-0.21, 0.29), PI * 0.25, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(1.7, 1.79), PI, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(1.20, 1.29), PI * 0.5, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-1.0, -0.91), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
);

const state_cat2: array<Transform2D, 7> = array(
    Transform2D(vec2<f32>(0.9, -0.21), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>( -0.8, -0.5), PI, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.9, -0.21), PI * 0.5, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-0.095, 0.205), PI * 1.75, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.9, -0.21), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(1.40, 0.29), PI * 1.5, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-1.8, -0.5), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
);

const state_cat3: array<Transform2D, 7> = array(
    Transform2D(vec2<f32>(-0.1, 0.91), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>( -0.51, -0.5), -PI * 0.75, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.9, -0.5), PI * 1.75, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.9, -1.9), PI*1.25, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.9, 1.91), PI, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.4, 1.41), PI * 0.5, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.19, -0.5), PI * 0.25, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
);

const state_cat4: array<Transform2D, 7> = array(
    Transform2D(vec2<f32>(-1.02, 0.5), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>( -0.515, 0.0), PI, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.9, 0.0), PI * 0.25, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.19, -0.71), PI*0.25, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-1.02, 0.5), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-0.52, 1.0), PI * 1.5, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(1.61, -1.42), PI * 0.75, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
);

const state_cat5: array<Transform2D, 7> = array(
    Transform2D(vec2<f32>(-1.0, -0.25), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>( 0.91, -0.75), PI * 0.25, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(1.61, -1.458), -PI * 0.25, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.2, -0.04), PI*0.25, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-1.0, -0.25), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-0.5, 0.25), PI * 1.5, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.2, -0.46), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
);
const state_cat6: array<Transform2D, 7> = array(
    Transform2D(vec2<f32>(1.3, -0.86), PI * 0.666, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>( 0.91, -0.75), PI * 0.666, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-1.675, -1.085), -PI * 1.085, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.515, -0.65), PI*1.416, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.61, -0.67), PI * 0.16, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.8, 0.005), PI * 1.666, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-2.49, 0.05), PI * 0.45, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
);

const state_heart: array<Transform2D, 7> = array(
    Transform2D(vec2<f32>(-0.5, -1.00), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>( 0.5, -1.00), 0.0, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-0.5, 1.0), PI * 0.5, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(-1.5, -1.0), PI * 0.5, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.0, 1.5), PI * 1.5, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(0.0, -0.5), PI * 1.5, vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0)),
    Transform2D(vec2<f32>(1.0, -0.5), PI, vec2<f32>(-1.0, 1.0), vec2<f32>(0.0, 0.0)),
);

const tangram_drawings: array<array<Transform2D, 7>, 7> = array(
    state_cat1,
    state_cat2,
    state_cat3,
    state_cat4,
    state_cat5,
    state_cat6,
    state_heart,
);
const tangram_openings: array<array<Transform2D, 7>, 7> = array(
    state_opened1,
    state_opened2,
    state_opened3,
    state_opened4,
    state_opened5,
    state_opened6,
    state_opened7,
);

// ---- Tangram Piece SDFs ----
// (These define the shapes in their local unit space)

fn tangramBigTri1(p: vec2<f32>, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    return scale_sdf_distance(tri(q,
        vec2(-1.0, 1.0),
        vec2(0.0, 0.0),
        vec2(1.0, 1.0)
    ), transform);
}
fn tangramBigTri2(p: vec2<f32>, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    return scale_sdf_distance(tri(q,
        vec2(-1.0, 1.0),
        vec2(0.0, 0.0),
        vec2(-1.0, -1.0)
    ), transform);
}

fn tangramMidTri(p: vec2<f32>, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    return scale_sdf_distance(tri(q,
        vec2(1.0, -1.0),
        vec2(1.0, 0.0),
        vec2(0.0, -1.0)
    ), transform);
}
fn tangramSmallTri1(p: vec2<f32>, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    return scale_sdf_distance(tri(q,
        vec2(1.0, 1.0),
        vec2(1.0, 0.0),
        vec2(0.5, 0.5)
    ), transform);
}
fn tangramSmallTri2(p: vec2<f32>, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    return scale_sdf_distance(tri(q,
        vec2(0.0, 0.0),
        vec2(0.5, -0.5),
        vec2(-0.5, -0.5)
    ), transform);
}

fn tangramSquare(p: vec2<f32>, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    // NOTE: This is the hard-coded transform discussed in the previous answer.
    // For a more flexible system, this transform should be part of the `pieces` data.
    var sqTransform: Transform2D;
    sqTransform.pos = vec2f(0.501, 0.0);
    sqTransform.angle = PI * 0.25;
    sqTransform.scale = vec2f(1.0, 1.0);
    // The final distance is scaled by the main piece's transform
    return scale_sdf_distance(transformedBox(q, vec2<f32>(0.3535, 0.3535), sqTransform),
    transform);
}

fn tangramParallelogram(p: vec2<f32>, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    // NOTE: This is also a hard-coded local transform.
    var parallelogramTransform: Transform2D;
    parallelogramTransform.pos = vec2f(-0.25, -1.0 + 0.25);
    parallelogramTransform.scale = vec2f(1.0, 1.0);
    parallelogramTransform.angle = 0.0;
    parallelogramTransform.anchor = vec2f(0.0);

    return scale_sdf_distance(transformedParallelogram(q, 0.5, 0.25, 0.25, parallelogramTransform), transform);
}


fn tangramPieceSDF(p: vec2f, piece: TangramPiece, transform: Transform2D) -> f32 {
    switch piece.type_id {
        case 0u: { // Square
            return tangramSquare(p, transform);
        }
        case 1u: { // Big Triangle 1
            return tangramBigTri1(p, transform);
        }
        case 2u: { // Big triangle 2
            return tangramBigTri2(p, transform);
        }
        case 3u: { // Mid Triangle
            return tangramMidTri(p, transform);
        }
        case 4u: { // Small Triangle 1
            return tangramSmallTri1(p, transform);
        }
        case 5u: { // Small Triangle 2
            return tangramSmallTri2(p, transform);
        }
        case 6u: { // Parallelogram
            return tangramParallelogram(p, transform);
        }
        default: {
            return AWAY; // Large distance for invalid type
        }
    }
}

fn fullTangramSDF(uv: vec2f, transform: Transform2D, pieces_transform: array<Transform2D, 7>) -> f32 {
    let q = transform_to_local(uv, transform);
    var result: f32 = AWAY;

    // Smooth blending for seamless edges
    let k = 0.01;

    for (var i = 0u; i < 7u; i++) {
        // Get animated state for this specific piece
        let shape_positions = pieces_transform[i];

        let piece_dist = tangramPieceSDF(q, pieces[i], shape_positions);
        // NOTE: Removed double scale correction - tangramPieceSDF already applies it

        result = smin(result, piece_dist, k);
    }
    return result;
}

fn boxOfBoxesTransform(BOB_SIZE: f32) -> array<Transform2D, 9> {
  return array<Transform2D, 9>(
    // First row (top left first)
    Transform2D(vec2f(0.0, -BOB_SIZE), 0.0, vec2f(1.0), vec2f(0.0, 0.0)),
    Transform2D(vec2f(-BOB_SIZE, -BOB_SIZE), 0.0, vec2f(1.0), vec2f(0.0, 0.0)),
    Transform2D(vec2f(BOB_SIZE, -BOB_SIZE), 0.0, vec2f(1.0), vec2f(0.0, 0.0)),

    // Middle row (left first)
    Transform2D(vec2f(-BOB_SIZE, 0.0), 0.0, vec2f(1.0), vec2f(0.0, 0.0)),
    Transform2D(vec2f(0.0, 0.0), 0.0, vec2f(1.0), vec2f(0.0, 0.0)),
    Transform2D(vec2f(BOB_SIZE, 0.0), 0.0, vec2f(1.0), vec2f(0.0, 0.0)),

    // Bottom row (right first)
    Transform2D(vec2f(BOB_SIZE, BOB_SIZE), 0.0, vec2f(1.0), vec2f(0.0, 0.0)),
    Transform2D(vec2f(0.0, BOB_SIZE), 0.0, vec2f(1.0), vec2f(0.0, 0.0)),
    Transform2D(vec2f(-BOB_SIZE, BOB_SIZE), 0.0, vec2f(1.0), vec2f(0.0, 0.0)),
  );
}

fn catFaceLogo2(p: vec2f, size: f32, whiskers_t:f32, transform: Transform2D) -> f32 {
  let qt = transform_to_local(p, transform);
  let catTransf = Transform2D(vec2f(), PI * 1.75, vec2f(1.0), vec2f());
  let q = transform_to_local(qt, catTransf);

  let bob_half_size = size / 3.0;
  let bob_size = bob_half_size * 2.0;

  let transforms = boxOfBoxesTransform(bob_size);
  var d = AWAY * 1000.0;
  for (var i = 0u; i < 8; i++) {
    let transf = transforms[i];

    d = min(d, transformedBox(q, vec2f(bob_half_size), transf)); //  - 0.001;
  }

  let cat = scale_sdf_distance(d, catTransf);

  let whiskersThickness = size * 0.0025;
  let startingY = -size * 0.8;
  let box1 = transformedBox(qt, vec2f(size * 0.8, whiskersThickness), Transform2D(vec2f(0.0, startingY), 0.0, vec2f(1.0), vec2f()));
  let box2 = transformedBox(qt, vec2f(size * 0.9, whiskersThickness), Transform2D(vec2f(0.0, startingY + whiskersThickness * 50.0), 0.0, vec2f(1.0), vec2f()));
  let box3 = transformedBox(qt, vec2f(size, whiskersThickness), Transform2D(vec2f(0.0, startingY + whiskersThickness * 100.0), 0.0, vec2f(1.0), vec2f()));

  return min(min(min(cat, box1), box2), box3);
}

const CAT: array<vec2f, 6> = array(
    vec2f(0, 212.13),
    vec2f(212.13, 424.26),    
    vec2f(424.26, 212.13),
    vec2f(282.84, 70.71),
    vec2f(212.13, 141.42),
    vec2f(141.42, 70.71)
);
fn catFaceLogo(p: vec2f, p_size: f32, whiskers_t:f32, transform: Transform2D) -> f32 {
  let qt = transform_to_local(p, transform);
  let size = 1.0 / 300.0;
  let catTransf = Transform2D(vec2f(0.71), PI, vec2f(size), vec2f());
  let q = transform_to_local(qt, catTransf);

  let polyCat = sixPolygon(q, CAT);
  let cat = scale_sdf_distance(polyCat, catTransf);

  let whiskersThickness = 0.02;
  let whiskersSize = 0.45; // 0.4;
  let whiskersMargin = 0.06;
  let startingY = -0.45;
  let box1 = transformedBox(qt, vec2f(whiskersSize * 0.8, whiskersThickness), Transform2D(vec2f(0.0, startingY), 0.0, vec2f(1.0), vec2f()));
  let box2 = transformedBox(qt, vec2f(whiskersSize * 0.9, whiskersThickness), Transform2D(vec2f(0.0, startingY + whiskersThickness + whiskersMargin * 0.828), 0.0, vec2f(1.0), vec2f()));
  let box3 = transformedBox(qt, vec2f(whiskersSize, whiskersThickness), Transform2D(vec2f(0.0, startingY + whiskersThickness + whiskersMargin * 2.0), 0.0, vec2f(1.0), vec2f()));
  let box1_scaled = scale_sdf_distance(box1, catTransf);
  let box2_scaled = scale_sdf_distance(box2, catTransf);
  let box3_scaled = scale_sdf_distance(box3, catTransf);

  return min(min(min(cat, box1_scaled), box2_scaled), box3_scaled);
}



// --- End import: tangram ---
struct PngineInputs {
  time: f32,
  canvasW: f32,
  canvasH: f32,
  canvasRatio: f32,
};

struct SceneYInputs {
  twist: f32,
  viz: f32,
  fov: f32,
}

@group(0) @binding(0) var<uniform> pngine: PngineInputs;
@group(0) @binding(1) var<uniform> inputs: SceneYInputs;

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) uv: vec2f,
  @location(1) correctedUv: vec2f,

  @location(2) twist: f32,
  @location(3) viz: f32,
  @location(4) fov: f32,
  @location(5) tint: f32,
  @location(6) sin_twist_half: f32,  // Precomputed: sin(twist * 0.5)
  @location(7) cos_twist: f32,       // Precomputed: cos(twist) for camera rotation
  @location(8) sin_twist: f32,       // Precomputed: sin(twist) for camera rotation
}

@vertex
fn vs_sceneY(@builtin(vertex_index) vertexIndex: u32) -> VertexOutput {
  var pos = array(
    vec2f(-1.0, -1.0),
    vec2f(-1.0,  3.0),
    vec2f( 3.0, -1.0),
  );

  var output: VertexOutput;
  let xy = pos[vertexIndex];
  output.position = vec4f(xy, 0.0, 1.0);
  output.uv = xy * vec2f(0.5, -0.5) + vec2f(0.5);

  // Aspect-ratio correction in vertex shader
  var corrected = output.uv * 2.0 - 1.0;  // Center to [-1, 1]

  // Normalize UV space so 1 unit == min(canvasW, canvasH) in pixels
  let minDim = min(pngine.canvasW, pngine.canvasH);
  let scale = vec2f(pngine.canvasW / minDim, pngine.canvasH / minDim);
  corrected *= scale;

  let beat = pngine.time * BEAT_SECS;
  output.correctedUv = corrected;

  output.twist = twist_bpm(beat);
  output.viz = viz_bpm(beat);
  output.fov = fov_bpm(beat);
  output.tint = tint_bpm(beat);

  // Precompute trig values for twist (used in map() and renderBalls())
  // These are constant for the entire frame - no need to compute per-pixel
  output.sin_twist_half = sin(output.twist * 0.5);
  output.cos_twist = cos(output.twist);
  output.sin_twist = sin(output.twist);

  return output;
}

// Scene timing
const SCENE_DURATION: f32 = 28.0;       // 7 compasses
const SCENE_END_DURATION: f32 = 4.0;    // 1 compass for fade out
const SCENE_END_START: f32 = SCENE_DURATION - SCENE_END_DURATION;  // beat 24

// twist: starts high and holds, then crescendo envelope (not beat-synced)
fn twist_bpm(beat: f32) -> f32 {
  let high_value = 0.8;

  // Hold immutable for 2 compasses (8 beats)
  if (beat < 9.0) {
    return high_value;
  }

  // After hold: smooth crescendo envelope
  let active_time = beat - 9.0;

  // Crescendo: slowly increasing amplitude over time
  let envelope = smoothstep(0.0, 32.0, active_time);  // ramps up over 32 beats

  // Smooth wave motion (not beat-synced, slower organic movement)
  let wave = sin(active_time * 0.3) * envelope * 0.3;

  // Gradual drift upward
  let drift = active_time * 0.01 * envelope;

  return high_value + wave + drift;
}

// fov: breathes with the music, kicks on strong beats
fn fov_bpm(beat: f32) -> f32 {
  // Base FOV
  let base = 1.0;

  // Gentle breathing
  let breathe = sin(beat * PI / 2.0) * 0.05;

  // Kick on strong beats (1 and 3)
  let bar_pos = beat % 4.0;
  let kick1 = smoothstep(0.0, 0.1, bar_pos) * (1.0 - smoothstep(0.1, 0.5, bar_pos)) * 0.15;
  let kick3 = smoothstep(2.0, 2.1, bar_pos) * (1.0 - smoothstep(2.1, 2.5, bar_pos)) * 0.1;

  return base + breathe - kick1 - kick3;
}

// viz: after intro, cycles between 0.0, 0.333, 0.666 on strong beats, returns to 1.0 at end
fn viz_bpm(beat: f32) -> f32 {
  // First compass: fade from 1.0 to base level
  if (beat < 4.0) {
    let progress = beat / 4.0;
    return mix(1.0, 0.0, smoothstep(0.0, 1.0, progress));
  }

  // Scene end: fade back to 1.0
  if (beat >= SCENE_END_START) {
    let end_progress = (beat - SCENE_END_START) / SCENE_END_DURATION;
    let current_viz = bar4(beat,
      vec4f(0.0, 2.0, 0.0, 0.0),
      vec4f(0.333, 2.0, 0.0, 0.0),
      vec4f(0.0, 2.0, 0.0, 0.0),
      vec4f(0.666, 2.0, 0.0, 0.0)
    );
    return mix(current_viz, 1.0, smoothstep(0.0, 1.0, end_progress));
  }

  // Main scene: step between values on strong beats
  let b1 = vec4f(0.0, 2.0, 0.0, 0.0);    // beat 1: low
  let b2 = vec4f(0.333, 2.0, 0.0, 0.0);  // beat 2: medium
  let b3 = vec4f(0.0, 2.0, 0.0, 0.0);    // beat 3: low
  let b4 = vec4f(0.666, 2.0, 0.0, 0.0);  // beat 4: high

  return bar4(beat, b1, b2, b3, b4);
}

// tint: starts at 1.0, holds for one compass (4 beats), then goes to 0.0 in one beat
fn tint_bpm(beat: f32) -> f32 {
  if (beat < 4.0) {
    return 1.0;  // hold at 1.0 for first compass
  }
  if (beat < 5.0) {
    // beat 4-5: transition from 1.0 to 0.0
    let t = beat - 4.0;
    return mix(1.0, 0.0, smoothstep(0.0, 1.0, t));
  }
  return 0.0;  // hold at 0.0 after
}

struct SDFResult {
  dist: f32,
  color: vec3f,
}

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

fn opExtrusion(p: vec3f, sdf: f32, h: f32) -> f32 {
    // 1. Construct the 2D vector
    // w.x = The distance to the 2D shape boundaries
    // w.y = The distance to the top/bottom "lids" of the extrusion
    let w = vec2f(sdf, abs(p.z) - h);
    
    // 2. Interior + Exterior distance logic
    // specific note: max(w, vec2f(0.0))
    // WGSL built-ins like max() generally require both arguments 
    // to be the same type. We cannot pass '0.0' (scalar) against 
    // 'w' (vector) directly; we must construct a zero vector.
    
    return min(max(w.x, w.y), 0.0) + length(max(w, vec2f(0.0)));
}

fn scene_sdf(uv: vec2f, transform: Transform2D, seed: f32) -> f32 { // <--- Adicionado 'seed'
    let q = transform_to_local(uv, transform);
    var result = SDFResult(1e10, vec3f(0.0));
    
    // Configura o número máximo de formas que tens disponíveis
    let maxShapes = 6u; 
    
    // Converte o valor aleatório (0.0 a 1.0) num índice (0 a 5)
    // Usamos min() para garantir que nunca sai fora do array
    let shapeId = min(u32(seed * f32(maxShapes)), maxShapes - 1u); 

    for (var i = 0u; i < 7u; i++) {
        let anim_transform = tangram_drawings[shapeId][i];

        let piece_dist = tangramPieceSDF(q, pieces[i], anim_transform);
        let d = scale_sdf_distance(piece_dist, transform);

        if (d < result.dist) {
            result.dist = d;
            // Early termination: if we're inside a piece, can't get smaller
            if (d < 0.001) { break; }
        }
    }
    return result.dist;
}

// OPTIMIZATION: Constant transform - no need to recreate per sdf() call
const SDF_SCALE: f32 = 0.05;
const SDF_TRANSFORM: Transform2D = Transform2D(vec2f(0.1, 0.1), PI, vec2f(SDF_SCALE), vec2f(0.0));
const EXTRUSION_HEIGHT: f32 = 0.05;
const GRID_SIZE: f32 = 8.0;

fn sdf(p: vec3f, h: vec3f) -> f32 {
  // Use precomputed const transform instead of creating new one each call
  var d = scene_sdf(p.xy, SDF_TRANSFORM, h.x);

  d = opExtrusion(p, d, EXTRUSION_HEIGHT);

  return d;
}

fn map(fsInput: VertexOutput, p_in: vec3<f32>) -> f32 {
    var p = p_in;

    // Space bending: twist world based on Z distance
    // OPTIMIZATION: Use precomputed sin_twist_half from vertex shader
    p = vec3f(p.xy * rot2D(p.z * 0.05 * fsInput.sin_twist_half), p.z);

    let cell_id = vec3<i32>(floor(p / GRID_SIZE));

    // Hash for random properties per cell
    let h = hash3(vec3f(f32(cell_id.x), f32(cell_id.y), f32(cell_id.z)) + 1337.0);

    var q = (p / GRID_SIZE);
    q = fract(q) - 0.5;

    // !!! UPGRADE 2: Audio Reactive Jitter
    // Use custom.viz to make the jitter more violent on the beat
    let bounce_energy = (pow(sin(4.0 * pngine.time), 4.0) + 1.0) / 2.0;
    // We add custom.viz to the bounce magnitude
    let audio_kick = fsInput.viz * 0.4; 
    
    let jitter = (h.yzx - vec3f(0.5)) * mix(0.1, 0.3 + audio_kick, bounce_energy);
    let local = (vec3f(q) + jitter);

    let sphere = sdf(local, h);
    return sphere * GRID_SIZE;
}

fn renderBalls(fsInput: VertexOutput, uv_i: vec2f) -> vec3f {
    // Camera rotation with twist
    // OPTIMIZATION: Use precomputed sin/cos from vertex shader instead of rot2D()
    let c = fsInput.cos_twist;
    let s = fsInput.sin_twist;
    let uv = vec2f(
        uv_i.x * c - uv_i.y * s,
        uv_i.x * s + uv_i.y * c
    );

    // Speed increases slightly with audio intensity
    let speed = 8.0; //  + (custom.viz * 10.0);
    
    // FOV kicks when audio hits (Zoom effect)
    let fov = fsInput.fov - (fsInput.viz * 0.2); 

    let ro = vec3f(0, 0, -3 + pngine.time * speed);
    let rd = normalize(vec3f(uv * fov, 1.0));
    
    var t = 0.0; 
    var col = vec3f(); // vec3<f32>(0.1, 0.8, 0.2) * (fsInput.viz); 
    
    // !!! UPGRADE 5: Better Raymarching Loop
    // Fixed iterations. Don't use viz for iterations (causes flickering artifacts)
    // 64 is usually enough for a grid like this
    for (var i: i32 = 0; i < 80; i++) {
        var p = ro + rd * t; 
        var d = map(fsInput, p); 

        // !!! UPGRADE 6: Palette Glow
        // Instead of constant orange, we generate color based on Z-depth
        // This makes distant spheres a different color than close ones
        let depth_color = palette(p.z * 0.04 + pngine.time * 0.2);
        
        // Audio boosts the glow density
        let density = 0.008 + (fsInput.viz * 0.01);
        let falloffSpeed = 8.0; // Looser falloff for more bloom
        
        col += depth_color * density * exp(-d * falloffSpeed);

        if (d < 0.001) {
            // When we hit a surface, we add a burst of white + the palette color
            col += depth_color * 2.0; 
            break;
        }

        t += d * 0.7 * (1.0 - fsInput.viz); // 0.7 is safer to prevent artifacts
        if (t > 150.0) { break; } // Shorter draw distance hides the "end" of the world
    }

    return col;

}

fn render(fsInput: VertexOutput) -> vec3f {
  return renderBalls(fsInput, fsInput.correctedUv);
}

@fragment
fn fs_sceneY(fsInput: VertexOutput) -> @location(0) vec4f {
  // DON'T REMOVE THESE (keeps uniform bindings active):
  var something = inputs.viz;
  something = inputs.twist;
  something = inputs.fov;

  var color = render(fsInput);

  // Apply magenta tint (1.0 = full magenta, 0.0 = original colors)
  let magenta = vec3f(1.0, 0.0, 1.0);
  let luminance = dot(color, vec3f(0.299, 0.587, 0.114));
  let tinted = magenta * luminance;
  color = mix(color, tinted, fsInput.tint);

  return vec4f(color, 1.0);
}

