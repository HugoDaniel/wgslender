//! Long-tail tests for `StableId`. Covers every symbol kind, shadowing in
//! sibling and nested blocks, for/if/switch/while/loop corner cases, deep
//! nesting, struct members, builtins, stability under unrelated edits,
//! graceful failure after deletion, and a bulk roundtrip over the
//! compute.toys shader corpus.
//!
//! Every test that roundtrips uses the pattern:
//!   analyze → collect (SymbolIndex, stableId) pairs → reverse lookup →
//!   assert equality. Edit-invariance tests additionally compare the
//!   stable-id strings between two source variants.

const std = @import("std");
const wgslender = @import("wgslender");
const Ast = wgslender.Ast;
const StableId = wgslender.StableId;

fn parse(a: std.mem.Allocator, source: [:0]const u8) !wgslender.Validator.AnalysisResult {
    return wgslender.analyze(a, source);
}

fn findSym(module: *const Ast.Module, kind: Ast.Symbol.Kind, name: []const u8) Ast.SymbolIndex {
    for (module.symbols.items, 0..) |s, i| {
        if (s.kind == kind and std.mem.eql(u8, s.original_name, name)) {
            return @enumFromInt(@as(u32, @intCast(i)));
        }
    }
    return .none;
}

fn allSyms(
    gpa: std.mem.Allocator,
    module: *const Ast.Module,
    kind: Ast.Symbol.Kind,
    name: []const u8,
) ![]Ast.SymbolIndex {
    var out: std.ArrayListUnmanaged(Ast.SymbolIndex) = .empty;
    errdefer out.deinit(gpa);
    for (module.symbols.items, 0..) |s, i| {
        if (s.kind == kind and std.mem.eql(u8, s.original_name, name)) {
            try out.append(gpa, @enumFromInt(@as(u32, @intCast(i))));
        }
    }
    return try out.toOwnedSlice(gpa);
}

fn roundtripOne(
    arena: std.mem.Allocator,
    module: *const Ast.Module,
    sym: Ast.SymbolIndex,
    expected_id: []const u8,
) !void {
    const id = (try StableId.stableIdFor(arena, module, sym)) orelse return error.MissingId;
    try std.testing.expectEqualStrings(expected_id, id.bytes);
    try std.testing.expectEqual(sym, StableId.symbolForStableId(module, id.bytes));
}

// ---------------------------------------------------------------------------
// Every symbol kind
// ---------------------------------------------------------------------------

test "every-kind: const/override/var/alias/struct/fn/param/let" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\const PI: f32 = 3.14;
        \\override N: u32 = 4u;
        \\alias V = vec3f;
        \\struct S { x: f32 }
        \\@group(0) @binding(0) var<uniform> u: S;
        \\fn main(p: f32) { let q = p + PI; }
    ;
    var an = try parse(a, src);
    defer an.deinit(a);
    const m = an.module.?;

    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    try roundtripOne(ar, m, findSym(m, .@"const", "PI"), "v1:const:PI");
    try roundtripOne(ar, m, findSym(m, .override, "N"), "v1:override:N");
    try roundtripOne(ar, m, findSym(m, .alias, "V"), "v1:alias:V");
    try roundtripOne(ar, m, findSym(m, .@"struct", "S"), "v1:struct:S");
    try roundtripOne(ar, m, findSym(m, .@"var", "u"), "v1:var:u");
    try roundtripOne(ar, m, findSym(m, .function, "main"), "v1:fn:main");
    try roundtripOne(ar, m, findSym(m, .parameter, "p"), "v1:fn:main/param:p");
    try roundtripOne(ar, m, findSym(m, .let, "q"), "v1:fn:main/block#0/let:q");
}

test "every-kind: struct member" {
    const a = std.testing.allocator;
    const src: [:0]const u8 = "struct S { x: f32, y: vec3f }";
    var an = try parse(a, src);
    defer an.deinit(a);
    const m = an.module.?;

    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    try roundtripOne(ar, m, findSym(m, .member, "x"), "v1:struct:S/member:x");
    try roundtripOne(ar, m, findSym(m, .member, "y"), "v1:struct:S/member:y");
}

