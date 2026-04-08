// The transformation structure (store angle in RADIANS)
struct Transform2D {
    pos: vec2f,      // World position (translation)
    angle: f32,      // Rotation in RADIANS (precomputed on CPU)
    scale: vec2f,    // 2D scale factors (x and y)
    anchor: vec2f,   // Rotation anchor in local space
};

struct SDFResult {
    dist: f32,
    color: vec3f,
}

const PI: f32 = 3.14159265359;
const square_col = vec3<f32>(0.773, 0.561, 0.702);
const bigtri1_col = vec3<f32>(0.502, 0.749, 0.239);
const bigtri2_col = vec3<f32>(0.494, 0.325, 0.545);
const midtri_col = vec3<f32>(0.439, 0.573, 0.235);
const smalltri1_col = vec3<f32>(0.604, 0.137, 0.443);
const smalltri2_col = vec3<f32>(0.012, 0.522, 0.298);
const parallelogram_col = vec3<f32>(0.133, 0.655, 0.420);
const bg_col = vec3f(0.9, 0.8, 0.7);

// 2. Core transformation function (correctly handles scale)
fn transform_to_local(uv: vec2f, xform: Transform2D) -> vec2f {
    // Remove world translation
    var p = uv - xform.pos;
    
    // Apply inverse rotation (using rotation identity)
    let c = cos(xform.angle);
    let s = sin(xform.angle);
    p = vec2f(
        c * p.x + s * p.y,   // [ c, s] * p
        -s * p.x + c * p.y   // [-s, c]
    );
    
    // Remove anchor (now in local space)
    p -= xform.anchor;
    
    // Apply inverse scale
    p /= xform.scale;
    
    return p;
}

// SDF distance scaling helper
fn scale_sdf_distance(dist: f32, xform: Transform2D) -> f32 {
    // For uniform scale
    if (abs(xform.scale.x - xform.scale.y) < 0.001) {
        return dist * xform.scale.x;
    }
    
    // For mild anisotropy (< 2:1 ratio)
    let ratio = max(xform.scale.x, xform.scale.y) / min(xform.scale.x, xform.scale.y);
    if (ratio < 2.0) {
        let avg_scale = 2.0 / (1.0/xform.scale.x + 1.0/xform.scale.y);
        return dist * avg_scale;
    }
    
    // For extreme anisotropy, use conservative estimate
    return dist * min(xform.scale.x, xform.scale.y);
}

// Circle SDF (works in LOCAL space)
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
    let outside = length(max(d, vec2f(0.0)));
    let inside = min(max(d.x, d.y), 0.0);
    return outside + inside;
}

fn transformedBox(p: vec2f, b: vec2f, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    let raw_dist = box(q, b);

    return scale_sdf_distance(raw_dist, transform);
}

// WGSL version of the SDF for a 2D triangle
fn tri(p: vec2<f32>, p0: vec2<f32>, p1: vec2<f32>, p2: vec2<f32>) -> f32 {
    // Calculate edges
    let e0: vec2<f32> = p1 - p0;
    let e1: vec2<f32> = p2 - p1;
    let e2: vec2<f32> = p0 - p2;

    // Calculate vectors from vertices to point
    let v0: vec2<f32> = p - p0;
    let v1: vec2<f32> = p - p1;
    let v2: vec2<f32> = p - p2;

    // Calculate perpendicular vectors (closest distance to edge)
    // This finds the closest point on the *infinite line* of each edge,
    // then clamps it to the *line segment*.
    let pq0: vec2<f32> = v0 - e0 * clamp(dot(v0, e0) / dot(e0, e0), 0.0f, 1.0f);
    let pq1: vec2<f32> = v1 - e1 * clamp(dot(v1, e1) / dot(e1, e1), 0.0f, 1.0f);
    let pq2: vec2<f32> = v2 - e2 * clamp(dot(v2, e2) / dot(e2, e2), 0.0f, 1.0f);

    // Calculate sign (based on 2D cross product to check winding order)
    let s: f32 = sign(e0.x * e2.y - e0.y * e2.x);

    // Calculate distance and sign for each edge
    // .x component is squared distance
    // .y component is the signed distance (cross product)
    let d0: vec2<f32> = vec2<f32>(dot(pq0, pq0), s * (v0.x * e0.y - v0.y * e0.x));
    let d1: vec2<f32> = vec2<f32>(dot(pq1, pq1), s * (v1.x * e1.y - v1.y * e1.x));
    let d2: vec2<f32> = vec2<f32>(dot(pq2, pq2), s * (v2.x * e2.y - v2.y * e2.x));

    // Find the minimum distance
    // min() on vectors performs a component-wise minimum
    let d: vec2<f32> = min(min(d0, d1), d2);

    // Final result: sqrt(squared_distance) * sign(signed_distance)
    // The negative sign at the start is because the 's' value 
    // might be negative (if vertices are wound clockwise),
    // and this calculation correctly flips the final sign.
    return -sqrt(d.x) * sign(d.y);
}

