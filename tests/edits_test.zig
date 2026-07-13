//! Library-level tests for the `Edits` module.
//!
//! These tests exercise the bidirectional flow without going through the
//! LSP handler: analyze a shader, locate a symbol, produce TextEdits,
//! apply them to the source, and verify the rewritten source re-analyzes
//! cleanly with the expected new name.

const std = @import("std");
const wgslender = @import("wgslender");

fn findOffsetOf(source: []const u8, needle: []const u8) u32 {
    return @intCast(std.mem.indexOf(u8, source, needle) orelse unreachable);
}

test "edits: rename a const across a shader preserves comments" {
    const a = std.testing.allocator;
    const source: [:0]const u8 =
        \\// This is a load-bearing comment.
        \\const PI: f32 = 3.14;
        \\fn circumference(r: f32) -> f32 {
        \\    return 2.0 * PI * r;
        \\}
    ;

    // Analyze to get symbols.
    var analysis = try wgslender.analyze(a, source);
    defer analysis.deinit();
    const module = analysis.module orelse return error.TestUnexpectedResult;

    // Locate PI by searching for its declared name.
    const pi_offset = findOffsetOf(source, "PI");
    const target = wgslender.Edits.symbolAtOffset(module, pi_offset);
    try std.testing.expect(target.isValid());

    const edits = try wgslender.Edits.renameEdits(a, module, target, "TAU") orelse
        return error.TestUnexpectedResult;
    defer a.free(edits);

    // Declaration + one usage = 2 edits.
    try std.testing.expectEqual(@as(usize, 2), edits.len);

    const rewritten = try wgslender.Edits.applyEdits(a, source, edits);
    defer a.free(rewritten);

    const expected =
        \\// This is a load-bearing comment.
        \\const TAU: f32 = 3.14;
        \\fn circumference(r: f32) -> f32 {
        \\    return 2.0 * TAU * r;
        \\}
    ;
    try std.testing.expectEqualStrings(expected, rewritten);
}

test "edits: rename a struct updates type references" {
    const a = std.testing.allocator;
    const source: [:0]const u8 =
        \\struct Uniforms { t: f32 }
        \\@group(0) @binding(0) var<uniform> u: Uniforms;
        \\@compute @workgroup_size(1) fn main() { let x = u.t; }
    ;

    var analysis = try wgslender.analyze(a, source);
    defer analysis.deinit();
    const module = analysis.module orelse return error.TestUnexpectedResult;

    const decl_offset = findOffsetOf(source, "Uniforms");
    const target = wgslender.Edits.symbolAtOffset(module, decl_offset);
    try std.testing.expect(target.isValid());

    const edits = try wgslender.Edits.renameEdits(a, module, target, "Globals") orelse
        return error.TestUnexpectedResult;
    defer a.free(edits);

    // Declaration + one type reference = 2 edits.
    try std.testing.expectEqual(@as(usize, 2), edits.len);

    const rewritten = try wgslender.Edits.applyEdits(a, source, edits);
    defer a.free(rewritten);

    // The new source must re-analyze without errors.
    const rewritten_z = try a.dupeZ(u8, rewritten);
    defer a.free(rewritten_z);
    var re = try wgslender.analyze(a, rewritten_z);
    defer re.deinit();
    try std.testing.expect(re.valid);

    // And the new name must appear where the old one was.
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Globals") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Uniforms") == null);
}

test "edits: renameEdits rejects invalid identifiers" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "const x: f32 = 1.0;";
    var analysis = try wgslender.analyze(a, source);
    defer analysis.deinit();
    const module = analysis.module orelse return error.TestUnexpectedResult;

    const target = wgslender.Edits.symbolAtOffset(module, findOffsetOf(source, "x"));
    try std.testing.expect(target.isValid());

    // Keyword → rejected.
    try std.testing.expect((try wgslender.Edits.renameEdits(a, module, target, "fn")) == null);
    // Leading digit → rejected.
    try std.testing.expect((try wgslender.Edits.renameEdits(a, module, target, "1x")) == null);
    // Double underscore prefix → rejected.
    try std.testing.expect((try wgslender.Edits.renameEdits(a, module, target, "__bad")) == null);
}

test "edits: findReferences includes assignment writes" {
    const a = std.testing.allocator;
    const source: [:0]const u8 =
        \\var<private> counter: i32 = 0;
        \\fn bump() { counter = counter + 1; }
    ;
    var analysis = try wgslender.analyze(a, source);
    defer analysis.deinit();
    const module = analysis.module orelse return error.TestUnexpectedResult;

    const target = wgslender.Edits.symbolAtOffset(module, findOffsetOf(source, "counter"));
    try std.testing.expect(target.isValid());

    const refs = try wgslender.Edits.findReferences(a, module, target, true);
    defer a.free(refs);

    // Declaration (write) + LHS of assignment (write) + RHS read = 3 refs.
    try std.testing.expectEqual(@as(usize, 3), refs.len);

    var writes: usize = 0;
    for (refs) |r| if (r.is_write) {
        writes += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), writes);
}

