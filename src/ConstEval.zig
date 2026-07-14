//! Constant-expression evaluator.
//!
//! One recursive interpreter for WGSL const-expressions, shared by the
//! Reflect layout computer (array sizes / `@workgroup_size` args / attribute
//! values) and — from `docs/deferred/consteval-extraction.md` Block C2 — the
//! Validator's `tryExtractIntValue` family. Before this module the two
//! consumers each carried their own evaluator with divergent semantics; the
//! divergences they must reconcile are parameters here, not forks:
//!
//!   * **Value domain** — `Value` carries the full `{int, float, bool}`
//!     domain (lifted verbatim from Reflect's old `ConstValue`). Callers that
//!     only want integers narrow the result with `Value.toI64`.
//!   * **Overflow** — `OverflowMode` selects `saturate` (the Validator's old
//!     `+|`), `wrap` (Reflect's old `+%`), or `checked` (§11: overflow →
//!     `null`). `mode` is comptime, so the arithmetic ops specialize with
//!     zero runtime dispatch and each caller's code path stays branch-identical
//!     to its pre-extraction form.
//!   * **Identifier / member resolution** — deliberately *not* baked in.
//!     `eval` takes a `resolver` (`anytype`) that owns the resolution context:
//!     the Validator's is an eager lookup into its precomputed `const_values`
//!     map; Reflect's is a lazy, memoized, cycle-breaking walk over module
//!     declarations. Keeping them separate preserves the "two different
//!     resolution contexts" the original deferred note identified. The module
//!     imports only `std` / `Ast` / `constants` and never Reflect or Validator
//!     — they import it, and the `anytype` resolver breaks the cycle (same
//!     trick `src/options.zig` uses to target the Minifier).
//!
//! The resolver must expose:
//!
//!   fn resolveIdent(self, ref: Ast.SymbolIndex) ?Value
//!   fn resolveMember(self, m: *Ast.MemberExpr, depth: u32) ?Value
//!
//! `resolveIdent` maps a bound symbol reference to its const value (or `null`
//! when the symbol is not a const-evaluable declaration). `resolveMember`
//! handles `a.x` on a const whose initializer is a struct constructor; it
//! recurses back into `eval` for the selected field, so it needs the owner's
//! declaration + naming context. A resolver that supports neither returns
//! `null` from both (see the freestanding literal-only use in the Validator).
//!
//! Characterization pins for the two consumers' observable behavior live in
//! `tests/const_eval_test.zig`.

const std = @import("std");
const Ast = @import("Ast.zig");
const constants = @import("constants.zig");

/// A folded const-expression value. Mirrors the WGSL const-expression domain
/// closely enough to evaluate the forms that reach layout / validation:
/// integer arithmetic, floating-point arithmetic (only meaningful when it
/// flows back through a cast to an integer, e.g. `u32(sin(radians(90)) + 3)`),
/// and the boolean intermediates of comparisons / logical negation.
pub const Value = union(enum) {
    int: i64,
    float: f64,
    bool: bool,

    /// Narrow to an `i64`, truncating a finite float toward zero. Returns
    /// `null` for a non-finite float (the caller cannot use NaN/±inf as an
    /// integer). `bool` maps to 0/1.
    pub fn toI64(self: Value) ?i64 {
        return switch (self) {
            .int => |v| v,
            .float => |v| if (std.math.isFinite(v)) @intFromFloat(@trunc(v)) else null,
            .bool => |v| @intFromBool(v),
        };
    }

    /// Widen to an `f64` (the promotion used by mixed int/float arithmetic).
    pub fn toF64(self: Value) f64 {
        return switch (self) {
            .int => |v| @floatFromInt(v),
            .float => |v| v,
            .bool => |v| if (v) 1.0 else 0.0,
        };
    }

    /// Narrow to an `i64` *only* when this value is exactly an `.int`. Unlike
    /// `toI64`, a `.float` or `.bool` folds to `null` — it does NOT coerce.
    /// This is the Validator's narrowing: its historical `tryExtractIntValue`
    /// never produced a value from a float literal or a comparison result, so
    /// the shared evaluator's richer domain is filtered back to int-only here.
    pub fn asInt(self: Value) ?i64 {
        return switch (self) {
            .int => |v| v,
            else => null,
        };
    }

    /// Narrow to a `bool` *only* when this value is exactly a `.bool` (the
    /// Validator's `const_assert` path — `tryEvalConstBool`). A `.int`/`.float`
    /// folds to `null`.
    pub fn asBool(self: Value) ?bool {
        return switch (self) {
            .bool => |v| v,
            else => null,
        };
    }
};

