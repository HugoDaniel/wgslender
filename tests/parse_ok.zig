//! Parse helpers for tests whose fixtures are supposed to be valid WGSL.
//!
//! `Parser.parse()` is error-*recovering*: it accumulates every diagnostic in
//! `parser.errors` and still returns a module, so `try parser.parse()` only
//! fails on OOM. A test helper that ignores `parser.errors` therefore accepts
//! a partial AST from a source that does not parse, and every assertion the
//! test makes afterwards is made against that partial AST. That is how a
//! fixture goes quietly vacuous: it keeps passing while testing less and less.
//!
//! `tests/validation_test.zig`'s `runValidation` hit exactly this — six
//! "expected valid" fixtures asserted against sources carrying three parse
//! errors each, and could not have failed.
//!
//! So: default to `parseOk`, which turns leftover parse errors into a loud
//! failure. Reach for `parseAllowingErrors` only when a partial AST is the
//! point of the test, and say why at the call site.

const std = @import("std");
const wgslender = @import("wgslender");
const Ast = wgslender.Ast;

/// What a failed parse should do besides returning `error.SourceDidNotParse`.
/// Real call sites want `.report` — the parser's messages are the whole point
/// of the failure. Only this file's own guard test wants `.stay_silent`, so a
/// deliberately-broken source does not print an alarming diagnostic block on
/// an otherwise-passing run.
const OnParseErrors = enum { report, stay_silent };

/// Parse `source`, requiring it to parse cleanly. Fails with the parser's own
/// diagnostics if it does not.
pub fn parseOk(arena: std.mem.Allocator, source: [:0]const u8) !*Ast.Module {
    return parseRequiringSuccess(arena, source, .report);
}

/// The `parseOk` check on its own, for call sites that must drive the lexer
/// themselves (they need the token list, not just the module) and so cannot
/// go through `parseOk`. Call it right after `parser.parse()`.
pub fn expectNoParseErrors(parser: *const wgslender.Parser, source: [:0]const u8) !void {
    return checkParseErrors(parser, source, .report);
}

fn parseRequiringSuccess(
    arena: std.mem.Allocator,
    source: [:0]const u8,
    on_errors: OnParseErrors,
) !*Ast.Module {
    const tokens = try wgslender.Lexer.tokenize(arena, source);
    var parser = try wgslender.Parser.init(arena, source, tokens);
    const module = try parser.parse();
    try checkParseErrors(&parser, source, on_errors);
    return module;
}

fn checkParseErrors(
    parser: *const wgslender.Parser,
    source: [:0]const u8,
    on_errors: OnParseErrors,
) !void {
    if (parser.errors.items.len == 0) return;
    if (on_errors == .report) {
        std.debug.print("\n=== SOURCE DID NOT PARSE ({d} error(s)) ===\n{s}\n", .{
            parser.errors.items.len,
            source,
        });
        for (parser.errors.items) |e| {
            std.debug.print("  at byte {d}: {s}\n", .{ e.pos, e.message });
        }
    }
    return error.SourceDidNotParse;
}

/// Parse `source` and hand back whatever AST came out, parse errors and all.
/// The named counterpart to `parseOk` — a call site using this is asserting
/// that a partial AST is what it wants to test.
pub fn parseAllowingErrors(arena: std.mem.Allocator, source: [:0]const u8) !*Ast.Module {
    const tokens = try wgslender.Lexer.tokenize(arena, source);
    var parser = try wgslender.Parser.init(arena, source, tokens);
    return parser.parse();
}

test "parseOk rejects a source that does not parse" {
    // Guard for every consumer of this file: a recovering `parser.parse()`
    // hands back a module for this source, and each of them would happily
    // assert against it. `.stay_silent` because this failure is the expected
    // one — it should not print.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.SourceDidNotParse,
        parseRequiringSuccess(arena.allocator(), "fn f( { }", .stay_silent),
    );
}

test "parseOk accepts valid WGSL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = try parseOk(arena.allocator(), "fn f() -> i32 { return 1; }");
    try std.testing.expectEqual(@as(usize, 1), module.declarations.items.len);
}

test "parseAllowingErrors keeps the partial AST" {
    // The counterpart to the guard above: the same source that `parseOk`
    // rejects still yields a module here, which is exactly the behaviour that
    // made silent vacuity possible in the first place.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parseAllowingErrors(arena.allocator(), "fn f( { }");
}