test "edits: symbolAtOffset returns none outside any identifier" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "const x: f32 = 1.0;";
    var analysis = try wgslender.analyze(a, source);
    defer analysis.deinit();
    const module = analysis.module orelse return error.TestUnexpectedResult;

    // Offset at the space between `const` and `x`.
    const s = wgslender.Edits.symbolAtOffset(module, 5);
    try std.testing.expect(!s.isValid());
}

test "edits: setWorkgroupSize changes attribute args" {
    const a = std.testing.allocator;
    const source: [:0]const u8 =
        \\@compute @workgroup_size(1) fn main() {}
    ;
    var analysis = try wgslender.analyze(a, source);
    defer analysis.deinit();
    const module = analysis.module orelse return error.TestUnexpectedResult;

    const edits = try wgslender.Edits.setWorkgroupSize(a, source, module, "main", .{ 8, 8, 1 }) orelse
        return error.TestUnexpectedResult;
    defer wgslender.Edits.freeBuiltEdits(a, edits);
    try std.testing.expectEqual(@as(usize, 1), edits.len);

    const rewritten = try wgslender.Edits.applyEdits(a, source, edits);
    defer a.free(rewritten);
    try std.testing.expectEqualStrings("@compute @workgroup_size(8, 8) fn main() {}", rewritten);

    // New source re-analyzes clean.
    const rewritten_z = try a.dupeZ(u8, rewritten);
    defer a.free(rewritten_z);
    var re = try wgslender.analyze(a, rewritten_z);
    defer re.deinit();
    try std.testing.expect(re.valid);
}

test "edits: setWorkgroupSize missing entry point returns null" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "@compute @workgroup_size(1) fn main() {}";
    var analysis = try wgslender.analyze(a, source);
    defer analysis.deinit();
    const module = analysis.module orelse return error.TestUnexpectedResult;

    const edits = try wgslender.Edits.setWorkgroupSize(a, source, module, "nonexistent", .{ 4, 1, 1 });
    try std.testing.expect(edits == null);
}

test "edits: setWorkgroupSize missing attribute returns null" {
    const a = std.testing.allocator;
    // `main` has no @workgroup_size.
    const source: [:0]const u8 = "@fragment fn main() -> @location(0) vec4f { return vec4f(0.0); }";
    var analysis = try wgslender.analyze(a, source);
    defer analysis.deinit();
    const module = analysis.module orelse return error.TestUnexpectedResult;

    const edits = try wgslender.Edits.setWorkgroupSize(a, source, module, "main", .{ 4, 1, 1 });
    try std.testing.expect(edits == null);
}

test "edits: insertAt appended declaration re-analyzes clean" {
    const a = std.testing.allocator;
    const source: [:0]const u8 =
        \\@group(0) @binding(0) var<uniform> u: f32;
        \\@compute @workgroup_size(1) fn main() {}
    ;
    const append_text = "\n@group(0) @binding(1) var<storage, read> data: array<f32>;";
    const edit = wgslender.Edits.insertAt(@intCast(source.len), append_text);
    const rewritten = try wgslender.Edits.applyEdits(a, source, &.{edit});
    defer a.free(rewritten);

    const rewritten_z = try a.dupeZ(u8, rewritten);
    defer a.free(rewritten_z);
    var re = try wgslender.reflect(a, rewritten_z);
    defer re.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), re.bindings.items.len);
}

// =========================================================================
// Bidirectional-tool scenario tests
//
// Each test performs the full loop that a code-aware editor would run:
// analyze → symbolAtOffset → renameEdits → applyEdits → re-analyze to
// confirm the result is valid WGSL and that the renamed symbol survived.
// =========================================================================

fn renameAndReanalyze(
    a: std.mem.Allocator,
    source: [:0]const u8,
    needle: []const u8,
    new_name: []const u8,
) ![]u8 {
    var analysis = try wgslender.analyze(a, source);
    defer analysis.deinit();
    const module = analysis.module orelse return error.TestUnexpectedResult;

    const off = findOffsetOf(source, needle);
    const target = wgslender.Edits.symbolAtOffset(module, off);
    if (!target.isValid()) return error.TestSymbolNotFound;

    const edits = try wgslender.Edits.renameEdits(a, module, target, new_name) orelse
        return error.TestRenameRejected;
    defer a.free(edits);

    const rewritten = try wgslender.Edits.applyEdits(a, source, edits);
    errdefer a.free(rewritten);

    const rewritten_z = try a.dupeZ(u8, rewritten);
    defer a.free(rewritten_z);
    var re = try wgslender.analyze(a, rewritten_z);
    defer re.deinit();
    if (!re.valid) return error.TestResultInvalid;

    return rewritten;
}