/// How integer arithmetic (`+`, `-`, `*`, unary `-`, `abs`) behaves on
/// overflow. Selected at comptime by each caller so there is no runtime
/// dispatch and the specialized code path matches the caller's pre-extraction
/// semantics exactly.
pub const OverflowMode = enum {
    /// Clamp to the i64 bound (`+|`, `-|`, `*|`). The Validator's semantics.
    saturate,
    /// Two's-complement wraparound (`+%`, `-%`, `*%`). Reflect's semantics.
    wrap,
    /// WGSL §11: overflow makes the whole expression un-evaluable (`null`).
    /// The resolver's `onOverflow` hook (a later block) turns that into a
    /// diagnostic; here it just fails the fold.
    checked,
};

/// Which expression forms the evaluator will fold. Selected at comptime by the
/// entry point (`eval` vs `evalIntOnly`), so each caller's reachable code paths
/// specialize with zero runtime dispatch.
const Feature = enum {
    /// The whole domain — casts (`u32(...)`), float builtins (`sin`), float
    /// arithmetic, struct-member access. Reflect's layout interpreter.
    full,
    /// The Validator's historical `tryExtractIntValue` reach: integer
    /// arithmetic / bitwise / shift over literals + resolved const idents,
    /// plus integer comparisons (for `const_assert`). No `.call` folding and
    /// no mixed-domain (float / bool-operand) binaries — those stay
    /// un-evaluable so the migrated Validator paths remain byte-identical.
    int_only,
};

// Only add/sub/mul (and the negations built on sub) differ by mode; every
// other integer op (bitwise, shift, div, mod) is overflow-neutral and stays
// identical across modes.

fn addInt(comptime mode: OverflowMode, a: i64, b: i64) ?i64 {
    return switch (mode) {
        .saturate => a +| b,
        .wrap => a +% b,
        .checked => blk: {
            const r = @addWithOverflow(a, b);
            break :blk if (r[1] == 1) null else r[0];
        },
    };
}

fn subInt(comptime mode: OverflowMode, a: i64, b: i64) ?i64 {
    return switch (mode) {
        .saturate => a -| b,
        .wrap => a -% b,
        .checked => blk: {
            const r = @subWithOverflow(a, b);
            break :blk if (r[1] == 1) null else r[0];
        },
    };
}

fn mulInt(comptime mode: OverflowMode, a: i64, b: i64) ?i64 {
    return switch (mode) {
        .saturate => a *| b,
        .wrap => a *% b,
        .checked => blk: {
            const r = @mulWithOverflow(a, b);
            break :blk if (r[1] == 1) null else r[0];
        },
    };
}

/// Wrap an `?i64` arithmetic result as a `?Value` — `null` (checked overflow)
/// propagates as an un-evaluable expression.
fn intVal(x: ?i64) ?Value {
    return if (x) |v| Value{ .int = v } else null;
}

/// Evaluate `expr` to a `Value`, or `null` when it is not a const-expression
/// or evaluation fails (overflow under `.checked`, div/mod by zero, an
/// out-of-range shift, an unresolved identifier, …). Recursion is capped at
/// `constants.max_const_eval_depth` to guard pathological ASTs.
///
/// `resolver` supplies identifier / member resolution; `mode` selects integer
/// overflow behavior. Both are comptime-friendly: `resolver` is `anytype` and
/// `mode` a comptime enum.
pub fn eval(resolver: anytype, comptime mode: OverflowMode, expr: Ast.Expr, depth: u32) ?Value {
    return evalImpl(resolver, mode, .full, expr, depth);
}

