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

// --- Begin import: mainBox ---

struct BoxLayer {
    type_id: u32, // 0 box body; 1; eye
    color: vec3f,
    transform: Transform2D,
}


const BoxLayersLength: u32 = 3;
const BoxLayers = array<BoxLayer, BoxLayersLength>(
  // 2 eyes:
  BoxLayer(1, vec3f(1.0), Transform2D(vec2f(0.07, -0.035), 0.0, vec2f(1.0), vec2f(0.0))),
  BoxLayer(1, vec3f(1.0), Transform2D(vec2f(-0.07, -0.035), 0.0, vec2f(1.0), vec2f(0.0))),
  // body:
  BoxLayer(0, vec3f(0.0), NO_TRANSFORM)
);

fn box_eye(p: vec2f, eye: BoxLayer, eyelid_t: f32) -> f32 {
  let eyeRatio = 2.87;
  let eyeW = 0.03;
  let eyeRadius = eyeW * 0.6;
  let eyeH = eyeW * eyeRatio;

  // Local space
  let eyeQ = transform_to_local(p, eye.transform);

  // Rounded box eye SDF
  let eyeSdf = box(eyeQ, vec2f(eyeW - eyeRadius, eyeH - eyeRadius)) - eyeRadius;

  // ----- Eyelid clipping from TOP -----
  let t = clamp(eyelid_t, 0.0, 1.0);

  // In Y-down coords:
  //   top ≈ -eyeH, bottom ≈ +eyeH
  // Lid moves from top (-eyeH) to bottom (+eyeH)
  let lidY = mix(-eyeH, eyeH + 0.01, t);

  // Half-space: keep region *below* the lid (y > lidY)
  // For y > lidY: lidSdf < 0 (inside allowed), y < lidY: lidSdf > 0 (clipped)
  let lidSdf = lidY - eyeQ.y;

  // Intersection: eye ∩ half-space
  let clippedEye = max(eyeSdf, lidSdf);

  return scale_sdf_distance(clippedEye, eye.transform);
}


fn box_full(p: vec2f, transform: Transform2D) -> f32 {
  return transformedBox(p, BOX_SIZE, transform);
}

fn box_without_eyes(p: vec2f, transform: Transform2D, eyelid_t: f32) -> f32 {
  let q = transform_to_local(p, transform);

  let eye1 = box_eye(q, BoxLayers[0], eyelid_t);
  let eye2 = box_eye(q, BoxLayers[1], eyelid_t);

  
  let bodyPiece = BoxLayers[BoxLayersLength - 1];
  let t = bodyPiece.transform;
  let raw = max(-eye2, max(-eye1, box(transform_to_local(q, t), BOX_SIZE)));
  let box = scale_sdf_distance(raw, t); 
  return box;
}

fn box_layer_sdf(p: vec2f, piece: BoxLayer, transform: Transform2D, eyelid_t: f32) -> f32 {
  let q = transform_to_local(p, transform);
  let t = piece.transform;

  switch piece.type_id {
    case 0u: {  return box_without_eyes(q, t, eyelid_t); }
    case 1u: { // Eye
      let eyeRatio = 2.87;
      let eyeW = 0.03;
      let eyeRadius = eyeW *  0.6;
      let eyeH = eyeW * eyeRatio;
      let eyeQ = transform_to_local(q, t);
      let eye = box(eyeQ, vec2f(eyeW - eyeRadius, eyeH - eyeRadius)) - eyeRadius;
      return scale_sdf_distance(eye, t); 
    }
    default: { return AWAY; }
  }
}


// --- End import: mainBox ---

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

struct SceneWInputs {
  eyelid_t: f32,
  cam_t: f32,
  tangram_visibility_t: f32,
  tangram_movement_t: f32,
  cam_rot_t: f32,
  video_visibility_t: f32,
  video_t: f32,
}

@group(0) @binding(0) var<uniform> pngine: PngineInputs;
@group(0) @binding(1) var<uniform> inputs: SceneWInputs;

// Video texture bindings
@group(1) @binding(0) var videoSampler: sampler;
@group(1) @binding(1) var videoTexture: texture_external;

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) uv: vec2f,
  @location(1) correctedUv: vec2f,
  @location(2) aaWidth: f32,
  @location(3) beat: vec2f,

  // 
  @location(4) v_attr1: vec4f,
  // eyelid_t: f32,
  // cam_t: f32,
  // tangram_visibility_t: f32,
  // tangram_movement_t: f32,
  @location(5) v_attr2: vec4f,
  // cam_rot_t: f32,
  // video_visibility_t: f32,
  // video_t: f32,
  // bridge_visibility_t: f32,

  // Bridge
  @location(6) height1: f32,
  @location(7) height2: f32,
  @location(8) dist: f32,
  @location(9) train_mov: f32,
// background
  @location(10) glow_t: f32,
  @location(11) bg_vis_t: f32,
}

fn get_eyelid_t(i: VertexOutput) -> f32 { return i.v_attr1.x; }
fn get_cam_t(i: VertexOutput) -> f32 { return i.v_attr1.y; }
fn get_tangram_visibility_t(i: VertexOutput) -> f32 { return i.v_attr1.z; }
fn get_tangram_movement_t(i: VertexOutput) -> f32 { return i.v_attr1.w; }
fn get_cam_rot_t(i: VertexOutput) -> f32 { return i.v_attr2.x; }
fn get_video_visibility_t(i: VertexOutput) -> f32 { return i.v_attr2.y; }
fn get_video_t(i: VertexOutput) -> f32 { return i.v_attr2.z; }
fn get_bridge_visibility_t(i: VertexOutput) -> f32 { return i.v_attr2.w; }