test "scenario: rename function updates all call sites" {
    const a = std.testing.allocator;
    const source: [:0]const u8 =
        \\fn helper(x: f32) -> f32 { return x * 2.0; }
        \\fn other(y: f32) -> f32 { return helper(y) + helper(1.0); }
        \\@compute @workgroup_size(1) fn main() { let z = helper(3.0); }
    ;
    const rewritten = try renameAndReanalyze(a, source, "helper", "scale");
    defer a.free(rewritten);
    // 1 declaration + 3 call-site references.
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, rewritten, "scale"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, rewritten, "helper"));
}

test "scenario: rename parameter touches only that function body" {
    const a = std.testing.allocator;
    const source: [:0]const u8 =
        \\fn first(x: f32) -> f32 { return x + 1.0; }
        \\fn second(x: f32) -> f32 { return x * 2.0; }
        \\@compute @workgroup_size(1) fn main() { let r = first(1.0) + second(2.0); }
    ;
    // Rename the parameter `x` in `first` only. The `x` in `second` must be untouched.
    const first_x_off = findOffsetOf(source, "x: f32) -> f32 { return x + 1.0");
    var analysis = try wgslender.analyze(a, source);
    defer analysis.deinit();
    const module = analysis.module orelse return error.TestUnexpectedResult;

    const target = wgslender.Edits.symbolAtOffset(module, first_x_off);
    try std.testing.expect(target.isValid());

    const edits = (try wgslender.Edits.renameEdits(a, module, target, "value")) orelse
        return error.TestUnexpectedResult;
    defer a.free(edits);
    // Parameter decl + 1 use inside first().
    try std.testing.expectEqual(@as(usize, 2), edits.len);

    const rewritten = try wgslender.Edits.applyEdits(a, source, edits);
    defer a.free(rewritten);

    // `value` appears exactly twice (param + body).
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, rewritten, "value"));
    // second()'s parameter `x` is unchanged — still appears at param position and body.
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "fn second(x: f32)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "return x * 2.0") != null);
}

test "scenario: rename local let updates in-scope uses" {
    const a = std.testing.allocator;
    const source: [:0]const u8 =
        \\fn compute_total(n: i32) -> i32 {
        \\    let count = n + 1;
        \\    let sum = count * 2;
        \\    return count + sum;
        \\}
    ;
    const rewritten = try renameAndReanalyze(a, source, "count = n + 1", "items");
    defer a.free(rewritten);
    // decl + 2 reads = 3 occurrences of the new name
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, rewritten, "items"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, rewritten, "count"));
}

test "scenario: rename variable used in index, member-base, and assignment" {
    const a = std.testing.allocator;
    const source: [:0]const u8 =
        \\struct Thing { x: f32, y: f32 }
        \\@group(0) @binding(0) var<storage, read_write> things: array<Thing, 4>;
        \\@compute @workgroup_size(1) fn main() {
        \\    let first = things[0];
        \\    let a = things[1].x;
        \\    things[2].y = 0.5;
        \\}
    ;
    const rewritten = try renameAndReanalyze(a, source, "things: array", "objects");
    defer a.free(rewritten);
    // 1 decl + 3 uses (index, member-base + index, LHS member-base + index)
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, rewritten, "objects"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, rewritten, "things"));
}

test "scenario: rename struct updates type uses, leaves fields alone" {
    const a = std.testing.allocator;
    const source: [:0]const u8 =
        \\struct Uniforms { time: f32, scale: f32 }
        \\@group(0) @binding(0) var<uniform> data: Uniforms;
        \\fn get_time(u: Uniforms) -> f32 { return u.time; }
        \\@compute @workgroup_size(1) fn main() { let t = get_time(data); }
    ;
    const rewritten = try renameAndReanalyze(a, source, "Uniforms {", "Globals");
    defer a.free(rewritten);

    // struct decl + type in var + param type = 3 occurrences of the new name.
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, rewritten, "Globals"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, rewritten, "Uniforms"));
    // Fields (`time`, `scale`, `.time`) survive unchanged.
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "time: f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "u.time") != null);
}