/// Integer-domain subset of `eval` — the Validator's `tryExtractIntValue`
/// reach. Folds integer arithmetic / bitwise / shift over literals and
/// resolver-supplied const idents (and integer comparisons → `.bool`, for the
/// `const_assert` path), but never `.call`s and never mixed float/bool-operand
/// binaries. Narrow the result with `Value.asInt` (int context) or
/// `Value.asBool` (const_assert). Byte-identical to the pre-extraction
/// extractor modulo the unified depth cap (32 → `max_const_eval_depth`).
pub fn evalIntOnly(resolver: anytype, comptime mode: OverflowMode, expr: Ast.Expr, depth: u32) ?Value {
    return evalImpl(resolver, mode, .int_only, expr, depth);
}

fn evalImpl(resolver: anytype, comptime mode: OverflowMode, comptime feat: Feature, expr: Ast.Expr, depth: u32) ?Value {
    if (depth > constants.max_const_eval_depth) return null;
    return switch (expr) {
        .literal => |lit| evalLiteral(lit),
        .paren => |p| evalImpl(resolver, mode, feat, p.expr, depth + 1),
        .unary => |u| evalUnary(resolver, mode, feat, u, depth),
        .binary => |b| evalBinary(resolver, mode, feat, b, depth + 1),
        .ident => |id| resolver.resolveIdent(id.ref),
        .call => |c| if (feat == .int_only) null else evalCall(resolver, mode, c, depth + 1),
        .member => |m| resolver.resolveMember(m, depth + 1),
        else => null,
    };
}

fn evalUnary(resolver: anytype, comptime mode: OverflowMode, comptime feat: Feature, u: *Ast.UnaryExpr, depth: u32) ?Value {
    const v = evalImpl(resolver, mode, feat, u.operand, depth + 1) orelse return null;
    return switch (u.op) {
        .neg => switch (v) {
            .int => |x| intVal(subInt(mode, 0, x)),
            .float => |x| Value{ .float = -x },
            .bool => null,
        },
        .bit_not => switch (v) {
            .int => |x| Value{ .int = ~x },
            else => null,
        },
        .not => switch (v) {
            .bool => |x| Value{ .bool = !x },
            else => null,
        },
        else => null,
    };
}

fn evalBinary(resolver: anytype, comptime mode: OverflowMode, comptime feat: Feature, b: *Ast.BinaryExpr, depth: u32) ?Value {
    const l = evalImpl(resolver, mode, feat, b.left, depth) orelse return null;
    const r = evalImpl(resolver, mode, feat, b.right, depth) orelse return null;
    // Both-integer path: exact integer semantics.
    const both_int = l == .int and r == .int;
    if (both_int) {
        const li = l.int;
        const ri = r.int;
        return switch (b.op) {
            .add => intVal(addInt(mode, li, ri)),
            .sub => intVal(subInt(mode, li, ri)),
            .mul => intVal(mulInt(mode, li, ri)),
            .div => if (ri == 0) null else .{ .int = @divTrunc(li, ri) },
            .mod => if (ri == 0) null else .{ .int = @mod(li, ri) },
            .@"and" => .{ .int = li & ri },
            .@"or" => .{ .int = li | ri },
            .xor => .{ .int = li ^ ri },
            .shl => if (ri >= 0 and ri < 64) .{ .int = li << @intCast(ri) } else null,
            .shr => if (ri >= 0 and ri < 64) .{ .int = li >> @intCast(ri) } else null,
            .eq => .{ .bool = li == ri },
            .ne => .{ .bool = li != ri },
            .lt => .{ .bool = li < ri },
            .le => .{ .bool = li <= ri },
            .gt => .{ .bool = li > ri },
            .ge => .{ .bool = li >= ri },
            .logical_and, .logical_or => null,
        };
    }
    // int_only never reaches a non-both-int binary: float literals and casts
    // are already gone, so a non-int operand here is a nested comparison/`.not`
    // result — which the pre-extraction extractor folded to `null`. Match it.
    if (feat == .int_only) return null;
    // Bitwise / shift / mod ops require integer operands.
    switch (b.op) {
        .@"and", .@"or", .xor, .shl, .shr, .mod => return null,
        else => {},
    }
    const lf = l.toF64();
    const rf = r.toF64();
    return switch (b.op) {
        .add => .{ .float = lf + rf },
        .sub => .{ .float = lf - rf },
        .mul => .{ .float = lf * rf },
        .div => if (rf == 0) null else .{ .float = lf / rf },
        .eq => .{ .bool = lf == rf },
        .ne => .{ .bool = lf != rf },
        .lt => .{ .bool = lf < rf },
        .le => .{ .bool = lf <= rf },
        .gt => .{ .bool = lf > rf },
        .ge => .{ .bool = lf >= rf },
        else => null,
    };
}

