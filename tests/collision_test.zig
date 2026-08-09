//! Collision detection tests.
//! Ensures the renamer never produces duplicate declaration names.

const std = @import("std");
const wgslender = @import("wgslender");

// =========================================================================
// Helper
// =========================================================================

/// Scans minified output for declaration keywords (struct, const, fn, var, let, alias)
/// and checks that no top-level declaration name appears more than once.
///
/// `var<...>` is listed separately from `var `: a module-scope binding prints
/// its address space as a template list (`var<uniform> u:S;`), so a scan for
/// `"var "` alone walks straight past every `@group`/`@binding` declaration —
/// exactly the ones a renamer is most likely to collide with, since they are
/// preserved rather than renamed by default.
fn checkNoDuplicateNames(code: []const u8) !void {
    const keywords = [_][]const u8{
        "struct ",
        "const ",
        "fn ",
        "var ",
        "var<",
        "let ",
        "alias ",
    };

    // Collect all declaration names. Use a hash map to count occurrences.
    var counts = std.StringHashMap(u32).init(std.testing.allocator);
    defer counts.deinit();

    var pos: usize = 0;
    while (pos < code.len) {
        var matched = false;
        for (keywords) |kw| {
            if (pos + kw.len <= code.len and std.mem.eql(u8, code[pos .. pos + kw.len], kw)) {
                // Extract identifier after the keyword. For `var<`, the name
                // sits past the address-space template list — reading straight
                // after the keyword would collect `uniform`/`storage` instead.
                var start = pos + kw.len;
                if (std.mem.eql(u8, kw, "var<")) {
                    start = (std.mem.indexOfScalarPos(u8, code, start, '>') orelse {
                        pos += kw.len;
                        matched = true;
                        break;
                    }) + 1;
                    while (start < code.len and std.ascii.isWhitespace(code[start])) start += 1;
                }
                var end = start;
                while (end < code.len and (std.ascii.isAlphanumeric(code[end]) or code[end] == '_')) {
                    end += 1;
                }
                if (end > start) {
                    const name = code[start..end];
                    const entry = try counts.getOrPut(name);
                    if (entry.found_existing) {
                        entry.value_ptr.* += 1;
                    } else {
                        entry.value_ptr.* = 1;
                    }
                }
                pos = end;
                matched = true;
                break;
            }
        }
        if (!matched) {
            pos += 1;
        }
    }

    // Check for duplicates
    var found_duplicate = false;
    var it = counts.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* > 1) {
            std.debug.print("duplicate declaration name \"{s}\" appears {d} times in output:\n{s}\n", .{ entry.key_ptr.*, entry.value_ptr.*, code });
            found_duplicate = true;
        }
    }
    if (found_duplicate) {
        return error.DuplicateDeclarationName;
    }
}

/// Minifies `source` under `options` and asserts the output still validates.
///
/// This is the load-bearing check for renamer collisions. It rejects on *any*
/// error rather than on `E0101 redeclaration` specifically: a reissued name
/// also silently re-points every later reference at the wrong symbol, so the
/// first diagnostic is often a downstream one instead — removing the guard in
/// `Pipeline.runBuildRenamer` makes these two tests report `E0206` (member
/// lookup against the shadowing struct) and `E0103` (a function that now
/// appears to call itself). Minified output should validate cleanly, full
/// stop; pinning one code would let the other shapes through.
///
/// Unlike `checkNoDuplicateNames` this goes through the real parser and scope
/// resolution, so it stays correct under `scope_local_rename`, where the same
/// local name legitimately recurs in sibling function bodies.
fn expectMinifiesWithoutRedeclaration(
    arena: std.mem.Allocator,
    source: [:0]const u8,
    options: wgslender.Minifier.Options,
) !void {
    const result = try wgslender.minifyWithOptions(arena, source, options);
    try std.testing.expect(result.errors.len == 0);

    const minified = try arena.dupeZ(u8, result.code);
    const validation = try wgslender.validateWithOptions(arena, minified, .{});

    for (validation.diagnostics.diagnostics.items) |d| {
        if (d.severity != .@"error") continue;
        std.debug.print(
            "minified output failed to validate: {s} [{s}]\noutput:\n{s}\n",
            .{ d.message, d.code, minified },
        );
        return error.MinifiedOutputInvalid;
    }
}