fn transformedTri(p: vec2f, p0: vec2<f32>, p1: vec2<f32>, p2: vec2<f32>, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    let raw_dist = tri(q, p0, p1, p2);

    return scale_sdf_distance(raw_dist, transform);
}

fn equilateralTriangle(p: vec2f, r: f32) -> f32 {
    let k = sqrt(3.0);
    var p_local = p;  // Create mutable copy (WGSL parameters are immutable by default)
    
    // Apply triangle distance calculation
    p_local.x = abs(p_local.x);
    p_local = p_local - vec2f(0.5, 0.5*k) * max(p_local.x + k*p_local.y, 0.0);
    p_local = p_local - vec2f(clamp(p_local.x, -0.5*r*k, 0.5*r*k), -0.5*r);
    
    return length(p_local) * sign(-p_local.y) - r * 0.1;
}

fn transformedEquilateralTriangle(p: vec2f, r: f32, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    let raw_dist = equilateralTriangle(q, r);

    return scale_sdf_distance(raw_dist, transform);
}


fn vesica(p_in: vec2<f32>, r: f32, d: f32) -> f32 {
    // Arguments are immutable, so we make a mutable local copy of 'p'
    var p = p_in;
    p = abs(p);

    let b = sqrt(r*r - d*d);

    // Use select(false_val, true_val, condition) to replace the ternary ?:
    let true_val = length(p - vec2<f32>(0.0f, b)) * sign(d);
    let false_val = length(p - vec2<f32>(-d, 0.0f)) - r;
    
    return select(
        false_val,
        true_val,
        (p.y - b) * d > p.x * b
    );
}

fn egg(p_in: vec2<f32>, he: f32, ra: f32, rb: f32) -> f32 {
    // all this can be precomputed for any given shape
    let ce = 0.5f * (he*he - (ra-rb)*(ra-rb)) / (ra-rb);

    // only this needs to be run per pixel
    
    // Create a mutable copy because function arguments are immutable
    var p = p_in; 
    p.x = abs(p.x);

    // WGSL requires braces {} for if/else blocks
    if (p.y < 0.0f) {
        return length(p) - ra;
    }
    
    // Vector constructors must be explicit: vec2<f32>(...)
    if (p.y*ce - p.x*he > he*ce) {
        return length(vec2<f32>(p.x, p.y - he)) - rb;
    }
        
    return length(vec2<f32>(p.x + ce, p.y)) - (ce + ra);
}

fn transformedEgg(p: vec2f, he: f32, ra: f32, rb: f32, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    let raw_dist = egg(q, he, ra, rb);

    return scale_sdf_distance(raw_dist, transform);
}

fn pie(p: vec2f, c: vec2f, r: f32) -> f32 {
    // Create mutable copy and mirror to right half-plane
    var point = p;
    point.x = abs(point.x);
    
    // Distance to circle boundary
    let circleDist = length(point) - r;
    
    // Project point onto edge direction
    let projection = dot(point, c);
    let clampedProjection = clamp(projection, 0.0, r);
    let edgePoint = c * clampedProjection;
    let edgeDist = length(point - edgePoint);
    
    // Determine which side of the edge we're on
    let orientation = c.y * point.x - c.x * point.y;
    let signedEdgeDist = edgeDist * sign(orientation);
    
    // Combine distances
    return max(circleDist, signedEdgeDist);
}
fn transformedPie(p: vec2f, l: f32, r: f32, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    let raw_dist = pie(q, vec2f(sin(l), cos(l)), r);

    return scale_sdf_distance(raw_dist, transform);
}

