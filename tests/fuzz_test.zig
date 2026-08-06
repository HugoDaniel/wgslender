//! Fuzz tests using std.testing.fuzz + Smith.
//!
//! In normal `zig build test`: runs deterministically from corpus seeds.
//! With `zig build test --fuzz`: runs continuously with mutation.
//!
//! Each test verifies that the pipeline does not crash on arbitrary input.
//! The idempotence test additionally checks a semantic property.

const std = @import("std");
const wgslender = @import("wgslender");

// =========================================================================
// Fuzz test 1: Parser no-crash
// =========================================================================

test "fuzz: parser no crash" {
    try std.testing.fuzz({}, testParserNoCrash, .{
        .corpus = &.{
            "fn main() {}",
            "struct S { x: f32 }",
            "@compute @workgroup_size(1) fn main() {}",
            "/* nested /* comment */ */",
            "const x = 1; const y = x + 2;",
            "var<storage, read_write> buf: array<f32, 64>;",
            "@group(0) @binding(0) var<uniform> u: f32;",
            "fn f(a: f32, b: vec3f) -> vec4f { return vec4f(a, b); }",
        },
    });
}

/// Property: Parser.parse never crashes on arbitrary byte sequences,
/// even when the lexer produces nonsense token streams. Errors must
/// surface through Parser.errors, never through panic / unreachable.
fn testParserNoCrash(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var buf: [512]u8 = undefined;
    const len = smith.slice(buf[0 .. buf.len - 1]);
    buf[len] = 0;
    const source: [:0]const u8 = buf[0..len :0];

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tokens = wgslender.Lexer.tokenize(alloc, source) catch return;
    defer tokens.deinit(alloc);
    var parser = wgslender.Parser.init(alloc, source, tokens) catch return;
    // `parser.errors` is deliberately ignored, and this is the one place that
    // is right: the input is random bytes, so a populated error list is the
    // expected outcome. The property under test is "does not crash", not
    // "parses". Everywhere else, use `tests/parse_ok.zig`.
    _ = parser.parse() catch return;
}

// =========================================================================
// Fuzz test 2: Minify no-crash
// =========================================================================

test "fuzz: minify no crash" {
    try std.testing.fuzz({}, testMinifyNoCrash, .{
        .corpus = &.{
            "fn main() { let x = 1; }",
            "@group(0) @binding(0) var<uniform> u: f32; @compute @workgroup_size(1) fn main() { let y = u; }",
            "struct S { x: f32, y: vec3f } @group(0) @binding(0) var<storage> s: S;",
            "const PI = 3.14159; fn circle(r: f32) -> f32 { return PI * r * r; }",
            "fn unused() -> f32 { return 0.0; } fn main() {}",
        },
    });
}

/// Property: full minify pipeline (parse → DCE → rename → print) is
/// crash-safe on arbitrary input. Result.errors signals invalid input;
/// no panic / OOB / use-after-free.
fn testMinifyNoCrash(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var buf: [1024]u8 = undefined;
    const len = smith.slice(buf[0 .. buf.len - 1]);
    buf[len] = 0;
    const source: [:0]const u8 = buf[0..len :0];

    var result = wgslender.minifyWithOptions(std.testing.allocator, source, .{}) catch return;
    result.deinit(std.testing.allocator);
}

// =========================================================================
// Fuzz test 3: Validate no-crash
// =========================================================================

test "fuzz: validate no crash" {
    try std.testing.fuzz({}, testValidateNoCrash, .{
        .corpus = &.{
            "@compute @workgroup_size(1) fn main() {}",
            "struct S { x: f32 } @group(0) @binding(0) var<uniform> s: S; @compute @workgroup_size(1) fn main() { let v = s.x; }",
            "fn f() { if true { } else { } }",
            "fn f() { for (var i = 0; i < 10; i++) { } }",
            "fn { invalid }",
        },
    });
}

/// Property: Validator.validate is crash-safe on arbitrary parsed
/// input. Diagnostics list captures every spec violation; nothing
/// escapes as a panic.
fn testValidateNoCrash(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var buf: [512]u8 = undefined;
    const len = smith.slice(buf[0 .. buf.len - 1]);
    buf[len] = 0;
    const source: [:0]const u8 = buf[0..len :0];

    var result = wgslender.validateWithOptions(std.testing.allocator, source, .{}) catch return;
    result.deinit();
}