fn evalCall(resolver: anytype, comptime mode: OverflowMode, c: *Ast.CallExpr, depth: u32) ?Value {
    const func = c.func orelse return null;
    const callee_name = switch (func) {
        .ident => |i| i.name,
        else => return null,
    };

    // Constructor casts to scalar types — convert the single argument.
    if (c.args.items.len == 1) {
        const arg = eval(resolver, mode, c.args.items[0], depth) orelse return null;
        if (std.mem.eql(u8, callee_name, "u32") or
            std.mem.eql(u8, callee_name, "i32"))
        {
            const v = arg.toI64() orelse return null;
            return .{ .int = v };
        }
        if (std.mem.eql(u8, callee_name, "f32") or
            std.mem.eql(u8, callee_name, "f16"))
        {
            return .{ .float = arg.toF64() };
        }
        if (std.mem.eql(u8, callee_name, "bool")) {
            return switch (arg) {
                .int => |v| Value{ .bool = v != 0 },
                .float => |v| Value{ .bool = v != 0.0 },
                .bool => arg,
            };
        }
    }

    // Const-evaluable builtin functions.
    if (std.mem.eql(u8, callee_name, "radians") and c.args.items.len == 1) {
        const a = eval(resolver, mode, c.args.items[0], depth) orelse return null;
        return .{ .float = a.toF64() * std.math.pi / 180.0 };
    }
    if (std.mem.eql(u8, callee_name, "degrees") and c.args.items.len == 1) {
        const a = eval(resolver, mode, c.args.items[0], depth) orelse return null;
        return .{ .float = a.toF64() * 180.0 / std.math.pi };
    }
    if (c.args.items.len == 1) {
        const a = eval(resolver, mode, c.args.items[0], depth) orelse return null;
        // `abs` preserves int vs float kind.
        if (std.mem.eql(u8, callee_name, "abs")) {
            return switch (a) {
                .int => |v| if (v < 0) intVal(subInt(mode, 0, v)) else Value{ .int = v },
                .float => |v| Value{ .float = @abs(v) },
                .bool => null,
            };
        }
        const f = a.toF64();
        const single_arg_builtins = std.StaticStringMap(*const fn (f64) f64).initComptime(.{
            .{ "sin", &builtinSin },
            .{ "cos", &builtinCos },
            .{ "tan", &builtinTan },
            .{ "asin", &builtinAsin },
            .{ "acos", &builtinAcos },
            .{ "atan", &builtinAtan },
            .{ "floor", &builtinFloor },
            .{ "ceil", &builtinCeil },
            .{ "round", &builtinRound },
            .{ "trunc", &builtinTrunc },
            .{ "sqrt", &builtinSqrt },
            .{ "exp", &builtinExp },
            .{ "log", &builtinLog },
        });
        if (single_arg_builtins.get(callee_name)) |fp| {
            return .{ .float = fp(f) };
        }
    }
    if (c.args.items.len == 2) {
        const a = eval(resolver, mode, c.args.items[0], depth) orelse return null;
        const b = eval(resolver, mode, c.args.items[1], depth) orelse return null;
        if (std.mem.eql(u8, callee_name, "min")) {
            if (a == .int and b == .int) return .{ .int = @min(a.int, b.int) };
            return .{ .float = @min(a.toF64(), b.toF64()) };
        }
        if (std.mem.eql(u8, callee_name, "max")) {
            if (a == .int and b == .int) return .{ .int = @max(a.int, b.int) };
            return .{ .float = @max(a.toF64(), b.toF64()) };
        }
        if (std.mem.eql(u8, callee_name, "pow")) {
            return .{ .float = std.math.pow(f64, a.toF64(), b.toF64()) };
        }
    }
    if (c.args.items.len == 3 and std.mem.eql(u8, callee_name, "clamp")) {
        const x = eval(resolver, mode, c.args.items[0], depth) orelse return null;
        const lo = eval(resolver, mode, c.args.items[1], depth) orelse return null;
        const hi = eval(resolver, mode, c.args.items[2], depth) orelse return null;
        if (x == .int and lo == .int and hi == .int) {
            return .{ .int = @max(lo.int, @min(hi.int, x.int)) };
        }
        return .{ .float = @max(lo.toF64(), @min(hi.toF64(), x.toF64())) };
    }

    return null;
}

