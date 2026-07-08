//! Characterization pin — current result-type / error behavior of every
//! binary and unary value operator across a representative operand matrix.
//!
//! Block 2.1 migrates the nine hand-rolled binary-operator checkers (and the
//! unary forms) in `validator/Expressions.zig` onto the `Overload` engine, one
//! family per commit. The `validation_location`/`validation`/corpus suites pin
//! *diagnostics* (wording, position, per-code counts) — but a silent change to
//! a *result type* (a broadcast width, an abstract-vs-concrete element, or a
//! matmul that today rejects yet would newly accept) can slip past all of them:
//! no message changes, no error count moves. This pin captures the exact
//! `(a op b) -> result-type-or-error` outcome for the whole operand cross
//! product so each family flip is *provably* neutral — or the drift shows up
//! here as a deliberate, reviewed golden change instead of escaping unnoticed.
//!
//! Outcome grammar (one line per case): `type=<T>` on a clean inference,
//! `err=<CODE>` when the operator (or the enclosing `let`) reports an error,
//! or `none` for a silent inference failure that emits neither. All three are
//! genuine current behaviors worth pinning — the `none` rows in particular
//! flag today's silent-failure paths (e.g. width-mismatched bitwise).
//!
//! Golden: `tests/inference/operator_result_golden.txt` (written when absent,
//! compared otherwise — same mechanism as the tint corpus pin). Regenerate
//! after an *intentional* change:
//!   rm tests/inference/operator_result_golden.txt && zig build test

const std = @import("std");
const wgslender = @import("wgslender");

/// Source scaffold: `let r = <a> <op> <b>;` in a trivial function. The `let`
/// is unannotated so the operator's *natural* result type is what lands in the
/// `expr_types` cache (no top-down materialization hint). Operand exprs are all
/// self-contained and operator-free in value, so the only diagnostics a case
/// can produce come from the operator under test.
const PREFIX = "fn f(){ let r = ";

/// Each operand is a constant expression producing a known, stable type.
/// Angle brackets are fine — operator offsets are computed arithmetically, not
/// searched — so `vec3<bool>` is includable. f16 is omitted to avoid the
/// `enable f16;` directive (and it is skipped by the corpus suites anyway).
const operands = [_][]const u8{
    "1", // abstract-int
    "1.0", // abstract-float
    "1i", // i32
    "1u", // u32
    "1f", // f32
    "true", // bool
    "vec2f()", // vec2<f32>
    "vec3f()", // vec3<f32>
    "vec2i()", // vec2<i32>
    "vec3i()", // vec3<i32>
    "vec2u()", // vec2<u32>
    "vec3u()", // vec3<u32>
    "vec3<bool>(true, true, true)", // vec3<bool>
    // Two integer-vector widths (vec2/vec3) are deliberate: they exercise the
    // int-vector width-mismatch paths (e.g. `vec3i() & vec2i()`), one of the
    // silent-failure shapes the migration must not perturb.
    "mat2x2f()", // mat2x2<f32>
    "mat2x3f()", // mat2x3<f32> (cols=2, rows=3)
    "mat3x2f()", // mat3x2<f32> (cols=3, rows=2)
    "mat3x3f()", // mat3x3<f32>
};

const binary_ops = [_][]const u8{
    "&&", "||", // logical
    "&",  "|",  "^", // bitwise
    "==", "!=", "<", "<=", ">", ">=", // comparison / equality
    "+",  "-",  "*", "/", "%", // arithmetic
    "<<", ">>", // shift
};

const unary_ops = [_][]const u8{ "-", "!", "~" };

fn analyze(src: [:0]const u8) !wgslender.Validator.AnalysisResult {
    return wgslender.analyzeWithOptions(std.testing.allocator, src, .{});
}

/// Append the operator's current outcome to `out`. Bytes are copied straight
/// into `out` before the caller frees `r`'s arena, so no lifetime hazard.
fn appendOutcome(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    r: *const wgslender.Validator.AnalysisResult,
    op_off: u32,
) !void {
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error") {
            try out.appendSlice(gpa, "err=");
            try out.appendSlice(gpa, d.code);
            return;
        }
    }
    if (r.expr_types.get(op_off)) |info| {
        try out.appendSlice(gpa, "type=");
        try out.appendSlice(gpa, info.typ.string());
        return;
    }
    try out.appendSlice(gpa, "none");
}

/// Write `out_items` to `golden_path` when absent, otherwise compare (trailing
/// newlines ignored) and fail on drift. Mirrors the tint corpus pin's helper.
fn writeOrCompareGolden(
    io: std.Io,
    gpa: std.mem.Allocator,
    golden_path: []const u8,
    out_items: []const u8,
) !void {
    const golden_bytes_or_err = std.Io.Dir.cwd().readFileAlloc(io, golden_path, gpa, .unlimited);
    if (golden_bytes_or_err) |golden_bytes| {
        defer gpa.free(golden_bytes);
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, golden_bytes, "\n"), std.mem.trimEnd(u8, out_items, "\n"))) {
            std.debug.print(
                "\noperator pin drift at {s}.\n" ++
                    "If this change is intentional, regenerate by deleting the golden and re-running:\n" ++
                    "  rm {s} && zig build test\n",
                .{ golden_path, golden_path },
            );
            return error.TestUnexpectedResult;
        }
    } else |err| switch (err) {
        error.FileNotFound => {
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = golden_path, .data = out_items }) catch |werr| {
                std.debug.print("operator pin: failed to write golden {s}: {s}\n", .{ golden_path, @errorName(werr) });
                return werr;
            };
            std.debug.print("operator pin: wrote {s}\n", .{golden_path});
        },
        else => return err,
    }
}

test "operator result-type + error characterization pin" {
    const gpa = std.testing.allocator;
    const io = std.Options.debug_io;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    for (binary_ops) |op| {
        for (operands) |a| {
            for (operands) |b| {
                const src = try std.fmt.allocPrintSentinel(gpa, "{s}{s} {s} {s}; }}", .{ PREFIX, a, op, b }, 0);
                defer gpa.free(src);
                // `a.loc` for the binary is the operator token (see the
                // `expr_types` keying in validator/Expressions.zig): PREFIX,
                // then `a`, then the single separating space.
                const op_off: u32 = @intCast(PREFIX.len + a.len + 1);
                var r = try analyze(src);
                defer r.deinit(gpa);
                try out.appendSlice(gpa, a);
                try out.append(gpa, ' ');
                try out.appendSlice(gpa, op);
                try out.append(gpa, ' ');
                try out.appendSlice(gpa, b);
                try out.appendSlice(gpa, " => ");
                try appendOutcome(&out, gpa, &r, op_off);
                try out.append(gpa, '\n');
            }
        }
    }

    for (unary_ops) |op| {
        for (operands) |a| {
            const src = try std.fmt.allocPrintSentinel(gpa, "{s}{s}{s}; }}", .{ PREFIX, op, a }, 0);
            defer gpa.free(src);
            const op_off: u32 = @intCast(PREFIX.len);
            var r = try analyze(src);
            defer r.deinit(gpa);
            try out.appendSlice(gpa, op);
            try out.appendSlice(gpa, a);
            try out.appendSlice(gpa, " => ");
            try appendOutcome(&out, gpa, &r, op_off);
            try out.append(gpa, '\n');
        }
    }

    try writeOrCompareGolden(io, gpa, "tests/inference/operator_result_golden.txt", out.items);
}