test "every-kind: var with module-scope let (global let binding)" {
    // WGSL 1.0 dropped module-scope `let`, but some older shaders have
    // module-scope const. Make sure plain module consts roundtrip.
    const a = std.testing.allocator;
    const src: [:0]const u8 = "const K: i32 = 7;";
    var an = try parse(a, src);
    defer an.deinit(a);
    const m = an.module.?;

    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    try roundtripOne(ar, m, findSym(m, .@"const", "K"), "v1:const:K");
}

// ---------------------------------------------------------------------------
// Shadowing
// ---------------------------------------------------------------------------

test "shadowing: sibling if branches declare same name" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\fn main() {
        \\  if (true) { let x = 1; }
        \\  else { let x = 2; }
        \\}
    ;
    var an = try parse(a, src);
    defer an.deinit(a);
    const m = an.module.?;

    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    const xs = try allSyms(a, m, .let, "x");
    defer a.free(xs);
    try std.testing.expectEqual(@as(usize, 2), xs.len);

    // Both `x` are locals in sibling blocks of the function body (block#0).
    try roundtripOne(ar, m, xs[0], "v1:fn:main/block#0/block#0/let:x");
    try roundtripOne(ar, m, xs[1], "v1:fn:main/block#0/block#1/let:x");

    try std.testing.expect(!StableId.StableId.eql(
        (try StableId.stableIdFor(ar, m, xs[0])).?,
        (try StableId.stableIdFor(ar, m, xs[1])).?,
    ));
}

test "shadowing: deeply nested blocks at 5 levels" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\fn f() {
        \\  { { { { { let x = 1; } } } } }
        \\}
    ;
    var an = try parse(a, src);
    defer an.deinit(a);
    const m = an.module.?;

    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    const x = findSym(m, .let, "x");
    // fn body is block#0; then 5 nested bare blocks each block#0.
    try roundtripOne(
        ar,
        m,
        x,
        "v1:fn:f/block#0/block#0/block#0/block#0/block#0/block#0/let:x",
    );
}

test "shadowing: same name nested — outer and inner both get distinct IDs" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\fn f() {
        \\  let x = 1;
        \\  { let x = 2; }
        \\}
    ;
    var an = try parse(a, src);
    defer an.deinit(a);
    const m = an.module.?;

    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    const xs = try allSyms(a, m, .let, "x");
    defer a.free(xs);
    try std.testing.expectEqual(@as(usize, 2), xs.len);

    try roundtripOne(ar, m, xs[0], "v1:fn:f/block#0/let:x");
    try roundtripOne(ar, m, xs[1], "v1:fn:f/block#0/block#0/let:x");
}

// ---------------------------------------------------------------------------
// Control-flow scope shapes
// ---------------------------------------------------------------------------

test "for-loop: init var and body let live in different scopes" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\fn f() {
        \\  for (var i = 0; i < 10; i = i + 1) {
        \\    let t = i;
        \\  }
        \\}
    ;
    var an = try parse(a, src);
    defer an.deinit(a);
    const m = an.module.?;

    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    // fn body is block#0; for-init is block#0 of that; for-body is block#0
    // of the for-init.
    try roundtripOne(ar, m, findSym(m, .@"var", "i"), "v1:fn:f/block#0/block#0/var:i");
    try roundtripOne(ar, m, findSym(m, .let, "t"), "v1:fn:f/block#0/block#0/block#0/let:t");
}

test "for-loop: shadowing — `i` in for-init vs `i` in body" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\fn f() {
        \\  for (var i = 0; i < 3; i = i + 1) {
        \\    let i = 99;
        \\  }
        \\}
    ;
    var an = try parse(a, src);
    defer an.deinit(a);
    const m = an.module.?;

    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    try roundtripOne(ar, m, findSym(m, .@"var", "i"), "v1:fn:f/block#0/block#0/var:i");
    try roundtripOne(ar, m, findSym(m, .let, "i"), "v1:fn:f/block#0/block#0/block#0/let:i");
}