// =========================================================================
// Fuzz test 4: Minify idempotence (whitespace + syntax only)
// =========================================================================

test "fuzz: minify idempotence" {
    try std.testing.fuzz({}, testMinifyIdempotence, .{
        .corpus = &.{
            "fn main(){}",
            "const x=1;fn f(){let y=x;}",
            "struct S{x:f32}fn f()->S{return S(1.0);}",
            "@compute @workgroup_size(1) fn main() { var x = 1; x = x + 1; }",
        },
    });
}

/// Property: minify(minify(x)) == minify(x) when minify_identifiers
/// is off. Identifier renaming is frequency-based and so not idempotent
/// — we deliberately exclude it from this check.
fn testMinifyIdempotence(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var buf: [512]u8 = undefined;
    const len = smith.slice(buf[0 .. buf.len - 1]);
    buf[len] = 0;
    const source: [:0]const u8 = buf[0..len :0];

    const opts: wgslender.Minifier.Options = .{
        .minify_whitespace = true,
        .minify_identifiers = false, // not idempotent (frequency-based)
        .minify_syntax = true,
        .tree_shaking = false,
    };

    // First minification
    var r1 = wgslender.minifyWithOptions(std.testing.allocator, source, opts) catch return;
    defer r1.deinit(std.testing.allocator);
    if (r1.errors.len > 0) return; // skip invalid inputs

    const code1 = r1.code;
    if (code1.len == 0) return;

    // Copy to sentinel-terminated buffer for second pass
    var buf2: [2048]u8 = undefined;
    if (code1.len >= buf2.len) return;
    @memcpy(buf2[0..code1.len], code1);
    buf2[code1.len] = 0;
    const s2: [:0]const u8 = buf2[0..code1.len :0];

    // Second minification
    var r2 = wgslender.minifyWithOptions(std.testing.allocator, s2, opts) catch return;
    defer r2.deinit(std.testing.allocator);
    if (r2.errors.len > 0) return;

    try std.testing.expectEqualStrings(code1, r2.code);
}

// =========================================================================
// Fuzz test 5: Reflect no-crash
// =========================================================================

test "fuzz: reflect no crash" {
    try std.testing.fuzz({}, testReflectNoCrash, .{
        .corpus = &.{
            "@group(0) @binding(0) var<uniform> u: f32;",
            "struct S { x: f32 } @group(0) @binding(0) var<storage> s: S;",
            "@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0); }",
            "fn main() {}",
        },
    });
}

/// Property: Reflect.reflect is crash-safe on arbitrary input. The
/// returned ReflectResult may be empty for invalid shaders, but the
/// pipeline never panics.
fn testReflectNoCrash(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var buf: [512]u8 = undefined;
    const len = smith.slice(buf[0 .. buf.len - 1]);
    buf[len] = 0;
    const source: [:0]const u8 = buf[0..len :0];

    var result = wgslender.reflect(std.testing.allocator, source) catch return;
    result.deinit(std.testing.allocator);
}

// =========================================================================
// Fuzz test 6: Compile no-crash
// =========================================================================

test "fuzz: compile no crash" {
    try std.testing.fuzz({}, testCompileNoCrash, .{
        .corpus = &.{
            "fn main() {}",
            "@compute @workgroup_size(1) fn main() { let x = 1; }",
            "const PI = 3.14159;",
        },
    });
}

/// Property: WGSL→WASM Compiler.compile is crash-safe on arbitrary
/// input. Even when Parser produces zero declarations, the WASM
/// assembler still emits a valid magic header (asserted at the API
/// boundary). Errors propagate; nothing panics.
fn testCompileNoCrash(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var buf: [512]u8 = undefined;
    const len = smith.slice(buf[0 .. buf.len - 1]);
    buf[len] = 0;
    const source: [:0]const u8 = buf[0..len :0];

    var result = wgslender.Compiler.compile(std.testing.allocator, source, .{}) catch return;
    result.deinit(std.testing.allocator);
}