/// The renaming-pressure axes. Identifier renaming is on throughout — with it
/// off there is no generator to collide with anything.
const rename_configs = [_]struct {
    name: []const u8,
    options: wgslender.Minifier.Options,
}{
    .{ .name = "defaults", .options = .{} },
    .{ .name = "mangle-external-bindings", .options = .{ .mangle_external_bindings = true } },
    .{ .name = "scope-local-rename", .options = .{ .scope_local_rename = true } },
    .{ .name = "sort+scope-local", .options = .{ .sort_declarations = true, .scope_local_rename = true } },
    .{ .name = "all", .options = .{
        .mangle_external_bindings = true,
        .sort_declarations = true,
        .scope_local_rename = true,
    } },
};

// =========================================================================
// Tests
// =========================================================================

test "collision: no duplicate names basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\struct S1 { x: f32 }
        \\struct S2 { y: f32 }
        \\const c1: f32 = 1.0;
        \\const c2: f32 = 2.0;
        \\const c3: f32 = 3.0;
        \\const c4: f32 = 4.0;
        \\const c5: f32 = 5.0;
        \\const c6: f32 = 6.0;
        \\const c7: f32 = 7.0;
        \\fn f1(a: S1) -> f32 { return a.x + c1; }
        \\fn f2(b: S2) -> f32 { return b.y + c2; }
        \\fn f3() -> f32 { return c3 + c4; }
        \\fn f4() -> f32 { return c5 + c6 + c7; }
        \\@vertex fn main() -> @builtin(position) vec4f {
        \\  let v = f1(S1(1.0)) + f2(S2(2.0)) + f3() + f4();
        \\  return vec4f(v, 0.0, 0.0, 1.0);
        \\}
    ;

    const result = try wgslender.minifyWithOptions(arena.allocator(), source, wgslender.Minifier.defaultOptions());
    try std.testing.expect(result.errors.len == 0);
    try checkNoDuplicateNames(result.code);
}