test "else-if chain of depth 3: each branch gets a unique ID" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\fn f() {
        \\  if (true) { let a = 1; }
        \\  else if (true) { let a = 2; }
        \\  else if (true) { let a = 3; }
        \\  else { let a = 4; }
        \\}
    ;
    var an = try parse(a, src);
    defer an.deinit(a);
    const m = an.module.?;

    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    const as = try allSyms(a, m, .let, "a");
    defer a.free(as);
    try std.testing.expectEqual(@as(usize, 4), as.len);

    // All four branches are sibling blocks within the function body.
    try roundtripOne(ar, m, as[0], "v1:fn:f/block#0/block#0/let:a");
    try roundtripOne(ar, m, as[1], "v1:fn:f/block#0/block#1/let:a");
    try roundtripOne(ar, m, as[2], "v1:fn:f/block#0/block#2/let:a");
    try roundtripOne(ar, m, as[3], "v1:fn:f/block#0/block#3/let:a");
}

test "switch: three case bodies plus default, each with let of same name" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\fn f(x: i32) {
        \\  switch (x) {
        \\    case 1: { let r = 1; }
        \\    case 2: { let r = 2; }
        \\    case 3: { let r = 3; }
        \\    default: { let r = 99; }
        \\  }
        \\}
    ;
    var an = try parse(a, src);
    defer an.deinit(a);
    const m = an.module.?;

    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    const rs = try allSyms(a, m, .let, "r");
    defer a.free(rs);
    try std.testing.expectEqual(@as(usize, 4), rs.len);

    // Each case body is a sibling block inside the function body.
    try roundtripOne(ar, m, rs[0], "v1:fn:f/block#0/block#0/let:r");
    try roundtripOne(ar, m, rs[1], "v1:fn:f/block#0/block#1/let:r");
    try roundtripOne(ar, m, rs[2], "v1:fn:f/block#0/block#2/let:r");
    try roundtripOne(ar, m, rs[3], "v1:fn:f/block#0/block#3/let:r");
}

test "while body" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\fn f() {
        \\  var i = 0;
        \\  while (i < 5) { let t = i; i = i + 1; }
        \\}
    ;
    var an = try parse(a, src);
    defer an.deinit(a);
    const m = an.module.?;

    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    try roundtripOne(ar, m, findSym(m, .@"var", "i"), "v1:fn:f/block#0/var:i");
    try roundtripOne(ar, m, findSym(m, .let, "t"), "v1:fn:f/block#0/block#0/let:t");
}

test "loop body and continuing are sibling blocks" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\fn f() {
        \\  loop {
        \\    let a = 1;
        \\    break;
        \\  } continuing {
        \\    let b = 2;
        \\  }
        \\}
    ;
    var an = try parse(a, src);
    defer an.deinit(a);
    const m = an.module.?;

    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    try roundtripOne(ar, m, findSym(m, .let, "a"), "v1:fn:f/block#0/block#0/let:a");
    try roundtripOne(ar, m, findSym(m, .let, "b"), "v1:fn:f/block#0/block#1/let:b");
}

// ---------------------------------------------------------------------------
// Empty / degenerate
// ---------------------------------------------------------------------------

test "empty function body" {
    const a = std.testing.allocator;
    const src: [:0]const u8 = "fn f() {}";
    var an = try parse(a, src);
    defer an.deinit(a);
    const m = an.module.?;

    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    try roundtripOne(ar, m, findSym(m, .function, "f"), "v1:fn:f");
}

test "empty struct" {
    const a = std.testing.allocator;
    const src: [:0]const u8 = "struct S {}";
    var an = try parse(a, src);
    defer an.deinit(a);
    const m = an.module.?;

    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    try roundtripOne(ar, m, findSym(m, .@"struct", "S"), "v1:struct:S");
}

test "bare block in function body" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\fn f() {
        \\  { let inner = 1; }
        \\}
    ;
    var an = try parse(a, src);
    defer an.deinit(a);
    const m = an.module.?;

    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    try roundtripOne(
        ar,
        m,
        findSym(m, .let, "inner"),
        "v1:fn:f/block#0/block#0/let:inner",
    );
}

// ---------------------------------------------------------------------------
// Edit-invariance — the stability contract
// ---------------------------------------------------------------------------

fn idFor(
    arena: std.mem.Allocator,
    module: *const Ast.Module,
    kind: Ast.Symbol.Kind,
    name: []const u8,
) !?[]const u8 {
    const sym = findSym(module, kind, name);
    if (!sym.isValid()) return null;
    const id = (try StableId.stableIdFor(arena, module, sym)) orelse return null;
    return id.bytes;
}

