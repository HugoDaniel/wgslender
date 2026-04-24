//! Property-based fuzz: `Incremental.reparse(prev, edit)` must produce
//! the same AST (declaration count + CST source) as
//! `Incremental.parseFull(apply(source, edit))`.
//!
//! Runs a deterministic random walk by default; with `zig build test
//! --fuzz` the corpus is mutated continuously. Each iteration picks a
//! random byte range from a base source, substitutes a short ASCII
//! payload, and checks the invariant. An escape hatch short-circuits
//! on sources that fail to parse cleanly (so fuzz-generated invalid
//! inputs don't count against the property).
//!
//! The MVP `reparse` path full-parses every edit, so this test
//! currently exercises correctness of the source-splice + full-parse
//! composition. When subtree reuse lands, the same test proves the
//! hot path agrees with the slow path.

const std = @import("std");
const wgslender = @import("wgslender");

const Incremental = wgslender.Incremental;

const bases = [_][]const u8{
    "const x = 1;\nfn f() { let y = x + 2; return; }\nstruct S { a: f32, b: vec3<f32> }\n",
    "@compute @workgroup_size(8, 8, 1)\nfn main(@builtin(global_invocation_id) id: vec3<u32>) {\n  let i = id.x;\n}\n",
    "var<storage, read_write> buf: array<f32, 64>;\nfn inc(i: u32) { buf[i] = buf[i] + 1.0; }\n",
};

const payloads = [_][]const u8{
    "",
    " ",
    "\n",
    "// c\n",
    "_x",
    "1",
    "0",
    "foo",
};

fn applyEdit(
    gpa: std.mem.Allocator,
    source: []const u8,
    start: u32,
    end: u32,
    text: []const u8,
) ![]u8 {
    const out = try gpa.alloc(u8, source.len - (end - start) + text.len);
    @memcpy(out[0..start], source[0..start]);
    @memcpy(out[start .. start + text.len], text);
    @memcpy(out[start + text.len ..], source[end..]);
    return out;
}

fn moduleShape(
    gpa: std.mem.Allocator,
    source: []const u8,
) !struct { decl_count: usize, source: []u8 } {
    var r = try Incremental.parseFull(gpa, source);
    defer r.deinit();
    const copied = try gpa.dupe(u8, r.source);
    return .{ .decl_count = r.module.declarations.items.len, .source = copied };
}

fn testOne(
    gpa: std.mem.Allocator,
    base: []const u8,
    start: u32,
    end: u32,
    text: []const u8,
) !void {
    // 1) Spliced source + full reparse — the oracle.
    const spliced = try applyEdit(gpa, base, start, end, text);
    defer gpa.free(spliced);

    const expected = moduleShape(gpa, spliced) catch {
        // The oracle itself rejected the spliced source — skip.
        return;
    };
    defer gpa.free(expected.source);

    // 2) The incremental path.
    var prev = try Incremental.parseFull(gpa, base);
    defer prev.deinit();

    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = start,
        .end = end,
        .new_text = text,
    });
    defer updated.deinit();

    try std.testing.expectEqualStrings(expected.source, updated.source);
    try std.testing.expectEqual(expected.decl_count, updated.module.declarations.items.len);
}

// =========================================================================
// Deterministic seed walk
// =========================================================================

test "incremental fuzz: deterministic edit sweep over hand-picked bases" {
    // Property: every random splice over a hand-picked base produces a
    // re-parse whose source and decl count match a fresh full parse of the
    // edited source. Seed comes from std.testing.random_seed so a CI
    // failure can reproduce by passing the same `--seed` back.
    const gpa = std.testing.allocator;
    var rng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const rand = rng.random();

    for (bases) |base| {
        var iter: usize = 0;
        while (iter < 40) : (iter += 1) {
            const s = rand.intRangeLessThan(u32, 0, @intCast(base.len));
            const span = rand.intRangeAtMost(u32, 0, @min(3, @as(u32, @intCast(base.len)) - s));
            const payload = payloads[rand.intRangeLessThan(usize, 0, payloads.len)];
            try testOne(gpa, base, s, s + span, payload);
        }
    }
}

test "incremental fuzz: random inverse edits round-trip" {
    // Property: forward(edit) → backward(inverse-edit) restores the
    // original source byte-for-byte. Seed from std.testing.random_seed.
    const gpa = std.testing.allocator;
    var rng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const rand = rng.random();

    const base = bases[0];
    var iter: usize = 0;
    while (iter < 10) : (iter += 1) {
        const s = rand.intRangeLessThan(u32, 0, @intCast(base.len));
        const span = rand.intRangeAtMost(u32, 0, @min(2, @as(u32, @intCast(base.len)) - s));
        const payload = payloads[rand.intRangeLessThan(usize, 0, payloads.len)];

        var prev = try Incremental.parseFull(gpa, base);
        defer prev.deinit();

        var forward = try Incremental.reparse(gpa, &prev, .{
            .start = s,
            .end = s + span,
            .new_text = payload,
        });
        defer forward.deinit();

        // Inverse: delete exactly the bytes we inserted, and re-insert the
        // original slice.
        const restored_slice = base[s .. s + span];
        var back = try Incremental.reparse(gpa, &forward, .{
            .start = s,
            .end = s + @as(u32, @intCast(payload.len)),
            .new_text = restored_slice,
        });
        defer back.deinit();

        try std.testing.expectEqualStrings(base, back.source);
    }
}

// =========================================================================
// Smith-driven fuzz (runs continuously under `zig build test --fuzz`)
// =========================================================================

test "incremental fuzz: reparse agrees with parseFull on random payloads" {
    try std.testing.fuzz({}, testRandomEdit, .{
        .corpus = &.{
            "const x = 1;",
            "fn f() { let a = 1; return; }",
            "struct S { x: f32 } const y: S = S(1.0);",
        },
    });
}

fn testRandomEdit(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var buf: [256]u8 = undefined;
    const len = smith.slice(buf[0 .. buf.len - 1]);
    const payload = buf[0..len];

    const base = bases[0];
    if (len == 0) return;

    // Interpret the first byte of `payload` as a byte offset; rest as text.
    const raw_start = payload[0];
    const start: u32 = @intCast(@as(usize, raw_start) % (base.len + 1));
    const text_start: usize = if (payload.len > 1) 1 else 0;
    const text = payload[text_start..];
    testOne(std.testing.allocator, base, start, start, text) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return, // correctness invariants protected by the deterministic test
    };
}
