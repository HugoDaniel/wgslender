//! `--` in expression position is two minus signs, not a decrement operator.
//!
//! WGSL has no prefix or infix decrement — `--` is a token only because the
//! *statement* form `i--;` exists (§9.4). Everywhere else the lexer's maximal
//! munch has to be undone: `two--one` is `two - (-one)`, and a run like
//! `two----one` is `two` minus three nested negations. Tint pins this in
//! `bug/chromium/380168990.wgsl`, which we rejected outright before this was
//! handled — the misparse ended the const declaration early, corrupting every
//! `const_assert` that read it.
//!
//! The split follows the same retag-and-bump discipline `expectTemplateClose`
//! uses to break a `>>` into two template closures.

const std = @import("std");
const wgslender = @import("wgslender");

const Ast = wgslender.Ast;
const Incremental = wgslender.Incremental;

// =========================================================================
// Helpers
// =========================================================================

fn constInit(module: *const Ast.Module, name: []const u8) ?Ast.Expr {
    for (module.declarations.items) |d| {
        if (d != .@"const") continue;
        const sym_idx = d.@"const".name;
        if (sym_idx == .none) continue;
        const sym = module.symbols.items[@intFromEnum(sym_idx)];
        if (!std.mem.eql(u8, sym.original_name, name)) continue;
        return d.@"const".initializer;
    }
    return null;
}

/// Depth of a right-leaning `neg` chain, and what sits at the bottom.
fn negDepth(expr: Ast.Expr) usize {
    var e = expr;
    var n: usize = 0;
    while (e == .unary and e.unary.op == .neg) : (n += 1) e = e.unary.operand;
    return n;
}

/// Asserts `name`'s initializer is `<ident> - <neg^depth ident>`.
fn expectSubThenNegs(module: *const Ast.Module, name: []const u8, depth: usize) !void {
    const init = constInit(module, name) orelse {
        std.debug.print("no const named {s}\n", .{name});
        return error.MissingConst;
    };
    if (init != .binary or init.binary.op != .sub) {
        std.debug.print("{s}: expected a `sub` at the root, got .{s}\n", .{ name, @tagName(init) });
        return error.NotSubtraction;
    }
    const got = negDepth(init.binary.right);
    if (got != depth) {
        std.debug.print("{s}: expected {d} nested negations, got {d}\n", .{ name, depth, got });
        return error.WrongNegDepth;
    }
}

fn expectValid(arena: std.mem.Allocator, source: [:0]const u8) !void {
    const result = try wgslender.validateWithOptions(arena, source, .{});
    if (result.valid) return;
    for (result.diagnostics.diagnostics.items) |d| {
        if (d.severity != .@"error") continue;
        std.debug.print("unexpected error: {s} [{s}]\n", .{ d.message, d.code });
    }
    return error.UnexpectedlyInvalid;
}

// =========================================================================
// AST shape — the flat printer cannot show precedence, so assert the tree
// =========================================================================

test "minus split: `two--one` is subtraction of a negation" {
    const gpa = std.testing.allocator;
    var result = try Incremental.parseFull(gpa,
        \\const one = 1i;
        \\const two = 2i;
        \\const a = two--one;
        \\const b = two---one;
        \\const c = two----one;
        \\const d = two-----one;
    );
    defer result.deinit();

    // `two--one`      -> two - (-one)                 : 1 negation
    // `two---one`     -> two - (-(-one))              : 2 negations
    // `two----one`    -> two - (-(-(-one)))           : 3 negations
    // `two-----one`   -> two - (-(-(-(-one))))        : 4 negations
    try expectSubThenNegs(result.module, "a", 1);
    try expectSubThenNegs(result.module, "b", 2);
    try expectSubThenNegs(result.module, "c", 3);
    try expectSubThenNegs(result.module, "d", 4);
}

test "minus split: spacing does not change the parse" {
    const gpa = std.testing.allocator;
    var result = try Incremental.parseFull(gpa,
        \\const one = 1i;
        \\const two = 2i;
        \\const a = two-- - -one;
        \\const b = two - - --one;
        \\const c = two----one;
    );
    defer result.deinit();

    // All three are `two` minus three nested negations, however the minus
    // signs happen to be grouped into tokens by the lexer.
    try expectSubThenNegs(result.module, "a", 3);
    try expectSubThenNegs(result.module, "b", 3);
    try expectSubThenNegs(result.module, "c", 3);
}

// =========================================================================
// Semantics — const_assert makes the folder check our arithmetic
// =========================================================================

test "minus split: const_assert agrees with Tint's expected values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Values lifted from tint's bug/chromium/380168990.wgsl. An odd number of
    // negations yields 2-1=1, an even number yields 2+1=3.
    try expectValid(arena.allocator(),
        \\const one = 1i;
        \\const two = 2i;
        \\const_assert(two--one == 3i);
        \\const_assert(two---one == 1i);
        \\const_assert(two----one == 3i);
        \\const_assert(two-----one == 1i);
        \\const_assert(two------one == 3i);
        \\const_assert(two-------one == 1i);
        \\const_assert(two--------one == 3i);
        \\const_assert(two---------one == 1i);
        \\const_assert(two----------one == 3i);
    );
}