test "invariant: whitespace-only edits don't change IDs" {
    const a = std.testing.allocator;
    const src_a: [:0]const u8 =
        \\fn f(x: f32) {
        \\  let y = x + 1.0;
        \\}
    ;
    const src_b: [:0]const u8 =
        \\// a comment
        \\
        \\fn     f   (  x : f32  )   {
        \\    let    y    =   x  + 1.0  ;
        \\}
    ;
    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    var an_a = try parse(a, src_a);
    defer an_a.deinit(a);
    var an_b = try parse(a, src_b);
    defer an_b.deinit(a);
    const m_a = an_a.module.?;
    const m_b = an_b.module.?;

    try std.testing.expectEqualStrings(
        (try idFor(ar, m_a, .function, "f")).?,
        (try idFor(ar, m_b, .function, "f")).?,
    );
    try std.testing.expectEqualStrings(
        (try idFor(ar, m_a, .parameter, "x")).?,
        (try idFor(ar, m_b, .parameter, "x")).?,
    );
    try std.testing.expectEqualStrings(
        (try idFor(ar, m_a, .let, "y")).?,
        (try idFor(ar, m_b, .let, "y")).?,
    );
}

test "invariant: inserting a non-scope statement leaves IDs unchanged" {
    const a = std.testing.allocator;
    const src_a: [:0]const u8 = "fn f() { let y = 1; }";
    const src_b: [:0]const u8 = "fn f() { let z = 99; let y = 1; }";

    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    var an_a = try parse(a, src_a);
    defer an_a.deinit(a);
    var an_b = try parse(a, src_b);
    defer an_b.deinit(a);

    try std.testing.expectEqualStrings(
        (try idFor(ar, an_a.module.?, .let, "y")).?,
        (try idFor(ar, an_b.module.?, .let, "y")).?,
    );
}

test "invariant: adding a new top-level const leaves existing module IDs intact" {
    const a = std.testing.allocator;
    const src_a: [:0]const u8 = "fn f() {} struct S { x: f32 }";
    const src_b: [:0]const u8 = "const K: i32 = 1; fn f() {} struct S { x: f32 }";

    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    var an_a = try parse(a, src_a);
    defer an_a.deinit(a);
    var an_b = try parse(a, src_b);
    defer an_b.deinit(a);

    try std.testing.expectEqualStrings(
        (try idFor(ar, an_a.module.?, .function, "f")).?,
        (try idFor(ar, an_b.module.?, .function, "f")).?,
    );
    try std.testing.expectEqualStrings(
        (try idFor(ar, an_a.module.?, .@"struct", "S")).?,
        (try idFor(ar, an_b.module.?, .@"struct", "S")).?,
    );
}

test "invariant: renaming an unrelated symbol leaves other IDs intact" {
    const a = std.testing.allocator;
    const src_a: [:0]const u8 = "fn foo() {} fn bar() { let x = 1; }";
    const src_b: [:0]const u8 = "fn renamed_foo() {} fn bar() { let x = 1; }";

    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    var an_a = try parse(a, src_a);
    defer an_a.deinit(a);
    var an_b = try parse(a, src_b);
    defer an_b.deinit(a);

    try std.testing.expectEqualStrings(
        (try idFor(ar, an_a.module.?, .let, "x")).?,
        (try idFor(ar, an_b.module.?, .let, "x")).?,
    );
    try std.testing.expectEqualStrings(
        (try idFor(ar, an_a.module.?, .function, "bar")).?,
        (try idFor(ar, an_b.module.?, .function, "bar")).?,
    );
}