test "collision: no duplicate names many symbols" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\struct Transform2D { pos: vec2f, angle: f32, scale: vec2f, anchor: vec2f }
        \\const NO_TRANSFORM = Transform2D(vec2f(0.0), 0.0, vec2f(1.0), vec2f(0.0));
        \\fn transform_to_local(p: vec2f, d: Transform2D) -> vec2f {
        \\  var b = p - d.pos;
        \\  let k = cos(d.angle);
        \\  let j = sin(d.angle);
        \\  b = vec2f(k * b.x + j * b.y, -j * b.x + k * b.y);
        \\  b -= d.anchor;
        \\  b /= d.scale;
        \\  return b;
        \\}
        \\fn scale_sdf_distance(i: f32, a: Transform2D) -> f32 {
        \\  if (abs(a.scale.x - a.scale.y) < 0.001) { return i * a.scale.x; }
        \\  let r = max(a.scale.x, a.scale.y) / min(a.scale.x, a.scale.y);
        \\  if (r < 2.0) { return i * (2.0 / (1.0 / a.scale.x + 1.0 / a.scale.y)); }
        \\  return i * min(a.scale.x, a.scale.y);
        \\}
        \\fn lerp_transform(h: Transform2D, f: Transform2D, e: f32) -> Transform2D {
        \\  var c: Transform2D;
        \\  c.pos = mix(h.pos, f.pos, e);
        \\  c.scale = mix(h.scale, f.scale, e);
        \\  c.anchor = mix(h.anchor, f.anchor, e);
        \\  c.angle = mix(h.angle, f.angle, e);
        \\  return c;
        \\}
        \\fn pixelate_uv(s: vec2f, l: f32) -> vec2f {
        \\  return (floor(s * l) + 0.5) / l;
        \\}
        \\fn dot_pattern(m: vec2f, q: f32, o: f32) -> f32 {
        \\  let n = fract(m * q) - 0.5;
        \\  return length(n) - o;
        \\}
        \\const color_a = vec3f(0.773, 0.561, 0.702);
        \\const color_b = vec3f(0.502, 0.749, 0.239);
        \\const color_c = vec3f(0.494, 0.325, 0.545);
        \\const color_d = vec3f(0.439, 0.573, 0.235);
        \\const color_e = vec3f(0.604, 0.137, 0.443);
        \\const color_f = vec3f(0.012, 0.522, 0.298);
        \\const color_g = vec3f(0.133, 0.655, 0.420);
        \\const state_a = vec2f(1.0);
        \\const state_b = vec2f();
        \\const offsets_a: array<vec3f, 7> = array(vec3f(-0.25, 0.0, -3.141592653589793 * 0.25),vec3f(0.0, 0.8, -0.18),vec3f(-0.8, 0.3, -0.18),vec3f(0.6, -0.6, 0.33),vec3f(0.5, 0.2, 0.1),vec3f(-0.83, -0.2, -0.22),vec3f(-0.6, -0.5, 0.15));
        \\const offsets_b: array<vec3f, 7> = array(vec3f(0.83, -0.30, -0.65),vec3f(0.06, -0.20, -0.36),vec3f(-0.23, 0.38, -0.71),vec3f(-0.83, -0.18, -0.26),vec3f(-0.59, -0.47, 0.05),vec3f(-0.14, -0.94, 0.95),vec3f(0.24, -0.89, -0.58));
        \\const offsets_c: array<vec3f, 7> = array(vec3f(0.59, -0.07, 0.35),vec3f(0.25, 0.08, 0.54),vec3f(-0.96, 0.59, -0.94),vec3f(0.27, -0.83, -0.30),vec3f(0.99, 0.68, -0.82),vec3f(0.06, 0.17, 0.74),vec3f(0.87, 0.73, 0.91));
        \\const offsets_d: array<vec3f, 7> = array(vec3f(0.73, -0.18, -0.88),vec3f(-0.64, 0.24, 0.69),vec3f(0.49, 0.68, -0.27),vec3f(0.02, 0.76, 0.78),vec3f(-0.002, 0.47, 0.58),vec3f(0.46, 0.93, 0.43),vec3f(-0.58, -0.32, -0.41));
        \\const offsets_e: array<vec3f, 7> = array(vec3f(0.46, -0.91, -0.56),vec3f(0.35, 0.35, 0.63),vec3f(-0.17, -0.93, 0.52),vec3f(-0.95, 0.29, 0.91),vec3f(-0.48, -0.94, -0.45),vec3f(-0.64, -0.01, 0.49),vec3f(-0.24, 0.74, -0.54));
        \\const offsets_f: array<vec3f, 7> = array(vec3f(-0.55, 0.12, -0.34),vec3f(0.62, 0.17, -0.35),vec3f(0.31, -0.95, 0.66),vec3f(0.61, -0.78, 0.46),vec3f(-0.24, 0.54, 0.36),vec3f(0.05, 0.93, 0.12),vec3f(-0.98, 0.96, 0.95));
        \\const offsets_g: array<vec3f, 7> = array(vec3f(0.98, -0.55, 0.68),vec3f(-0.03, -0.63, 0.52),vec3f(-0.83, 0.05, -0.67),vec3f(-0.19, 0.19, -0.32),vec3f(0.81, -0.80, 0.66),vec3f(0.58, -0.76, -0.30),vec3f(-0.38, -0.50, -0.45));
        \\struct PngineInputs {
        \\  time: f32,
        \\  canvasW: f32,
        \\  canvasH: f32,
        \\  canvasRatio: f32,
        \\}
        \\@group(0) @binding(0) var<uniform> pngine: PngineInputs;
        \\struct VertexOutput {
        \\  @builtin(position) position: vec4f,
        \\  @location(0) uv: vec2f,
        \\  @location(1) correctedUv: vec2f,
        \\  @location(2) shape_t: f32,
        \\  @location(3) beat_t: f32,
        \\  @location(4) anim_t: f32,
        \\}
        \\const BEAT_SECS: f32 = 170.0 * f32(0.016666666666666666);
        \\fn background(uv: vec2f, t: f32, beat: f32) -> vec3f {
        \\  let radius = length(uv);
        \\  let radial = 1.0 - smoothstep(0.0, 2.5, radius);
        \\  let wave1 = sin(uv.x * 8.0 + t * 3.0) * sin(uv.y * 8.0 - t * 2.0);
        \\  let wave2 = sin(uv.x * 12.0 - t * 1.5) * cos(uv.y * 6.0 + t * 2.5);
        \\  let wave = (wave1 + wave2 * 0.5) * 0.5 + 0.5;
        \\  let c1 = vec3f(1.0, 0.85, 0.7);
        \\  let c2 = vec3f(0.5, 0.35, 0.5);
        \\  let c3 = vec3f(0.9, 0.5, 0.3);
        \\  var bg = mix(c2, c1, radial * 0.8 + wave * 0.2);
        \\  bg = mix(bg, c3, wave * radial * 0.3);
        \\  return bg;
        \\}
        \\fn compute_transform(idx: u32) -> Transform2D {
        \\  let off = offsets_a[idx];
        \\  return Transform2D(4.0 * off.xy, 2.0 * 3.14159 * off.z, state_a, state_b);
        \\}
        \\fn use_colors() -> vec3f {
        \\  return color_a + color_b + color_c + color_d + color_e + color_f + color_g;
        \\}
        \\fn use_offsets() -> vec3f {
        \\  return offsets_b[0] + offsets_c[0] + offsets_d[0] + offsets_e[0] + offsets_f[0] + offsets_g[0];
        \\}
        \\@vertex fn vs_main(@builtin(vertex_index) vi: u32) -> VertexOutput {
        \\  var pos = array(vec2f(-1.0, -1.0), vec2f(-1.0, 3.0), vec2f(3.0, -1.0));
        \\  var output: VertexOutput;
        \\  let xy = pos[vi];
        \\  output.position = vec4f(xy, 0.0, 1.0);
        \\  output.uv = xy * vec2f(0.5, -0.5) + vec2f(0.5);
        \\  var corrected = output.uv * 2.0 - 1.0;
        \\  let minDim = min(pngine.canvasW, pngine.canvasH);
        \\  let sc = vec2f(pngine.canvasW / minDim, pngine.canvasH / minDim);
        \\  corrected *= sc;
        \\  output.correctedUv = corrected;
        \\  let beat = pngine.time * BEAT_SECS;
        \\  output.shape_t = 0.0;
        \\  output.beat_t = 0.0;
        \\  output.anim_t = 0.0;
        \\  return output;
        \\}
        \\@fragment fn fs_main(fsInput: VertexOutput) -> @location(0) vec4f {
        \\  let t = pngine.time;
        \\  let beat = t * BEAT_SECS;
        \\  let bg = background(fsInput.correctedUv, t, beat);
        \\  let pix = pixelate_uv(fsInput.correctedUv, 400.0);
        \\  let dp = dot_pattern(pix, 10.0, 0.3);
        \\  let tr = compute_transform(0u);
        \\  let local = transform_to_local(pix, tr);
        \\  let sd = scale_sdf_distance(length(local), tr);
        \\  let lt = lerp_transform(tr, NO_TRANSFORM, 0.5);
        \\  let cols = use_colors();
        \\  let offs = use_offsets();
        \\  return vec4f(bg + cols * 0.001 + offs * 0.001 + vec3f(sd * 0.001 + dp * 0.001 + lt.angle * 0.001), 1.0);
        \\}
    ;

    const result = try wgslender.minifyWithOptions(arena.allocator(), source, wgslender.Minifier.defaultOptions());
    try std.testing.expect(result.errors.len == 0);
    try checkNoDuplicateNames(result.code);
}