fn arc(p: vec2f, len: f32, ra: f32, rb: f32) -> f32 {
    var p_local = p;
    p_local.x = abs(p_local.x);
    let sc = vec2f(sin(len), cos(len));
    
    let condition = sc.y * p_local.x > sc.x * p_local.y;
    let result = select(
        abs(length(p_local) - ra),  // False branch (when condition is false)
        length(p_local - sc * ra),  // True branch (when condition is true)
        condition
    );
    
    return result - rb;
}


fn transformedArc(p: vec2f, len: f32, ra: f32, rb: f32, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    let raw_dist = arc(q, len, ra, rb);

    return scale_sdf_distance(raw_dist, transform);
}

fn parabola(pos: vec2f, wi: f32, he: f32) -> f32 {
    // 1. Mutability
    // WGSL arguments are immutable. We create a local mutable copy 'p'.
    var p = pos;
    p.x = abs(p.x);

    // 2. Setup Coefficients
    let ik = wi * wi / he;
    
    // Note: Renamed GLSL variable 'p' to 'coeff_p' to avoid 
    // naming collision with our position vector 'p'.
    let coeff_p = ik * (he - p.y - 0.5 * ik) / 3.0;
    
    let q = p.x * ik * ik / 4.0;
    let h = q * q - coeff_p * coeff_p * coeff_p;
    
    var x = 0.0;

    // 3. Solve Cubic Equation
    if (h > 0.0) {
        let r = pow(q + sqrt(h), 1.0 / 3.0);
        x = r + coeff_p / r;
    } else {
        let r = sqrt(coeff_p);
        x = 2.0 * r * cos(acos(q / (coeff_p * r)) / 3.0);
    }

    // 4. Final Distance Calculation
    x = min(x, wi);
    
    let closest = vec2f(x, he - x * x / ik);
    
    return length(p - closest) * sign(ik * (p.y - he) + p.x * p.x);
}

fn transformedParabola(p: vec2f, wi: f32, he: f32, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    let raw_dist = parabola(q, wi, he);

    return scale_sdf_distance(raw_dist, transform);
}

fn transformedParallelogram(p: vec2f, wi: f32, he: f32, sk: f32, transform: Transform2D) -> f32 {
    let q = transform_to_local(p, transform);
    let raw_dist = parallelogram(q, wi, he, sk);

    return scale_sdf_distance(raw_dist, transform);
}