@vertex
fn vs_sceneW(@builtin(vertex_index) vertexIndex: u32) -> VertexOutput {
  var pos = array(
    vec2f(-1.0, -1.0),
    vec2f(-1.0, 3.0),
    vec2f(3.0, -1.0),
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

  output.correctedUv = corrected;

  // Calculate anti-aliasing width. This is approx. 1 pixel wide
  // in world-space units. We use the main screen resolution for this.
  // (Using 1.5 for a slightly softer 1px blend)
  output.aaWidth = 1.5 / f32(pngine.canvasW);

// SYNC:

  let beat = pngine.time * BEAT_SECS;
  let bar = beat % 4.0;
  output.beat = vec2f(bar, beat);

  output.v_attr1 = vec4f(
      eyelid_bpm(beat),
      cam_bpm(beat),
      tangram_vis_bpm(beat),
      tangram_movement_bpm(beat)
  );

  output.v_attr2 = vec4f(
    cam_rot_bpm(beat), // cam_rot_t,
    bg_visibility_bpm(beat), // 1.0, // video_visibility_t
    pngine.time, // video_t
    bridge_visibility_bpm(beat) // bridge_visibility_t
  );

  // BRIDGE:
  output.height1 = bridge_height1_bpm(beat);
  output.height2 = bridge_height2_bpm(beat);
  output.dist = bridge_dist_bpm(beat);
  output.train_mov = train_bpm(beat);

  output.glow_t = glow_bpm(beat);
  output.bg_vis_t = bg_visibility_bpm(beat);

  return output;
}

const TRAIN_MOV_START = bridgeStart + 1.0;
fn train_bpm(beat: f32) -> f32 {
  let compass = 4.0; // 1 compass = 4 beats

  let start = TRAIN_MOV_START;
  let t1 = smoothstep(0.0, 1.0, progress(beat, compass * start, compass * (start + 5.0)));

  // -- Composition --
  var value = mix(0.0, 1.0, t1);

  return value;
}

fn bg_visibility_bpm(beat: f32) -> f32 {
  let compass = 4.0; // 1 compass = 4 beats

  let start1 = offTime;
  // 1. 
  let param1 = progress(beat, compass * start1, compass * (start1 + 1.0));
  let t1 = (sin(param1 * PI - PI * 0.5) + 1.0) / 2.0;

  // -- Composition --
  // Start at 0.0. (go from 0 to 1)
  var value = mix(0.0, 1.0, t1);

  return value;
}

const offTime = TRAIN_MOV_START + 3.5;
const bridgeStart = tangramMovement1 + 1.0;
fn bridge_visibility_bpm(beat: f32) -> f32 {
  let compass = 4.0; // 1 compass = 4 beats

  let start1 = bridgeStart;
  // 1. 
  let param1 = progress(beat, compass * start1, compass * (start1 + 1.0));
  let t1 = (sin(param1 * PI - PI * 0.5) + 1.0) / 2.0;

  // -- Composition --
  // Start at 0.0. (go from 0 to 1)
  var value = mix(0.0, 1.0, t1);

  let start2 = offTime;
  let param2 = progress(beat, compass * start2, compass * (start2 + 1.0));
  let t2 = (sin(param2 * PI - PI * 0.5) + 1.0) / 2.0;
  value = mix(value, 0.0, t2);

  return value;
}

const tangramStart = 5.0;
const tangramMovement1 = tangramStart + 1.0;
const tangramMovement2 = tangramMovement1 + 2.0;
const tangramMovement3 = tangramMovement2 + 3.0;

fn tangram_movement_bpm(beat: f32) -> f32 {
  let compass = 4.0; // 1 compass = 4 beats

  // 1. 
  let start1 = tangramMovement1;
  let param1 = progress(beat, compass * start1, compass * (start1 + 1.0));
  let t1 = (sin(param1 * PI - PI * 0.5) + 1.0) / 2.0;

  // 2. 
  let start2 = tangramMovement2;
  let param2 = progress(beat, compass * start2, compass * (start2 + 1.0));
  let t2 = (sin(param2 * PI - PI * 0.5) + 1.0) / 2.0;

  // 3. 
  let start3 = tangramMovement3;
  let param3 = progress(beat, compass * start3, compass * (start3 + 1.0));
  let t3 = (sin(param3 * PI - PI * 0.5) + 1.0) / 2.0;

  // -- Composition --
  // Start at 0.0. (go from 0 to 1)
  var value = mix(0.0, 0.333, t1);

  // Apply second movement: mix from result to 1.0 based on t2
  value = mix(value, 0.667, t2);

  // Apply second movement: mix from result to 1.0 based on t2
  value = mix(value, 0.78, t3);

  return value;
}


fn bridge_dist_bpm(beat:f32) -> f32 {
  let phase = floor(beat / 4.0) % 4.0;

  // Shared Constants
  let H1 = 0.3;
  let H2 = 0.7;
  let H3 = 0.4;
  let H4 = 0.5;

  var value: f32;

  switch u32(phase) {
      case 0u: {
          let b1 = vec4f(H1, 2.0, 0.0, 0.0);
          let b2 = vec4f(H2, 2.0, 0.0, 0.0);
          let b3 = vec4f(H3, 2.0, 0.0, 0.0);
          let b4 = vec4f(H4, 2.0, 0.0, 0.0);

          value = bar4(beat * 2.0, b1, b2, b3, b4);
      }
      default: {
        let b1 = vec4f(H1, 2.0, 0.0, 0.0);
        let b2 = vec4f(H1, 2.0, 0.0, 0.0);
        let b3 = vec4f(H1, 2.0, 0.0, 0.0);
        let b4 = vec4f(H1, 2.0, 0.0, 0.0);

        value = bar4(beat * 2.0, b1, b2, b3, b4);
      }
  }


  return value;
}

fn bridge_height1_bpm(beat:f32) -> f32 {
  // Shared Constants
  let H1 = 0.3;
  let H2 = 0.7;
  let H3 = 0.4;
  let H4 = 0.5;
  let phase = floor(beat / 4.0) % 4.0;

  var value: f32;

  switch u32(phase) {
      case 0u: {
          let b1 = vec4f(H1, 2.0, 0.0, 0.0);
          let b2 = vec4f(H2, 2.0, 0.0, 0.0);
          let b3 = vec4f(H3, 2.0, 0.0, 0.0);
          let b4 = vec4f(H4, 2.0, 0.0, 0.0);

          value = bar4(beat * 2.0, b1, b2, b3, b4);
      }
      default: {
        let b1 = vec4f(H1, 2.0, 0.0, 0.0);
        let b2 = vec4f(H3, 2.0, 0.0, 0.0);
        let b3 = vec4f(H4, 2.0, 0.0, 0.0);
        let b4 = vec4f(H2, 2.0, 0.0, 0.0);

        value = bar4(beat * 2.0, b1, b2, b3, b4);
      }
  }


  return value;
}

fn bridge_height2_bpm(beat:f32) -> f32 {
  // Shared Constants
  let H1 = 0.5;
  let H2 = 0.2;
  let H3 = 0.48;
  let H4 = 0.666;
  let phase = floor(beat / 4.0) % 4.0;

  var value: f32;

  switch u32(phase) {
      case 0u: {
          let b1 = vec4f(H1, 2.0, 0.0, 0.0);
          let b2 = vec4f(H2, 2.0, 0.0, 0.0);
          let b3 = vec4f(H3, 2.0, 0.0, 0.0);
          let b4 = vec4f(H4, 2.0, 0.0, 0.0);

          value = bar4(beat * 2.0, b1, b2, b3, b4);
      }
      default: {
        let b1 = vec4f(H1, 2.0, 0.0, 0.0);
        let b2 = vec4f(H3, 2.0, 0.0, 0.0);
        let b3 = vec4f(H1, 2.0, 0.0, 0.0);
        let b4 = vec4f(H4, 2.0, 0.0, 0.0);

        value = bar4(beat * 2.0, b1, b2, b3, b4);
      }
  }


  return value;
}

fn cam_rot_bpm(beat:f32) -> f32 {
  let phase = floor(beat / 4.0); //  % 4.0;

  // Shared Constants
  let OPEN = 0.0;
  let CLOSED = 1.0;
  let BEAT = 10.0;

  var glow_value: f32;

  let b1 = vec4f(OPEN, 2.0, 0.0, 0.0);
  let b2 = vec4f(CLOSED, 2.0, 0.0, 0.0);
  let b3 = vec4f(OPEN, 2.0, 0.0, 0.0);
  let b4 = vec4f(CLOSED, 2.0, 0.0, 0.0);

  glow_value = bar4(beat * 2.0, b1, b2, b3, b4);

  return glow_value;
}
fn glow_bpm(beat:f32) -> f32 {
  let phase = floor(beat / 4.0); //  % 4.0;

  // Shared Constants
  let OPEN = 0.0;
  let CLOSED = 1.0;

  var glow_value: f32;

  let b1 = vec4f(OPEN, 2.0, 0.0, 0.0);
  let b2 = vec4f(CLOSED, 2.0, 0.0, 0.0);
  let b3 = vec4f(OPEN, 2.0, 0.0, 0.0);
  let b4 = vec4f(CLOSED, 2.0, 0.0, 0.0);

  glow_value = bar4(beat * 2.0, b1, b2, b3, b4);

  return glow_value;
}

fn tangram_vis_bpm(beat: f32) -> f32 {
  let compass = 4.0; // 1 compass = 4 beats

  // 1. Calculate the progress for the first move (Compass 2: beats 4 to 8)
  // We use Smoothstep here to make the camera start and stop gently
  let start = 5.0;
  let t1 = smoothstep(0.0, 1.0, progress(beat, compass * start, compass * (start + 1.0)));

  // 2. Calculate the progress for the second move (Compass 4: beats 12 to 16)
  // let t2 = smoothstep(0.0, 1.0, progress(beat, compass * 300.0, compass * 301.0));

  // -- Composition --
  // Start at 0.0. (go from 0 to 1)
  var value = mix(0.0, 1.0, t1);

  let start2 = offTime;
  let param2 = progress(beat, compass * start2, compass * (start2 + 1.0));
  let t2 = (sin(param2 * PI - PI * 0.5) + 1.0) / 2.0;
  value = mix(value, 0.0, t2);
  // Apply second movement: mix from result to 1.0 based on t2
  // value = mix(1.0, 0.0, t2);

  return value;
}

fn cam_bpm(beat: f32) -> f32 {
  // -- Helper variables for readability --
  let compass = 4.0; // 1 compass = 4 beats

  // 1. Calculate the progress for the first move (Compass 2: beats 4 to 8)
  // We use Smoothstep here to make the camera start and stop gently
  let t1 = smoothstep(0.0, 1.0, progress(beat, compass * 1.0, compass * 2.0));

  // 2. Calculate the progress for the second move (Compass 4: beats 12 to 16)
  let t2 = smoothstep(0.0, 1.0, progress(beat, compass * 3.0, compass * 4.0));

  // -- Composition --

  // Start at 0.0.
  // Apply first movement: mix to 0.2 based on t1
  var cam_val = mix(0.0, 0.2, t1);

  // Apply second movement: mix from result to 1.0 based on t2
  cam_val = mix(cam_val, 1.0, t2);

  return cam_val;
}

fn eyelid_bpm(beat: f32) -> f32 {
  let phase = floor(beat / 4.0) % 4.0;

  // Shared Constants
  let OPEN = 0.0;
  let CLOSED = 1.0;

  var eye_value: f32;

  switch u32(phase) {
      case 0u: {
        let b1 = vec4f(OPEN, 2.0, 0.0, 0.0);
        let b2 = vec4f(CLOSED, 2.0, 0.0, 0.0);
        let b3 = vec4f(OPEN, 2.0, 0.0, 0.0);
        let b4 = vec4f(OPEN, 2.0, 0.0, 0.0);

        eye_value = bar4(beat, b1, b2, b3, b4);
      }
      case 2u: {
        let b1 = vec4f(OPEN, 2.0, 0.0, 0.0);
        let b2 = vec4f(CLOSED, 2.0, 0.0, 0.0);
        let b3 = vec4f(OPEN, 2.0, 0.0, 0.0);
        let b4 = vec4f(CLOSED, 2.0, 0.0, 0.0);

        eye_value = bar4(beat, b1, b2, b3, b4);
      }
      default: {
        let fast_beat = beat * 2.0;

        let b1 = vec4f(OPEN, 2.0, 0.0, 0.0);   
        let b2 = vec4f(OPEN, 2.0, 0.0, 0.0); 
        let b3 = vec4f(OPEN, 2.0, 0.0, 0.0);
        let b4 = vec4f(OPEN, 2.0, 0.0, 0.0);

        eye_value = bar4(fast_beat, b1, b2, b3, b4);
      }
  }

  return eye_value;
}


// ==========================================
// CONSTANTS & DATA
// ==========================================

const CAM_ROT_MAX_ANGLE = 0.01;

struct SDFResult {
  dist: f32,
  color: vec3f,
}


// The tangram square movement, rotating and anchor adjustment:
fn tangramTransform(initX: f32, fsInput: VertexOutput) -> Transform2D {
    let left = -0.5 * pngine.canvasRatio;
    let box_scene_pos_x = initX + (BOX_SIZE.x * 2.0) * 3.0; // left + BOX_SIZE.x * 4.0;

    const movements: u32 = 3;
    let animT = get_tangram_movement_t(fsInput) * f32(movements);
    let index: u32 = u32(floor(animT)); // u32(floor(round((1.0 + sin(0.5 * time.elapsed)) / 2.0)));
    let tangramScale = 0.20;
    let position = array<vec2<f32>, movements>(
        vec2f(box_scene_pos_x, 0.0) + vec2f(0.0, 1.0)*tangramScale,
        vec2f(box_scene_pos_x - BOX_SIZE.x * 2.0, 0.0) + vec2f(0.0, 1.0)*tangramScale,
        vec2f(box_scene_pos_x - BOX_SIZE.x * 3.0, 0.0) + vec2f(-1.0, 1.0)*tangramScale
    )[index];
    // x is inverted (left is 1.0, and right -1.0, so its from 1.0 to -1.0)
    let anchor = array<vec2<f32>, movements>(
        vec2f(1.0, -1.0) * tangramScale,
        vec2f(1.0, 1.0) * tangramScale,
        vec2f(-1.0, 1.0) * tangramScale,
    )[index];
    let startingAngle = array<f32, movements>(
        0.0,
        -PI * 0.5,
        -PI,
    )[index];
    let endingAngle = array<f32, movements>(-PI * 0.5, -PI, -PI * 1.5)[index];

    let tangramTransf = Transform2D(
        position,
        mix(startingAngle, endingAngle, fract(animT)),
        vec2f(tangramScale),
        anchor
    );

    return tangramTransf;
}

// Helper function to sample video
fn sampleVideo(uv: vec2f) -> vec4f {
  return textureSampleBaseClampToEdge(videoTexture, videoSampler, uv);
}

const VIDEO_RATIO: f32 = 1033.0 / 919.0; // w / h

fn scene_sdf_io(fsInput: VertexOutput, p: vec2f, transform: Transform2D) -> SDFResult {
  let q = transform_to_local(p, transform);
  let left = -1.0 * pngine.canvasRatio;
  let right = 1.0 * pngine.canvasRatio;

  var result = SDFResult(AWAY, vec3f(0.0));


  // Render box layers:
  let boxX = mix(0, left + BOX_SIZE.x * 3.0, get_cam_t(fsInput));
  let boxTransfInit = Transform2D(vec2f(boxX, 0.0), 0.0, vec2f(1.0), vec2f(0.0));
  let boxTransfFinal = Transform2D(vec2f(0.0, -0.3), 2*PI, vec2f(1.78), vec2f(0.0));
  var boxTransf = mixTransform(boxTransfInit, boxTransfFinal, fsInput.bg_vis_t); 
  var video_color = vec3f();
  var box_pieces_color = vec3f();

  for (var i = 0u; i < BoxLayersLength; i++) {
    let layer_dist = box_layer_sdf(q, BoxLayers[i], boxTransf, get_eyelid_t(fsInput));

    if (layer_dist < result.dist) {
      result.dist = layer_dist;
      box_pieces_color = BoxLayers[i].color;

      if (get_video_t(fsInput) > 0.0) {
        let boxLocal = transform_to_local(q, boxTransf);
        var videoUV = (boxLocal / BOX_SIZE) * 0.66 + 0.66;
        videoUV.x -= 0.16;
        videoUV.y += 0.02;
        video_color = sampleVideo(videoUV).xyz;
      }
    }
  }
  result.color = mix(box_pieces_color, video_color, get_video_visibility_t(fsInput));

  // Render tangram box:
  if (get_tangram_visibility_t(fsInput) > 0.0) {
    let tangramQ = transform_to_local(q, tangramTransform(boxX, fsInput));
    for (var i = 0u; i < 7u; i++) {
      // 'q' is the coordinate in the *main tangram's* local space.
      // This is the correct coordinate to pass to the piece SDF.
      let piece_dist = tangramPieceSDF(tangramQ, pieces[i], state_closed[i]);
    
      // 'piece_dist' is already scaled by the piece's transform.
      // Now we scale it *again* by the main tangram's transform.
      let d = scale_sdf_distance(piece_dist, transform);
    
      if (d < result.dist) {
          // Tangram visibility:
          result.dist = mix(result.dist, d, get_tangram_visibility_t(fsInput)); // (sin(pngine.time) + 1.0) / 2.0);
          result.color = pieces[i].color;
      }
    }
  } 

  // Ground
  let d = segment(q, vec2f(left * 2.0, BOX_SIZE.y + 0.01), vec2f(right * 2.0, 0.0 + BOX_SIZE.y+ 0.01), 0.01);
  if (d < result.dist) {
    result.dist = d;
    result.color = vec3f(0.4, 0.2, 0.0);
  }

  // const bridgeScale = 1.0;
  // const transformBridge = Transform2D(vec2f(0.0, -0.2), 0.0, vec2f(bridgeScale, -bridgeScale), vec2f(0.0));
  // result = renderBridge(fsInput, q, transformBridge, result);

  return result;
  // let d = scale_sdf_distance(box(q, vec2f(0.3535)), transform);
}

fn render(fsInput: VertexOutput, time: f32, transform: Transform2D) -> vec3f {
    let uv = fsInput.uv;
    let correctedUv = fsInput.correctedUv;

    let sdf = scene_sdf_io(fsInput, correctedUv, transform);
    let d = sdf.dist;

    var color: vec3f;
    if (d > 0.0) {
        color = mix(vec3f(0.0), background(correctedUv, time, fsInput), get_cam_t(fsInput));
    } else {
        color = sdf.color;
    }

    // Render bridge as overlay with alpha blending
    if (get_bridge_visibility_t(fsInput) > 0.0) {
        let bridgeTransform = Transform2D(vec2f(), 0.0, vec2f(1.0, -1.0), vec2f());
        let q = transform_to_local(correctedUv, transform);
        let bridgeResult = renderBridge(fsInput, q, bridgeTransform, SDFResult());
        if (bridgeResult.dist < 0.0) {
            // Blend bridge color over existing color based on visibility
            color = mix(color, bridgeResult.color, get_bridge_visibility_t(fsInput));
        }
    }

    return color;
}

fn background(p: vec2f, t: f32, fsInput: VertexOutput) -> vec3f {
    // 1. Transform Coordinates
    let uv = transform_to_local(p, Transform2D(vec2f(), -CAM_ROT_MAX_ANGLE * get_cam_rot_t(fsInput), vec2f(1.0), vec2f()));

    // 2. Define Base Colors (High-Key / Bright)
    let bg_col = vec3f(0.96, 0.96, 0.99); // Almost white sky
    let floor_col = vec3f(0.85, 0.92, 0.88); // Mint floor

    // 3. Grid Calculation
    let grid_scale = 10.0;

    // Calculate grid lines (0.0 = background, 1.0 = line)
    // We use smoothstep for anti-aliased, crisp lines
    let gx = abs(sin(uv.x * grid_scale));
    let gy = abs(sin(uv.y * grid_scale));
    let line_width = 0.05;
    let grid_mask = smoothstep(line_width, 0.0, gx) + smoothstep(line_width, 0.0, gy);
    // Fade out grid as bridge appears
    let grid_fade = 1.0 - get_bridge_visibility_t(fsInput);
    let is_line = clamp(grid_mask, 0.0, 1.0) * grid_fade;

    // 4. Wave Glow Logic
    // Create a diagonal wave moving across the screen
    // sin(x + y - t) creates diagonal movement
    let wave_speed = 3.0;
    let wave_freq = 1.5;
    let wave_val = sin((uv.x + uv.y) * wave_freq - t * wave_speed);
    
    // Sharpen the wave so it looks like a "pulse" of light passing through
    let pulse = smoothstep(0.5, 1.0, wave_val);

    // 5. Line Color Logic
    // State A: Pure Black (High Contrast)
    let line_base = vec3f(0.0, 0.0, 0.0);
    
    // State B: Neon Cyan Glow (Bright & Cool)
    // We add 1.5 to make it "super bright" (bloom-like if supported, or just max saturated)
    let line_glow = vec3f(0.2, 1.0, 1.0) * 1.5; 
    
    // Mix the static black line with the glowing wave
    // We multiply by inputs.line_glow_t to control the overall effect strength
    // let glow_t = inputs.line_glow_t;
    let glow_t = fsInput.glow_t;
    let current_line_col = mix(line_base, line_glow, pulse * glow_t);

    // 6. Apply Grid to Background
    var final_col = mix(bg_col, current_line_col, is_line);

    // 7. The Floor (Overlay)
    let deckY = -1.0 + 0.05 * 2.0 + baseH * 2.0 + crossHeight * 2.0;
    if (-uv.y < deckY) {
        final_col = floor_col;
        
        // Optional: Fainter grid on the floor
        let floor_line_col = mix(vec3f(0.5, 0.6, 0.55), line_glow, pulse * glow_t);
        final_col = mix(final_col, floor_line_col, is_line * 0.5); // 50% opacity grid on floor
        
        // Horizon line
        // 
        let dist_from_top = abs((1.0 - uv.y) - deckY);
        if (dist_from_top < 0.02) {
            final_col = vec3f(0.6, 0.7, 0.65); 
        }
    }

    return mix(final_col, vec3f(0.9, 0.8, 0.7), fsInput.bg_vis_t);
}


// 1. Define a Struct to handle the 'out' parameter logic
struct BezierResult {
    dist: f32,    // The signed distance
    point: vec2f  // The 'outQ' closest point on the curve
}

// 2. Helper functions required by the math
fn dot2(v: vec2f) -> f32 {
    return dot(v, v);
}

fn cro(a: vec2f, b: vec2f) -> f32 {
    return a.x * b.y - a.y * b.x;
}

// 3. The Main Function
fn bezier(pos: vec2f, A: vec2f, B: vec2f, C: vec2f) -> BezierResult {
    let a = B - A;
    let b = A - 2.0 * B + C;
    let c = a * 2.0;
    let d = A - pos;

    // Cubic equation setup
    let kk = 1.0 / dot(b, b);
    let kx = kk * dot(a, b);
    let ky = kk * (2.0 * dot(a, a) + dot(d, b)) / 3.0;
    let kz = kk * dot(d, a);

    var res = 0.0;
    var sgn = 0.0;
    var outQ = vec2f(0.0);

    let p = ky - kx * kx;
    let q = kx * (2.0 * kx * kx - 3.0 * ky) + kz;
    let p3 = p * p * p;
    let q2 = q * q;
    var h = q2 + 4.0 * p3;

    if (h >= 0.0) {
        // --- 1 Root Case ---
        h = sqrt(h);
        
        // copysign logic: (q < 0.0) ? h : -h
        // WGSL select is (false_val, true_val, cond)
        h = select(-h, h, q < 0.0); 
        
        let x = (h - q) / 2.0;
        let v = sign(x) * pow(abs(x), 1.0 / 3.0);
        var t = v - p / v;

        // Newton iteration to correct cancellation errors
        t -= (t * (t * t + 3.0 * p) + q) / (3.0 * t * t + 3.0 * p);
        
        t = clamp(t - kx, 0.0, 1.0);
        
        let w = d + (c + b * t) * t;
        outQ = w + pos;
        res = dot2(w);
        sgn = cro(c + 2.0 * b * t, w);
    } else {
        // --- 3 Roots Case ---
        let z = sqrt(-p);
        
        // Using standard Trig instead of custom cos_acos_3 approximation
        let v = acos(q / (p * z * 2.0)) / 3.0;
        let m = cos(v);
        let n = sin(v) * sqrt(3.0);
        
        let t = clamp(vec3f(m + m, -n - m, n - m) * z - kx, vec3f(0.0), vec3f(1.0));
        
        // Check candidate 1
        let qx = d + (c + b * t.x) * t.x;
        let dx = dot2(qx);
        let sx = cro(a + b * t.x, qx);
        
        // Check candidate 2
        let qy = d + (c + b * t.y) * t.y;
        let dy = dot2(qy);
        let sy = cro(a + b * t.y, qy);

        if (dx < dy) {
            res = dx;
            sgn = sx;
            outQ = qx + pos;
        } else {
            res = dy;
            sgn = sy;
            outQ = qy + pos;
        }
    }

    // Return the struct combining the point and the distance
    return BezierResult(sqrt(res) * sign(sgn), outQ);
}

const baseW = 0.2;
const baseH = 0.05;
const columnW = baseW / 8.66;
const columnH = 0.8;
const leftColumnX = -baseW / 1.5;
const rightColumnX = baseW / 1.5;
const crossHeight = 0.333 * 0.5;

fn renderCross(uv: vec2f, transform: Transform2D) -> f32 {
    let q = transform_to_local(uv, transform);
    let crossCol = vec3(0.0, 1.0, 1.0);
    let crossBar1Transf = Transform2D(vec2f(0.0, 0.0), PI * 0.25, vec2f(1.0), vec2f());
    let crossBar1P = transform_to_local(q, crossBar1Transf);
    let crossBar1D = box(crossBar1P, vec2f(columnW * 0.5, (rightColumnX - leftColumnX)*0.75));
    if (crossBar1D < 0.0) {
        return crossBar1D;
    }
    let crossBar2Transf = Transform2D(vec2f(0.0, 0.0), -PI * 0.25, vec2f(1.0), vec2f());
    let crossBar2P = transform_to_local(q, crossBar2Transf);
    let crossBar2D = box(crossBar2P, vec2f(columnW * 0.5, (rightColumnX - leftColumnX)*0.75));
    if (crossBar2D < 0.0) {
        return crossBar2D;
    }
    // Render CrossCircle
    let crossCircle2Transf = Transform2D(vec2f(0.0, 0.0), 0.0, vec2f(1.0), vec2f());
    let crossCircle2P = transform_to_local(q, crossCircle2Transf);
    let crossCircle2D = circle(crossCircle2P, vec2f(), columnW*1.5);
    if (crossCircle2D < 0.0) {
        return crossCircle2D;
    }

    return 1e10;
}

fn renderTrainWindow(q: vec2f, x: f32, y: f32) -> f32 {
    let windowsTransf = Transform2D(vec2f(x, y), 0.0, vec2f(1.0), vec2f());
    let windowsD = transformedBox(q, vec2f(0.02, 0.02), windowsTransf);
    return windowsD;
}

fn renderTrain(uv: vec2f, transform: Transform2D) -> SDFResult {
    let q = transform_to_local(uv, transform);
    var result = SDFResult(1e10, vec3f(0.0));
    
    // Train colors (matching reference)
    let bodyCol = vec3<f32>(0.122, 0.322, 0.518) * 1.5;     // yellow/gold body
    let windowCol = vec3f(0.95, 0.95, 0.9);   // cream/white windows
    let windowFrameCol = vec3f(0.15, 0.15, 0.15); // dark window frames
    let undercarriageCol = vec3f(0.1, 0.1, 0.1);  // dark undercarriage
    
    // Train dimensions
    let bodyW = 0.4;
    let bodyH = 0.055;
    let bodyY = 0.0;
    

    let windowsY = 0.01;
    let windowsX = -0.2;
    let windowsMargin = 0.1;
    let windowsD = min(
        renderTrainWindow(q, windowsX, windowsY),
        min(renderTrainWindow(q, windowsX + windowsMargin * 1.0, windowsY),
        min(renderTrainWindow(q, windowsX + windowsMargin * 2.0, windowsY),
        min(renderTrainWindow(q, windowsX + windowsMargin * 3.0, windowsY),
        min(renderTrainWindow(q, windowsX + windowsMargin * 4.0, windowsY),
        renderTrainWindow(q, windowsX + windowsMargin * 5.0, windowsY))
        )))); 
    if (result.dist > windowsD && windowsD <= 0) {
        result.color = windowCol;
        result.dist = windowsD;
        return result;
    }

    let door1Transf = Transform2D(vec2f(-0.33, 0.0), 0.0, vec2f(1.0), vec2f());
    let door1D = transformedBox(q, vec2f(0.05 * 0.5, bodyH - 0.01), door1Transf);
    if (door1D <= 0) {
        result.color = windowCol;
        result.dist = door1D;
        return result;
    }
    let door2Transf = Transform2D(vec2f(-0.27, 0.0), 0.0, vec2f(1.0), vec2f());
    let door2D = transformedBox(q, vec2f(0.05 * 0.5, bodyH - 0.01), door2Transf);
    if (door2D <= 0) {
        result.color = windowCol;
        result.dist = door2D;
        return result;
    }
    
    let carriageTransf = Transform2D(vec2f(0.0, 0.0), 0.0, vec2f(1.0), vec2f());
    let carriageD = transformedBox(q, vec2f(bodyW, bodyH), carriageTransf) - 0.01;
    if (result.dist > carriageD) {
        result.color = bodyCol;
        result.dist = carriageD;
    }


    let noseTransf = Transform2D(vec2f(-0.39, -0.004), PI * 0.33, vec2f(1.0), vec2f());
    let noseD = transformedBox(q, vec2f(bodyH * 0.5, bodyH * 0.5), noseTransf) - 0.03;
    
    if (result.dist > noseD) {

        result.color = bodyCol;
        result.dist = noseD;
    
    }

    let noseWindowTransf = Transform2D(vec2f(-0.43, -0.01), 0.0, vec2f(1.0), vec2f());
    let noseWindowD = transformedTri(q, vec2f(0.0), vec2f(0.03, 0.05), vec2f(0.03, 0.0), noseWindowTransf) - 0.01;
    
    if (noseWindowD < 0.0) {
        result.color = windowCol;
        result.dist = noseWindowD;
    }


    return result;
}

fn renderColumn(uv: vec2f, transform: Transform2D, height: f32) -> SDFResult {
    let q = transform_to_local(uv, transform);
    
    var result = SDFResult(1e10, vec3f(0.0));

    let deckBridgeY = 0.256;
    let crossesAvailableHeight = height - deckBridgeY;
    let numberOfCrosses = u32(crossesAvailableHeight / crossHeight);

    // 1. Define Gradient Colors
    let gradBot = vec3f(0.2, 0.0, 0.4); // Deep Violet
    let gradTop = vec3f(1.0, 0.0, 0.6); // Hot Pink

    // 2. Calculate Gradient
    // 0.0 is bottom, 1.0 is top (scaled to the column height)
    let gradient_t = smoothstep(-0.5, height, q.y);
    let pillarColor = mix(gradBot, gradTop, gradient_t);

    // Neon Cyan for structural crosses
    let crossCol = vec3(0.0, 1.0, 1.0); 

    for (var i = 0u; i < numberOfCrosses; i++) {
        let cross1D = renderCross(q, Transform2D(vec2f(0.0, -0.21 + 0.333 * f32(i)), 0.0, vec2f(1.0), vec2f()));
        if (cross1D < 0.0) {
            result.dist = cross1D;
            result.color = crossCol;
        }
    } 

    // Render Crosses Bottom
    let cross4D = renderCross(q, Transform2D(vec2f(0.0, -0.71), 0.0, vec2f(1.0), vec2f()));
    if (cross4D < 0.0) {
        result.dist = cross4D;
        result.color = crossCol;
    }

    // Render Pillar Base
    let baseCol = vec3f(0.1, 0.1, 0.15); // Dark Metallic

    let baseTransf = Transform2D(vec2f(0.0, -1.0 + baseH), 0.0, vec2f(1.0), vec2f());
    let baseP = transform_to_local(q, baseTransf);
    let baseD = box(baseP, vec2f(baseW, baseH));
    if (baseD < 0.0) {
        result.dist = baseD;
        result.color = baseCol;
    }

    // Render Pillar Left Column
    const leftColumnY = -1.0 + columnH + baseH * 2.0;
    let leftColumnTransf = Transform2D(vec2f(leftColumnX, height), 0.0, vec2f(1.0), vec2f(0.0, -1.0 + baseH * 2.0));
    let leftColumnP = transform_to_local(q, leftColumnTransf);
    let leftColumnD = box(leftColumnP, vec2f(columnW, height));
    if (leftColumnD < 0.0) {
        result.dist = leftColumnD;
        result.color = pillarColor;
    }

    // Render Pillar Right Column
    let rightColumnTransf = Transform2D(vec2f(rightColumnX, height), 0.0, vec2f(1.0), vec2f(0.0, -1.0 + baseH * 2.0));
    let rightColumnP = transform_to_local(q, rightColumnTransf);
    let rightColumnD = box(rightColumnP, vec2f(columnW, height));
    if (rightColumnD < 0.0) {
        result.dist = rightColumnD;
        result.color = pillarColor;
    }

    // Render Top Cap
    // MATCH LOGIC: We use gradTop because the gradient smoothstep reaches 1.0 exactly at 'height'
    let topCol = gradTop; 
    
    let topTransf = Transform2D(vec2f(0.0, height * 2.0), 0.0, vec2f(1.0), vec2f(0.0, -1.0 + baseH));
    let topP = transform_to_local(q, topTransf);
    let topD = box(topP, vec2f((rightColumnX - leftColumnX) * 0.5, baseH * 0.5));
    if (topD < 0.0) {
        result.dist = topD;
        result.color = topCol;
    }

    return result;
}

fn renderBridge(custom: VertexOutput, uv: vec2f, transform: Transform2D, currentRes: SDFResult) -> SDFResult {
    let q = transform_to_local(uv, transform);
    var res = currentRes;

    // Early exit if bridge is fully invisible
    if (get_bridge_visibility_t(custom) <= 0.0) {
        return res;
    }

    let vis = get_bridge_visibility_t(custom);
    let glow = custom.glow_t;

    let column1Height = 0.333 + custom.height1;
    let column2Height = 0.333 + custom.height2;
    let columnDist = custom.dist * 2.5;
    let column1X = columnDist * 0.5;
    let column2X = -column1X;

    let deckCol = vec3f(0.05, 0.05, 0.05); 
    let deckH = 0.05;
    let deckY = -1.0 + deckH * 2.0 + baseH * 2.0 + crossHeight * 2.0;

    // Arc parameters
    let arcThickness = 0.012;
    let arcRightY = -0.333 + custom.height1 * 2.0;
    let arcLeftY = -0.333 + custom.height2 * 2.0;
    let columnMargin = (rightColumnX - leftColumnX) * 0.5;

    let arcLeft = vec2f(column2X + baseW - columnW * 2.0, arcLeftY);
    let arcRight = vec2f(column1X - baseW + columnW * 2.0, arcRightY);
    let arcMid = vec2f(0.0, deckY);

    let leftArcStart = vec2f(column2X - columnMargin, arcLeftY);
    let rightArcStart = vec2f(column1X + columnMargin, arcRightY);
    let leftArcEnd = vec2f(-2.0, deckY + deckH);
    let leftArcMid = vec2f((leftArcStart.x + leftArcEnd.x) * 0.5, deckY);
    let rightArcEnd = vec2f(2.0, deckY + deckH);
    let rightArcMid = vec2f((rightArcStart.x + rightArcEnd.x) * 0.5, deckY);

    let cableThickness = 0.008;
    let cableSpacing = 0.15;
    let cableCol = vec3f(0.7, 0.75, 0.8); 

    // --- LAYER 1: CABLES ---
    // Center cables
    let spanWidth = arcRight.x - arcLeft.x;
    let numCables = i32(spanWidth / cableSpacing);
    for (var i = 1; i < numCables; i++) {
        let t = f32(i) / f32(numCables);
        let arcPointX = (1.0 - t) * (1.0 - t) * arcLeft.x + 2.0 * (1.0 - t) * t * arcMid.x + t * t * arcRight.x;
        let arcPointY = (1.0 - t) * (1.0 - t) * arcLeft.y + 2.0 * (1.0 - t) * t * arcMid.y + t * t * arcRight.y;
        let cableTop = arcPointY;
        let cableBottom = deckY + deckH;
        let cableHeight = (cableTop - cableBottom) * 0.5;
        let cableCenterY = (cableTop + cableBottom) * 0.5;
        let cableD = box(q - vec2f(arcPointX, cableCenterY), vec2f(cableThickness, cableHeight));
        if (cableD < 0.0) {
            res.dist = mix(res.dist, cableD, vis);
            res.color = cableCol;
        }
    }

    // Left cables
    let leftSpanWidth = leftArcStart.x - leftArcEnd.x;
    let numLeftCables = i32(leftSpanWidth / cableSpacing);
    for (var i = 1; i < numLeftCables; i++) {
        let t = f32(i) / f32(numLeftCables);
        let arcPointX = (1.0 - t) * (1.0 - t) * leftArcStart.x + 2.0 * (1.0 - t) * t * leftArcMid.x + t * t * leftArcEnd.x;
        let arcPointY = (1.0 - t) * (1.0 - t) * leftArcStart.y + 2.0 * (1.0 - t) * t * leftArcMid.y + t * t * leftArcEnd.y;
        let cableTop = arcPointY;
        let cableBottom = deckY + deckH;
        if (cableTop > cableBottom) {
            let cableHeight = max((cableTop - cableBottom) * 0.5, 0.001);
            let cableCenterY = (cableTop + cableBottom) * 0.5;
            let cableD = box(q - vec2f(arcPointX, cableCenterY), vec2f(cableThickness, cableHeight));
            if (cableD < 0.0) {
                res.dist = mix(res.dist, cableD, vis);
                res.color = cableCol;
            }
        }
    }

    // Right cables
    let rightSpanWidth = rightArcEnd.x - rightArcStart.x;
    let numRightCables = i32(rightSpanWidth / cableSpacing);
    for (var i = 1; i < numRightCables; i++) {
        let t = f32(i) / f32(numRightCables);
        let arcPointX = (1.0 - t) * (1.0 - t) * rightArcStart.x + 2.0 * (1.0 - t) * t * rightArcMid.x + t * t * rightArcEnd.x;
        let arcPointY = (1.0 - t) * (1.0 - t) * rightArcStart.y + 2.0 * (1.0 - t) * t * rightArcMid.y + t * t * rightArcEnd.y;
        let cableTop = arcPointY;
        let cableBottom = deckY + deckH;
        if (cableTop > cableBottom) {
            let cableHeight = max((cableTop - cableBottom) * 0.5, 0.001);
            let cableCenterY = (cableTop + cableBottom) * 0.5;
            let cableD = box(q - vec2f(arcPointX, cableCenterY), vec2f(cableThickness, cableHeight));
            if (cableD < 0.0) {
                res.dist = mix(res.dist, cableD, vis);
                res.color = cableCol;
            }
        }
    }

    // --- LAYER 2: ARCS ---
    let arcColor = vec3f(0.6, 0.6, 0.65); 

    let centerArcD = abs(bezier(q, arcLeft, arcMid, arcRight).dist) - arcThickness;
    if (centerArcD < 0.0) {
        res.dist = mix(res.dist, centerArcD, vis);
        res.color = arcColor;
    }

    let leftArcD = abs(bezier(q, leftArcStart, leftArcMid, leftArcEnd).dist) - arcThickness;
    if (leftArcD < 0.0) {
        res.dist = mix(res.dist, leftArcD, vis);
        res.color = arcColor;
    }

    let rightArcD = abs(bezier(q, rightArcStart, rightArcMid, rightArcEnd).dist) - arcThickness;
    if (rightArcD < 0.0) {
        res.dist = mix(res.dist, rightArcD, vis);
        res.color = arcColor;
    }

    // --- LAYER 3: COLUMNS ---
    let column1Transf = Transform2D(vec2f(column1X, 0.0), 0.0, vec2f(1.0), vec2f());
    let columnResult1 = renderColumn(q, column1Transf, column1Height);
    if (columnResult1.dist < 0.0) {
        res.dist = mix(res.dist, columnResult1.dist, vis);
        res.color = columnResult1.color;
    }

    let column2Transf = Transform2D(vec2f(column2X, 0.0), 0.0, vec2f(1.0), vec2f());
    let columnResult2 = renderColumn(q, column2Transf, column2Height);
    if (columnResult2.dist < 0.0) {
        res.dist = mix(res.dist, columnResult2.dist, vis);
        res.color = columnResult2.color;
    }

    // --- LAYER 4: TRAINS ---
    let trainY = deckY + deckH + 0.018;
    let trainX = 2.5 - 6.0 * custom.train_mov;

    let train1Transf = Transform2D(vec2f(trainX, trainY + 0.04), 0.0, vec2f(1.0), vec2f());
    let train1Result = renderTrain(q, train1Transf);
    if (train1Result.dist < 0.0) {
        res.dist = mix(res.dist, train1Result.dist, vis);
        res.color = train1Result.color;
    }

    let train2Transf = Transform2D(vec2f(trainX + 0.84, trainY + 0.04), 0.0, vec2f(-1.0, 1.0), vec2f());
    let train2Result = renderTrain(q, train2Transf);
    if (train2Result.dist < 0.0) {
        res.dist = mix(res.dist, train2Result.dist, vis);
        res.color = train2Result.color;
    }

    // --- LAYER 5: DECK ---
    let deckTransf = Transform2D(vec2f(0.0, deckY), 0.0, vec2f(1.0), vec2f());
    let deckD = transformedBox(q, vec2f(2.0, deckH), deckTransf);
    if (deckD < 0.0) {
        res.dist = mix(res.dist, deckD, vis);
        res.color = deckCol;
    }

    // --- LAYER 6: DECK CIRCLES ---
    let circleRadiusBase = deckH * 0.5;
    let circleSpacing = 0.12;
    let circleCol = vec3f(0.0, 0.8, 0.8);
    
    let cellIndex = round(q.x / circleSpacing);
    let qx_repeated = q.x - circleSpacing * cellIndex;
    let circleCenter = vec2f(0.0, deckY);
    let circleD = circle(vec2f(qx_repeated, q.y), circleCenter, circleRadiusBase);
    if (circleD < 0.0) {
        res.dist = mix(res.dist, circleD, vis);
        res.color = circleCol;
    }

    return res;
}

@fragment
fn fs_sceneW(fsInput: VertexOutput) -> @location(0) vec4f {
  let t = pngine.time;
  
  let eyelid_t = inputs.eyelid_t;
  let cam_t = inputs.cam_t;
  let tangram_visibility_t = inputs.tangram_visibility_t;
  let tangram_movement_t = inputs.tangram_movement_t;
  let cam_rot_t = inputs.cam_rot_t;
  let video_visibility_t = inputs.video_visibility_t;
  let video_t = inputs.video_t;

  let cam = get_cam_t(fsInput);
  let left = -0.5 * pngine.canvasRatio;
  let box_scene_pos_x = mix(0, left + BOX_SIZE.x * 2.0, cam);

  var sceneTransform: Transform2D;
  // boxTransform.pos = vec2f(0.0, 0.0);
  sceneTransform.pos = vec2f(mix(0.0, 0.0, cam), 0.0);
  sceneTransform.anchor = vec2f(mix(2.0, 0.0, cam), mix(0.0, 0.2, cam));
  sceneTransform.angle = -CAM_ROT_MAX_ANGLE * get_cam_rot_t(fsInput); // PI * 0.25;
  // boxTransform.scale = vec2f(2.25);
  sceneTransform.scale = vec2f(mix(5.25, 1.0, cam));
  var color = render(fsInput, t, sceneTransform);

  color = pow(color, vec3f(2.2));

  return vec4f(color, 1.0);
}