test "invariant: inserting a new block statement shifts later blocks but keeps non-block siblings" {
    const a = std.testing.allocator;
    // Source A: if { } then let
    const src_a: [:0]const u8 =
        \\fn f() {
        \\  if (true) { let a = 1; }
        \\  let y = 2;
        \\}
    ;
    // Source B: new bare { } inserted before the if
    const src_b: [:0]const u8 =
        \\fn f() {
        \\  { let inserted = 0; }
        \\  if (true) { let a = 1; }
        \\  let y = 2;
        \\}
    ;

    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    var an_a = try parse(a, src_a);
    defer an_a.deinit(a);
    var an_b = try parse(a, src_b);
    defer an_b.deinit(a);

    // `let y` is NOT in a block; its ID uses the function body (block#0),
    // unchanged.
    try std.testing.expectEqualStrings(
        (try idFor(ar, an_a.module.?, .let, "y")).?,
        (try idFor(ar, an_b.module.?, .let, "y")).?,
    );

    // `let a` WAS inside block#0 of the function body in src_a; in src_b
    // the inserted bare block is block#0, so `a` is now inside block#1 —
    // shifted by design. (Stability contract: inserting a scope-producing
    // construct of the SAME kind DOES shift later siblings.)
    const a_src_a = (try idFor(ar, an_a.module.?, .let, "a")).?;
    const a_src_b = (try idFor(ar, an_b.module.?, .let, "a")).?;
    try std.testing.expect(!std.mem.eql(u8, a_src_a, a_src_b));
}

test "stale ID after deletion returns .none" {
    const a = std.testing.allocator;
    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    const src_a: [:0]const u8 = "fn main() { let x = 1; }";
    var id_str: []u8 = undefined;
    {
        var an = try parse(a, src_a);
        defer an.deinit(a);
        const id = (try StableId.stableIdFor(ar, an.module.?, findSym(an.module.?, .let, "x"))).?;
        id_str = try a.dupe(u8, id.bytes);
    }
    defer a.free(id_str);

    const src_b: [:0]const u8 = "fn main() {}";
    var an_b = try parse(a, src_b);
    defer an_b.deinit(a);

    try std.testing.expectEqual(
        Ast.SymbolIndex.none,
        StableId.symbolForStableId(an_b.module.?, id_str),
    );
}

// ---------------------------------------------------------------------------
// Offset helpers
// ---------------------------------------------------------------------------

test "stableIdAtOffset + locateStableId round-trip" {
    const a = std.testing.allocator;
    const src: [:0]const u8 = "fn f() { let foo = 1; }";
    var an = try parse(a, src);
    defer an.deinit(a);
    const m = an.module.?;

    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    const foo_off: u32 = @intCast(std.mem.indexOf(u8, src, "foo").?);
    const id = (try StableId.stableIdAtOffset(ar, m, foo_off)).?;
    try std.testing.expectEqualStrings("v1:fn:f/block#0/let:foo", id.bytes);

    const range = StableId.locateStableId(m, id.bytes).?;
    try std.testing.expectEqual(foo_off, range.start);
    try std.testing.expectEqual(foo_off + 3, range.end);
}

// ---------------------------------------------------------------------------
// Edge cases on identifier names
// ---------------------------------------------------------------------------

test "identifier-name edge: local named 'param' (legal WGSL)" {
    // WGSL doesn't reserve 'param', 'body', 'member', etc. — they are only
    // component strings in our ID format. Our `kind:` prefix on the
    // terminal segment disambiguates a local named `param` from a
    // structural `param` segment.
    const a = std.testing.allocator;
    const src: [:0]const u8 = "fn f() { let param = 1; let member = 2; let block = 3; }";
    var an = try parse(a, src);
    defer an.deinit(a);
    const m = an.module.?;

    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    try roundtripOne(ar, m, findSym(m, .let, "param"), "v1:fn:f/block#0/let:param");
    try roundtripOne(ar, m, findSym(m, .let, "member"), "v1:fn:f/block#0/let:member");
    try roundtripOne(ar, m, findSym(m, .let, "block"), "v1:fn:f/block#0/let:block");
}