test "scenario: rename type alias updates usages" {
    const a = std.testing.allocator;
    const source: [:0]const u8 =
        \\alias Pixel = vec4f;
        \\fn shade() -> Pixel { return Pixel(1.0, 0.0, 0.0, 1.0); }
    ;
    const rewritten = try renameAndReanalyze(a, source, "Pixel =", "Color");
    defer a.free(rewritten);
    // alias decl + return type + constructor = 3 occurrences.
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, rewritten, "Color"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, rewritten, "Pixel"));
}

test "scenario: rename across shadowed scopes updates only the target" {
    const a = std.testing.allocator;
    const source: [:0]const u8 =
        \\const value: i32 = 42;
        \\fn compute() -> i32 {
        \\    let value: i32 = 7;
        \\    return value + 1;
        \\}
        \\fn top() -> i32 { return value; }
    ;
    // Rename the INNER `value` (inside compute's body).
    const inner_off = findOffsetOf(source, "value: i32 = 7");
    var analysis = try wgslender.analyze(a, source);
    defer analysis.deinit();
    const module = analysis.module orelse return error.TestUnexpectedResult;

    const target = wgslender.Edits.symbolAtOffset(module, inner_off);
    try std.testing.expect(target.isValid());

    const edits = (try wgslender.Edits.renameEdits(a, module, target, "local")) orelse
        return error.TestUnexpectedResult;
    defer a.free(edits);
    // Inner decl + one use inside compute().
    try std.testing.expectEqual(@as(usize, 2), edits.len);

    const rewritten = try wgslender.Edits.applyEdits(a, source, edits);
    defer a.free(rewritten);

    // Inner renamed to `local`.
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "let local: i32 = 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "return local + 1") != null);
    // Outer `const value` and its use in top() untouched.
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const value: i32 = 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "return value;") != null);
}

test "scenario: rename entry-point preserves @compute attribute" {
    const a = std.testing.allocator;
    const source: [:0]const u8 =
        \\@compute @workgroup_size(64) fn simulate(@builtin(global_invocation_id) id: vec3u) {
        \\    let i = id.x;
        \\}
    ;
    const rewritten = try renameAndReanalyze(a, source, "simulate", "step");
    defer a.free(rewritten);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "@compute @workgroup_size(64) fn step(") != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, rewritten, "simulate"));
}

test "scenario: findReferences without declaration excludes decl site" {
    const a = std.testing.allocator;
    const source: [:0]const u8 =
        \\const PI: f32 = 3.14;
        \\fn area(r: f32) -> f32 { return PI * r * r; }
    ;
    var analysis = try wgslender.analyze(a, source);
    defer analysis.deinit();
    const module = analysis.module orelse return error.TestUnexpectedResult;

    const target = wgslender.Edits.symbolAtOffset(module, findOffsetOf(source, "PI"));
    try std.testing.expect(target.isValid());

    const with_decl = try wgslender.Edits.findReferences(a, module, target, true);
    defer a.free(with_decl);
    try std.testing.expectEqual(@as(usize, 2), with_decl.len);

    const without_decl = try wgslender.Edits.findReferences(a, module, target, false);
    defer a.free(without_decl);
    try std.testing.expectEqual(@as(usize, 1), without_decl.len);
    try std.testing.expect(!without_decl[0].is_write);
}

test "scenario: rename builtin-conflict name rejected at apply, not edit-build" {
    // Renaming to a keyword should be rejected. Library currently rejects
    // early in renameEdits via isValidWgslIdentifier.
    const a = std.testing.allocator;
    const source: [:0]const u8 = "const v: i32 = 0;";
    var analysis = try wgslender.analyze(a, source);
    defer analysis.deinit();
    const module = analysis.module orelse return error.TestUnexpectedResult;

    const target = wgslender.Edits.symbolAtOffset(module, findOffsetOf(source, "v"));
    try std.testing.expect(target.isValid());

    try std.testing.expect((try wgslender.Edits.renameEdits(a, module, target, "let")) == null);
    try std.testing.expect((try wgslender.Edits.renameEdits(a, module, target, "return")) == null);
    try std.testing.expect((try wgslender.Edits.renameEdits(a, module, target, "struct")) == null);
}

test "scenario: rename function used inside a loop body" {
    const a = std.testing.allocator;
    const source: [:0]const u8 =
        \\fn noisy(i: i32) -> i32 { return i * 17; }
        \\@compute @workgroup_size(1) fn main() {
        \\    var total: i32 = 0;
        \\    for (var k: i32 = 0; k < 10; k = k + 1) {
        \\        total = total + noisy(k);
        \\    }
        \\}
    ;
    const rewritten = try renameAndReanalyze(a, source, "noisy", "hash");
    defer a.free(rewritten);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, rewritten, "hash"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, rewritten, "noisy"));
}