// -------------------------------------------------------------------------
// Literal parsing
// -------------------------------------------------------------------------

fn evalLiteral(lit: *Ast.LiteralExpr) ?Value {
    if (lit.value.len == 0) return null;
    return switch (lit.kind) {
        .int_literal => parseIntLiteral(lit.value),
        .float_literal => parseFloatLiteral(lit.value),
        .true_literal => .{ .bool = true },
        .false_literal => .{ .bool = false },
        else => null,
    };
}

pub fn parseIntLiteral(s: []const u8) ?Value {
    var v = s;
    if (v.len == 0) return null;
    if (v[v.len - 1] == 'i' or v[v.len - 1] == 'u') v = v[0 .. v.len - 1];
    const i = std.fmt.parseInt(i64, v, 0) catch return null;
    return .{ .int = i };
}

pub fn parseFloatLiteral(s: []const u8) ?Value {
    var v = s;
    if (v.len == 0) return null;
    // Strip suffixes: f32 = 'f', f16 = 'h'.
    if (v[v.len - 1] == 'f' or v[v.len - 1] == 'h') v = v[0 .. v.len - 1];
    const f = std.fmt.parseFloat(f64, v) catch return null;
    return .{ .float = f };
}

// f64 wrappers for std.math functions so they can be held in a comptime map.

fn builtinSin(x: f64) f64 {
    return std.math.sin(x);
}
fn builtinCos(x: f64) f64 {
    return std.math.cos(x);
}
fn builtinTan(x: f64) f64 {
    return std.math.tan(x);
}
fn builtinAsin(x: f64) f64 {
    return std.math.asin(x);
}
fn builtinAcos(x: f64) f64 {
    return std.math.acos(x);
}
fn builtinAtan(x: f64) f64 {
    return std.math.atan(x);
}
fn builtinFloor(x: f64) f64 {
    return @floor(x);
}
fn builtinCeil(x: f64) f64 {
    return @ceil(x);
}
fn builtinRound(x: f64) f64 {
    return @round(x);
}
fn builtinTrunc(x: f64) f64 {
    return @trunc(x);
}
fn builtinSqrt(x: f64) f64 {
    return @sqrt(x);
}
fn builtinExp(x: f64) f64 {
    return @exp(x);
}
fn builtinLog(x: f64) f64 {
    return @log(x);
}

// -------------------------------------------------------------------------
// Resolvers
// -------------------------------------------------------------------------

/// A resolver that resolves nothing — the literal/arithmetic-only context.
/// Every identifier and member folds to `null`, so `eval`/`evalIntOnly` see
/// only the syntactic const forms. Used by the Validator's freestanding
/// `extractLiteralIntValue` (helpers without a `*Validator`) and by the unit
/// tests below.
pub const NullResolver = struct {
    pub fn resolveIdent(_: NullResolver, _: Ast.SymbolIndex) ?Value {
        return null;
    }
    pub fn resolveMember(_: NullResolver, _: *Ast.MemberExpr, _: u32) ?Value {
        return null;
    }
};

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;

/// Build a heap-allocated literal expression for the eval unit tests. The
/// arena frees everything on `deinit`.
fn litInt(arena: std.mem.Allocator, text: []const u8) !Ast.Expr {
    const lit = try arena.create(Ast.LiteralExpr);
    lit.* = .{ .kind = .int_literal, .value = text };
    return .{ .literal = lit };
}