// WGSL version of the SDF for a parallelogram
fn parallelogram(p_in: vec2<f32>, wi: f32, he: f32, sk: f32) -> f32 {
    let e: vec2<f32> = vec2<f32>(sk, he);
    
    // Copy the input 'p' to a mutable variable
    var p: vec2<f32> = p_in;

    // p = (p.y<0.0)?-p:p;
    if (p.y < 0.0f) {
        p = -p;
    }

    // vec2 w = p - e; w.x -= clamp(w.x,-wi,wi);
    var w: vec2<f32> = p - e;
    w.x = w.x - clamp(w.x, -wi, wi);

    // vec2 d = vec2(dot(w,w), -w.y);
    var d: vec2<f32> = vec2<f32>(dot(w, w), -w.y);

    // float s = p.x*e.y - p.y*e.x;
    let s: f32 = p.x * e.y - p.y * e.x;

    // p = (s<0.0)?-p:p;
    if (s < 0.0f) {
        p = -p;
    }

    // vec2 v = p - vec2(wi,0); v -= e*clamp(dot(v,e)/dot(e,e),-1.0,1.0);
    var v: vec2<f32> = p - vec2<f32>(wi, 0.0f);
    v = v - e * clamp(dot(v, e) / dot(e, e), -1.0f, 1.0f);
    
    // d = min( d, vec2(dot(v,v), wi*he-abs(s)));
    d = min(d, vec2<f32>(dot(v, v), wi * he - abs(s)));

    // return sqrt(d.x)*sign(-d.y);
    return sqrt(d.x) * sign(-d.y);
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

fn renderColumn(uv: vec2f, transform: Transform2D, height: f32) -> SDFResult {
    let q = transform_to_local(uv, transform);
    
    var result = SDFResult(1e10, vec3f(0.0));

    let deckBridgeY = 0.256;
    let crossesAvailableHeight = height - deckBridgeY;
    let numberOfCrosses = u32(crossesAvailableHeight / crossHeight);

    let crossCol = vec3(0.0, 1.0, 1.0);
    for (var i = 0u; i < numberOfCrosses; i++) {
        let cross1D = renderCross(q, Transform2D(vec2f(0.0, -0.21 + 0.333 * f32(i)), 0.0, vec2f(1.0), vec2f()));
        if (cross1D < 0.0) {
            result.dist = cross1D;
            result.color = crossCol;
        }
    } 

    // Render Crosses

    let cross4D = renderCross(q, Transform2D(vec2f(0.0, -0.71), 0.0, vec2f(1.0), vec2f()));
    if (cross4D < 0.0) {
        result.dist = cross4D;
        result.color = crossCol;
    }

    // Render Pillar Base
    let baseCol = vec3f(1.0, 0.0, 0.0);

    let baseTransf = Transform2D(vec2f(0.0, -1.0 + baseH), 0.0, vec2f(1.0), vec2f());
    let baseP = transform_to_local(q, baseTransf);
    let baseD = box(baseP, vec2f(baseW, baseH));
    if (baseD < 0.0) {
        result.dist = baseD;
        result.color = baseCol;
    }
    // Render Pillar Left Column
    let leftColumnCol = vec3f(0.0, 1.0, 0.0);

    const leftColumnY = -1.0 + columnH + baseH * 2.0;
    let leftColumnTransf = Transform2D(vec2f(leftColumnX, height), 0.0, vec2f(1.0), vec2f(0.0, -1.0 + baseH * 2.0));
    let leftColumnP = transform_to_local(q, leftColumnTransf);
    let leftColumnD = box(leftColumnP, vec2f(columnW, height));
    if (leftColumnD < 0.0) {
        result.dist = leftColumnD;
        result.color = leftColumnCol;
    }
    // Render Pillar Right Column
    let rightColumnCol = vec3f(0.0, 0.0, 1.0);

    let rightColumnTransf = Transform2D(vec2f(rightColumnX, height), 0.0, vec2f(1.0), vec2f(0.0, -1.0 + baseH * 2.0));
    let rightColumnP = transform_to_local(q, rightColumnTransf);
    let rightColumnD = box(rightColumnP, vec2f(columnW, height));
    if (rightColumnD < 0.0) {
        result.dist = rightColumnD;
        result.color = rightColumnCol;
    }
    // Render Top
    let topCol = vec3f(1.0, 1.0, 0.0);
    let topTransf = Transform2D(vec2f(0.0, height * 2.0), 0.0, vec2f(1.0), vec2f(0.0, -1.0 + baseH));
    let topP = transform_to_local(q, topTransf);
    let topD = box(topP, vec2f((rightColumnX - leftColumnX) * 0.5, baseH * 0.5));
    if (topD < 0.0) {
        result.dist = topD;
        result.color = topCol;
    }

    return result;
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
    let bodyCol = vec3f(0.95, 0.75, 0.2);     // yellow/gold body
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

fn renderBridge(uv: vec2f, transform: Transform2D) -> vec3f {
    let q = transform_to_local(uv, transform);
    let column1Height = 0.333 + custom.height1;
    let column2Height = 0.333 + custom.height2;

    let columnDist = custom.dist * 2.5;
    let column1X = columnDist * 0.5;
    let column1Transf = Transform2D(vec2f(column1X, 0.0), 0.0, vec2f(1.0), vec2f());
    let columnResult1 = renderColumn(uv, column1Transf, column1Height);
    if (columnResult1.dist <= 0.0) {
        return columnResult1.color;
    }

    let column2X = -column1X;
    let column2Transf = Transform2D(vec2f(column2X, 0.0), 0.0, vec2f(1.0), vec2f());
    let columnResult2 = renderColumn(uv, column2Transf, column2Height);
    if (columnResult2.dist <= 0.0) {
        return columnResult2.color;
    }

    // Render deck
    let deckCol = vec3f(0.9, 0.8, 0.2);
    let deckH = 0.05;
    let deckY = -1.0 + deckH*2.0 + baseH*2.0 + crossHeight*2.0;
    let deckTransf = Transform2D(vec2f(0.0, deckY), 0.0, vec2f(1.0), vec2f());
    let deckD = transformedBox(q, vec2f(2.0, deckH), deckTransf);
    
 
     // === DECK CIRCLES (repeating with oscillating radius) ===
    let circleRadiusBase = deckH * 0.5;
    let circleRadiusVariation = deckH * 0.3; // how much it oscillates
    let circleSpacing = 0.12;
    let circleFrequency = 2.0; // oscillation frequency
    let circleCol = vec3f(0.2, 0.2, 0.2);
    
    // Get the cell index for this position
    let cellIndex = round(q.x / circleSpacing);
    
    // Oscillate radius based on cell index
    let circleRadius = circleRadiusBase;
    // let circleRadius = circleRadiusBase + circleRadiusVariation * sin(cellIndex * circleFrequency);
    // let circleRadius = circleRadiusBase + circleRadiusVariation * sin(cellIndex * circleFrequency + time.elapsed); 
    // Use modulo to create repetition
    let qx_repeated = q.x - circleSpacing * cellIndex;
    let circleCenter = vec2f(0.0, deckY);
    let circleD = circle(vec2f(qx_repeated, q.y), circleCenter, circleRadius);
    
    if (circleD <= 0.0) {
        return circleCol;
    }
    
    // Render deck after circles
    if (deckD <= 0.0) {
        return deckCol;
    }

    // === RENDER TRAIN ===
    let trainY = deckY + deckH + 0.018; // sit on top of deck
    let trainX = 2.5 - 6.0 * custom.train_mov; // position along deck (adjust or animate)
    let train1Transf = Transform2D(vec2f(trainX, trainY + 0.04), 0.0, vec2f(1.0), vec2f());
    let train1Result = renderTrain(q, train1Transf);
    let train2Transf = Transform2D(vec2f(trainX + 0.84, trainY + 0.04), 0.0, vec2f(-1.0, 1.0), vec2f());
    let train2Result = renderTrain(q, train2Transf);
    let train1D = train1Result.dist;
    let train2D = train2Result.dist;
    if (train1D <= 0.0) { return train1Result.color; }
    if (train2D <= 0.0) { return train2Result.color; }


    // Arc parameters
    let arcThickness = 0.012;
    let arcRightY = -0.333 + custom.height1 * 2.0;
    let arcLeftY = -0.333 + custom.height2 * 2.0;
    let columnMargin = (rightColumnX - leftColumnX) * 0.5;
    
    // Center arc - between inner edges of columns
    let arcLeft = vec2f(column2X + baseW - columnW * 2.0, arcLeftY);
    let arcRight = vec2f(column1X - baseW + columnW * 2.0, arcRightY);
    let arcMid = vec2f(0.0, deckY);

    // Side arcs - start from outer edges of columns
    let leftArcStart = vec2f(column2X - columnMargin, arcLeftY);
    let rightArcStart = vec2f(column1X + columnMargin, arcRightY);

    // Cable parameters
    let cableThickness = 0.008;
    let cableSpacing = 0.15;
    let cableCol = vec3f(0.6, 0.6, 0.6);

    // === CENTER ARC CABLES ===
    let spanWidth = arcRight.x - arcLeft.x;
    let numCables = i32(spanWidth / cableSpacing);
    
    for (var i = 1; i < numCables; i++) {
        let t = f32(i) / f32(numCables);
        
        let arcPointX = (1.0 - t) * (1.0 - t) * arcLeft.x 
                      + 2.0 * (1.0 - t) * t * arcMid.x 
                      + t * t * arcRight.x;
        let arcPointY = (1.0 - t) * (1.0 - t) * arcLeft.y 
                      + 2.0 * (1.0 - t) * t * arcMid.y 
                      + t * t * arcRight.y;
        
        let cableTop = arcPointY;
        let cableBottom = deckY + deckH;
        let cableHeight = (cableTop - cableBottom) * 0.5;
        let cableCenterY = (cableTop + cableBottom) * 0.5;
        
        let cableD = box(q - vec2f(arcPointX, cableCenterY), vec2f(cableThickness, cableHeight));
        if (cableD <= 0.0) {
            return cableCol;
        }
    }

    // === LEFT SIDE ARC (from outer edge of left column, going off-screen) ===
    let leftArcEnd = vec2f(-2.0, deckY + deckH);
    let leftArcMid = vec2f((leftArcStart.x + leftArcEnd.x) * 0.5, deckY);
    
    let leftSpanWidth = leftArcStart.x - leftArcEnd.x;
    let numLeftCables = i32(leftSpanWidth / cableSpacing);
    
    for (var i = 1; i < numLeftCables; i++) {
        let t = f32(i) / f32(numLeftCables);
        
        let arcPointX = (1.0 - t) * (1.0 - t) * leftArcStart.x 
                      + 2.0 * (1.0 - t) * t * leftArcMid.x 
                      + t * t * leftArcEnd.x;
        let arcPointY = (1.0 - t) * (1.0 - t) * leftArcStart.y 
                      + 2.0 * (1.0 - t) * t * leftArcMid.y 
                      + t * t * leftArcEnd.y;
        
        let cableTop = arcPointY;
        let cableBottom = deckY + deckH;
        let cableHeight = max((cableTop - cableBottom) * 0.5, 0.001);
        let cableCenterY = (cableTop + cableBottom) * 0.5;
        
        if (cableTop > cableBottom) {
            let cableD = box(q - vec2f(arcPointX, cableCenterY), vec2f(cableThickness, cableHeight));
            if (cableD <= 0.0) {
                return cableCol;
            }
        }
    }

    // === RIGHT SIDE ARC (from outer edge of right column, going off-screen) ===
    let rightArcEnd = vec2f(2.0, deckY + deckH);
    let rightArcMid = vec2f((rightArcStart.x + rightArcEnd.x) * 0.5, deckY);
    
    let rightSpanWidth = rightArcEnd.x - rightArcStart.x;
    let numRightCables = i32(rightSpanWidth / cableSpacing);
    
    for (var i = 1; i < numRightCables; i++) {
        let t = f32(i) / f32(numRightCables);
        
        let arcPointX = (1.0 - t) * (1.0 - t) * rightArcStart.x 
                      + 2.0 * (1.0 - t) * t * rightArcMid.x 
                      + t * t * rightArcEnd.x;
        let arcPointY = (1.0 - t) * (1.0 - t) * rightArcStart.y 
                      + 2.0 * (1.0 - t) * t * rightArcMid.y 
                      + t * t * rightArcEnd.y;
        
        let cableTop = arcPointY;
        let cableBottom = deckY + deckH;
        let cableHeight = max((cableTop - cableBottom) * 0.5, 0.001);
        let cableCenterY = (cableTop + cableBottom) * 0.5;
        
        if (cableTop > cableBottom) {
            let cableD = box(q - vec2f(arcPointX, cableCenterY), vec2f(cableThickness, cableHeight));
            if (cableD <= 0.0) {
                return cableCol;
            }
        }
    }

    // === RENDER CENTER ARC ===
    let bezierResult = bezier(q, arcLeft, arcMid, arcRight);
    let d = abs(bezierResult.dist) - arcThickness;
    if (d <= -0.001) {
        return vec3f(1.0);
    }

    // === RENDER LEFT SIDE ARC ===
    let leftBezierResult = bezier(q, leftArcStart, leftArcMid, leftArcEnd);
    let leftD = abs(leftBezierResult.dist) - arcThickness;
    if (leftD <= -0.001) {
        return vec3f(1.0);
    }

    // === RENDER RIGHT SIDE ARC ===
    let rightBezierResult = bezier(q, rightArcStart, rightArcMid, rightArcEnd);
    let rightD = abs(rightBezierResult.dist) - arcThickness;
    if (rightD <= -0.001) {
        return vec3f(1.0);
    }

    return vec3f();
}

@compute @workgroup_size(16, 16)
fn main_image(@builtin(global_invocation_id) id: vec3u) {
    // Viewport resolution (in pixels)
    let screen_size = textureDimensions(screen);

    // Prevent overdraw for workgroups on the edge of the viewport
    if (id.x >= screen_size.x || id.y >= screen_size.y) { return; }

    // Pixel coordinates (centre of pixel, origin at bottom left)
    let fragCoord = vec2f(f32(id.x) + .5, f32(screen_size.y - id.y) - .5);
    let uv = (fragCoord * 2.0 - vec2<f32>(screen_size)) / f32(screen_size.y);

    // Time varying pixel colour
    // var col = .5 + .5 * cos(time.elapsed + uv.xyx + vec3f(0.,2.,4.));
    var col = bg_col;
    let alpha = 1.0;

    const bridgeScale = 1.0;
    const transformBridge = Transform2D(vec2f(0.0), 0.0, vec2f(bridgeScale), vec2f(0.0));
    col = renderBridge(uv, transformBridge);
    // Convert from gamma-encoded to linear colour space
    col = pow(col, vec3f(2.2));

    // Output to screen (linear colour space)
    textureStore(screen, id.xy, vec4f(col, alpha));
}