test "minus split: const_assert agrees across spacing variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try expectValid(arena.allocator(),
        \\const one = 1i;
        \\const two = 2i;
        \\const_assert((two-- - -one) == 3i);
        \\const_assert((two - - --one) == 3i);
        \\const_assert((two -- -- -- -- -- one) == 3i);
        \\const_assert((two-- - - - - - - --one) == 3i);
        \\const_assert((two-- - -- -- - -- one) == 3i);
        \\const_assert((two - -- -- --- - - one) == 3i);
        \\const_assert((two - -- --- ---- one) == 3i);
    );
}

test "minus split: leading unary run in a value position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // No left operand at all — the run is pure prefix negation.
    try expectValid(arena.allocator(),
        \\const one = 1i;
        \\const_assert(--one == 1i);
        \\const_assert(---one == -1i);
        \\const_assert(----one == 1i);
    );
}

// =========================================================================
// The statement forms `--` exists for must keep working
// =========================================================================

test "minus split: decrement and increment statements are untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // The two statement-tail shapes are `i--;` and `for (…; …; i--)` — the
    // `;` and `)` the binary level declines to split on.
    try expectValid(arena.allocator(),
        \\@compute @workgroup_size(1) fn m() {
        \\  var i = 5;
        \\  i--;
        \\  i++;
        \\  var j = 2 - -i;
        \\  for (var k = 0; k < 3; k++) { i--; }
        \\  for (var k = 3; k > 0; k--) { i++; }
        \\  var a = array<i32, 4>(0, 1, 2, 3);
        \\  a[i]--;
        \\}
    );
}

test "minus split: works inside a function body, not just module scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // tint/statements/decrement/split.wgsl — a `var` initializer reaches the
    // expression parser through the statement path, where `--` also has to
    // survive the statement parser's own decrement check.
    try expectValid(arena.allocator(),
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\  var b = 2;
        \\  var c = b--b;
        \\  var d = b----b;
        \\  b--;
        \\}
    );
}

test "minus split: `++` gains no unary meaning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // WGSL's unary operators are `-`, `!`, `~`, `*`, `&` — there is no unary
    // `+`, so `b++a` stays an error rather than becoming `b + (+a)`.
    const result = try wgslender.validateWithOptions(arena.allocator(),
        \\const a = 1i;
        \\const b = 2i;
        \\const c = b++a;
    , .{});
    try std.testing.expect(!result.valid);
}

// =========================================================================
// Lossless CST across the split
// =========================================================================

fn concatCst(
    gpa: std.mem.Allocator,
    tree: *const wgslender.Cst.Tree,
    buf: *std.ArrayListUnmanaged(u8),
    node_idx: wgslender.Cst.NodeIndex,
) !void {
    const n = tree.getNode(node_idx);
    for (tree.children[n.first_child .. n.first_child + n.child_count]) |el| {
        if (el.asToken()) |token| {
            const s = tree.tokens.items(.start)[token];
            const e = tree.tokens.items(.end)[token];
            try buf.appendSlice(gpa, tree.source[s..e]);
        } else if (el.asNode()) |child| {
            try concatCst(gpa, tree, buf, child);
        }
    }
}

test "minus split: source round-trips through the CST" {
    const gpa = std.testing.allocator;
    const sources = [_][]const u8{
        "const one = 1i;\nconst two = 2i;\nconst a = two--one;\n",
        "const one = 1i;\nconst two = 2i;\nconst a = two----------one;\n",
        "const one = 1i;\nconst two = 2i;\nconst a = two-- - -- -- - -- one;\n",
        "@compute @workgroup_size(1) fn m() { var i = 5; i--; }\n",
    };

    for (sources) |source| {
        var result = try Incremental.parseFull(gpa, source);
        defer result.deinit();
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(gpa);
        try concatCst(gpa, &result.cst, &buf, result.cst.root());
        try std.testing.expectEqualStrings(source, buf.items);
    }
}

// =========================================================================
// Minified output must mean the same thing
// =========================================================================

test "minus split: minified output preserves the arithmetic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: [:0]const u8 =
        \\const one = 1i;
        \\const two = 2i;
        \\const v = two----one;
        \\@fragment fn fs() -> @location(0) vec4f { return vec4f(f32(v)); }
    ;

    // Identifier renaming stays off so the appended assertion can still name
    // `v`; the point here is the printed *expression*, not the symbol table.
    const result = try wgslender.minifyWithOptions(alloc, source, .{
        .minify_identifiers = false,
        .tree_shaking = false,
    });
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);

    // Re-parse the output and assert the value is still 3, not something the
    // printer flattened into `two----one` with a different grouping.
    const round = try std.fmt.allocPrintSentinel(
        alloc,
        "{s}\nconst_assert(v == 3i);",
        .{result.code},
        0,
    );
    try expectValid(alloc, round);
}
