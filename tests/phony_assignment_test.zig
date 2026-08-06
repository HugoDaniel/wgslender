//! Phony assignment — WGSL §9.3 `'_' '=' expression`.
//!
//! The statement evaluates its right-hand side and discards the value. It
//! exists for two jobs the language offers no substitute for:
//!
//!   1. Silencing an unused-value diagnostic without inventing a variable.
//!   2. Forcing a resource into the pipeline layout — `_ = tex;` makes a
//!      binding statically used, so it survives into the bind-group layout
//!      even when nothing reads it.
//!
//! `_` is NOT an identifier. It lexes as its own `.underscore` token and
//! `eatIdent` does not accept it, so no `Symbol` is ever built for it. That
//! is deliberate: the left-hand side of a phony assignment is a grammar
//! position, not a name, and `Ast.PhonyStmt` has no `SymbolIndex` field to
//! reflect that.

const std = @import("std");
const wgslender = @import("wgslender");

const Ast = wgslender.Ast;
const Incremental = wgslender.Incremental;

/// Parse `src`, assert it produced no parse errors, and return the result.
/// Caller owns the result (`defer r.deinit()`).
fn parseClean(src: [:0]const u8) !Incremental.ReparseResult {
    var r = try Incremental.parseFull(std.testing.allocator, src);
    errdefer r.deinit();
    if (r.errors.len != 0) {
        for (r.errors) |e| std.debug.print("unexpected parse error @{d}: {s}\n", .{ e.pos, e.message });
        return error.UnexpectedParseErrors;
    }
    return r;
}

/// Return the statements of the first function declaration named `name`.
fn bodyOf(r: *const Incremental.ReparseResult, name: []const u8) ![]const Ast.Stmt {
    for (r.module.declarations.items) |d| {
        if (d != .function) continue;
        const fd = d.function;
        if (!fd.name.isValid()) continue;
        if (!std.mem.eql(u8, r.module.symbols.items[fd.name.index()].original_name, name)) continue;
        const body = fd.body orelse return error.NoBody;
        return body.stmts.items;
    }
    return error.NoSuchFunction;
}

test "phony: `_ = x;` parses as a phony statement" {
    var r = try parseClean(
        \\@compute @workgroup_size(1)
        \\fn main() { let x = 1.0; _ = x; }
        \\
    );
    defer r.deinit();

    const stmts = try bodyOf(&r, "main");
    try std.testing.expectEqual(@as(usize, 2), stmts.len);
    try std.testing.expect(stmts[1] == .phony);
    try std.testing.expect(stmts[1].phony.expr == .ident);
    try std.testing.expectEqualStrings("x", stmts[1].phony.expr.ident.name);
}

test "phony: the `_` token position is recorded on the node" {
    const src =
        \\fn f() { _ = 1; }
        \\
    ;
    var r = try parseClean(src);
    defer r.deinit();

    const stmts = try bodyOf(&r, "f");
    try std.testing.expectEqual(@as(usize, 1), stmts.len);
    // `loc` points at the `_`, not at the `=`.
    try std.testing.expectEqual(@as(u8, '_'), src[stmts[0].phony.loc]);
}

test "phony: span covers `_` through the semicolon" {
    const src =
        \\fn f() { _ = 1 + 2; }
        \\
    ;
    var r = try parseClean(src);
    defer r.deinit();

    const stmts = try bodyOf(&r, "f");
    const span = stmts[0].span();
    try std.testing.expectEqualStrings("_ = 1 + 2;", src[span.start..span.end]);
}

test "phony: accepts an arbitrary expression, not just an identifier" {
    var r = try parseClean(
        \\@group(0) @binding(0) var<storage, read> buf: array<f32>;
        \\fn f() { _ = buf[0] * 2.0; }
        \\
    );
    defer r.deinit();

    const stmts = try bodyOf(&r, "f");
    try std.testing.expect(stmts[0] == .phony);
    try std.testing.expect(stmts[0].phony.expr == .binary);
}

test "phony: legal in a for-init and a for-update (§9.4.3)" {
    var r = try parseClean(
        \\fn f() { for (_ = 1; false; _ = 2) {} }
        \\
    );
    defer r.deinit();

    const stmts = try bodyOf(&r, "f");
    try std.testing.expect(stmts[0] == .@"for");
    const fs = stmts[0].@"for";
    try std.testing.expect(fs.init_stmt.? == .phony);
    try std.testing.expect(fs.update.? == .phony);
}

