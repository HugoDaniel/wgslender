//! Expression type-checking + inference.
//!
//! Owns the `checkExpr` family — literal/ident/binary/unary/call/index/member
//! and the bitcast / type-constructor dispatch. Driven from `Statements.zig`
//! and (for module-decl initializers) `Declarations.zig`. The walker reads
//! and writes validator state via the `*Validator` receiver: `expr_types`
//! (LSP hover cache), `enabled_features`, `expr_depth`, plus diagnostics.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../Ast.zig");
const Types = @import("../Types.zig");
const Builtins = @import("../Builtins.zig");
const Overload = @import("../Overload.zig");
const Operators = @import("../Operators.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Suggest = @import("../Suggest.zig");
const Validator = @import("../Validator.zig");
const constants = @import("../constants.zig");

const suggestName = Suggest.suggestName;

const LocRange = Validator.LocRange;
const ExprStage = Validator.ExprStage;
const InferResult = Validator.InferResult;
const Expectation = Validator.Expectation;

const exprSpan = Validator.exprSpan;
const exprRange = Validator.exprRange;
const exprLoc = Validator.exprLoc;
const astTypeRange = Validator.astTypeRange;
const astTypeLoc = Validator.astTypeLoc;


const max_expr_depth: u32 = 256;

pub fn checkExpr(v: *Validator, expr: Ast.Expr) Allocator.Error!InferResult {
    return checkExprE(v, expr, .none);
}

pub fn checkExprE(v: *Validator, expr: Ast.Expr, exp: Expectation) Allocator.Error!InferResult {
    if (v.expr_depth >= max_expr_depth) return .fail;
    v.expr_depth += 1;
    defer v.expr_depth -= 1;
    var result: InferResult = switch (expr) {
        .literal => |e| checkLiteral(v, e),
        .ident => |e| checkIdent(v, e),
        .binary => |e| try checkBinaryE(v, e, exp),
        .unary => |e| try checkUnaryE(v, e, exp),
        .call => |e| try checkCallExpr(v, e),
        .index => |e| try checkIndex(v, e),
        .member => |e| try checkMember(v, e),
        .paren => |e| try checkExprE(v, e.expr, exp),
    };
    // Apply the surrounding expectation to (a) validate shape at the
    // inference site, (b) decide what to record in `expr_types` for LSP
    // hovers, and (c) potentially short-circuit the returned type so
    // callers don't pile on redundant follow-up diagnostics.
    //
    // `.exact(T)`       — if the inferred type is abstract and convertible
    //                     to T, record T; the outer decl validator still
    //                     enforces the exact match on the returned type.
    // `.integer_scalar` — the inferred type must be a scalar integer;
    //                     non-matches emit E0200 here and null the result
    //                     so the outer form (index, shift) skips its own
    //                     secondary check.
    // `.concrete`       — abstract types materialize to their default
    //                     concrete form in the cache. Never errors.
    const recorded_typ: ?Types.Type = blk: {
        const typ = result.typ orelse break :blk null;
        switch (exp) {
            .none => break :blk typ,
            .exact => |target| {
                break :blk if (!typ.isConcrete() and Types.canConvertTo(typ, target)) target else typ;
            },
            .integer_scalar => {
                if (typ != .scalar or !typ.scalar.isInteger()) {
                    v.addErrorWithCodeR(exprSpan(expr), Diagnostic.Code.type_mismatch, v.fmtError("expected integer scalar, got '{s}'", .{typ.string()}));
                    result.typ = null;
                    break :blk null;
                }
                break :blk typ;
            },
            .concrete => break :blk if (!typ.isConcrete()) Types.concreteType(typ) else typ,
        }
    };
    if (recorded_typ) |typ| {
        // Key on each expression's own loc (operator for binary, open-paren
        // for call, etc.) so nested expressions that share the same start
        // offset don't collide in the hash map. `.paren` has no distinct loc
        // of its own — the inner expression has already registered itself
        // via the recursive `checkExpr` call above.
        const key: ?u32 = switch (expr) {
            .literal => |e| e.loc,
            .ident => |e| e.loc,
            .binary => |e| e.loc,
            .unary => |e| e.loc,
            .call => |e| e.loc,
            .index => |e| e.loc,
            .member => |e| e.loc,
            .paren => null,
        };
        if (key) |k| {
            try v.expr_types.put(v.arena, k, .{
                .typ = typ,
                .end_offset = exprSpan(expr).end,
            });
        }
    }
    return result;
}

pub fn checkLiteral(v: *Validator, e: *Ast.LiteralExpr) InferResult {
    const val = e.value;
    if (val.len == 0) return InferResult.some(Types.AbstractInt, .const_expr);

    // Dispatch on the lexer's token classification — text-based heuristics
    // mistype hex literals (e.g. `0xf` ends in 'f', `0xe5` contains 'e'),
    // while the lexer already tracks int vs float via the `p`/`.` markers.
    switch (e.kind) {
        .true_literal, .false_literal => return InferResult.some(Types.Bool, .const_expr),
        .float_literal => {
            checkFloatLiteralValue(v, e);
            const last = val[val.len - 1];
            if (last == 'h') {
                checkF16Enabled(v, e.loc);
                return InferResult.some(Types.F16, .const_expr);
            }
            if (last == 'f') return InferResult.some(Types.F32, .const_expr);
            return InferResult.some(Types.AbstractFloat, .const_expr);
        },
        .int_literal => {
            const last = val[val.len - 1];
            if (last == 'u') {
                checkIntLiteralRange(v, e, .u);
                return InferResult.some(Types.U32, .const_expr);
            }
            if (last == 'i') {
                checkIntLiteralRange(v, e, .i);
                return InferResult.some(Types.I32, .const_expr);
            }
            checkIntLiteralRange(v, e, .abstract);
            return InferResult.some(Types.AbstractInt, .const_expr);
        },
        else => return InferResult.some(Types.AbstractInt, .const_expr),
    }
}

pub const IntLiteralKind = enum { u, i, abstract };

/// Reject integer literals whose magnitude overflows the destination type.
/// Per WGSL §16.1 / §4.4.2 the literal's magnitude is bounded by the target:
///   - `u`      : [0, 2^32 − 1]
///   - `i`      : magnitude ≤ 2^31 (2^31 is admitted so `-2147483648i` is
///                 legal when negated via unary `-`)
///   - abstract : magnitude ≤ 2^63 (same carve-out for the i64 min case)
/// Underscore digit separators are stripped before parsing. Magnitudes that
/// don't fit in u64 at all are rejected wholesale.
pub fn checkIntLiteralRange(v: *Validator, e: *Ast.LiteralExpr, kind: IntLiteralKind) void {
    const val = e.value;
    var num_end = val.len;
    if (num_end > 0 and (val[num_end - 1] == 'u' or val[num_end - 1] == 'i')) num_end -= 1;
    if (num_end == 0) return;

    const num_str = val[0..num_end];
    // WGSL §4.4 allows `_` as a digit separator; `std.fmt.parseInt` does not.
    var buf: [128]u8 = undefined;
    var j: usize = 0;
    for (num_str) |c| {
        if (c == '_') continue;
        if (j >= buf.len) {
            v.addErrorWithCodeR(
                .{ .start = e.loc, .end = e.loc +| @as(u32, @intCast(val.len)) },
                Diagnostic.Code.integer_overflow,
                v.fmtError("integer literal '{s}' is too long to fit in any integer type", .{val}),
            );
            return;
        }
        buf[j] = c;
        j += 1;
    }
    const magnitude = std.fmt.parseInt(u64, buf[0..j], 0) catch {
        v.addErrorWithCodeR(
            .{ .start = e.loc, .end = e.loc +| @as(u32, @intCast(val.len)) },
            Diagnostic.Code.integer_overflow,
            v.fmtError("integer literal '{s}' exceeds the maximum magnitude (2^63)", .{val}),
        );
        return;
    };
    const limit: u64 = switch (kind) {
        .u => std.math.maxInt(u32),
        .i => @as(u64, std.math.maxInt(i32)) + 1,
        .abstract => @as(u64, std.math.maxInt(i64)) + 1,
    };
    if (magnitude > limit) {
        const type_name = switch (kind) {
            .u => "u32",
            .i => "i32",
            .abstract => "abstract-int",
        };
        v.addErrorWithCodeR(
            .{ .start = e.loc, .end = e.loc +| @as(u32, @intCast(val.len)) },
            Diagnostic.Code.integer_overflow,
            v.fmtError("integer literal '{s}' is out of range for '{s}'", .{ val, type_name }),
        );
    }
}
pub fn checkF16Enabled(v: *Validator, loc: u32) void {
    if (!v.enabled_features.contains("f16")) {
        v.addErrorWithCodeDataR(.{ .start = loc, .end = loc +| 1 }, Diagnostic.Code.feature_not_enabled, "'f16' requires 'enable f16;'", .{ .feature_not_enabled = "f16" });
    }
}

/// Validate that a float literal fits its target type. NaN/Inf rejects every
/// form. `f`-suffixed literals additionally must fit the finite f32 range,
/// and `h`-suffixed must fit f16 — so `1e40f` and `1e10h` are caught even
/// though they parse to finite f64 values.
pub fn checkFloatLiteralValue(v: *Validator, e: *Ast.LiteralExpr) void {
    // Strip suffix for parsing
    const raw = e.value;
    var parse_str = raw;
    const suffix: u8 = if (raw.len > 0 and (raw[raw.len - 1] == 'f' or raw[raw.len - 1] == 'h')) raw[raw.len - 1] else 0;
    if (suffix != 0) parse_str = parse_str[0 .. parse_str.len - 1];
    if (parse_str.len == 0) return;
    const range: LocRange = .{ .start = e.loc, .end = e.loc +| @as(u32, @intCast(raw.len)) };
    const parsed = std.fmt.parseFloat(f64, parse_str) catch return;
    if (std.math.isNan(parsed)) {
        v.addErrorWithCodeR(range, Diagnostic.Code.invalid_float_literal, "float literal evaluates to NaN");
        return;
    }
    if (std.math.isInf(parsed)) {
        v.addErrorWithCodeR(range, Diagnostic.Code.invalid_float_literal, "float literal evaluates to infinity");
        return;
    }
    const abs_val = @abs(parsed);
    switch (suffix) {
        'f' => {
            const f32_max: f64 = std.math.floatMax(f32);
            if (abs_val > f32_max) {
                v.addErrorWithCodeR(range, Diagnostic.Code.invalid_float_literal, v.fmtError("f32 literal '{s}' is out of range (|value| > {e})", .{ raw, f32_max }));
            }
        },
        'h' => {
            const f16_max: f64 = std.math.floatMax(f16);
            if (abs_val > f16_max) {
                v.addErrorWithCodeR(range, Diagnostic.Code.invalid_float_literal, v.fmtError("f16 literal '{s}' is out of range (|value| > {e})", .{ raw, f16_max }));
            }
        },
        else => {},
    }
}

pub fn checkIdent(v: *Validator, e: *Ast.IdentExpr) InferResult {
    // Staging follows the declaration kind. Unresolved idents (attribute
    // arguments still being wired up) fall back to a by-name classifier.
    // Stage is always computed — even when type inference fails — so that
    // enclosing staging checks don't see a spurious `.runtime_expr`.
    const stage: ExprStage = blk: {
        if (e.ref.isValid()) {
            const idx = e.ref.index();
            if (idx < v.module.symbols.items.len) {
                break :blk switch (v.module.symbols.items[idx].kind) {
                    .@"const" => .const_expr,
                    .override => .override_expr,
                    .let, .@"var", .parameter => .runtime_expr,
                    .@"struct", .alias => .const_expr,
                    .function, .builtin => .const_expr,
                    else => .runtime_expr,
                };
            }
        }
        break :blk v.classifyIdentByName(e.name);
    };

    // Check if it's a type name being used as expression (constructor)
    if (v.lookupType(e.name)) |t| {
        return InferResult.some(t, stage);
    }

    // Check symbol table
    if (e.ref.isValid()) {
        if (v.symbol_types.get(e.ref.index())) |t| {
            return InferResult.some(t, stage);
        }
    }

    // Check if it's a builtin function — type is resolved at the call site.
    // Stage still propagates so enclosing expressions classify correctly.
    if (Builtins.isBuiltin(e.name)) {
        return .{ .typ = null, .stage = stage };
    }

    // Check if it's a user-defined function (by looking up symbols in module)
    if (e.ref.isValid()) {
        const idx = e.ref.index();
        if (idx < v.module.symbols.items.len) {
            const kind = v.module.symbols.items[idx].kind;
            // Function type resolved at call site
            if (kind == .function) return .{ .typ = null, .stage = stage };
            // Symbol exists but type not yet assigned — use-before-decl
            // (parser already emitted E0102, don't also report E0100)
            if (kind != .unbound) return .{ .typ = null, .stage = stage };
        }
    }

    // Undefined identifier
    if (v.suggestIdentifier(e.name)) |s| {
        v.addErrorWithCodeDataR(exprRange(.{ .ident = e }), Diagnostic.Code.undefined_symbol, v.fmtError("use of undeclared identifier '{s}'; did you mean '{s}'?", .{ e.name, s }), .{ .did_you_mean = s });
    } else {
        v.addErrorWithCodeR(exprRange(.{ .ident = e }), Diagnostic.Code.undefined_symbol, v.fmtError("use of undeclared identifier '{s}'", .{e.name}));
    }
    return InferResult.fail;
}

pub fn checkBinary(v: *Validator, e: *Ast.BinaryExpr) Allocator.Error!InferResult {
    return checkBinaryE(v, e, .none);
}

pub fn checkBinaryE(v: *Validator, e: *Ast.BinaryExpr, exp: Expectation) Allocator.Error!InferResult {
    // Arithmetic / bitwise operators type-check against a common operand
    // type, so an outer `exact(T)` / `.concrete` expectation applies
    // symmetrically to both sides. Boolean / comparison forms have fixed
    // operand shapes that do not benefit from propagating `T`. Shifts pass
    // `.none` to both operands and let `checkShiftBinary` own all shift
    // typing: the RHS shape depends on the LHS (scalar `int << u32`;
    // component-wise `vecN<int> << vecN<u32>`), which a fixed per-operand
    // expectation can't express.
    //
    // `.integer_scalar` never forwards to arithmetic operands: we want
    // the diagnostic to fire at the binary as a whole (e.g. the full
    // `1.0 + 2.0` in `a[1.0 + 2.0]`), not at each literal individually.
    const forward_exp: Expectation = switch (exp) {
        .integer_scalar => .none,
        else => exp,
    };
    const left_exp: Expectation = switch (e.op) {
        .add, .sub, .mul, .div, .mod, .@"and", .@"or", .xor => forward_exp,
        .logical_and, .logical_or, .eq, .ne, .lt, .le, .gt, .ge, .shl, .shr => .none,
    };
    const right_exp: Expectation = switch (e.op) {
        .add, .sub, .mul, .div, .mod, .@"and", .@"or", .xor => forward_exp,
        .logical_and, .logical_or, .eq, .ne, .lt, .le, .gt, .ge, .shl, .shr => .none,
    };
    const lr = try checkExprE(v, e.left, left_exp);
    const rr = try checkExprE(v, e.right, right_exp);
    // Stage is computed from both children regardless of type inference
    // success so enclosing staging checks (const decls, const_assert,
    // switch selectors, …) don't mis-report a subtree that merely had a
    // type error as "not a const-expression".
    const stage = ExprStage.combine(lr.stage, rr.stage);
    const left_type = lr.typ orelse return .{ .typ = null, .stage = stage };
    const right_type = rr.typ orelse return .{ .typ = null, .stage = stage };

    const er = exprRange(.{ .binary = e }); // operator range
    const op_str = e.op.string();
    return switch (e.op) {
        .logical_and, .logical_or, .@"and", .@"or", .xor => binaryViaEngine(v, e.op, left_type, right_type, stage, er, op_str),
        .eq, .ne => binaryViaEngine(v, e.op, left_type, right_type, stage, er, op_str),
        .lt, .le, .gt, .ge => binaryViaEngine(v, e.op, left_type, right_type, stage, er, op_str),
        .add, .sub => checkAdditiveBinary(v, e, left_type, right_type, stage, er, op_str),
        .mul => checkMulBinary(v, e, left_type, right_type, stage, er),
        .div => checkDivBinary(v, e, left_type, right_type, stage, er),
        .mod => checkModBinary(v, e, left_type, right_type, stage, er),
        .shl, .shr => checkShiftBinary(v, e, left_type, right_type, stage, er, op_str),
    };
}

/// Shared binary-operator validation on the overload engine — the operator
/// analogue of `ctorViaEngine`. Resolves against `Operators.binarySigs(op)`,
/// materializes the winning result rule, and on no-match emits the family's
/// diagnostic. Only migrated operators (whose `binarySigs` is non-empty) route
/// here; the rest still use their hand-rolled checker. Value-dependent
/// post-checks (div-by-zero, shift range) stay at the outer call site and
/// migrate with their families.
fn binaryViaEngine(
    v: *Validator,
    op: Ast.BinaryOp,
    left_type: Types.Type,
    right_type: Types.Type,
    stage: ExprStage,
    er: LocRange,
    op_str: []const u8,
) Allocator.Error!InferResult {
    const sigs = Operators.binarySigs(op);
    const arg_types = [_]?Types.Type{ left_type, right_type };
    switch (Overload.resolve(sigs, &arg_types)) {
        .ok => |ok| {
            const sig = sigs[ok.sig_index];
            var args8: [8]?Types.Type = @splat(null);
            args8[0] = left_type;
            args8[1] = right_type;
            const ret = (try buildOverloadResult(v, sig.result, &ok.bindings, args8)) orelse
                return InferResult.fail;
            return InferResult.some(ret, stage);
        },
        .err => {
            v.addErrorWithCodeR(er, Diagnostic.Code.invalid_operand, binaryFailureMessage(v, op, op_str, left_type, right_type));
            return InferResult.fail;
        },
    }
}

/// The per-family "no matching overload" message, reproducing the wording the
/// hand-rolled checkers emitted — now also covering the shapes they used to
/// reject *silently* (mixed-sign / width-mismatched / scalar↔vector integer
/// pairs), which now surface this diagnostic instead of a typeless success.
fn binaryFailureMessage(v: *Validator, op: Ast.BinaryOp, op_str: []const u8, left_type: Types.Type, right_type: Types.Type) []const u8 {
    return switch (op) {
        .logical_and, .logical_or => v.fmtError("operator '{s}' requires 'bool' operands, got '{s}' and '{s}'", .{ op_str, left_type.string(), right_type.string() }),
        .@"and", .@"or", .xor => v.fmtError("operator '{s}' requires integer or bool, got '{s}' and '{s}'", .{ op_str, left_type.string(), right_type.string() }),
        // Comparison: a non-numeric operand (bool, matrix, …) is the "wrong
        // domain" case; two numeric-but-incompatible operands (mixed sign,
        // int-vs-float, width mismatch) fail the common-type requirement.
        // Reproduces the hand-rolled `checkComparisonBinary` split exactly.
        .lt, .le, .gt, .ge => if (!Types.isNumeric(left_type) or !Types.isNumeric(right_type))
            v.fmtError("operator '{s}' requires numeric operands, got '{s}' and '{s}'", .{ op_str, left_type.string(), right_type.string() })
        else
            v.fmtError("operator '{s}' requires compatible types, got '{s}' and '{s}'", .{ op_str, left_type.string(), right_type.string() }),
        // Equality: a composite operand (matrix, struct, array, …) is outside
        // the scalar/vector domain equality is defined on — its own message.
        // Two scalar/vector operands that simply don't share a type keep the
        // hand-rolled `checkEqualityBinary` wording. The matrix-domain case is
        // the ⚠ behavior change: `mat == mat` used to succeed silently.
        .eq, .ne => if ((left_type != .scalar and left_type != .vector) or
            (right_type != .scalar and right_type != .vector))
            v.fmtError("operator '{s}' requires scalar or vector operands, got '{s}' and '{s}'", .{ op_str, left_type.string(), right_type.string() })
        else
            v.fmtError("operator '{s}' requires compatible types, got '{s}' and '{s}'", .{ op_str, left_type.string(), right_type.string() }),
        else => unreachable,
    };
}

pub fn checkAdditiveBinary(v: *Validator, e: *Ast.BinaryExpr, left_type: Types.Type, right_type: Types.Type, stage: ExprStage, er: LocRange, op_str: []const u8) InferResult {
    _ = e;
    const result = Types.addSubResultType(v.arena, left_type, right_type) catch return InferResult.fail;
    if (result) |r| {
        return InferResult.some(r, stage);
    }
    v.addErrorWithCodeR(er, Diagnostic.Code.invalid_operand, v.fmtError("operator '{s}' requires numeric types, got '{s}' and '{s}'", .{ op_str, left_type.string(), right_type.string() }));
    return InferResult.fail;
}

pub fn checkMulBinary(v: *Validator, e: *Ast.BinaryExpr, left_type: Types.Type, right_type: Types.Type, stage: ExprStage, er: LocRange) InferResult {
    _ = e;
    const result = Types.multiplyResultType(v.arena, left_type, right_type) catch return InferResult.fail;
    if (result) |r| {
        return InferResult.some(r, stage);
    }
    v.addErrorWithCodeR(er, Diagnostic.Code.invalid_operand, v.fmtError("cannot multiply '{s}' by '{s}'", .{ left_type.string(), right_type.string() }));
    return InferResult.fail;
}

pub fn checkDivBinary(v: *Validator, e: *Ast.BinaryExpr, left_type: Types.Type, right_type: Types.Type, stage: ExprStage, er: LocRange) InferResult {
    const result = Types.divResultType(v.arena, left_type, right_type) catch return InferResult.fail;
    if (result) |r| {
        // Const division by zero
        if (v.tryExtractIntValue(e.right)) |rhs_val| {
            if (rhs_val == 0) {
                v.addErrorWithCodeR(exprRange(e.right), Diagnostic.Code.division_by_zero, "division by zero in const-expression");
            }
        }
        return InferResult.some(r, stage);
    }
    v.addErrorWithCodeR(er, Diagnostic.Code.invalid_operand, v.fmtError("cannot divide '{s}' by '{s}'", .{ left_type.string(), right_type.string() }));
    return InferResult.fail;
}

pub fn checkModBinary(v: *Validator, e: *Ast.BinaryExpr, left_type: Types.Type, right_type: Types.Type, stage: ExprStage, er: LocRange) InferResult {
    // WGSL % works on both integers and floats (unlike C where fmod is separate).
    if (!Types.isNumeric(left_type) or !Types.isNumeric(right_type)) {
        v.addErrorWithCodeR(er, Diagnostic.Code.invalid_operand, v.fmtError("operator '%' requires numeric operands, got '{s}' and '{s}'", .{ left_type.string(), right_type.string() }));
        return InferResult.fail;
    }
    // Const modulo by zero
    if (v.tryExtractIntValue(e.right)) |rhs_val| {
        if (rhs_val == 0) {
            v.addErrorWithCodeR(exprRange(e.right), Diagnostic.Code.division_by_zero, "division by zero in const-expression");
        }
    }
    const common = Types.commonType(left_type, right_type) orelse return InferResult.fail;
    return InferResult.some(common, stage);
}

pub fn checkShiftBinary(v: *Validator, e: *Ast.BinaryExpr, left_type: Types.Type, right_type: Types.Type, stage: ExprStage, er: LocRange, op_str: []const u8) Allocator.Error!InferResult {
    // Shape + result come from the engine (`Operators.shift_sigs`): scalar
    // `int << u32 -> int`, or component-wise `vecN<int> << vecN<u32> -> vecN<int>`
    // (§8.7). The result is the LHS type — the u32 shift amount is an
    // independent tparam that never leaks into it.
    const sigs = Operators.binarySigs(e.op);
    const arg_types = [_]?Types.Type{ left_type, right_type };
    switch (Overload.resolve(sigs, &arg_types)) {
        .ok => |ok| {
            const sig = sigs[ok.sig_index];
            var args8: [8]?Types.Type = @splat(null);
            args8[0] = left_type;
            args8[1] = right_type;
            const ret = (try buildOverloadResult(v, sig.result, &ok.bindings, args8)) orelse
                return InferResult.fail;
            // WGSL §8.7 value-dependent post-check: a constant shift amount must
            // be < the LHS bit width. Not expressible as an overload, so it runs
            // after a successful shape resolve. AbstractInt LHS has no in-source
            // bit width (`Scalar.size()` is 0); per spec it concretizes to
            // i32/u32, so a 32-bit cap is the shader-creation-time ceiling (also
            // the width for concrete i32/u32 LHS).
            if (v.tryExtractIntValue(e.right)) |shift_val| {
                const bit_width: i64 = blk: {
                    if (left_type != .scalar) break :blk 32;
                    const sz = left_type.scalar.size();
                    break :blk if (sz == 0) 32 else @as(i64, sz) * 8;
                };
                if (shift_val < 0 or shift_val >= bit_width) {
                    v.addErrorWithCodeR(exprRange(e.right), Diagnostic.Code.invalid_operand, v.fmtError("shift amount {d} exceeds bit width of {d}", .{ shift_val, bit_width }));
                }
            }
            return InferResult.some(ret, stage);
        },
        .err => {
            // The engine's single "no match" can't say *which* operand failed,
            // so re-derive the shift-specific diagnostic (the constructor path's
            // `ctorRefine` does the same). A non-integer LHS is the operator's
            // fault (underline the operator); an integer LHS with a bad shift
            // amount is the RHS's fault (underline the amount, and name the exact
            // expected shape: scalar `u32` vs component-wise `vecN<u32>`).
            if (!Types.isInteger(left_type)) {
                v.addErrorWithCodeR(er, Diagnostic.Code.invalid_operand, v.fmtError("operator '{s}' requires integer left operand, got '{s}'", .{ op_str, left_type.string() }));
            } else if (left_type == .vector) {
                v.addErrorWithCodeR(exprRange(e.right), Diagnostic.Code.invalid_operand, v.fmtError("shift amount must be 'vec{d}<u32>', got '{s}'", .{ left_type.vector.width, right_type.string() }));
            } else {
                v.addErrorWithCodeR(exprRange(e.right), Diagnostic.Code.invalid_operand, v.fmtError("shift amount must be 'u32', got '{s}'", .{right_type.string()}));
            }
            return InferResult.fail;
        },
    }
}

/// Syntactic approximation of whether an expression can denote a reference
/// — i.e. something addressable by `&`. The check is conservative: it
/// permits ident / paren-wrapped forms (which may reach a variable), `*p`
/// (deref of a pointer yields a reference), and member / index forms whose
/// *base* is itself addressable. Rejects shapes that definitionally produce
/// values (literals, calls, other unary forms, binary ops) — including when
/// they sit beneath a member or index projection (e.g. `&foo().x`,
/// `&(a+b).x`), which would otherwise slip past the gate and force the
/// AS/AM resolver into its lossy fallback.
pub fn addrOfOperandLooksAddressable(operand: Ast.Expr) bool {
    return switch (operand) {
        .ident => true,
        .member => |m| addrOfOperandLooksAddressable(m.base),
        .index => |ix| addrOfOperandLooksAddressable(ix.base),
        .paren => |p| addrOfOperandLooksAddressable(p.expr),
        // `*e` denotes a reference whenever `e` type-checks as a pointer — the
        // deref (E0214) check is the real gate, so a deref is always syntactically
        // addressable. Recursing into the operand wrongly rejected `&*&x` and
        // `&*(pointer value)`, whose operand (`&x` / a pointer value) is itself a
        // value, not a reference.
        .unary => |u| u.op == .deref,
        .literal, .call, .binary => false,
    };
}

/// Walks a parenthesized chain, returning the first non-paren inner expr.
pub fn stripParens(operand: Ast.Expr) Ast.Expr {
    var cur = operand;
    while (cur == .paren) cur = cur.paren.expr;
    return cur;
}

/// Address-space / access-mode pair used when materializing a pointer type
/// from `&`. Pulled out so the recovery helper below can return both fields
/// in one shot.
pub const AddrSpaceAndMode = struct {
    address_space: Ast.AddressSpace,
    access_mode: Ast.AccessMode,
};

/// Walks an addressable chain (ident / *p / member / index / paren) and
/// resolves the AS/AM that `&`-of-that-chain should carry. Returns `null`
/// when the chain cannot be traced — caller should then return
/// `InferResult.fail` rather than materializing a bogus pointer type.
///
/// Two sources feed the answer:
///   • `var`-declared ident at the root → `var_info` stores the normalized
///     AS/AM.
///   • `*ptr_expr` root → the inner `ptr_expr`'s inferred pointer type
///     supplies AS/AM, keeping `&(*p)` (and chains built on top) faithful to
///     `p`'s source pointer.
///
/// Non-`var` ident roots (const / override / let / parameter / struct /
/// alias / function / builtin) are **not** references per WGSL §6.5, so
/// this helper also emits a kind-specific `E0215` at `er` and returns null.
/// Unbound idents and already-failed sub-expressions return null silently —
/// an upstream diagnostic is already in flight and a second generic error
/// here would only add noise.
///
/// The historical `function` / `read_write` default was a foot-gun: it let
/// `&foo().x` or `&my_const` silently produce `ptr<function, T, rw>` and
/// cascade into misleading downstream type-mismatch errors. Returning null
/// and bailing at the call site keeps the diagnostic stream honest.
pub fn addrOfOperandAsAm(v: *Validator, expr: Ast.Expr, er: LocRange) Allocator.Error!?AddrSpaceAndMode {
    var cur = expr;
    for (0..constants.max_tree_walk_iterations) |_| {
        switch (cur) {
            .ident => |id| {
                if (!id.ref.isValid()) return null; // undefined-ident already reported
                const idx = id.ref.index();
                if (idx >= v.module.symbols.items.len) return null;
                const sym = v.module.symbols.items[idx];
                switch (sym.kind) {
                    .@"var" => {
                        if (v.var_info.get(idx)) |info| {
                            return .{ .address_space = info.address_space, .access_mode = info.access_mode };
                        }
                        return null;
                    },
                    .@"const" => {
                        v.addErrorWithCodeR(er, Diagnostic.Code.addr_of_requires_reference, v.fmtError("cannot take the address of '{s}': 'const' declarations have no memory location", .{sym.original_name}));
                        return null;
                    },
                    .override => {
                        v.addErrorWithCodeR(er, Diagnostic.Code.addr_of_requires_reference, v.fmtError("cannot take the address of '{s}': 'override' declarations have no memory location", .{sym.original_name}));
                        return null;
                    },
                    .let => {
                        v.addErrorWithCodeR(er, Diagnostic.Code.addr_of_requires_reference, v.fmtError("cannot take the address of '{s}': 'let' bindings are not references", .{sym.original_name}));
                        return null;
                    },
                    .parameter => {
                        v.addErrorWithCodeR(er, Diagnostic.Code.addr_of_requires_reference, v.fmtError("cannot take the address of parameter '{s}': parameters are not references (declare a 'var' or project through a 'ptr<…>' parameter via '&(*p)')", .{sym.original_name}));
                        return null;
                    },
                    .@"struct", .alias => {
                        v.addErrorWithCodeR(er, Diagnostic.Code.addr_of_requires_reference, v.fmtError("cannot take the address of type name '{s}'", .{sym.original_name}));
                        return null;
                    },
                    .function, .builtin => {
                        v.addErrorWithCodeR(er, Diagnostic.Code.addr_of_requires_reference, v.fmtError("cannot take the address of function '{s}'", .{sym.original_name}));
                        return null;
                    },
                    .unbound, .member => return null,
                }
            },
            .paren => |p| cur = p.expr,
            .member => |m| cur = m.base,
            .index => |ix| cur = ix.base,
            .unary => |u| {
                if (u.op != .deref) return null; // unreachable after syntactic gate
                // `*x` — for this arm to have type-checked, x is a pointer
                // (or a reference, by load-rule). Either way its type
                // carries the AS/AM we project onto the outer `&`. If x
                // didn't type-check, an upstream diagnostic exists and we
                // silently return null instead of fabricating AS/AM.
                const inner = try checkExpr(v, u.operand);
                const t = inner.typ orelse return null;
                return switch (t) {
                    .pointer => |p| .{ .address_space = p.address_space, .access_mode = p.access_mode },
                    .reference => |r| .{ .address_space = r.address_space, .access_mode = r.access_mode },
                    else => null,
                };
            },
            else => return null, // unreachable after syntactic gate
        }
    } else unreachable;
}

/// `&` / `*` diagnostics helper: returns true when `base_type` is a vector,
/// so `&base.x` / `&base[i]` can be rejected per WGSL "Texel shader values
/// and vector components are not references" (§10554+).
pub fn isVectorOrVectorRef(t: Types.Type) bool {
    return switch (t) {
        .vector => true,
        .reference => |r| r.element == .vector,
        else => false,
    };
}

pub fn checkUnary(v: *Validator, e: *Ast.UnaryExpr) Allocator.Error!InferResult {
    return checkUnaryE(v, e, .none);
}

pub fn checkUnaryE(v: *Validator, e: *Ast.UnaryExpr, exp: Expectation) Allocator.Error!InferResult {
    // `-` and `~` produce a value of the operand's type, so an outer
    // `exact(T)` / `.concrete` expectation applies to the operand. `!`,
    // `&`, `*` change shape (bool result, pointer wrap/unwrap) —
    // forwarding would stamp the wrong type into the cache.
    //
    // `.integer_scalar` never forwards: the check fires at the unary
    // form as a whole so the diagnostic range covers the full `-x` or
    // `~x` rather than the inner operand alone.
    const forward_exp: Expectation = switch (exp) {
        .integer_scalar => .none,
        else => exp,
    };
    const operand_exp: Expectation = switch (e.op) {
        .neg, .bit_not => forward_exp,
        .not, .deref, .addr => .none,
    };
    const or_ = try checkExprE(v, e.operand, operand_exp);
    const stage = or_.stage;
    const operand_type = or_.typ orelse return .{ .typ = null, .stage = stage };
    const er = exprRange(.{ .unary = e });

    switch (e.op) {
        .neg => {
            if (!Types.isNumeric(operand_type)) {
                v.addErrorWithCodeR(er, Diagnostic.Code.invalid_operand, v.fmtError("unary '-' requires numeric type, got '{s}'", .{operand_type.string()}));
                return InferResult.fail;
            }
            return InferResult.some(operand_type, stage);
        },
        .not => {
            if (!operand_type.eql(Types.Bool)) {
                // Also allow vector<bool>
                if (operand_type == .vector and operand_type.vector.element.kind == .bool) {
                    return InferResult.some(operand_type, stage);
                }
                v.addErrorWithCodeR(er, Diagnostic.Code.invalid_operand, v.fmtError("unary '!' requires 'bool', got '{s}'", .{operand_type.string()}));
                return InferResult.fail;
            }
            return InferResult.some(Types.Bool, stage);
        },
        .bit_not => {
            if (!Types.isInteger(operand_type)) {
                v.addErrorWithCodeR(er, Diagnostic.Code.invalid_operand, v.fmtError("unary '~' requires integer type, got '{s}'", .{operand_type.string()}));
                return InferResult.fail;
            }
            return InferResult.some(operand_type, stage);
        },
        .deref => {
            switch (operand_type) {
                .pointer => |p| return InferResult.some(p.element, stage),
                .reference => |r| return InferResult.some(r.element, stage),
                else => {
                    v.addErrorWithCodeR(er, Diagnostic.Code.deref_requires_pointer, v.fmtError("unary '*' requires a pointer, got '{s}'", .{operand_type.string()}));
                    return InferResult.fail;
                },
            }
        },
        .addr => return checkAddrOfUnary(v, e, er, operand_type, stage),
    }
}

/// `&` produces a pointer to the reference denoted by its operand.
/// The spec restricts what can be addressed:
///   1. The operand must syntactically denote a memory location —
///      an ident, member, index, `*p`, or paren-wrapping of one
///      of these. Literals / calls / arithmetic produce values
///      with no address.
///   2. Vector components and sub-vector swizzles are *values*,
///      never references, so `&v.x` and `&v[i]` (where `v` is a
///      vector) are forbidden. See "Reference types" in §6.5 and
///      the detailed rule-out in §10.4 ("Address-of").
///   3. Handles (textures, samplers) are not first-class memory
///      locations — `&my_texture` is also forbidden.
/// If the root is a plain variable, the resulting pointer carries
/// that variable's address space and access mode rather than the
/// historical `function` / `read_write` defaults.
pub fn checkAddrOfUnary(v: *Validator, e: *Ast.UnaryExpr, er: LocRange, operand_type: Types.Type, stage: ExprStage) Allocator.Error!InferResult {
    if (!addrOfOperandLooksAddressable(e.operand)) {
        v.addErrorWithCodeR(
            er,
            Diagnostic.Code.addr_of_requires_reference,
            "unary '&' requires a reference (e.g. a variable or member access); the operand has no address",
        );
        return InferResult.fail;
    }

    // Reject `&vector.x` / `&vector[i]` — vector components are not
    // references.
    const inner = stripParens(e.operand);
    switch (inner) {
        .member => |m| {
            if ((try checkExpr(v, m.base)).typ) |base_ty| {
                if (isVectorOrVectorRef(base_ty)) {
                    v.addErrorWithCodeR(
                        er,
                        Diagnostic.Code.addr_of_vector_component,
                        v.fmtError("cannot take the address of '.{s}': vector components are not references", .{m.member_name}),
                    );
                    return InferResult.fail;
                }
            }
        },
        .index => |ix| {
            if ((try checkExpr(v, ix.base)).typ) |base_ty| {
                if (isVectorOrVectorRef(base_ty)) {
                    v.addErrorWithCodeR(
                        er,
                        Diagnostic.Code.addr_of_vector_component,
                        "cannot take the address of a vector component: vector components are not references",
                    );
                    return InferResult.fail;
                }
            }
        },
        else => {},
    }

    // Reject `&handle_var` — textures/samplers have no memory
    // location users can form pointers to.
    if (Types.isTexture(operand_type) or Types.isSampler(operand_type)) {
        v.addErrorWithCodeR(
            er,
            Diagnostic.Code.addr_of_handle,
            v.fmtError("cannot take the address of handle type '{s}': textures and samplers are not references", .{operand_type.string()}),
        );
        return InferResult.fail;
    }

    // Choose AS/AM from the addressable chain: a var ident supplies
    // its declared AS/AM, a `*x` arm projects x's pointer type. A
    // null return means the chain leads to a non-reference (const,
    // let, parameter, …) — in which case addrOfOperandAsAm has
    // already emitted a kind-specific E0215 — or an upstream
    // sub-expression already failed to type-check. Either way, we
    // bail instead of fabricating a `ptr<function, T, rw>` that
    // would cascade misleading type-mismatch errors downstream.
    const asam = (try addrOfOperandAsAm(v, e.operand, er)) orelse return InferResult.fail;

    const p = v.arena.create(Types.Pointer) catch return InferResult.fail;
    p.* = .{
        .address_space = asam.address_space,
        .element = operand_type,
        .access_mode = asam.access_mode,
    };
    return InferResult.some(.{ .pointer = p }, stage);
}

pub fn checkCallExpr(v: *Validator, e: *Ast.CallExpr) Allocator.Error!InferResult {
    const callee_name = extractCalleeName(v, e) orelse return InferResult.fail;

    // bitcast<T>(expr) — WGSL §17.9.5. The template T is resolved to a
    // concrete Types.Type by `resolveType`, then we pick the matching sig
    // array in `Builtins` based on T's shape, pre-seed slot 0 (element
    // kind) and — for vector templates — slot 1 (width), and dispatch to
    // `Overload.resolveSeeded` for arg validation. Size compatibility is
    // verified post-resolution so cross-shape sigs can't produce
    // ill-sized pairs. See `checkBitcastCall` below.
    if (std.mem.eql(u8, callee_name, "bitcast")) {
        return try checkBitcastDispatch(v, e);
    }

    // Template type constructor (e.g. array<vec3f, 7>(...), vec3<f32>(...))
    if (e.template_type) |tt| {
        return try checkTemplateTypeCtor(v, e, tt, callee_name);
    }

    // A value declaration (let/var/const/override/parameter) named after a
    // builtin function shadows it. The binder already resolved this callee to
    // that declaration, so the call targets a non-callable value, not the
    // builtin — the "shadowed builtin is uncallable" error real toolchains
    // (Tint) reject. Detect it before the builtin dispatch below, which would
    // otherwise treat the call as the builtin and silently accept it.
    if (shadowedBuiltinValueCall(v, e)) {
        for (e.args.items) |arg| _ = try checkExpr(v, arg);
        v.addErrorWithCodeR(exprRange(.{ .call = e }), Diagnostic.Code.shadowed_builtin_call, v.fmtError(
            "'{s}' resolves to a declaration that shadows the WGSL builtin function of the same name; the builtin cannot be called here",
            .{callee_name},
        ));
        return InferResult.fail;
    }

    // Check if it's a builtin function
    if (Builtins.lookup(callee_name)) |builtin_fn| {
        return checkBuiltinCall(v, e, callee_name, builtin_fn);
    }

    // For non-builtin calls, validate all argument expressions and collect types
    var constructor_arg_types: std.ArrayList(?Types.Type) = .empty;
    var args_stage: ExprStage = .const_expr;
    for (e.args.items) |arg| {
        const ar = try checkExpr(v, arg);
        try constructor_arg_types.append(v.arena, ar.typ);
        args_stage = ExprStage.combine(args_stage, ar.stage);
    }

    // Check if it's a type constructor
    if (v.lookupType(callee_name)) |t| {
        return checkBareTypeCtor(v, e, callee_name, t, constructor_arg_types.items, args_stage);
    }

    // Check if it's a user-defined function
    if (e.func) |func| {
        switch (func) {
            .ident => |ident| return checkUserFunctionCall(v, e, ident, callee_name),
            else => {},
        }
    }

    // Unresolved call — if we have a name and it's not a builtin, error
    if (callee_name.len > 0) {
        reportNotCallable(v, e, callee_name);
    }
    return InferResult.fail;
}

pub fn extractCalleeName(v: *Validator, e: *Ast.CallExpr) ?[]const u8 {
    const func = e.func orelse return "";
    return switch (func) {
        .ident => |ident| ident.name,
        .member => "", // Method call — simplified, treat as unknown
        else => blk: {
            v.addErrorWithCodeR(exprRange(.{ .call = e }), Diagnostic.Code.not_callable, "expression is not callable");
            break :blk null;
        },
    };
}

pub fn checkBitcastDispatch(v: *Validator, e: *Ast.CallExpr) Allocator.Error!InferResult {
    if (e.template_type) |tt| {
        const dest_type = v.resolveType(tt) orelse return InferResult.fail;
        return try checkBitcastCall(v, e, dest_type);
    }
    v.addErrorWithCodeR(
        exprRange(.{ .call = e }),
        Diagnostic.Code.invalid_conversion,
        v.fmtError("'bitcast' requires a template type argument, e.g. 'bitcast<u32>(x)'", .{}),
    );
    return InferResult.fail;
}

pub fn checkTemplateTypeCtor(v: *Validator, e: *Ast.CallExpr, tt: Ast.Type, callee_name: []const u8) Allocator.Error!InferResult {
    const resolved = v.resolveType(tt) orelse return InferResult.fail;
    // Use type string as callee_name when the parser doesn't set func
    const name = if (callee_name.len > 0) callee_name else resolved.string();
    // Validate constructor arguments against the resolved type
    var constructor_arg_types: std.ArrayList(?Types.Type) = .empty;
    var args_stage: ExprStage = .const_expr;
    for (e.args.items) |arg| {
        const ar = try checkExpr(v, arg);
        try constructor_arg_types.append(v.arena, ar.typ);
        args_stage = ExprStage.combine(args_stage, ar.stage);
    }
    const ret = checkTypeConstructor(v, e, name, resolved, constructor_arg_types.items) orelse
        return .{ .typ = null, .stage = args_stage };
    return InferResult.some(ret, args_stage);
}

pub fn checkBareTypeCtor(v: *Validator, e: *Ast.CallExpr, callee_name: []const u8, t: Types.Type, arg_types: []const ?Types.Type, args_stage: ExprStage) InferResult {
    // Bare vec/mat constructors (`vec2`, `mat3x3`, …) infer their
    // element type from the argument list per WGSL §14.462 rather than
    // defaulting to f32. parseVectorShorthand / parseMatrixShorthand
    // return a f32-default type; swap its element with the arg-unified
    // scalar before validation so `let x = vec2(1, 2)` is vec2<i32>
    // (or vec2<abstract-int> in contexts that retain abstractness).
    const effective_t = inferGenericCtorElement(v, callee_name, t, arg_types) orelse t;
    const ret = checkTypeConstructor(v, e, callee_name, effective_t, arg_types) orelse
        return .{ .typ = null, .stage = args_stage };
    return InferResult.some(ret, args_stage);
}

pub fn checkBuiltinCall(v: *Validator, e: *Ast.CallExpr, callee_name: []const u8, builtin_fn: Builtins.Builtin) Allocator.Error!InferResult {
    // Check argument count
    const arg_count: u32 = @intCast(e.args.items.len);
    if (!builtin_fn.checkArgCount(arg_count)) {
        v.addErrorWithCodeR(exprRange(.{ .call = e }), Diagnostic.Code.invalid_arg_count, v.fmtError("'{s}' expects {d} to {d} arguments, got {d}", .{ callee_name, builtin_fn.min_args, builtin_fn.max_args, arg_count }));
        return InferResult.fail;
    }

    // Collect argument types (single pass — no double evaluation)
    var arg_types: [8]?Types.Type = .{null} ** 8;
    var args_stage: ExprStage = .const_expr;
    const max_check = @min(e.args.items.len, 8);
    for (0..max_check) |i| {
        const ar = try checkExpr(v, e.args.items[i]);
        arg_types[i] = ar.typ;
        args_stage = ExprStage.combine(args_stage, ar.stage);
    }
    // A builtin's own evaluation stage caps how early the call can run:
    // a `.const_eval` builtin preserves its args' stage; `.runtime` forces
    // runtime; `.override` allows at most override-time evaluation.
    const call_stage: ExprStage = switch (builtin_fn.stage) {
        .const_eval => args_stage,
        .override => ExprStage.combine(args_stage, .override_expr),
        .runtime => .runtime_expr,
    };

    if (try preValidateTextureBuiltin(v, e, callee_name, arg_types[0..max_check])) |result| {
        return result;
    }

    // Declarative overload resolution. Every callable builtin reaches
    // this point with `overloads` populated; `bitcast<T>` dispatched
    // earlier via `checkBitcastCall` because its sig set is template-
    // shape-selected and its slot-0/slot-1 bindings are seeded from the
    // template — but the solver and signature DSL it uses are the same.
    // The `Builtins` test suite enforces the invariant that every entry
    // other than bitcast has a non-empty `_sigs`.
    std.debug.assert(builtin_fn.overloads.len > 0);
    const argc = @min(e.args.items.len, 8);
    const res = Overload.resolve(builtin_fn.overloads, arg_types[0..argc]);
    switch (res) {
        .err => |err| {
            // Arity was already validated above via `checkArgCount`, so
            // a count mismatch here means the builtin's per-overload
            // arity differs from min/max — treat it as a no-match.
            const bad_idx = if (err.kind == .no_matching_overload) err.first_bad_arg else 0;
            const bad_type_str: []const u8 = if (bad_idx < argc)
                if (arg_types[bad_idx]) |bt| bt.string() else "<unknown>"
            else
                "<missing>";
            v.addErrorWithCodeR(
                exprRange(.{ .call = e }),
                Diagnostic.Code.invalid_arg_type,
                v.fmtError(
                    "no matching overload for '{s}': argument {d} has type '{s}'",
                    .{ callee_name, bad_idx + 1, bad_type_str },
                ),
            );
            return InferResult.fail;
        },
        .ok => |ok| {
            const sig = builtin_fn.overloads[ok.sig_index];
            const ret = try buildOverloadResult(v, sig.result, &ok.bindings, arg_types) orelse
                return .{ .typ = null, .stage = call_stage };
            return InferResult.some(ret, call_stage);
        },
    }
}

/// Materialize the return type for an overload-resolved builtin call.
/// Dispatches on the signature's `ResultRule` — pattern-driven types go
/// through `Overload.buildPatternType`; struct-synthesizing builtins call
/// `synthesize{Frexp,Modf,AtomicExchange}Result` so the cached
/// `__frexp_result_*` / `__modf_result_*` structs stay shared across
/// every call site that produces them.
pub fn buildOverloadResult(
    v: *Validator,
    rule: Overload.ResultRule,
    bindings: *const [Overload.max_tparams]Overload.Binding,
    arg_types: [8]?Types.Type,
) Allocator.Error!?Types.Type {
    switch (rule) {
        .pattern => |p| return Overload.buildPatternType(v.arena, p, bindings),
        .fixed => |t| return t,
        .synth_frexp => |arg_idx| {
            const at = arg_types[arg_idx] orelse return null;
            return try synthesizeFrexpResult(v, at);
        },
        .synth_modf => |arg_idx| {
            const at = arg_types[arg_idx] orelse return null;
            return try synthesizeModfResult(v, at);
        },
        .synth_atomic_cmp_xchg => |arg_idx| {
            const at = arg_types[arg_idx] orelse return null;
            if (at != .pointer) return null;
            if (at.pointer.element != .atomic) return null;
            const elem = at.pointer.element.atomic.element;
            return try synthesizeAtomicExchangeResult(v, elem);
        },
        .bound_scalar_as_type => |tp_idx| {
            const b = bindings[tp_idx];
            if (!b.bound) return null;
            const kind = b.scalar_kind orelse return null;
            return .{ .scalar = switch (kind) {
                .bool => Types.scalar_bool_ptr,
                .i32 => Types.scalar_i32_ptr,
                .u32 => Types.scalar_u32_ptr,
                .f32 => Types.scalar_f32_ptr,
                .f16 => Types.scalar_f16_ptr,
                .abstract_int => Types.scalar_abstract_int_ptr,
                .abstract_float => Types.scalar_abstract_float_ptr,
            } };
        },
        .bool_shape_of => |arg_idx| {
            const at = arg_types[arg_idx] orelse return null;
            return try boolShapeOf(v, at);
        },
    }
}

/// Bool-shaped like `t`: `vecN<bool>` for a `vecN` operand, `bool` otherwise.
/// The result type of the comparison / equality operators (§8.7) — the
/// materializer for `Overload.ResultRule.bool_shape_of`.
fn boolShapeOf(v: *Validator, t: Types.Type) Allocator.Error!Types.Type {
    if (t == .vector) {
        const bvec = try v.arena.create(Types.Vector);
        bvec.* = .{ .width = t.vector.width, .element = Types.scalar_bool_ptr };
        return .{ .vector = bvec };
    }
    return Types.Bool;
}

/// Runs before `Overload.resolve()` for the two builtins whose WGSL rules
/// can't be expressed as pattern constraints without adding a per-field
/// mismatch-reason channel to the generic solver. See the
/// `Pattern.tparam_texture` comment in `Overload.zig` for the trade-off.
///
/// Returns `null` to let the declarative solver run; returns
/// `InferResult.fail` (after emitting a diagnostic) when an access-mode
/// or coord-dim rule is violated.
pub fn preValidateTextureBuiltin(
    v: *Validator,
    e: *Ast.CallExpr,
    callee_name: []const u8,
    arg_types: []const ?Types.Type,
) Allocator.Error!?InferResult {
    const is_store = std.mem.eql(u8, callee_name, "textureStore");
    const is_load = std.mem.eql(u8, callee_name, "textureLoad");
    if (!is_store and !is_load) return null;
    if (arg_types.len == 0) return null;

    const at = arg_types[0] orelse return null;
    if (at != .texture or at.texture.kind != .storage) return null;

    const am = at.texture.access_mode;
    if (is_store and am != .write and am != .read_write) {
        v.addErrorWithCodeR(
            exprRange(.{ .call = e }),
            Diagnostic.Code.invalid_arg_type,
            v.fmtError("'textureStore' requires 'write' or 'read_write' access, got 'read'", .{}),
        );
        return InferResult.fail;
    }
    if (is_load and am != .read and am != .read_write) {
        v.addErrorWithCodeR(
            exprRange(.{ .call = e }),
            Diagnostic.Code.invalid_arg_type,
            v.fmtError("'textureLoad' requires 'read' or 'read_write' access on a storage texture, got 'write'", .{}),
        );
        return InferResult.fail;
    }

    if (is_store and arg_types.len > 1) {
        if (arg_types[1]) |coord| {
            if (!textureCoordMatches(at.texture.dimension, coord)) {
                v.addErrorWithCodeR(
                    exprRange(.{ .call = e }),
                    Diagnostic.Code.invalid_arg_type,
                    v.fmtError(
                        "'textureStore' coord has wrong dimension: expected {s}, got '{s}'",
                        .{ textureCoordExpected(at.texture.dimension), coord.string() },
                    ),
                );
                return InferResult.fail;
            }
        }
    }

    return null;
}

/// Returns true when `coord` has the scalar/vector width the texture
/// dimension requires. Covers only the shapes that appear in
/// textureStore (coord is always integer-typed) and other indexed loads.
/// cube/cube_array use vec3<f32> for sampling direction, but textureStore
/// is not defined on them, so this helper doesn't model that case.
pub fn textureCoordMatches(dim: Types.TextureDimension, coord: Types.Type) bool {
    const coord_conc = Types.concreteType(coord);
    return switch (dim) {
        .@"1d" => coord_conc == .scalar and Types.isInteger(coord_conc),
        .@"2d" => coord_conc == .vector and coord_conc.vector.width == 2 and Types.isInteger(.{ .scalar = coord_conc.vector.element }),
        .@"2d_array" => coord_conc == .vector and coord_conc.vector.width == 2 and Types.isInteger(.{ .scalar = coord_conc.vector.element }),
        .@"3d" => coord_conc == .vector and coord_conc.vector.width == 3 and Types.isInteger(.{ .scalar = coord_conc.vector.element }),
        .cube, .cube_array => coord_conc == .vector and coord_conc.vector.width == 3,
    };
}

pub fn textureCoordExpected(dim: Types.TextureDimension) []const u8 {
    return switch (dim) {
        .@"1d" => "i32/u32",
        .@"2d", .@"2d_array" => "vec2<i32>/vec2<u32>",
        .@"3d" => "vec3<i32>/vec3<u32>",
        .cube, .cube_array => "vec3<f32>",
    };
}

pub fn checkUserFunctionCall(v: *Validator, e: *Ast.CallExpr, ident: *Ast.IdentExpr, callee_name: []const u8) Allocator.Error!InferResult {
    // Stage follows the args' combined staging. This matches the long-
    // standing `classifyExprStage` behavior: WGSL doesn't allow user
    // functions at shader-creation time, but a separate initializer /
    // const_assert check already rejects that via the `invalid_const_expr`
    // diagnostic on the enclosing expression, so we don't bump to
    // `.runtime_expr` here and avoid duplicate staging errors.
    if (ident.ref.isValid()) {
        const idx = ident.ref.index();

        // Entry points must not be called as functions (WGSL spec 8.6)
        if (idx < v.module.symbols.items.len and v.module.symbols.items[idx].flags.is_entry_point) {
            v.addErrorWithCodeR(exprRange(.{ .call = e }), Diagnostic.Code.entry_point_called, v.fmtError("entry point '{s}' cannot be the target of a function call", .{callee_name}));
            return InferResult.fail;
        }

        if (v.symbol_types.get(idx)) |sym_type| {
            switch (sym_type) {
                .function => |fn_type| {
                    const call_range = exprRange(.{ .call = e });
                    const fn_related = v.makeRelatedR(v.symbolRange(ident.ref), v.fmtError("'{s}' declared here", .{callee_name}));
                    // Check argument count
                    if (e.args.items.len != fn_type.parameters.len) {
                        v.addErrorWithRelatedR(call_range, Diagnostic.Code.invalid_arg_count, v.fmtError("'{s}' expects {d} arguments, got {d}", .{ callee_name, fn_type.parameters.len, e.args.items.len }), fn_related);
                        return InferResult.fail;
                    }
                    // Check argument types
                    var args_stage: ExprStage = .const_expr;
                    for (e.args.items, 0..) |arg, ai| {
                        if (ai < fn_type.parameters.len) {
                            const arg_r = try checkExpr(v, arg);
                            args_stage = ExprStage.combine(args_stage, arg_r.stage);
                            if (arg_r.typ) |at| {
                                const param_type = fn_type.parameters[ai];
                                if (!at.eql(param_type) and !Types.canConvertTo(at, param_type)) {
                                    v.addErrorWithRelatedR(call_range, Diagnostic.Code.invalid_arg_type, v.fmtError("argument {d} of '{s}' has type '{s}', expected '{s}'", .{ ai + 1, callee_name, at.string(), param_type.string() }), fn_related);
                                    return InferResult.fail;
                                }
                            }
                        }
                    }
                    const ret = fn_type.return_type orelse return InferResult.fail;
                    return InferResult.some(ret, args_stage);
                },
                else => {
                    // Symbol exists but is not a function
                    reportNotCallable(v, e, callee_name);
                    return InferResult.fail;
                },
            }
        }
        // Symbol exists but no type — check if it's a function symbol
        if (idx < v.module.symbols.items.len and
            v.module.symbols.items[idx].kind == .function)
        {
            // User function — check argument count against parameters
            return InferResult.fail; // Can't fully type-check without function type
        }
    }

    // Not resolvable — report error
    if (callee_name.len > 0 and !Builtins.isBuiltin(callee_name)) {
        reportNotCallable(v, e, callee_name);
        return InferResult.fail;
    }
    return InferResult.fail;
}

/// Bare `vec2`/`vec3`/`vec4` and `matCxR` accept any scalar element type
/// that's common to the arguments. `lookupType` hands back an f32 default
/// so other call paths stay simple; here we replace the element with the
/// unified scalar across the args (AbstractInt/AbstractFloat propagate
/// unless a concrete arg is present). Returns null when the name is not
/// a bare numeric constructor or when we fail to pick an element.
pub fn inferGenericCtorElement(v: *Validator, name: []const u8, default: Types.Type, arg_types: []const ?Types.Type) ?Types.Type {
    if (std.mem.eql(u8, name, "array")) return inferArrayCtorType(v, arg_types);

    const is_bare_vec = std.mem.eql(u8, name, "vec2") or
        std.mem.eql(u8, name, "vec3") or
        std.mem.eql(u8, name, "vec4");
    const is_bare_mat = name.len == 6 and
        std.mem.startsWith(u8, name, "mat") and
        name[4] == 'x';
    if (!is_bare_vec and !is_bare_mat) return null;

    var elem: ?*const Types.Scalar = null;
    for (arg_types) |at_opt| {
        const at = at_opt orelse continue;
        const scalar_ptr: *const Types.Scalar = switch (at) {
            .scalar => |s| s,
            .vector => |vv| vv.element,
            .matrix => |mm| mm.element,
            else => continue,
        };
        elem = unifyScalarKinds(elem, scalar_ptr);
    }

    // WGSL zero-value vector constructor `vecN()` (no template, no args) is an
    // abstract-int vector, so it materializes to whatever concrete element the
    // context demands: `var i : vec3i = vec3();` → vec3<i32>, and the f32/u32
    // slots likewise. This mirrors the argument-typed path below — `vec3(1,2,3)`
    // already unifies to vec3<abstract-int>. Matrices keep the f32 default here
    // (their element must be floating-point) and are handled by checkMatrixCtor.
    if (is_bare_vec and arg_types.len == 0) {
        const result = v.arena.create(Types.Vector) catch return null;
        result.* = .{ .width = default.vector.width, .element = Types.scalar_abstract_int_ptr };
        return .{ .vector = result };
    }

    const chosen = elem orelse return null;
    if (is_bare_vec) {
        const result = v.arena.create(Types.Vector) catch return null;
        result.* = .{ .width = default.vector.width, .element = chosen };
        return .{ .vector = result };
    }
    // Matrices carry a float element only; fall back to default if an
    // integer sneaks in — checkTypeConstructor reports the real error.
    if (!chosen.isFloat()) return null;
    const result = v.arena.create(Types.Matrix) catch return null;
    result.* = .{ .cols = default.matrix.cols, .rows = default.matrix.rows, .element = chosen };
    return .{ .matrix = result };
}

/// Infers the type of an element-typed array constructor `array(e1, e2, ...)`:
/// element type is the common type of the arguments (kept abstract, like the
/// bare vec/mat forms, so it concretizes at the use site) and the count is the
/// argument count. Returns null — falling back to the default `array<f32, 0>`
/// so the array-ctor overload sigs report the mismatch — when there are no arguments or
/// the argument types have no common type.
fn inferArrayCtorType(v: *Validator, arg_types: []const ?Types.Type) ?Types.Type {
    if (arg_types.len == 0) return null;
    var elem: ?Types.Type = null;
    for (arg_types) |at_opt| {
        const at = at_opt orelse return null; // unknown arg type — bail
        elem = if (elem) |prev| (Types.commonType(prev, at) orelse return null) else at;
    }
    const chosen = elem orelse return null;
    // Keep synthesized array types within the same nesting ceiling the parser
    // enforces on declared types (`max_parser_type_depth`). A pathologically
    // deep `array(array(array(...)))` therefore falls back to the default
    // `array<f32, 0>` and is cleanly rejected as not-constructible instead of
    // producing an unbounded-depth type. `+ 1` accounts for the array level
    // this call adds on top of `chosen`.
    if (Types.arrayNestingDepth(chosen, constants.max_parser_type_depth) + 1 >= constants.max_parser_type_depth) return null;
    const result = v.arena.create(Types.Array) catch return null;
    result.* = .{ .element = chosen, .count = @intCast(arg_types.len) };
    return .{ .array = result };
}

pub fn unifyScalarKinds(a: ?*const Types.Scalar, b: *const Types.Scalar) ?*const Types.Scalar {
    const prev = a orelse return b;
    if (prev.kind == b.kind) return prev;
    // Abstract operands yield to concrete of a compatible family.
    if (prev.kind == .abstract_int and b.kind != .bool) return b;
    if (b.kind == .abstract_int and prev.kind != .bool) return prev;
    if (prev.kind == .abstract_float and b.isFloat()) return b;
    if (b.kind == .abstract_float and prev.isFloat()) return prev;
    // Incompatible concrete kinds — keep prev; validation will report it.
    return prev;
}

pub fn reportNotCallable(v: *Validator, e: *Ast.CallExpr, callee_name: []const u8) void {
    if (v.suggestCallable(callee_name, e.args.items.len)) |s| {
        v.addErrorWithCodeDataR(exprRange(.{ .call = e }), Diagnostic.Code.not_callable, v.fmtError("'{s}' is not a function or type constructor; did you mean '{s}'?", .{ callee_name, s }), .{ .did_you_mean = s });
    } else {
        v.addErrorWithCodeR(exprRange(.{ .call = e }), Diagnostic.Code.not_callable, v.fmtError("'{s}' is not a function or type constructor", .{callee_name}));
    }
}

/// True when a call's callee is an identifier that names a WGSL builtin
/// function but the binder resolved it to a *value* declaration
/// (let/var/const/override/parameter) in scope. That declaration shadows the
/// builtin, so the call targets a non-callable value — the "shadowed builtin
/// is uncallable" error Tint reports. A user function / struct / alias of the
/// same name is deliberately excluded: calling it resolves to a callable or
/// constructible entity, which WGSL permits.
fn shadowedBuiltinValueCall(v: *Validator, e: *Ast.CallExpr) bool {
    const func = e.func orelse return false;
    const ident = switch (func) {
        .ident => |id| id,
        else => return false,
    };
    // `was_counted` is set only when the binder resolved the callee to an
    // in-scope symbol on the normal (declared-before) path. It both proves the
    // ref is valid and excludes the use-before-declaration case (E0102), where
    // the ref is set for goto-def but the shadow error would be redundant.
    if (!ident.was_counted or !ident.ref.isValid()) return false;
    if (!Builtins.isBuiltin(ident.name)) return false;
    const idx = ident.ref.index();
    if (idx >= v.module.symbols.items.len) return false;
    return switch (v.module.symbols.items[idx].kind) {
        .@"const", .override, .let, .@"var", .parameter => true,
        else => false,
    };
}

// Cache synthesized structs so repeated calls to frexp/modf/
// atomicCompareExchangeWeak with the same operand type return the
// same *Struct pointer (lets downstream member-access / eq work).
pub fn getOrSynthStruct(v: *Validator, name: []const u8, build: *const fn (*Validator, []const u8) Allocator.Error!*Types.Struct) Allocator.Error!*Types.Struct {
    if (v.struct_types.get(name)) |st| return st;
    const st = try build(v, name);
    try v.struct_types.put(v.arena, st.name, st);
    return st;
}

pub fn synthesizeAtomicExchangeResult(v: *Validator, elem: *const Types.Scalar) Allocator.Error!Types.Type {
    const name = try std.fmt.allocPrint(v.arena, "__atomic_compare_exchange_result_{s}", .{elem.string()});
    if (v.struct_types.get(name)) |st| return .{ .@"struct" = st };

    const fields = try v.arena.alloc(Types.StructField, 2);
    fields[0] = .{ .name = "old_value", .typ = .{ .scalar = elem }, .offset = 0 };
    fields[1] = .{ .name = "exchanged", .typ = Types.Bool, .offset = 0 };
    const st = try v.arena.create(Types.Struct);
    st.* = .{ .name = name, .fields = fields, .size_bytes = 0, .align_bytes = 0, .has_runtime_array = false };
    st.computeLayout();
    try v.struct_types.put(v.arena, name, st);
    return .{ .@"struct" = st };
}

pub fn frexpExpType(v: *Validator, operand: Types.Type) Allocator.Error!Types.Type {
    switch (operand) {
        .scalar => return Types.I32,
        .vector => |vv| {
            const result = try v.arena.create(Types.Vector);
            result.* = .{ .width = vv.width, .element = Types.scalar_i32_ptr };
            return .{ .vector = result };
        },
        else => return Types.I32,
    }
}

pub fn synthesizeFrexpResult(v: *Validator, operand: Types.Type) Allocator.Error!?Types.Type {
    if (!Types.isFloat(operand)) return null;
    const name = try std.fmt.allocPrint(v.arena, "__frexp_result_{s}", .{operand.string()});
    if (v.struct_types.get(name)) |st| return .{ .@"struct" = st };

    const fields = try v.arena.alloc(Types.StructField, 2);
    fields[0] = .{ .name = "fract", .typ = operand, .offset = 0 };
    fields[1] = .{ .name = "exp", .typ = try frexpExpType(v, operand), .offset = 0 };
    const st = try v.arena.create(Types.Struct);
    st.* = .{ .name = name, .fields = fields, .size_bytes = 0, .align_bytes = 0, .has_runtime_array = false };
    st.computeLayout();
    try v.struct_types.put(v.arena, name, st);
    return .{ .@"struct" = st };
}

pub fn synthesizeModfResult(v: *Validator, operand: Types.Type) Allocator.Error!?Types.Type {
    if (!Types.isFloat(operand)) return null;
    const name = try std.fmt.allocPrint(v.arena, "__modf_result_{s}", .{operand.string()});
    if (v.struct_types.get(name)) |st| return .{ .@"struct" = st };

    const fields = try v.arena.alloc(Types.StructField, 2);
    fields[0] = .{ .name = "fract", .typ = operand, .offset = 0 };
    fields[1] = .{ .name = "whole", .typ = operand, .offset = 0 };
    const st = try v.arena.create(Types.Struct);
    st.* = .{ .name = name, .fields = fields, .size_bytes = 0, .align_bytes = 0, .has_runtime_array = false };
    st.computeLayout();
    try v.struct_types.put(v.arena, name, st);
    return .{ .@"struct" = st };
}

pub fn checkTypeConstructor(v: *Validator, e: *Ast.CallExpr, callee_name: []const u8, t: Types.Type, arg_types: []const ?Types.Type) ?Types.Type {
    const range = exprRange(.{ .call = e });

    // Spec: only constructible types can be used as value constructors.
    // Vectors/matrices with an abstract element type are transient results
    // of bare `vec2(...)` / `matCxR(...)` element inference — they will be
    // concretized at the enclosing use site, so we permit them here even
    // though `isConstructible` rejects abstract-typed containers.
    const is_transient_abstract = switch (t) {
        .vector => |vv| !vv.element.isConcrete(),
        .matrix => |mm| !mm.element.isConcrete(),
        .array => |aa| !aa.element.isConcrete(),
        else => false,
    };
    if (!t.isConstructible() and !is_transient_abstract and !std.mem.eql(u8, callee_name, "bitcast")) {
        v.addErrorWithCodeR(range, Diagnostic.Code.type_mismatch, v.fmtError("type '{s}' is not constructible", .{t.string()}));
        return null;
    }

    // scalar / vector / matrix / struct / array all validate through the
    // overload engine. `ctorSigsFor` yields an empty sig set for any other
    // target, but the constructibility gate above already excluded those, so
    // `else` is unreachable for a well-typed call and just passes t through.
    return switch (t) {
        .scalar, .vector, .matrix, .@"struct", .array => ctorViaEngine(v, range, callee_name, t, arg_types),
        else => t,
    };
}

/// Per-invocation context handed to `ctorRefine` through the engine's opaque
/// `ctx` pointer. Carries what the refiner needs to reproduce constructor
/// diagnostics — the validator (for `fmtError`), the callee name, and the
/// target type — none of which live in `Overload.RefineInput`.
const CtorRefineCtx = struct {
    v: *Validator,
    callee_name: []const u8,
    target: Types.Type,
};

/// Shared value-constructor validation on the overload engine. Derives the sig
/// set with `Overload.ctorSigsFor`, resolves against `t`, and on failure lets
/// `ctorRefine` reproduce the constructor-specific message (component counts,
/// "did you mean 'vec3'?", field/element conversion, …). On success the result
/// IS `t`; scalar targets additionally get the W0101 redundant-cast warning the
/// old switch emitted on a no-op cast. Constructors are migrated onto this path
/// family by family (Block 4b); the outer `checkTypeConstructor` switch routes
/// the migrated arms here.
fn ctorViaEngine(v: *Validator, range: LocRange, callee_name: []const u8, t: Types.Type, arg_types: []const ?Types.Type) ?Types.Type {
    const sigs = Overload.ctorSigsFor(v.arena, t) catch return null;
    var rctx = CtorRefineCtx{ .v = v, .callee_name = callee_name, .target = t };
    const res = Overload.resolveTargetedRefined(sigs, t, arg_types, .{
        .ctx = &rctx,
        .refine = ctorRefine,
    });
    switch (res) {
        .ok => |typ| {
            if (t == .scalar) warnRedundantScalarCast(v, range, t, arg_types);
            return typ;
        },
        .err => |f| {
            if (f.refined) |rd| {
                v.addErrorWithCodeR(range, rd.code, rd.message);
            } else {
                // Every migrated family's refiner is exhaustive on its failures,
                // so this fallback is unreachable in practice; keep a generic
                // message rather than emitting nothing.
                v.addErrorWithCodeR(range, Diagnostic.Code.invalid_arg_type, v.fmtError("no matching overload for '{s}' constructor", .{callee_name}));
            }
            return null;
        },
    }
}

/// Engine failure-path hook: reproduces the constructor diagnostic the
/// hand-rolled switch used to emit, dispatched on the target type. Cast back
/// from the opaque `ctx` the validator installed. Returns null only for a
/// target family not yet migrated onto `ctorViaEngine` (whose arm never routes
/// here).
fn ctorRefine(ctx_ptr: *anyopaque, input: Overload.RefineInput) ?Overload.RefinedDiagnostic {
    const ctx: *CtorRefineCtx = @ptrCast(@alignCast(ctx_ptr));
    return switch (ctx.target) {
        .scalar => refineScalarCtor(ctx.v, ctx.callee_name, ctx.target, input.arg_types),
        .vector => |ve| refineVectorCtor(ctx.v, ctx.callee_name, ctx.target, ve, input.arg_types),
        .matrix => |mt| refineMatrixCtor(ctx.v, ctx.callee_name, ctx.target, mt, input.arg_types),
        .@"struct" => |st| refineStructCtor(ctx.v, ctx.callee_name, st, input.arg_types),
        .array => |arr| refineArrayCtor(ctx.v, ctx.callee_name, arr, input.arg_types),
        else => null,
    };
}

/// Scalar `T(...)` failures: too many args, or a non-scalar argument. Mirrors
/// the old `checkScalarCtor` error branches verbatim.
fn refineScalarCtor(v: *Validator, callee_name: []const u8, t: Types.Type, arg_types: []const ?Types.Type) ?Overload.RefinedDiagnostic {
    if (arg_types.len > 1) return .{
        .code = Diagnostic.Code.invalid_arg_count,
        .message = v.fmtError("'{s}' constructor takes at most 1 argument, got {d}", .{ callee_name, arg_types.len }),
    };
    if (arg_types.len == 1) {
        if (arg_types[0]) |at| {
            if (at != .scalar) return .{
                .code = Diagnostic.Code.invalid_conversion,
                .message = v.fmtError("cannot convert '{s}' to '{s}'", .{ at.string(), t.string() }),
            };
        }
    }
    return null;
}

/// W0101 on a no-op scalar cast (`f32(x)` where x is already a concrete f32).
/// Emitted on the *success* path — the refiner only runs on failure — so it
/// lives here, not in `ctorRefine`.
fn warnRedundantScalarCast(v: *Validator, range: LocRange, t: Types.Type, arg_types: []const ?Types.Type) void {
    if (arg_types.len != 1) return;
    const at = arg_types[0] orelse return;
    if (at != .scalar) return;
    if (at.scalar.kind == t.scalar.kind and t.scalar.isConcrete()) {
        v.addWarningWithCodeR(range, Diagnostic.Code.redundant_cast, v.fmtError("redundant cast: '{s}' is already '{s}'", .{ at.string(), t.string() }));
    }
}

/// Vector `vecN<E>(...)` failures, dispatched on arity like the old
/// `checkVectorCtor`. Reproduces the component-count / element-conversion
/// messages the engine's generic no-match can't. Reached only on engine
/// failure — a zero-arg / splat / copy / valid-compose call succeeds in the
/// engine and never lands here.
fn refineVectorCtor(v: *Validator, callee_name: []const u8, t: Types.Type, ve: *const Types.Vector, arg_types: []const ?Types.Type) ?Overload.RefinedDiagnostic {
    if (arg_types.len == 1) return refineVectorCtorOne(v, callee_name, t, ve, arg_types);
    return refineVectorCtorMulti(v, callee_name, t, ve, arg_types);
}

fn refineVectorCtorOne(v: *Validator, callee_name: []const u8, t: Types.Type, ve: *const Types.Vector, arg_types: []const ?Types.Type) ?Overload.RefinedDiagnostic {
    const at = arg_types[0] orelse return null; // null arg is engine-feasible
    if (at == .scalar) {
        // Splat rejected: element not implicitly convertible to E.
        return .{ .code = Diagnostic.Code.invalid_conversion, .message = v.fmtError("cannot convert '{s}' to '{s}' in '{s}' constructor", .{ at.string(), ve.element.string(), callee_name }) };
    }
    if (at == .vector) {
        const src_width: u8 = at.vector.width;
        if (src_width != ve.width) {
            if (suggestVecForComponents(v, callee_name, src_width)) |suggestion| {
                return .{ .code = Diagnostic.Code.invalid_arg_count, .message = v.fmtError("'{s}' requires {d} components, got {d}; did you mean '{s}'?", .{ callee_name, ve.width, src_width, suggestion }) };
            }
            return .{ .code = Diagnostic.Code.invalid_arg_count, .message = v.fmtError("'{s}' requires {d} components, got {d}", .{ callee_name, ve.width, src_width }) };
        }
        // Same width: the single-vector copy form is explicit (composite_convert),
        // so reaching here means a genuinely non-convertible element
        // (e.g. abstract-float -> i32).
        return .{ .code = Diagnostic.Code.invalid_conversion, .message = v.fmtError("cannot convert '{s}' to '{s}'", .{ at.string(), t.string() }) };
    }
    // Any other argument shape: the old switch silently accepted these (return
    // t); the engine now rejects them. Report the closest conversion error.
    return .{ .code = Diagnostic.Code.invalid_conversion, .message = v.fmtError("cannot convert '{s}' to '{s}'", .{ at.string(), t.string() }) };
}

fn refineVectorCtorMulti(v: *Validator, callee_name: []const u8, t: Types.Type, ve: *const Types.Vector, arg_types: []const ?Types.Type) ?Overload.RefinedDiagnostic {
    // Count total components (scalars + vector widths).
    var total: usize = 0;
    for (arg_types) |at_opt| {
        const at = at_opt orelse return null; // null arg is engine-feasible
        if (at == .scalar) {
            total += 1;
        } else if (at == .vector) {
            total += at.vector.width;
        } else {
            // Non scalar/vector arg: old switch accepted; engine now rejects.
            return .{ .code = Diagnostic.Code.invalid_conversion, .message = v.fmtError("cannot convert '{s}' to '{s}'", .{ at.string(), t.string() }) };
        }
    }
    if (total != ve.width) {
        if (suggestVecForComponents(v, callee_name, total)) |suggestion| {
            return .{ .code = Diagnostic.Code.invalid_arg_count, .message = v.fmtError("'{s}' requires {d} components, got {d}; did you mean '{s}'?", .{ callee_name, ve.width, total, suggestion }) };
        }
        return .{ .code = Diagnostic.Code.invalid_arg_count, .message = v.fmtError("'{s}' requires {d} components, got {d}", .{ callee_name, ve.width, total }) };
    }
    // Component count matches: some argument's element failed to convert.
    for (arg_types) |at_opt| {
        const at = at_opt orelse continue;
        const src_elem = elementTypeOf(at) orelse continue;
        if (!canConvertScalarTo(src_elem, ve.element)) {
            return .{ .code = Diagnostic.Code.invalid_conversion, .message = v.fmtError("cannot convert '{s}' to '{s}' in '{s}' constructor", .{ src_elem.string(), ve.element.string(), callee_name }) };
        }
    }
    return null;
}

/// Matrix `matCxR<E>(...)` failures, dispatched on arity like the old
/// `checkMatrixCtor`. Reproduces the dichotomy / conversion messages the
/// engine's generic no-match can't. Reached only on engine failure.
fn refineMatrixCtor(v: *Validator, callee_name: []const u8, t: Types.Type, mt: *const Types.Matrix, arg_types: []const ?Types.Type) ?Overload.RefinedDiagnostic {
    if (arg_types.len == 1) return refineMatrixCtorOne(v, t, arg_types);
    return refineMatrixCtorMulti(v, callee_name, mt, arg_types);
}

fn refineMatrixCtorOne(v: *Validator, t: Types.Type, arg_types: []const ?Types.Type) ?Overload.RefinedDiagnostic {
    const at = arg_types[0] orelse return null; // null arg is engine-feasible
    // Single-matrix copy/convert (composite_convert): a dimension or element
    // mismatch. A single non-matrix argument — which the old switch silently
    // accepted via `return t` — also lands here now; the same conversion error
    // is the right report.
    return .{ .code = Diagnostic.Code.invalid_conversion, .message = v.fmtError("cannot convert '{s}' to '{s}'", .{ at.string(), t.string() }) };
}

fn refineMatrixCtorMulti(v: *Validator, callee_name: []const u8, mt: *const Types.Matrix, arg_types: []const ?Types.Type) ?Overload.RefinedDiagnostic {
    // Classify args: all scalars or all vectors.
    var all_scalar = true;
    var all_vector = true;
    for (arg_types) |at_opt| {
        const at = at_opt orelse return null; // null arg is engine-feasible
        if (at != .scalar) all_scalar = false;
        if (at != .vector) all_vector = false;
    }

    if (all_scalar) {
        // C*R scalars required.
        if (arg_types.len != mt.cols * mt.rows) {
            return .{ .code = Diagnostic.Code.invalid_arg_count, .message = v.fmtError("'{s}' scalar constructor requires {d} values, got {d}", .{ callee_name, mt.cols * mt.rows, arg_types.len }) };
        }
        for (arg_types) |at_opt| {
            const at = at_opt orelse continue;
            if (at == .scalar and !canConvertScalarTo(at.scalar, mt.element)) {
                return .{ .code = Diagnostic.Code.invalid_conversion, .message = v.fmtError("cannot convert '{s}' to '{s}' in '{s}' constructor", .{ at.scalar.string(), mt.element.string(), callee_name }) };
            }
        }
        return null;
    }
    if (all_vector) {
        // C column vectors of height R required.
        if (arg_types.len != mt.cols) {
            return .{ .code = Diagnostic.Code.invalid_arg_count, .message = v.fmtError("'{s}' column constructor requires {d} vectors, got {d}", .{ callee_name, mt.cols, arg_types.len }) };
        }
        for (arg_types) |at_opt| {
            if (at_opt) |at| {
                if (at == .vector) {
                    if (at.vector.width != mt.rows) {
                        return .{ .code = Diagnostic.Code.invalid_arg_type, .message = v.fmtError("'{s}' column vectors must have {d} components, got {d}", .{ callee_name, mt.rows, at.vector.width }) };
                    }
                    if (!canConvertScalarTo(at.vector.element, mt.element)) {
                        return .{ .code = Diagnostic.Code.invalid_conversion, .message = v.fmtError("cannot convert '{s}' to '{s}' in '{s}' constructor", .{ at.vector.element.string(), mt.element.string(), callee_name }) };
                    }
                }
            }
        }
        return null;
    }
    // Mix of scalars and column vectors.
    return .{ .code = Diagnostic.Code.invalid_arg_type, .message = v.fmtError("'{s}' constructor requires all scalar values or all column vectors, not a mix", .{callee_name}) };
}

/// Struct `S(...)` failures: arity mismatch, or a field whose argument does not
/// convert. Mirrors the old `checkStructCtor` error branches verbatim. Reached
/// only on engine failure (arg_count 0 and arg_count == fields.len both succeed
/// in the engine, so a reached failure is a genuine count or field mismatch).
fn refineStructCtor(v: *Validator, callee_name: []const u8, st: *const Types.Struct, arg_types: []const ?Types.Type) ?Overload.RefinedDiagnostic {
    if (arg_types.len != st.fields.len) {
        return .{ .code = Diagnostic.Code.invalid_arg_count, .message = v.fmtError("'{s}' constructor expects {d} arguments, got {d}", .{ callee_name, st.fields.len, arg_types.len }) };
    }
    for (st.fields, 0..) |field, i| {
        if (i < arg_types.len) {
            if (arg_types[i]) |at| {
                if (!at.eql(field.typ) and !Types.canConvertTo(at, field.typ)) {
                    return .{ .code = Diagnostic.Code.invalid_conversion, .message = v.fmtError("cannot convert '{s}' to '{s}' for field '{s}'", .{ at.string(), field.typ.string(), field.name }) };
                }
            }
        }
    }
    return null;
}

/// Array `array<E, N>(...)` failures: wrong element count, or an element that
/// does not convert to E. Mirrors the old `checkArrayCtor` error branches
/// verbatim. Reached only on engine failure.
fn refineArrayCtor(v: *Validator, callee_name: []const u8, arr: *const Types.Array, arg_types: []const ?Types.Type) ?Overload.RefinedDiagnostic {
    if (arr.count > 0 and arg_types.len != arr.count) {
        return .{ .code = Diagnostic.Code.invalid_arg_count, .message = v.fmtError("'{s}' constructor expects {d} elements, got {d}", .{ callee_name, arr.count, arg_types.len }) };
    }
    for (arg_types, 0..) |at_opt, i| {
        if (at_opt) |at| {
            if (!at.eql(arr.element) and !Types.canConvertTo(at, arr.element)) {
                return .{ .code = Diagnostic.Code.invalid_conversion, .message = v.fmtError("cannot convert '{s}' to '{s}' for element {d}", .{ at.string(), arr.element.string(), i }) };
            }
        }
    }
    return null;
}

pub fn canConvertScalarTo(src: *const Types.Scalar, dst: *const Types.Scalar) bool {
    if (src == dst) return true;
    return Types.canConvertTo(.{ .scalar = src }, .{ .scalar = dst });
}

pub fn elementTypeOf(t: Types.Type) ?*const Types.Scalar {
    return switch (t) {
        .scalar => |s| s,
        .vector => |ve| ve.element,
        .matrix => |mt| mt.element,
        else => null,
    };
}

/// Returns the bit-width of a type for bitcast validation, or 0 if not bitcastable.
/// Spec: bitcast operands must be concrete numeric scalar or vector of concrete numeric scalars.
pub fn bitcastSize(t: Types.Type) u32 {
    switch (t) {
        .scalar => |s| {
            return switch (s.kind) {
                .f32, .i32, .u32 => 32,
                .f16 => 16,
                .bool, .abstract_int, .abstract_float => 0,
            };
        },
        .vector => |ve| {
            const elem_bits: u32 = switch (ve.element.kind) {
                .f32, .i32, .u32 => 32,
                .f16 => 16,
                .bool, .abstract_int, .abstract_float => return 0,
            };
            return elem_bits * ve.width;
        },
        else => return 0,
    }
}

/// Template-shape classification for `bitcast<T>(e)` dispatch. Selects
/// which sig array in `Builtins.bitcast_to_*_sigs` matches T's structure.
pub const BitcastTemplateShape = enum { scalar_32, vecN_32, vec2_f16, vec4_f16, invalid };

pub fn bitcastTemplateShape(t: Types.Type) BitcastTemplateShape {
    switch (t) {
        .scalar => |s| return switch (s.kind) {
            .i32, .u32, .f32 => .scalar_32,
            else => .invalid,
        },
        .vector => |ve| {
            switch (ve.element.kind) {
                .i32, .u32, .f32 => return .vecN_32,
                .f16 => return switch (ve.width) {
                    2 => .vec2_f16,
                    4 => .vec4_f16,
                    else => .invalid,
                },
                else => return .invalid,
            }
        },
        else => return .invalid,
    }
}

/// Declarative bitcast validation. The template type is already resolved;
/// pick its sig array, pre-seed bindings from the template, then run the
/// solver over the (1-arg) value arg. Size compat is post-checked.
pub fn checkBitcastCall(
    v: *Validator,
    e: *Ast.CallExpr,
    dest_type: Types.Type,
) Allocator.Error!InferResult {
    const range = exprRange(.{ .call = e });

    if (e.args.items.len != 1) {
        v.addErrorWithCodeR(range, Diagnostic.Code.invalid_arg_count, v.fmtError("'bitcast' requires exactly 1 argument, got {d}", .{e.args.items.len}));
        return InferResult.fail;
    }

    // Reject templates outside the bitcast domain up-front (bool scalar,
    // matrix, atomic, pointer, f16 scalar, vec3<f16>, …). This keeps the
    // "cannot bitcast to …" wording identical to the pre-Phase-3b path.
    const shape = bitcastTemplateShape(dest_type);
    const dst_size = bitcastSize(dest_type);
    if (shape == .invalid or dst_size == 0) {
        v.addErrorWithCodeR(range, Diagnostic.Code.invalid_conversion, v.fmtError("cannot bitcast to '{s}'; must be a numeric scalar or vector of numeric scalars", .{dest_type.string()}));
        // Still evaluate the arg for downstream type-checking; return dest_type.
        const arg_r = try checkExpr(v, e.args.items[0]);
        return InferResult.some(dest_type, arg_r.stage);
    }

    // Evaluate the source argument; concretize abstract numerics per §6.7.2.
    const arg_r = try checkExpr(v, e.args.items[0]);
    const raw_src = arg_r.typ orelse return InferResult.some(dest_type, arg_r.stage);
    const src_type = Types.concreteType(raw_src);

    // Domain check first: source must be a numeric scalar or vector of
    // numeric scalars. `bitcastSize` returns 0 for bool/pointer/matrix/
    // atomic/struct/handle — same gate as the pre-3b ad-hoc path.
    const src_size = bitcastSize(src_type);
    if (src_size == 0) {
        v.addErrorWithCodeR(range, Diagnostic.Code.invalid_conversion, v.fmtError("cannot bitcast from '{s}'; must be a numeric scalar or vector of numeric scalars", .{raw_src.string()}));
        return InferResult.some(dest_type, arg_r.stage);
    }

    // Size compatibility. Rejecting this before the solver preserves the
    // "must have the same bit-width" wording for cases where both operands
    // are individually valid numerics but their shapes don't line up.
    if (src_size != dst_size) {
        v.addErrorWithCodeR(range, Diagnostic.Code.invalid_conversion, v.fmtError("bitcast source type '{s}' ({d} bits) and destination type '{s}' ({d} bits) must have the same bit-width", .{ src_type.string(), src_size, dest_type.string(), dst_size }));
        return InferResult.some(dest_type, arg_r.stage);
    }

    // Pre-seed slot 0 with the template's element scalar kind; for vector
    // templates also seed slot 1 with the width. `bindScalar`/`bindWidth`
    // in the solver then enforce equality when sigs reference those slots.
    var seed: [Overload.max_tparams]Overload.Binding = @splat(.{});
    switch (dest_type) {
        .scalar => |s| seed[0] = .{ .bound = true, .scalar_kind = s.kind },
        .vector => |ve| {
            seed[0] = .{ .bound = true, .scalar_kind = ve.element.kind };
            seed[1] = .{ .bound = true, .width = ve.width };
        },
        else => unreachable, // filtered by bitcastTemplateShape above
    }

    const sigs = switch (shape) {
        .scalar_32 => Builtins.bitcast_to_scalar_sigs,
        .vecN_32 => Builtins.bitcast_to_vecN_32_sigs,
        .vec2_f16 => Builtins.bitcast_to_vec2_f16_sigs,
        .vec4_f16 => Builtins.bitcast_to_vec4_f16_sigs,
        .invalid => unreachable,
    };

    // Declarative shape-domain check: with sizes already matched, the
    // solver enforces that (src shape, dst shape) is one of the spec's
    // permitted combinations. Exotic same-size pairs that aren't in the
    // sig table (e.g. vec3<f16>↔vec3<f16> identity) would fall through
    // here as "cannot bitcast from"; none of those are currently tested
    // or reachable because `bitcastTemplateShape` rejects vec3<f16>
    // templates up-front.
    const res = Overload.resolveSeeded(sigs, seed, &[_]?Types.Type{src_type});
    if (res == .err) {
        v.addErrorWithCodeR(range, Diagnostic.Code.invalid_conversion, v.fmtError("cannot bitcast from '{s}'; must be a numeric scalar or vector of numeric scalars", .{raw_src.string()}));
    }
    return InferResult.some(dest_type, arg_r.stage);
}

/// Suggest a vector type name matching `total_components` by replacing the
/// width digit in `callee_name` (e.g. "vec2f" + 3 components → "vec3f").
pub fn suggestVecForComponents(v: *Validator, callee_name: []const u8, total_components: usize) ?[]const u8 {
    if (total_components < 2 or total_components > 4) return null;
    if (callee_name.len < 4 or !std.mem.startsWith(u8, callee_name, "vec")) return null;
    const buf = v.arena.alloc(u8, callee_name.len) catch return null;
    @memcpy(buf, callee_name);
    buf[3] = @as(u8, @intCast('0' + total_components));
    return buf;
}

pub fn checkIndex(v: *Validator, e: *Ast.IndexExpr) Allocator.Error!InferResult {
    const br = try checkExpr(v, e.base);
    // Push an `.integer_scalar` expectation down so non-integer-scalar
    // indices (floats, bools, vectors, composites) are rejected at the
    // index sub-expression rather than at the outer `[]` form, and so
    // `expr_types` records the integer shape for hovers.
    const ir = try checkExprE(v, e.idx, .integer_scalar);
    const stage = ExprStage.combine(br.stage, ir.stage);
    const base_type = br.typ orelse return .{ .typ = null, .stage = stage };

    // Out-of-bounds literal index detection
    if (v.tryExtractIntValue(e.idx)) |idx_val| {
        const bound: ?i64 = switch (base_type) {
            .array => |a| if (a.count > 0) @as(i64, @intCast(a.count)) else null,
            .vector => |ve| @as(i64, @intCast(ve.width)),
            .matrix => |m| @as(i64, @intCast(m.cols)),
            else => null,
        };
        if (bound) |b| {
            if (idx_val < 0 or idx_val >= b) {
                v.addErrorWithCodeR(exprRange(e.idx), Diagnostic.Code.index_out_of_bounds, v.fmtError("index {d} is out of bounds for '{s}' with {d} element{s}", .{ idx_val, base_type.string(), b, if (b != 1) "s" else "" }));
            }
        }
    }

    // Get element type. A pointer/reference base indexes through to its
    // pointee per WGSL pointer-composite-access sugar: `p[i]` is shorthand for
    // `(*p)[i]` when `p` is a pointer (and a reference indexes like its
    // referent). Previously only pointer/reference-to-array was unwrapped, so
    // `p[0]` on a `ptr<_, vecN>` / `<_, matCxR>` was wrongly rejected as "not
    // indexable" (with a cascading "cannot determine type" on the enclosing var).
    const indexed: Types.Type = switch (base_type) {
        .pointer => |p| p.element,
        .reference => |r| r.element,
        else => base_type,
    };
    switch (indexed) {
        .array => |a| return InferResult.some(a.element, stage),
        .vector => |ve| return InferResult.some(.{ .scalar = ve.element }, stage),
        .matrix => |m| {
            // Indexing a matrix gives a column vector
            const col_vec = v.arena.create(Types.Vector) catch return InferResult.fail;
            col_vec.* = .{ .width = m.rows, .element = m.element };
            return InferResult.some(.{ .vector = col_vec }, stage);
        },
        else => {},
    }

    v.addErrorWithCodeR(exprRange(.{ .index = e }), Diagnostic.Code.not_indexable, v.fmtError("type '{s}' is not indexable", .{base_type.string()}));
    return InferResult.fail;
}

pub fn validateSwizzle(v: *Validator, name: []const u8, vec_width: u8, loc: u32, base_type: Types.Type) bool {
    // Range covers the dot + swizzle name
    const r: LocRange = .{ .start = loc, .end = loc +| 1 +| @as(u32, @intCast(name.len)) };
    const xyzw = "xyzw";
    const rgba = "rgba";
    var has_xyzw = false;
    var has_rgba = false;
    for (name) |c| {
        const xyzw_idx = std.mem.indexOfScalar(u8, xyzw, c);
        const rgba_idx = std.mem.indexOfScalar(u8, rgba, c);
        if (xyzw_idx == null and rgba_idx == null) {
            const msg = if (suggestSwizzle(v, name, vec_width)) |s|
                v.fmtError("invalid swizzle '.{s}' on type '{s}'; valid components are xyzw or rgba; did you mean '.{s}'?", .{ name, base_type.string(), s })
            else
                v.fmtError("invalid swizzle '.{s}' on type '{s}'; valid components are xyzw or rgba", .{ name, base_type.string() });
            v.addErrorWithCodeR(r, Diagnostic.Code.no_such_member, msg);
            return false;
        }
        if (xyzw_idx != null) has_xyzw = true;
        if (rgba_idx != null) has_rgba = true;
        // Check component index vs vector width
        const idx: u8 = @intCast(xyzw_idx orelse rgba_idx.?);
        if (idx >= vec_width) {
            v.addErrorWithCodeR(r, Diagnostic.Code.no_such_member, v.fmtError("swizzle component '{c}' is out of bounds for '{s}'", .{ c, base_type.string() }));
            return false;
        }
    }
    if (has_xyzw and has_rgba) {
        const msg = if (suggestSwizzle(v, name, vec_width)) |s|
            v.fmtError("swizzle '.{s}' mixes xyzw and rgba groups; did you mean '.{s}'?", .{ name, s })
        else
            v.fmtError("swizzle '.{s}' mixes xyzw and rgba groups", .{name});
        v.addErrorWithCodeR(r, Diagnostic.Code.no_such_member, msg);
        return false;
    }
    return true;
}

/// Build a best-guess valid swizzle name. The dominant group (xyzw or rgba)
/// wins ties; invalid / out-of-bounds chars are replaced with the group's
/// first in-bounds component. Returns null when no change is needed, when
/// the name is empty, or when the vector width is zero.
pub fn suggestSwizzle(v: *Validator, name: []const u8, vec_width: u8) ?[]const u8 {
    if (name.len == 0 or name.len > 4 or vec_width == 0) return null;
    var xyzw_count: u8 = 0;
    var rgba_count: u8 = 0;
    for (name) |c| {
        if (std.mem.indexOfScalar(u8, "xyzw", c)) |_| xyzw_count += 1;
        if (std.mem.indexOfScalar(u8, "rgba", c)) |_| rgba_count += 1;
    }
    const group: []const u8 = if (xyzw_count >= rgba_count) "xyzw" else "rgba";
    const max_w: u8 = @min(vec_width, 4);
    var buf = v.arena.alloc(u8, name.len) catch return null;
    var changed = false;
    for (name, 0..) |c, i| {
        if (std.mem.indexOfScalar(u8, group, c)) |idx| {
            if (idx < max_w) {
                buf[i] = c;
            } else {
                buf[i] = group[max_w - 1];
                changed = true;
            }
        } else {
            buf[i] = group[0];
            changed = true;
        }
    }
    if (!changed) return null;
    return buf;
}

pub fn checkMember(v: *Validator, e: *Ast.MemberExpr) Allocator.Error!InferResult {
    const br = try checkExpr(v, e.base);
    const stage = br.stage;
    var base_type = br.typ orelse return .{ .typ = null, .stage = stage };
    const mr = exprRange(.{ .member = e }); // dot + member_name

    // Auto-dereference pointers/references
    for (0..32) |_| {
        switch (base_type) {
            .pointer => |p| base_type = p.element,
            .reference => |r| base_type = r.element,
            else => break,
        }
    } else unreachable;

    switch (base_type) {
        .@"struct" => |st| {
            if (st.getField(e.member_name)) |field| {
                if (v.findStructDecl(st.name)) |sd| {
                    for (sd.members.items) |m| {
                        if (std.mem.eql(u8, v.symbolName(m.name), e.member_name)) {
                            e.member_ref = m.name;
                            break;
                        }
                    }
                }
                return InferResult.some(field.typ, stage);
            }
            const related = if (v.findStructDecl(st.name)) |sd|
                v.makeRelatedR(v.symbolRange(sd.name), v.fmtError("struct '{s}' defined here", .{st.name}))
            else
                &[_]Diagnostic.RelatedInfo{};
            const suggestion = blk: {
                var field_names: [64][]const u8 = undefined;
                const count = @min(st.fields.len, 64);
                for (0..count) |i| field_names[i] = st.fields[i].name;
                break :blk suggestName(e.member_name, field_names[0..count], 3);
            };
            if (suggestion) |s| {
                v.addErrorWithRelatedDataR(mr, Diagnostic.Code.no_such_member, v.fmtError("struct '{s}' has no member '{s}'; did you mean '{s}'?", .{ st.name, e.member_name, s }), related, .{ .did_you_mean = s });
            } else {
                v.addErrorWithRelatedR(mr, Diagnostic.Code.no_such_member, v.fmtError("struct '{s}' has no member '{s}'", .{ st.name, e.member_name }), related);
            }
            return InferResult.fail;
        },
        .vector => |ve| {
            if (e.member_name.len < 1 or e.member_name.len > 4) {
                v.addErrorWithCodeR(mr, Diagnostic.Code.no_such_member, v.fmtError("invalid swizzle '.{s}' on type '{s}'; valid components are xyzw or rgba", .{ e.member_name, base_type.string() }));
                return InferResult.fail;
            }
            if (!validateSwizzle(v, e.member_name, ve.width, e.loc, base_type)) return InferResult.fail;
            // Single-component swizzle: returns scalar
            if (e.member_name.len == 1) {
                return InferResult.some(.{ .scalar = ve.element }, stage);
            }
            // Multi-component swizzle: returns vector
            const swiz_vec = v.arena.create(Types.Vector) catch return InferResult.fail;
            swiz_vec.* = .{
                .width = @intCast(e.member_name.len),
                .element = ve.element,
            };
            return InferResult.some(.{ .vector = swiz_vec }, stage);
        },
        else => {
            v.addErrorWithCodeR(mr, Diagnostic.Code.no_such_member, v.fmtError("type '{s}' has no members", .{base_type.string()}));
            return InferResult.fail;
        },
    }
}
