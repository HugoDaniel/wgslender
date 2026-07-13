//! Corpus-sweep that no two diagnostics share the same
//! (code, start_offset, end_offset, message) tuple. Validators that
//! re-run resolution across phases (type collection vs function
//! validation, etc.) can produce duplicate errors at the same location;
//! `Diagnostic.deduplicate` is meant to collapse them before emission.
//!
//! DIAGNOSTICS_ROADMAP.md item 5, Phase D.

const std = @import("std");
const wgslender = @import("wgslender");
const validation_data = @import("validation_data");

const Key = struct {
    code: []const u8,
    start: u32,
    end: u32,
    message: []const u8,
};

fn expectNoDuplicates(label: []const u8, source: [:0]const u8) !void {
    var r = try wgslender.validateWithOptions(std.testing.allocator, source, .{});
    defer r.deinit();

    const diags = r.diagnostics.items();
    var seen: std.ArrayListUnmanaged(Key) = .empty;
    defer seen.deinit(std.testing.allocator);

    for (diags) |d| {
        const key: Key = .{
            .code = d.code,
            .start = d.range.start.offset,
            .end = d.range.end.offset,
            .message = d.message,
        };
        for (seen.items) |prev| {
            if (std.mem.eql(u8, prev.code, key.code) and
                prev.start == key.start and
                prev.end == key.end and
                std.mem.eql(u8, prev.message, key.message))
            {
                std.debug.print(
                    "\n[{s}] duplicate diagnostic ({s} @ {d}..{d}): {s}\n",
                    .{ label, key.code, key.start, key.end, key.message },
                );
                std.debug.print("full set:\n", .{});
                for (diags) |dd| {
                    std.debug.print(
                        "  {d}:{d} [{s}] {s}: {s}\n",
                        .{ dd.range.start.line, dd.range.start.column, dd.code, dd.severity.string(), dd.message },
                    );
                }
                return error.TestUnexpectedResult;
            }
        }
        try seen.append(std.testing.allocator, key);
    }
}

// -------------------------------------------------------------------------
// Type errors surface once regardless of phase
// -------------------------------------------------------------------------

test "dedup: unknown type in function signature" {
    try expectNoDuplicates("fn-signature",
        \\@fragment fn main(input: BadType) {}
    );
}

test "dedup: unknown return type" {
    try expectNoDuplicates("return-type",
        \\@vertex fn main() -> BadOutput {
        \\  return vec4f(0.0);
        \\}
    );
}

test "dedup: unknown type in const + var + let" {
    try expectNoDuplicates("multi-decl",
        \\const x: BadType = 0;
        \\var<private> y: BadType;
        \\fn main() { let z: BadType = 0; }
    );
}

// -------------------------------------------------------------------------
// Symbol errors surface once
// -------------------------------------------------------------------------

test "dedup: undefined symbol referenced twice" {
    try expectNoDuplicates("undef-twice",
        \\fn main() {
        \\  let a = missing_var;
        \\  let b = missing_var;
        \\}
    );
}

test "dedup: duplicate struct member" {
    try expectNoDuplicates("dup-member",
        \\struct S { a: i32, a: i32 }
        \\fn main() { let s: S = S(1, 2); }
    );
}

// -------------------------------------------------------------------------
// Attribute / binding errors surface once
// -------------------------------------------------------------------------

test "dedup: duplicate binding" {
    try expectNoDuplicates("dup-binding",
        \\@group(0) @binding(0) var<uniform> a: f32;
        \\@group(0) @binding(0) var<uniform> b: f32;
    );
}

test "dedup: missing binding error" {
    try expectNoDuplicates("missing-binding",
        \\var<uniform> a: f32;
    );
}

// -------------------------------------------------------------------------
// Control flow errors surface once
// -------------------------------------------------------------------------

test "dedup: break outside loop" {
    try expectNoDuplicates("break-outside",
        \\fn main() { break; }
    );
}

// -------------------------------------------------------------------------
// Stress: multiple mixed errors in the same source
// -------------------------------------------------------------------------

test "dedup: mixed error types across phases" {
    try expectNoDuplicates("mixed",
        \\const bad: UnknownT = 0;
        \\@vertex fn v() -> BadOut {
        \\  let x = undefined_ident;
        \\  return vec4f(0.0);
        \\}
        \\@fragment fn f(input: UnknownT) {}
    );
}

// -------------------------------------------------------------------------
// Corpus sweep: every `errors/*` fixture in tests/testdata_validation.zig
// should satisfy the same invariant.
// -------------------------------------------------------------------------

test "dedup: corpus sweep over all errors/* validation fixtures" {
    @setEvalBranchQuota(100_000);
    inline for (@typeInfo(validation_data).@"struct".decls) |decl| {
        comptime if (!std.mem.startsWith(u8, decl.name, "errors/")) continue;
        const source = @field(validation_data, decl.name);
        const sentinel_source: [:0]const u8 = source ++ [_:0]u8{};
        try expectNoDuplicates(decl.name, sentinel_source);
    }
}
