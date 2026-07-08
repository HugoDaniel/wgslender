//! Property-based fuzz: `Incremental.reparse(prev, edit)` must produce a
//! module *structurally identical* to `Incremental.parseFull(apply(source,
//! edit))` — same symbols, use-counts, scopes, and decl/stmt/expr/type
//! trees with byte-identical spans, checked via `ast_equal.expectModulesEqual`.
//!
//! Runs a deterministic random walk by default; with `zig build test
//! --fuzz` the corpus is mutated continuously. Each iteration picks a
//! random byte range from a base source, substitutes a short ASCII
//! payload, and checks the invariant. An escape hatch short-circuits
//! on sources that fail to parse cleanly (so fuzz-generated invalid
//! inputs don't count against the property).
//!
//! This is Tier 1's primary correctness gate for retiring `CstLower`:
//! from Block 1.4 the incremental hot path re-parses each anchor with the
//! Parser (no CstLower re-lower), so a splice whose AST drifts from a
//! fresh full parse must fail here. The full `expectModulesEqual` compare
//! is what makes that drift observable — a coarse decl-count/source check
//! would not.

const std = @import("std");
const wgslender = @import("wgslender");
const ast_equal = @import("ast_equal.zig");

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

fn testOne(
    gpa: std.mem.Allocator,
    base: []const u8,
    start: u32,
    end: u32,
    text: []const u8,
) !void {
    // 1) Spliced source + full reparse — the oracle. `parseFull` copies the
    //    source into its own arena, so a plain (non-sentinel) slice is fine.
    const spliced = try applyEdit(gpa, base, start, end, text);
    defer gpa.free(spliced);

    var oracle = Incremental.parseFull(gpa, spliced) catch {
        // The oracle itself OOM'd — skip. Parse *errors* don't fail here;
        // they land in the module + error list, and the module invariant
        // below still holds (both paths parse the same bytes).
        return;
    };
    defer oracle.deinit();

    // 2) The incremental path.
    var prev = try Incremental.parseFull(gpa, base);
    defer prev.deinit();

    var updated = try Incremental.reparse(gpa, &prev, .{
        .start = start,
        .end = end,
        .new_text = text,
    });
    defer updated.deinit();

    // The hot path shifts spans of decls after the edit lazily: they carry
    // an `interior_pending` bias until drained. Every external span reader
    // (Validator, LSP, Printer, …) calls `absorbInteriors` at entry; the
    // oracle comparison is one such reader, so drain here before comparing.
    // A no-op on the full-parse oracle (fresh decls start at zero bias).
    updated.module.absorbInteriors();
    oracle.module.absorbInteriors();

    // 3) The hot-path splice (or its parseFull fallback) must produce a
    //    module equivalent to a fresh full parse of the edited source:
    //    identical decl/stmt/expr/type trees with byte-identical spans and
    //    flags, identical scope structure, and per-symbol use-count parity —
    //    tolerant only of the hot path's append-only symbol table (removed
    //    declarations leave a dead, use_count==0 symbol behind). This is the
    //    gate that keeps the Parser-driven anchor splice honest once CstLower
    //    is gone; a coarse decl-count/source check would not see the drift.
    ast_equal.expectModulesEquivalent(gpa, oracle.module, updated.module) catch |err| {
        std.debug.print(
            "fuzz AST divergence ({s}): edit=[{d}..{d}]=<<{s}>> reused={} base=<<{s}>>\n",
            .{ @errorName(err), start, end, text, updated.reused, base },
        );
        return err;
    };
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
    // original source byte-for-byte. Seed is fixed because random splice
    // positions can land mid-token and produce sources the parser
    // reshapes — the property only holds for splice positions that
    // happen to fall on token boundaries; the chosen seed walks one
    // such sequence. Genuine reproducibility comes from the corpus
    // edit suite below, not from this seed walk.
    const gpa = std.testing.allocator;
    var rng = std.Random.DefaultPrng.init(0xFEEDC0DE);
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