fn binExpr(arena: std.mem.Allocator, op: Ast.BinaryOp, l: Ast.Expr, r: Ast.Expr) !Ast.Expr {
    const b = try arena.create(Ast.BinaryExpr);
    b.* = .{ .op = op, .left = l, .right = r };
    return .{ .binary = b };
}

fn unaryExpr(arena: std.mem.Allocator, op: Ast.UnaryOp, operand: Ast.Expr) !Ast.Expr {
    const u = try arena.create(Ast.UnaryExpr);
    u.* = .{ .op = op, .operand = operand };
    return .{ .unary = u };
}

test "eval: literal int/float/bool via NullResolver" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(?i64, 42), (eval(NullResolver{}, .wrap, try litInt(a, "42"), 0).?).toI64());
    const flit = try a.create(Ast.LiteralExpr);
    flit.* = .{ .kind = .float_literal, .value = "1.5" };
    try testing.expectEqual(@as(f64, 1.5), eval(NullResolver{}, .wrap, .{ .literal = flit }, 0).?.float);
    const blit = try a.create(Ast.LiteralExpr);
    blit.* = .{ .kind = .true_literal, .value = "true" };
    try testing.expectEqual(true, eval(NullResolver{}, .wrap, .{ .literal = blit }, 0).?.bool);
}

test "eval: add/sub/mul overflow — wrap vs saturate vs checked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const max_lit = try litInt(a, "9223372036854775807"); // i64::MAX
    const one = try litInt(a, "1");
    const add = try binExpr(a, .add, max_lit, one);
    // wrap: i64::MAX + 1 = i64::MIN
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), eval(NullResolver{}, .wrap, add, 0).?.int);
    // saturate: clamps to i64::MAX
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), eval(NullResolver{}, .saturate, add, 0).?.int);
    // checked: overflow → null
    try testing.expectEqual(@as(?Value, null), eval(NullResolver{}, .checked, add, 0));
}

test "eval: bitwise, shift, comparison, div/mod-by-zero guards" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (1 << 4) | 3 & 255 style — validate operators in isolation.
    const shifted = try binExpr(a, .shl, try litInt(a, "1"), try litInt(a, "4"));
    try testing.expectEqual(@as(i64, 16), eval(NullResolver{}, .wrap, shifted, 0).?.int);
    const ored = try binExpr(a, .@"or", try litInt(a, "16"), try litInt(a, "3"));
    try testing.expectEqual(@as(i64, 19), eval(NullResolver{}, .wrap, ored, 0).?.int);
    // shift out of range → null
    const bad_shift = try binExpr(a, .shl, try litInt(a, "1"), try litInt(a, "64"));
    try testing.expectEqual(@as(?Value, null), eval(NullResolver{}, .wrap, bad_shift, 0));
    // comparison → bool
    const cmp = try binExpr(a, .eq, try litInt(a, "4"), try litInt(a, "4"));
    try testing.expectEqual(true, eval(NullResolver{}, .wrap, cmp, 0).?.bool);
    // div / mod by zero → null
    const divz = try binExpr(a, .div, try litInt(a, "1"), try litInt(a, "0"));
    try testing.expectEqual(@as(?Value, null), eval(NullResolver{}, .wrap, divz, 0));
    const modz = try binExpr(a, .mod, try litInt(a, "1"), try litInt(a, "0"));
    try testing.expectEqual(@as(?Value, null), eval(NullResolver{}, .wrap, modz, 0));
}

test "eval: unary negation respects mode; bit_not; logical not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // -(i64::MIN) — wrap keeps i64::MIN, saturate clamps to i64::MAX, checked null.
    const min_lit = try litInt(a, "-9223372036854775808");
    const neg = try unaryExpr(a, .neg, min_lit);
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), eval(NullResolver{}, .wrap, neg, 0).?.int);
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), eval(NullResolver{}, .saturate, neg, 0).?.int);
    try testing.expectEqual(@as(?Value, null), eval(NullResolver{}, .checked, neg, 0));
    // ~0 = -1
    const bnot = try unaryExpr(a, .bit_not, try litInt(a, "0"));
    try testing.expectEqual(@as(i64, -1), eval(NullResolver{}, .wrap, bnot, 0).?.int);
}