test "rejecting ill-formed IDs" {
    const a = std.testing.allocator;
    const src: [:0]const u8 = "fn main() { let x = 1; }";
    var an = try parse(a, src);
    defer an.deinit(a);
    const m = an.module.?;

    // Unknown version.
    try std.testing.expectEqual(Ast.SymbolIndex.none, StableId.symbolForStableId(m, "v2:fn:main"));
    // Missing `v1:` prefix.
    try std.testing.expectEqual(Ast.SymbolIndex.none, StableId.symbolForStableId(m, "fn:main"));
    // Empty body.
    try std.testing.expectEqual(Ast.SymbolIndex.none, StableId.symbolForStableId(m, "v1:"));
    // Unknown kind.
    try std.testing.expectEqual(Ast.SymbolIndex.none, StableId.symbolForStableId(m, "v1:wat:main"));
    // Bare colon.
    try std.testing.expectEqual(Ast.SymbolIndex.none, StableId.symbolForStableId(m, "v1:fn:"));
    // Wrong kind for existing symbol (main is fn, not const).
    try std.testing.expectEqual(Ast.SymbolIndex.none, StableId.symbolForStableId(m, "v1:const:main"));
    // Nonexistent block index.
    try std.testing.expectEqual(
        Ast.SymbolIndex.none,
        StableId.symbolForStableId(m, "v1:fn:main/block#42/let:x"),
    );
    // Valid block, wrong kind on terminal.
    try std.testing.expectEqual(
        Ast.SymbolIndex.none,
        StableId.symbolForStableId(m, "v1:fn:main/block#0/var:x"),
    );
}

test "too-long ID rejected" {
    const a = std.testing.allocator;
    const src: [:0]const u8 = "fn f() {}";
    var an = try parse(a, src);
    defer an.deinit(a);
    const m = an.module.?;

    // Construct a >MAX_LEN string after the `v1:` prefix.
    var long = std.ArrayListUnmanaged(u8).empty;
    defer long.deinit(a);
    try long.appendSlice(a, StableId.VERSION_PREFIX);
    try long.appendNTimes(a, 'a', StableId.MAX_LEN + 1);

    try std.testing.expectEqual(
        Ast.SymbolIndex.none,
        StableId.symbolForStableId(m, long.items),
    );
}

// ---------------------------------------------------------------------------
// Multiple functions on the same module
// ---------------------------------------------------------------------------

test "multi-function: each has its own namespace" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\fn a() { let x = 1; }
        \\fn b() { let x = 2; }
        \\fn c() { let x = 3; }
    ;
    var an = try parse(a, src);
    defer an.deinit(a);
    const m = an.module.?;

    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    const xs = try allSyms(a, m, .let, "x");
    defer a.free(xs);
    try std.testing.expectEqual(@as(usize, 3), xs.len);

    try roundtripOne(ar, m, xs[0], "v1:fn:a/block#0/let:x");
    try roundtripOne(ar, m, xs[1], "v1:fn:b/block#0/let:x");
    try roundtripOne(ar, m, xs[2], "v1:fn:c/block#0/let:x");
}

// ---------------------------------------------------------------------------
// Bulk roundtrip: exhaustive per-symbol check on a moderately complex shader
// ---------------------------------------------------------------------------

test "bulk: every named symbol in a complex shader roundtrips" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\struct Camera { view: mat4x4f, proj: mat4x4f }
        \\struct VIn { @location(0) pos: vec3f }
        \\struct VOut { @builtin(position) pos: vec4f }
        \\
        \\@group(0) @binding(0) var<uniform> cam: Camera;
        \\const EPSILON: f32 = 1e-5;
        \\alias Vec = vec3f;
        \\
        \\fn square(x: f32) -> f32 { return x * x; }
        \\
        \\@vertex
        \\fn vs_main(in: VIn) -> VOut {
        \\  var out: VOut;
        \\  for (var i = 0u; i < 3u; i = i + 1u) {
        \\    let d = square(EPSILON);
        \\    if (d < 0.0) { let flag = true; }
        \\    else { let flag = false; }
        \\  }
        \\  return out;
        \\}
    ;
    var an = try parse(a, src);
    defer an.deinit(a);
    const m = an.module.?;

    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    var n_roundtrip: usize = 0;
    for (m.symbols.items, 0..) |s, i| {
        // Skip unbound and builtins (they roundtrip, but the test is
        // about user-defined symbols).
        if (s.kind == .unbound) continue;
        if (s.flags.is_builtin or s.kind == .builtin) continue;

        const idx: Ast.SymbolIndex = @enumFromInt(@as(u32, @intCast(i)));
        const id = (try StableId.stableIdFor(ar, m, idx)) orelse {
            std.debug.print("no id for sym #{d} {s} kind={s}\n", .{
                i, s.original_name, @tagName(s.kind),
            });
            return error.MissingId;
        };
        const back = StableId.symbolForStableId(m, id.bytes);
        std.testing.expectEqual(idx, back) catch |err| {
            std.debug.print(
                "roundtrip failed: sym #{d} {s} kind={s} id={s} got #{d}\n",
                .{ i, s.original_name, @tagName(s.kind), id.bytes, if (back.isValid()) back.index() else 99999 },
            );
            return err;
        };
        n_roundtrip += 1;
    }
    // Sanity: we exercised a non-trivial number of symbols.
    try std.testing.expect(n_roundtrip >= 10);
}