// --- Regression: a preserved binding name must not be reissued ---
//
// Reported against a sibling minifier (miniray #1): `var<uniform> u` is
// preserved by default (external bindings keep their name so the host API
// keeps working), but the name generator was not told `u` was taken, so it
// counted up to `u` and handed it to a function — yielding a module with two
// `u` declarations. The guard here is `reserveUnrenamedSymbolNames`, run
// between slot allocation and name assignment in `Pipeline.runBuildRenamer`:
// every symbol that will *not* be renamed contributes its original name to the
// reserved set, and `assignNames` skips reserved names.
//
// The shader is kept at the reporter's size on purpose — the collision only
// appears once the generator has issued enough names to reach `u`.
test "collision: preserved external binding name is not reissued to a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\struct Uniforms {
        \\  hue: f32,
        \\  use_p3: f32,
        \\}
        \\@group(0) @binding(0) var<uniform> u: Uniforms;
        \\struct VertexOutput {
        \\  @builtin(position) position: vec4f,
        \\  @location(0) uv: vec2f,
        \\}
        \\@vertex
        \\fn vs_main(@builtin(vertex_index) vi: u32) -> VertexOutput {
        \\  var out: VertexOutput;
        \\  let x = f32(i32(vi & 1u)) * 4.0 - 1.0;
        \\  let y = f32(i32(vi >> 1u)) * 4.0 - 1.0;
        \\  out.position = vec4f(x, y, 0.0, 1.0);
        \\  out.uv = vec2f((x + 1.0) * 0.5, (1.0 - y) * 0.5);
        \\  return out;
        \\}
        \\fn oklch_to_oklab(l: f32, c: f32, h_deg: f32) -> vec3f {
        \\  let h = h_deg * 3.14159265 / 180.0;
        \\  return vec3f(l, c * cos(h), c * sin(h));
        \\}
        \\fn oklab_to_lms(L: f32, a: f32, b: f32) -> vec3f {
        \\  let l_ = L + 0.3963377774 * a + 0.2158037573 * b;
        \\  let m_ = L - 0.1055613458 * a - 0.0638541728 * b;
        \\  let s_ = L - 0.0894841775 * a - 1.291485548 * b;
        \\  return vec3f(l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_);
        \\}
        \\fn lms_to_linear_srgb(lms: vec3f) -> vec3f {
        \\  return vec3f(
        \\    4.0767416621 * lms.x - 3.3077115913 * lms.y + 0.2309699292 * lms.z,
        \\    -1.2684380046 * lms.x + 2.6097574011 * lms.y - 0.3413193965 * lms.z,
        \\    -0.0041960863 * lms.x - 0.7034186147 * lms.y + 1.707614701 * lms.z,
        \\  );
        \\}
        \\fn lms_to_linear_p3(lms: vec3f) -> vec3f {
        \\  return vec3f(
        \\    3.1277455454 * lms.x - 2.2571357909 * lms.y + 0.1293902455 * lms.z,
        \\    -1.0910086139 * lms.x + 2.0133420547 * lms.y + 0.0776665591 * lms.z,
        \\    -0.0260256887 * lms.x - 0.3541460076 * lms.y + 1.3801716964 * lms.z,
        \\  );
        \\}
        \\fn linear_to_gamma(c: f32) -> f32 {
        \\  return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, 12.92 * c, c <= 0.0031308);
        \\}
        \\@fragment
        \\fn fs_main(in: VertexOutput) -> @location(0) vec4f {
        \\  let l = 1.0 - in.uv.y;
        \\  let c = in.uv.x * 0.37;
        \\  let lab = oklch_to_oklab(l, c, u.hue);
        \\  let lms = oklab_to_lms(lab.x, lab.y, lab.z);
        \\  var rgb_lin: vec3f;
        \\  if (u.use_p3 > 0.5) {
        \\    rgb_lin = lms_to_linear_p3(lms);
        \\  } else {
        \\    rgb_lin = lms_to_linear_srgb(lms);
        \\  }
        \\  rgb_lin = clamp(rgb_lin, vec3f(0.0), vec3f(1.0));
        \\  let rgb = vec3f(
        \\    linear_to_gamma(rgb_lin.x),
        \\    linear_to_gamma(rgb_lin.y),
        \\    linear_to_gamma(rgb_lin.z),
        \\  );
        \\  return vec4f(rgb, 1.0);
        \\}
    ;

    for (rename_configs) |cfg| {
        expectMinifiesWithoutRedeclaration(arena.allocator(), source, cfg.options) catch |err| {
            std.debug.print("config \"{s}\" produced a colliding module\n", .{cfg.name});
            return err;
        };
    }
}