test "eval: depth cap bails to null beyond max_const_eval_depth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Nest parens one past the cap.
    var expr = try litInt(a, "1");
    var i: u32 = 0;
    while (i <= constants.max_const_eval_depth) : (i += 1) {
        const p = try a.create(Ast.ParenExpr);
        p.* = .{ .expr = expr };
        expr = .{ .paren = p };
    }
    try testing.expectEqual(@as(?Value, null), eval(NullResolver{}, .wrap, expr, 0));
}

test "eval: unresolved ident folds to null through NullResolver" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = try a.create(Ast.IdentExpr);
    id.* = .{ .name = "X" };
    try testing.expectEqual(@as(?Value, null), eval(NullResolver{}, .wrap, .{ .ident = id }, 0));
}

// -------------------------------------------------------------------------
// evalIntOnly — the Validator subset (byte-neutral with `tryExtractIntValue`)
// -------------------------------------------------------------------------

fn floatLit(arena: std.mem.Allocator, text: []const u8) !Ast.Expr {
    const lit = try arena.create(Ast.LiteralExpr);
    lit.* = .{ .kind = .float_literal, .value = text };
    return .{ .literal = lit };
}

fn callExpr(arena: std.mem.Allocator, name: []const u8, arg: Ast.Expr) !Ast.Expr {
    const id = try arena.create(Ast.IdentExpr);
    id.* = .{ .name = name };
    const c = try arena.create(Ast.CallExpr);
    c.* = .{ .func = .{ .ident = id }, .args = .empty };
    try c.args.append(arena, arg);
    return .{ .call = c };
}

test "evalIntOnly: suppresses casts/builtins that full eval would fold" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `u32(3)` — full eval casts to 3; int-only never folds a call.
    const cast = try callExpr(a, "u32", try litInt(a, "3"));
    try testing.expectEqual(@as(i64, 3), eval(NullResolver{}, .saturate, cast, 0).?.int);
    try testing.expectEqual(@as(?Value, null), evalIntOnly(NullResolver{}, .saturate, cast, 0));
}

test "evalIntOnly: float literal narrows to null (never enters the int domain)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try floatLit(a, "3.5");
    // A bare float folds under full eval but `asInt` drops it; and a float
    // comparison is un-evaluable under int-only (mixed-domain guard).
    try testing.expectEqual(@as(?i64, null), evalIntOnly(NullResolver{}, .saturate, f, 0).?.asInt());
    const fcmp = try binExpr(a, .lt, try floatLit(a, "1.5"), try floatLit(a, "2.5"));
    try testing.expectEqual(@as(?Value, null), evalIntOnly(NullResolver{}, .saturate, fcmp, 0));
}

test "evalIntOnly: integer comparison yields bool (asBool), saturates arithmetic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Comparison → bool: asBool sees it, asInt drops it (matches the old
    // tryEvalConstBool vs tryExtractIntValue split).
    const cmp = try binExpr(a, .eq, try litInt(a, "4"), try litInt(a, "4"));
    try testing.expectEqual(@as(?bool, true), evalIntOnly(NullResolver{}, .saturate, cmp, 0).?.asBool());
    try testing.expectEqual(@as(?i64, null), evalIntOnly(NullResolver{}, .saturate, cmp, 0).?.asInt());
    // Saturating add (the Validator's overflow mode).
    const add = try binExpr(a, .add, try litInt(a, "9223372036854775807"), try litInt(a, "1"));
    try testing.expectEqual(@as(?i64, std.math.maxInt(i64)), evalIntOnly(NullResolver{}, .saturate, add, 0).?.asInt());
    // A bool-operand binary is un-evaluable (matches the old int extractor).
    const mixed = try binExpr(a, .add, cmp, try litInt(a, "1"));
    try testing.expectEqual(@as(?Value, null), evalIntOnly(NullResolver{}, .saturate, mixed, 0));
}