test "phony: only `=` is accepted — compound operators are rejected" {
    // §9.3 spells the phony form with a plain `=`; `_ += x` is not WGSL.
    var r = try Incremental.parseFull(std.testing.allocator,
        \\fn f() { let x = 1.0; _ += x; }
        \\
    );
    defer r.deinit();
    try std.testing.expect(r.errors.len > 0);
}

// -------------------------------------------------------------------------
// Block 2 — the RHS is a real evaluated expression.
//
// Every one of the 49 Class-A fixtures in the repo depends on this and on
// nothing else in the feature: they write `let x = u; _ = x;` purely so the
// binding counts as used. `_ = tex;` in real shaders depends on it for a
// stronger reason — it is the only way to force a resource into the
// bind-group layout when nothing reads it (§9.3).
// -------------------------------------------------------------------------

/// Look up a symbol by name and return its Pass-2 use count.
fn useCountOf(r: *const Incremental.ReparseResult, name: []const u8) !u32 {
    for (r.module.symbols.items, 0..) |sym, i| {
        if (!std.mem.eql(u8, sym.original_name, name)) continue;
        return r.module.use_counts.get(@enumFromInt(@as(u32, @intCast(i))));
    }
    return error.NoSuchSymbol;
}

test "phony: the RHS counts as a use of the symbols it names" {
    var r = try parseClean(
        \\fn f() { let x = 1.0; _ = x; }
        \\
    );
    defer r.deinit();

    try std.testing.expectEqual(@as(u32, 1), try useCountOf(&r, "x"));
}

test "phony: identifiers in the RHS are bound to their declarations" {
    var r = try parseClean(
        \\fn f() { let x = 1.0; _ = x; }
        \\
    );
    defer r.deinit();

    const stmts = try bodyOf(&r, "f");
    // An unbound ident would leave `ref` invalid and E0100 would not fire
    // (the parse succeeded), so a silently-unwalked RHS is invisible
    // without this assertion.
    try std.testing.expect(stmts[1].phony.expr.ident.ref.isValid());
}

test "phony: DCE keeps a binding referenced only by a phony assignment" {
    // The reason `_ = tex;` exists. If DCE cannot see through the phony
    // RHS it drops the declaration and emits a shader that references an
    // undeclared name — silently wrong output, not a diagnostic.
    var r = try parseClean(
        \\@group(0) @binding(0) var<uniform> u: vec4f;
        \\@compute @workgroup_size(1)
        \\fn main() { _ = u; }
        \\
    );
    defer r.deinit();

    var out = try wgslender.minify(std.testing.allocator, r.source);
    defer out.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, out.code, "@binding(0)") != null);
}

// -------------------------------------------------------------------------
// Block 3 — printing and minification.
// -------------------------------------------------------------------------

/// Minify `src` with the given options and return the code. Caller must
/// `deinit` the returned result.
fn minifyWith(src: [:0]const u8, opts: wgslender.Minifier.Options) !wgslender.Minifier.Result {
    return wgslender.minifyWithOptions(std.testing.allocator, src, opts);
}

test "phony: minifies to `_=x;`" {
    var out = try wgslender.minify(std.testing.allocator,
        \\@compute @workgroup_size(1)
        \\fn main() { let x = 1.0; _ = x; }
        \\
    );
    defer out.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, out.code, "_=") != null);
}

test "phony: survives a print → reparse round-trip" {
    var opts = wgslender.Minifier.defaultOptions();
    opts.minify_identifiers = false;
    var out = try minifyWith(
        \\@group(0) @binding(0) var<uniform> u: vec4f;
        \\@compute @workgroup_size(1)
        \\fn main() { _ = u; }
        \\
    , opts);
    defer out.deinit(std.testing.allocator);

    // Re-parse the printed text: the statement must come back as a phony,
    // not as an error-recovered fragment that happens to print the same.
    const round: [:0]const u8 = try std.testing.allocator.dupeZ(u8, out.code);
    defer std.testing.allocator.free(round);
    var r = try parseClean(round);
    defer r.deinit();
    const stmts = try bodyOf(&r, "main");
    try std.testing.expectEqual(@as(usize, 1), stmts.len);
    try std.testing.expect(stmts[0] == .phony);
}

test "phony: for-init and for-update forms print without a stray semicolon" {
    var opts = wgslender.Minifier.defaultOptions();
    opts.minify_identifiers = false;
    var out = try minifyWith(
        \\@compute @workgroup_size(1)
        \\fn main() { for (_ = 1; false; _ = 2) {} }
        \\
    , opts);
    defer out.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, out.code, "for(_=1;false;_=2)") != null);
}