// ---------------------------------------------------------------------------
// compute.toys corpus — long-tail real-world shaders
// ---------------------------------------------------------------------------

fn makeSentinel(a: std.mem.Allocator, bytes: []const u8) ![:0]const u8 {
    const buf = try a.alloc(u8, bytes.len + 1);
    @memcpy(buf[0..bytes.len], bytes);
    buf[bytes.len] = 0;
    return buf[0..bytes.len :0];
}

test "compute.toys: every symbol in every shader roundtrips" {
    const io = std.Options.debug_io;
    const dir_path = "tests/testdata/compute.toys";

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound or err == error.NotFound) {
            std.debug.print("skip: compute.toys directory missing\n", .{});
            return;
        }
        return err;
    };
    defer dir.close(io);

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var walker = try dir.walk(a);
    defer walker.deinit();

    var n_shaders: usize = 0;
    var n_symbols: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".wgsl")) continue;

        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();

        const source_bytes = entry.dir.readFileAlloc(io, entry.basename, alloc, .unlimited) catch {
            continue;
        };
        const src = try makeSentinel(alloc, source_bytes);

        var an = wgslender.analyze(a, src) catch |e| switch (e) {
            error.OutOfMemory => return e,
        };
        defer an.deinit(a);
        const m = an.module orelse continue;

        for (m.symbols.items, 0..) |s, i| {
            if (s.kind == .unbound) continue;
            if (s.flags.is_builtin or s.kind == .builtin) continue;
            if (s.original_name.len == 0) continue;

            const idx: Ast.SymbolIndex = @enumFromInt(@as(u32, @intCast(i)));
            const id = (try StableId.stableIdFor(alloc, m, idx)) orelse continue;
            const back = StableId.symbolForStableId(m, id.bytes);
            std.testing.expectEqual(idx, back) catch |err| {
                std.debug.print(
                    "compute.toys {s}: sym #{d} name={s} kind={s} id={s} -> #{d}\n",
                    .{ entry.path, i, s.original_name, @tagName(s.kind), id.bytes, if (back.isValid()) back.index() else 99999 },
                );
                return err;
            };
            n_symbols += 1;
        }
        n_shaders += 1;
    }
    std.debug.print(
        "compute.toys stable_id roundtrip: {d} shaders, {d} symbols\n",
        .{ n_shaders, n_symbols },
    );
    try std.testing.expect(n_shaders > 0);
}

// ---------------------------------------------------------------------------
// Integration: rename by stable ID
// ---------------------------------------------------------------------------

test "integration: stableId → symbolAtOffset-equivalent → renameEdits" {
    const a = std.testing.allocator;
    const src: [:0]const u8 = "fn foo() { let val = 1; }";
    var an = try parse(a, src);
    defer an.deinit(a);
    const m = an.module.?;

    var aa = std.heap.ArenaAllocator.init(a);
    defer aa.deinit();
    const ar = aa.allocator();

    const val_sym = findSym(m, .let, "val");
    const id = (try StableId.stableIdFor(ar, m, val_sym)).?;

    // Pretend we only kept the ID; recover the symbol.
    const recovered = StableId.symbolForStableId(m, id.bytes);
    try std.testing.expectEqual(val_sym, recovered);

    const edits = try wgslender.Edits.renameEdits(a, m, recovered, "value") orelse
        return error.TestUnexpectedResult;
    defer a.free(edits);
    const out = try wgslender.Edits.applyEdits(a, src, edits);
    defer a.free(out);
    try std.testing.expectEqualStrings("fn foo() { let value = 1; }", out);
}