// --- Regression: bindings squatting the head of the generated-name sequence ---
//
// Sharpens the case above. `a`, `b`, `c` are the first names the generator
// emits, and as external bindings they are preserved rather than renamed — so
// every one of them is a collision waiting to happen on the very first slot.
// A renamer missing the reservation step fails here immediately, without
// needing a shader large enough to count up to a longer name.
test "collision: bindings occupying the first generated names are skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\struct U { hue: f32, k: f32 }
        \\@group(0) @binding(0) var<uniform> a: U;
        \\@group(0) @binding(1) var<uniform> b: U;
        \\@group(0) @binding(2) var<uniform> c: U;
        \\fn f1(x: f32) -> f32 { return x * a.hue; }
        \\fn f2(x: f32) -> f32 { return f1(x) + b.k; }
        \\fn f3(x: f32) -> f32 { return f2(x) * c.hue; }
        \\fn f4(x: f32) -> f32 { return f3(x) - f1(x); }
        \\fn f5(x: f32) -> f32 { return f4(x) / f2(x); }
        \\@fragment fn fs() -> @location(0) vec4f {
        \\  return vec4f(f5(1.0), f4(2.0), f3(3.0), 1.0);
        \\}
    ;

    for (rename_configs) |cfg| {
        expectMinifiesWithoutRedeclaration(arena.allocator(), source, cfg.options) catch |err| {
            std.debug.print("config \"{s}\" produced a colliding module\n", .{cfg.name});
            return err;
        };
    }

    // With the bindings preserved (the default), the generator must route
    // around `a`/`b`/`c` rather than shadowing them.
    const result = try wgslender.minifyWithOptions(arena.allocator(), source, .{});
    try std.testing.expect(result.errors.len == 0);
    try checkNoDuplicateNames(result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "var<uniform> a:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "fn a(") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "fn b(") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "fn c(") == null);
}