test "phony: the minifier does not drop a pure phony assignment" {
    // `_ = 1;` has no observable effect and is a legitimate future
    // optimization — but dropping it is a semantics decision of its own,
    // and wrong for `_ = tex;`. Pin today's behaviour so the change is
    // deliberate when it comes. See the plan's §9.
    var out = try wgslender.minify(std.testing.allocator,
        \\@compute @workgroup_size(1)
        \\fn main() { _ = 1; }
        \\
    );
    defer out.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, out.code, "_=1;") != null);
}

// -------------------------------------------------------------------------
// Block 4 — validation, and `_` used where a name is expected.
// -------------------------------------------------------------------------

const Diagnostic = wgslender.Diagnostic;

/// Validate `src` and return the diagnostics. Caller owns the result.
fn validate(src: [:0]const u8) !wgslender.Validator.Result {
    return wgslender.validateWithOptions(std.testing.allocator, src, .{});
}

fn countErrors(r: wgslender.Validator.Result) usize {
    var n: usize = 0;
    for (r.diagnostics.items()) |d| {
        if (d.severity == .@"error") n += 1;
    }
    return n;
}

fn hasCode(r: wgslender.Validator.Result, code: []const u8) bool {
    for (r.diagnostics.items()) |d| {
        if (std.mem.eql(u8, d.code, code)) return true;
    }
    return false;
}

test "phony: the RHS is type-checked — an undeclared name is reported" {
    var r = try validate(
        \\fn f() { _ = nope; }
        \\
    );
    defer r.deinit();
    try std.testing.expect(hasCode(r, "E0100"));
}

test "phony: a type error in the RHS is reported" {
    var r = try validate(
        \\fn f() { _ = 1.0 + vec2f(1.0, 2.0) * mat2x3f(); }
        \\
    );
    defer r.deinit();
    try std.testing.expect(countErrors(r) > 0);
}

test "phony: `let _ = x;` produces exactly one diagnostic, not a cascade" {
    // Six errors before this block, the first of them misattributed to
    // the *previous* line. `let _` is genuinely invalid WGSL (§2.4: `_`
    // may only appear as the left-hand side of a phony assignment) and
    // should be rejected — but with one message that names the problem.
    var r = try validate(
        \\fn f() {
        \\  let _ = 3.14;
        \\}
        \\
    );
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), countErrors(r));
    try std.testing.expect(hasCode(r, Diagnostic.Code.reserved_identifier));
}

test "phony: `var _ : f32;` is rejected the same way" {
    var r = try validate(
        \\fn f() { var _ : f32; }
        \\
    );
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), countErrors(r));
    try std.testing.expect(hasCode(r, Diagnostic.Code.reserved_identifier));
}

test "phony: the `_` diagnostic points at the `_`, not the previous line" {
    var r = try validate(
        \\fn f() {
        \\  let _ = 3.14;
        \\}
        \\
    );
    defer r.deinit();
    for (r.diagnostics.items()) |d| {
        if (!std.mem.eql(u8, d.code, Diagnostic.Code.reserved_identifier)) continue;
        try std.testing.expectEqual(@as(u32, 2), d.range.start.line);
        try std.testing.expectEqual(@as(u32, 7), d.range.start.column);
        return;
    }
    return error.NoReservedIdentifierDiagnostic;
}

test "phony: `_` is rejected in every declaration-name position" {
    // Before this block only `let`/`var` reached the validator at all;
    // parameters, struct members, `const`, `alias` and `fn` names each
    // derailed into their own multi-error cascade. `Parser.isDeclNameLike`
    // routes all of them through `eatIdent` so one message covers them.
    const cases = [_][:0]const u8{
        "fn f(_ : f32) {}\n",
        "struct S { _: f32 }\n",
        "const _ = 1;\n",
        "alias _ = f32;\n",
        "fn _() {}\n",
        "fn f() { let _ = 3.14; }\n",
        "fn f() { var _ : f32; }\n",
    };
    for (cases) |src| {
        var r = try validate(src);
        defer r.deinit();
        std.testing.expectEqual(@as(usize, 1), countErrors(r)) catch |e| {
            std.debug.print("case: {s}", .{src});
            for (r.diagnostics.items()) |d| std.debug.print("  [{s}] {s}\n", .{ d.code, d.message });
            return e;
        };
        try std.testing.expect(hasCode(r, Diagnostic.Code.reserved_identifier));
    }
}

test "phony: `_` in member position stays a parse error, not a member named `_`" {
    // `isDeclNameLike` deliberately does not cover member access: there is
    // no declaration there to hang the reserved-identifier message on.
    var r = try Incremental.parseFull(std.testing.allocator,
        \\fn f() { let v = vec2f(); _ = v._; }
        \\
    );
    defer r.deinit();
    try std.testing.expect(r.errors.len > 0);
}
