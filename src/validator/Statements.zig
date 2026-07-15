//! Statement validation, control-flow analysis, and post-pass walkers.
//!
//! Owns Phase 4's per-function statement walker (validateFunctions/Function
//! plus the validateStmt family), Phase 6's scope-tree shadow detection, and
//! Phase 7's operator-precedence ambiguity check. Block-flow utilities
//! (`blockHasExit`, `continuingHasBreakIf`) live here too because every
//! caller is statement-walker code. Driven from `Validator.validate` /
//! `Validator.analyze`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../Ast.zig");
const Types = @import("../Types.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Builtins = @import("../Builtins.zig");
const Validator = @import("../Validator.zig");
const Expressions = @import("Expressions.zig");

const isSwizzleName = Validator.isSwizzleName;
const hasDuplicateSwizzleChars = Validator.hasDuplicateSwizzleChars;

const LocRange = Validator.LocRange;
const ShaderStage = Validator.ShaderStage;

const exprSpan = Validator.exprSpan;
const exprRange = Validator.exprRange;
const exprLoc = Validator.exprLoc;
const astTypeRange = Validator.astTypeRange;

// Free-fn aliases for cross-phase helpers that don't take *Validator first
// (these live in Validator.zig today; will follow into Declarations.zig later).
const determineShaderStage = Validator.determineShaderStage;
const resolveFunctionParameters = Validator.resolveFunctionParameters;
const attrRange = Validator.attrRange;

// Phase 4 ----------------------------------------------------------------

pub fn validateFunctions(v: *Validator) Allocator.Error!void {
    for (v.module.declarations.items) |decl| {
        switch (decl) {
            .function => |fn_decl| try validateFunction(v, fn_decl),
            else => {},
        }
    }
}

pub fn validateFunction(v: *Validator, fn_decl: *Ast.FunctionDecl) Allocator.Error!void {
    // Reset the per-function cursor at function entry. WGSL functions don't
    // nest, so a flat reset is sound: in_loop/in_switch/in_continuing/
    // break_exits_continuing → false, return_type → null, has_return → false
    // (all via FnContext defaults). The depth counters are deliberately
    // preserved, not zeroed — they are defer-balanced across the whole walk
    // and asserted 0 at runPhases exit, so resetting them per function would
    // mask an imbalance the asserts exist to catch.
    v.fn_ctx = .{
        .current_func = fn_decl,
        .current_stage = determineShaderStage(fn_decl),
        .expr_depth = v.fn_ctx.expr_depth,
        .stmt_depth = v.fn_ctx.stmt_depth,
    };

    // WGSL spec §11.2.3: @workgroup_size is valid only on compute entry points.
    for (fn_decl.attributes.items) |attr| {
        if (std.mem.eql(u8, attr.name, "workgroup_size") and v.fn_ctx.current_stage != .compute) {
            v.addErrorWithCodeR(attrRange(&attr), Diagnostic.Code.invalid_attribute, "@workgroup_size is only valid on compute entry points");
        }
    }

    // WGSL spec: function parameter count must not exceed 255
    if (fn_decl.parameters.items.len > 255) {
        v.addErrorWithCodeR(v.symbolRange(fn_decl.name), Diagnostic.Code.invalid_entry_point, v.fmtError("function '{s}' has {d} parameters, exceeding the maximum of 255", .{ v.symbolName(fn_decl.name), fn_decl.parameters.items.len }));
    }

    // Resolve return type
    if (fn_decl.return_type) |rt| {
        v.fn_ctx.return_type = try v.resolveType(rt);
        if (v.fn_ctx.return_type) |ret| {
            if (!ret.isConstructible()) {
                v.addErrorWithCodeR(v.symbolRange(fn_decl.name), Diagnostic.Code.type_mismatch, v.fmtError("function '{s}' has non-constructible return type '{s}'", .{ v.symbolName(fn_decl.name), ret.string() }));
            }
        }
    } else {
        v.fn_ctx.return_type = null;
    }

    const param_types = try resolveFunctionParameters(v, fn_decl);
    v.validateReturnAttributes(fn_decl);

    // Register function type in symbol_types so calls can resolve it
    if (fn_decl.name.isValid()) {
        const fn_type = Types.functionType(v.arena, param_types, v.fn_ctx.return_type) catch null;
        if (fn_type) |ft| {
            try v.setSymbolType(fn_decl.name, ft);
        }
    }

    // Validate entry point requirements
    if (v.fn_ctx.current_stage != .none) {
        try v.validateEntryPoint(fn_decl);
    }

    // Validate function body
    if (fn_decl.body) |body| {
        try validateCompoundStmt(v, body);
    }

    // Check for missing return
    if (v.fn_ctx.return_type != null and !v.fn_ctx.has_return) {
        v.addErrorWithCodeR(v.symbolRange(fn_decl.name), Diagnostic.Code.missing_return, v.fmtError("function '{s}' must return a value", .{v.symbolName(fn_decl.name)}));
    }

    v.fn_ctx.current_func = null;
    v.fn_ctx.return_type = null;
}

// Statement Validation ---------------------------------------------------

pub fn validateStmt(v: *Validator, stmt: Ast.Stmt) Allocator.Error!void {
    switch (stmt) {
        .compound => |s| try validateCompoundStmt(v, s),
        .@"return" => |s| try validateReturnStmt(v, s),
        .@"if" => |s| try validateIfStmt(v, s),
        .@"switch" => |s| try validateSwitchStmt(v, s),
        .loop => |s| try validateLoopStmt(v, s),
        .@"while" => |s| try validateWhileStmt(v, s),
        .@"for" => |s| try validateForStmt(v, s),
        .@"break" => |s| validateBreakStmt(v, s),
        .break_if => |s| try validateBreakIfStmt(v, s),
        .@"continue" => |s| validateContinueStmt(v, s),
        .discard => |s| validateDiscardStmt(v, s),
        .assign => |s| try validateAssignStmt(v, s),
        .incr_decr => |s| try validateIncrDecrStmt(v, s),
        .call => |s| try validateCallStmt(v, s),
        .decl => |s| try validateDeclStmt(v, s),
    }
}

const max_stmt_depth: u32 = 127;

pub fn validateCompoundStmt(v: *Validator, s: *Ast.CompoundStmt) Allocator.Error!void {
    v.fn_ctx.stmt_depth += 1;
    defer v.fn_ctx.stmt_depth -= 1;

    if (v.fn_ctx.stmt_depth > max_stmt_depth) {
        // Report once at the first stmt in the block (if any)
        const loc: LocRange = if (s.stmts.items.len > 0) getStmtRange(v, s.stmts.items[0]) else .{ .start = 0, .end = 1 };
        v.addErrorWithCodeR(loc, Diagnostic.Code.nesting_too_deep, v.fmtError("statement nesting depth exceeds maximum of {d}", .{max_stmt_depth}));
        return;
    }

    var terminated = false;
    for (s.stmts.items) |stmt| {
        if (terminated) {
            // Unreachable code is valid WGSL (still type-checked, never runs;
            // Tint accepts it), so this is a non-fatal W0103 warning — escalated
            // back to an error only under Options.strict_mode. See Diagnostic.zig.
            v.addWarningWithCodeR(getStmtRange(v, stmt), Diagnostic.Code.unreachable_code, "code is unreachable");
            break; // report once per block
        }
        try validateStmt(v, stmt);
        if (stmtTerminates(stmt)) terminated = true;
    }
}

/// Iteratively checks whether a statement always terminates (return/break/continue).
/// Uses a fixed-size stack: all pushed statements must terminate for the result to be true.
pub fn stmtTerminates(root: Ast.Stmt) bool {
    var stack: [64]Ast.Stmt = undefined;
    var top: usize = 1;
    stack[0] = root;

    while (top > 0) {
        top -= 1;
        var current = stack[top];
        // Follow compound→last and if→body+else chains
        for (0..65536) |_| {
            switch (current) {
                // `discard` is intentionally NOT a terminator: WGSL control flow
                // continues past it, so statements after a `discard` are reachable
                // (Tint accepts `discard; <stmt>`). The return requirement is
                // satisfied separately via `has_return` in validateDiscardStmt;
                // the advisory lint W0210 still flags post-discard orphans.
                .@"return", .@"break", .@"continue" => break,
                .compound => |s| {
                    if (s.stmts.items.len == 0) return false;
                    current = s.stmts.items[s.stmts.items.len - 1];
                },
                .@"if" => |s| {
                    if (s.body.stmts.items.len == 0) return false;
                    // Push else branch — it must also terminate
                    const eb = s.else_branch orelse return false;
                    if (top >= stack.len) return false;
                    stack[top] = eb;
                    top += 1;
                    // Continue checking body's last statement
                    current = s.body.stmts.items[s.body.stmts.items.len - 1];
                },
                .@"switch" => |s| {
                    var has_default = false;
                    for (s.cases.items) |c| {
                        if (c.has_default) has_default = true;
                        if (c.body.stmts.items.len == 0) return false;
                        // Push each case's last statement — all must terminate
                        if (top >= stack.len) return false;
                        stack[top] = c.body.stmts.items[c.body.stmts.items.len - 1];
                        top += 1;
                    }
                    if (!has_default) return false;
                    break;
                },
                else => return false,
            }
        } else unreachable;
    }
    return true;
}

pub fn getStmtLoc(v: *Validator, stmt: Ast.Stmt) u32 {
    return getStmtRange(v, stmt).start;
}

pub fn getStmtRange(v: *Validator, stmt: Ast.Stmt) LocRange {
    return switch (stmt) {
        .@"return" => |s| .{ .start = s.loc, .end = s.loc +| 6 }, // "return"
        .@"break" => |s| .{ .start = s.loc, .end = s.loc +| 5 }, // "break"
        .@"continue" => |s| .{ .start = s.loc, .end = s.loc +| 8 }, // "continue"
        .discard => |s| .{ .start = s.loc, .end = s.loc +| 7 }, // "discard"
        .assign => |s| .{ .start = s.loc, .end = s.loc +| @as(u32, @intCast(s.op.string().len)) },
        .incr_decr => |s| .{ .start = s.loc, .end = s.loc +| 2 }, // ++ or --
        .call => |s| exprRange(.{ .call = s.call }),
        .decl => |s| v.symbolRange(s.decl.nameRef()),
        else => .{ .start = 0, .end = 1 },
    };
}

pub fn validateReturnStmt(v: *Validator, s: *Ast.ReturnStmt) Allocator.Error!void {
    v.fn_ctx.has_return = true;
    const ret_range: LocRange = .{ .start = s.loc, .end = s.loc +| 6 }; // "return"

    // WGSL spec section 9.5.2: continuing block must not contain a return statement.
    if (v.fn_ctx.in_continuing) {
        v.addErrorWithCodeR(ret_range, Diagnostic.Code.return_in_continuing, "'return' is not allowed inside a continuing block");
    }

    if (s.value == null) {
        if (v.fn_ctx.return_type) |rt| {
            v.addErrorWithCodeR(ret_range, Diagnostic.Code.missing_return, v.fmtError("return must provide a value of type '{s}'", .{rt.string()}));
        }
        return;
    }

    const expr_type = (try v.checkExpr(s.value.?)).typ orelse return;

    if (expr_type.isRuntimeSizedArray()) {
        v.addErrorWithCodeR(exprSpan(s.value.?), Diagnostic.Code.type_mismatch, "cannot return a runtime-sized array");
        return;
    }

    if (v.fn_ctx.return_type) |rt| {
        if (!Types.canConvertTo(expr_type, rt)) {
            const related = if (v.fn_ctx.current_func) |func| blk: {
                if (func.return_type) |frt| {
                    const rt_r = astTypeRange(frt);
                    if (rt_r.start != 0) break :blk v.makeRelatedR(rt_r, v.fmtError("return type '{s}' declared here", .{rt.string()}));
                }
                break :blk &[_]Diagnostic.RelatedInfo{};
            } else &[_]Diagnostic.RelatedInfo{};
            v.addErrorWithRelatedDataR(exprSpan(s.value.?), Diagnostic.Code.type_mismatch, v.fmtError("cannot return '{s}' from function expecting '{s}'", .{ expr_type.string(), rt.string() }), related, .{ .type_mismatch = .{ .actual = expr_type.string(), .expected = rt.string() } });
        }
    } else {
        const fn_name = if (v.fn_ctx.current_func) |f| v.symbolName(f.name) else "";
        v.addErrorWithCodeR(exprSpan(s.value.?), Diagnostic.Code.invalid_return, v.fmtError("cannot return a value from void function '{s}'", .{fn_name}));
    }
}

/// Iteratively validates if/else-if/else chains without recursion.
pub fn validateIfStmt(v: *Validator, s: *Ast.IfStmt) Allocator.Error!void {
    var current: *Ast.IfStmt = s;
    for (0..65536) |_| {
        const cond_type = (try v.checkExpr(current.condition)).typ;
        if (cond_type) |ct| {
            if (!ct.eql(Types.Bool)) {
                v.addErrorWithCodeR(exprSpan(current.condition), Diagnostic.Code.type_mismatch, v.fmtError("if condition must be 'bool', got '{s}'", .{ct.string()}));
            }
        }

        try validateCompoundStmt(v, current.body);
        const eb = current.else_branch orelse break;
        switch (eb) {
            .@"if" => |next_if| current = next_if,
            else => {
                try validateStmt(v, eb);
                break;
            },
        }
    } else unreachable;
}

pub fn validateSwitchStmt(v: *Validator, s: *Ast.SwitchStmt) Allocator.Error!void {
    const selector_type = (try v.checkExpr(s.expr)).typ;
    if (selector_type) |st| {
        if (!Types.isInteger(st)) {
            v.addErrorWithCodeR(exprSpan(s.expr), Diagnostic.Code.type_mismatch, v.fmtError("switch selector must be integer, got '{s}'", .{st.string()}));
        }
    }

    const prev_in_switch = v.fn_ctx.in_switch;
    v.fn_ctx.in_switch = true;
    // A `break` in a case body targets this switch (see break_exits_continuing).
    const prev_bec = v.fn_ctx.break_exits_continuing;
    v.fn_ctx.break_exits_continuing = false;

    var default_count: u32 = 0;
    var seen_values: std.AutoHashMapUnmanaged(i64, u32) = .{};

    for (s.cases.items) |case| {
        if (case.has_default) {
            // Default clause: a bare `default:` or a `default` selector.
            default_count += 1;
            if (default_count > 1) {
                v.addErrorWithCodeR(exprSpan(s.expr), Diagnostic.Code.missing_default_case, "switch statement has multiple default clauses");
            }
        }
        for (case.selectors.items) |sel| {
            const sel_r = try v.checkExpr(sel);
            const sel_type = sel_r.typ;
            if (sel_type != null and selector_type != null) {
                if (!Types.canConvertTo(sel_type.?, selector_type.?)) {
                    v.addErrorWithRelatedR(exprRange(sel), Diagnostic.Code.type_mismatch, v.fmtError("case selector '{s}' doesn't match switch type '{s}'", .{ sel_type.?.string(), selector_type.?.string() }), v.makeRelatedR(exprRange(s.expr), v.fmtError("switch expression has type '{s}'", .{selector_type.?.string()})));
                }
            }
            // Switch case selectors must be const-expressions
            if (sel_r.stage != .const_expr) {
                v.addErrorWithCodeR(exprRange(sel), Diagnostic.Code.expression_not_const, "case selector must be a const-expression");
            }
            // Check for duplicate case selector values
            if (v.tryExtractIntValue(sel)) |val| {
                if (seen_values.get(val) != null) {
                    v.addErrorWithCodeR(exprRange(sel), Diagnostic.Code.duplicate_case_selector, v.fmtError("duplicate case selector value '{d}'", .{val}));
                } else {
                    try seen_values.put(v.arena, val, 1);
                }
            }
        }
        try validateCompoundStmt(v, case.body);
    }

    if (default_count == 0) {
        v.addErrorWithCodeR(exprSpan(s.expr), Diagnostic.Code.missing_default_case, "switch statement must have a default clause");
    }

    v.fn_ctx.break_exits_continuing = prev_bec;
    v.fn_ctx.in_switch = prev_in_switch;
}

pub fn validateLoopStmt(v: *Validator, s: *Ast.LoopStmt) Allocator.Error!void {
    const prev_in_loop = v.fn_ctx.in_loop;
    v.fn_ctx.in_loop = true;

    // A `break` in this loop's body targets this loop, not any enclosing
    // continuing block, so it is legal here.
    const prev_body_bec = v.fn_ctx.break_exits_continuing;
    v.fn_ctx.break_exits_continuing = false;
    try validateCompoundStmt(v, s.body);
    v.fn_ctx.break_exits_continuing = prev_body_bec;

    if (s.continuing) |cont| {
        const prev_in_continuing = v.fn_ctx.in_continuing;
        v.fn_ctx.in_continuing = true;
        // A plain `break` directly in the continuing block would exit THIS loop,
        // which WGSL forbids (a nested loop/switch below clears this again).
        const prev_cont_bec = v.fn_ctx.break_exits_continuing;
        v.fn_ctx.break_exits_continuing = true;
        try validateCompoundStmt(v, cont);
        v.fn_ctx.break_exits_continuing = prev_cont_bec;
        v.fn_ctx.in_continuing = prev_in_continuing;

        // Spec: break if must be the last statement in a continuing block.
        for (cont.stmts.items, 0..) |stmt, i| {
            if (stmt == .break_if and i != cont.stmts.items.len - 1) {
                v.addErrorWithCodeR(getStmtRange(v, stmt), Diagnostic.Code.break_outside_loop, "'break if' must be the last statement in a continuing block");
            }
        }
    }

    // Detect infinite loops: body has no exit and continuing has no break_if
    if (!blockHasExit(s.body) and !continuingHasBreakIf(s.continuing)) {
        // Use the first statement's location if available, or a default
        const loc = if (s.body.stmts.items.len > 0) getStmtRange(v, s.body.stmts.items[0]).start else 0;
        v.addWarningR(.{ .start = loc, .end = loc +| 4 }, "loop has no exit path (break, return, or discard)");
    }

    v.fn_ctx.in_loop = prev_in_loop;
}

pub fn validateWhileStmt(v: *Validator, s: *Ast.WhileStmt) Allocator.Error!void {
    const cond_type = (try v.checkExpr(s.condition)).typ;
    if (cond_type) |ct| {
        if (!ct.eql(Types.Bool)) {
            v.addErrorWithCodeR(exprSpan(s.condition), Diagnostic.Code.type_mismatch, v.fmtError("while condition must be 'bool', got '{s}'", .{ct.string()}));
        }
    }

    const prev_in_loop = v.fn_ctx.in_loop;
    v.fn_ctx.in_loop = true;
    // A `break` in the body targets this loop (see break_exits_continuing).
    const prev_bec = v.fn_ctx.break_exits_continuing;
    v.fn_ctx.break_exits_continuing = false;
    try validateCompoundStmt(v, s.body);
    v.fn_ctx.break_exits_continuing = prev_bec;
    v.fn_ctx.in_loop = prev_in_loop;
}

pub fn validateForStmt(v: *Validator, s: *Ast.ForStmt) Allocator.Error!void {
    if (s.init_stmt) |init| {
        try validateStmt(v, init);
    }
    if (s.condition) |cond| {
        const cond_type = (try v.checkExpr(cond)).typ;
        if (cond_type) |ct| {
            if (!ct.eql(Types.Bool)) {
                v.addErrorWithCodeR(exprSpan(cond), Diagnostic.Code.type_mismatch, v.fmtError("for condition must be 'bool', got '{s}'", .{ct.string()}));
            }
        }
    }
    if (s.update) |update| {
        try validateStmt(v, update);
    }

    const prev_in_loop = v.fn_ctx.in_loop;
    v.fn_ctx.in_loop = true;
    // A `break` in the body targets this loop (see break_exits_continuing).
    const prev_bec = v.fn_ctx.break_exits_continuing;
    v.fn_ctx.break_exits_continuing = false;
    try validateCompoundStmt(v, s.body);
    v.fn_ctx.break_exits_continuing = prev_bec;
    v.fn_ctx.in_loop = prev_in_loop;
}

pub fn validateBreakStmt(v: *Validator, s: *Ast.BreakStmt) void {
    const r: LocRange = .{ .start = s.loc, .end = s.loc +| 5 }; // "break"
    if (!v.fn_ctx.in_loop and !v.fn_ctx.in_switch) {
        v.addErrorWithCodeR(r, Diagnostic.Code.break_outside_loop, "break statement must be inside a loop or switch");
    } else if (v.fn_ctx.break_exits_continuing) {
        v.addErrorWithCodeR(r, Diagnostic.Code.break_outside_loop, "'break' must not be used in a continuing block (use 'break if' instead)");
    }
}

pub fn validateBreakIfStmt(v: *Validator, s: *Ast.BreakIfStmt) Allocator.Error!void {
    const cond_type = (try v.checkExpr(s.condition)).typ;
    if (cond_type) |ct| {
        if (!ct.eql(Types.Bool)) {
            v.addErrorWithCodeR(exprSpan(s.condition), Diagnostic.Code.type_mismatch, v.fmtError("break if condition must be 'bool', got '{s}'", .{ct.string()}));
        }
    }
}

pub fn validateContinueStmt(v: *Validator, s: *Ast.ContinueStmt) void {
    if (!v.fn_ctx.in_loop) {
        v.addErrorWithCodeR(.{ .start = s.loc, .end = s.loc +| 8 }, Diagnostic.Code.continue_outside_loop, "continue statement must be inside a loop"); // "continue"
    }
}

pub fn validateDiscardStmt(v: *Validator, s: *Ast.DiscardStmt) void {
    if (v.fn_ctx.current_stage != .fragment) {
        v.addErrorWithCodeR(.{ .start = s.loc, .end = s.loc +| 7 }, Diagnostic.Code.discard_outside_fragment, v.fmtError("'discard' is only valid in fragment shaders, not {s}", .{v.fn_ctx.current_stage.string()})); // "discard"
    }
    // discard terminates the invocation, satisfying any return requirement.
    v.fn_ctx.has_return = true;
}

pub fn validateAssignStmt(v: *Validator, s: *Ast.AssignStmt) Allocator.Error!void {
    const lhs_type = (try v.checkExpr(s.left)).typ orelse return;
    const rhs_type = (try v.checkExpr(s.right)).typ orelse return;

    checkAssignToImmutable(v, s);
    checkSwizzleAssignTarget(v, s);

    if (s.op == .simple) {
        // Simple assignment: RHS must be convertible to LHS.
        if (!Types.canConvertTo(rhs_type, lhs_type)) {
            v.addErrorWithRelatedDataR(exprSpan(s.right), Diagnostic.Code.type_mismatch, v.fmtError("cannot assign '{s}' to '{s}'", .{ rhs_type.string(), lhs_type.string() }), v.makeRelatedR(exprRange(s.left), v.fmtError("left-hand side has type '{s}'", .{lhs_type.string()})), .{ .type_mismatch = .{ .actual = rhs_type.string(), .expected = lhs_type.string() } });
        }
        return;
    }

    const result_type = compoundAssignResultType(v, s.op, lhs_type, rhs_type);
    if (result_type == null) {
        const op_range: LocRange = .{ .start = s.loc, .end = s.loc +| @as(u32, @intCast(s.op.string().len)) };
        v.addErrorWithCodeR(op_range, Diagnostic.Code.invalid_operand, v.fmtError("invalid operands for '{s}': '{s}' and '{s}'", .{ s.op.string(), lhs_type.string(), rhs_type.string() }));
        return;
    }

    if (!Types.canConvertTo(result_type.?, lhs_type)) {
        const op_range: LocRange = .{ .start = s.loc, .end = s.loc +| @as(u32, @intCast(s.op.string().len)) };
        v.addErrorWithCodeR(op_range, Diagnostic.Code.type_mismatch, v.fmtError("result type '{s}' of '{s}' is not assignable to '{s}'", .{ result_type.?.string(), s.op.string(), lhs_type.string() }));
    }
}

/// WGSL spec section 9.4: assignment to `let`, `const`, `override`, or
/// parameter is invalid.
pub fn checkAssignToImmutable(v: *Validator, s: *Ast.AssignStmt) void {
    if (s.left != .ident) return;
    const ident = s.left.ident;
    if (!ident.ref.isValid()) return;
    const idx = ident.ref.index();
    if (idx >= v.module.symbols.items.len) return;
    const kind = v.module.symbols.items[idx].kind;
    switch (kind) {
        .let => v.addErrorWithCodeR(exprRange(s.left), Diagnostic.Code.invalid_assignment, v.fmtError("cannot assign to 'let' variable '{s}'", .{ident.name})),
        .@"const" => v.addErrorWithCodeR(exprRange(s.left), Diagnostic.Code.invalid_assignment, v.fmtError("cannot assign to 'const' '{s}'", .{ident.name})),
        .override => v.addErrorWithCodeR(exprRange(s.left), Diagnostic.Code.invalid_assignment, v.fmtError("cannot assign to 'override' '{s}'", .{ident.name})),
        .parameter => v.addErrorWithCodeR(exprRange(s.left), Diagnostic.Code.invalid_assignment, v.fmtError("cannot assign to parameter '{s}'", .{ident.name})),
        else => {},
    }
}

/// Swizzle write-target rules, WGSL §5.3.4 and §9.4:
/// 1. A multi-letter swizzle always yields a value (rvalue), so it
///    cannot appear on the LHS of an assignment.
/// 2. Even single-occurrence multi-letter swizzles like `.xy` are
///    invalid as write targets; only single-letter swizzles are lvalues.
/// 3. Duplicate components (`.xx`, `.xyx`) are trivially invalid.
pub fn checkSwizzleAssignTarget(v: *Validator, s: *Ast.AssignStmt) void {
    if (s.left != .member) return;
    const member = s.left.member;
    if (member.base != .ident and member.base != .member) return;
    const is_swiz = isSwizzleName(member.member_name);
    const is_multi = member.member_name.len > 1;
    if (!is_swiz or !is_multi) return;
    if (hasDuplicateSwizzleChars(member.member_name)) {
        v.addErrorWithCodeR(exprRange(s.left), Diagnostic.Code.invalid_assignment, v.fmtError("swizzle assignment target '{s}' has duplicate components", .{member.member_name}));
    } else {
        v.addErrorWithCodeR(exprRange(s.left), Diagnostic.Code.invalid_assignment, v.fmtError("multi-letter swizzle '{s}' cannot appear on the left-hand side of an assignment", .{member.member_name}));
    }
}

/// Compound assignment (`v op= e`) is defined as `v = v op e`, so its operand
/// shapes resolve exactly like the binary operator `op`: map the assignment
/// operator to its identically-named binary counterpart and go through the same
/// `Operators.binarySigs` overload engine the binary path was migrated onto in
/// Block 2.1, giving one source of truth for operand shapes. The caller verifies
/// the result is assignable back to the target. The value-dependent post-checks
/// the binary div/mod/shift shells add (div/mod-by-zero, shift bit width) gate
/// const-expression contexts a mutable assignment target never is, so they do
/// not apply here — this computes shape only.
pub fn compoundAssignResultType(v: *Validator, op: Ast.AssignOp, lhs_type: Types.Type, rhs_type: Types.Type) ?Types.Type {
    const binop: Ast.BinaryOp = switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .@"and" => .@"and",
        .@"or" => .@"or",
        .xor => .xor,
        .shl => .shl,
        .shr => .shr,
        .simple => unreachable,
    };
    return Expressions.binaryResultType(v, binop, lhs_type, rhs_type);
}

pub fn validateIncrDecrStmt(v: *Validator, s: *Ast.IncrDecrStmt) Allocator.Error!void {
    const expr_type = (try v.checkExpr(s.expr)).typ orelse return;
    // Spec: operand must be a concrete integer scalar (i32 or u32 only).
    const is_concrete_int_scalar = switch (expr_type) {
        .scalar => |sc| sc.kind == .i32 or sc.kind == .u32,
        else => false,
    };
    if (!is_concrete_int_scalar) {
        v.addErrorWithCodeR(exprSpan(s.expr), Diagnostic.Code.type_mismatch, v.fmtError("increment/decrement requires concrete integer scalar (i32 or u32), got '{s}'", .{expr_type.string()}));
    }
}

pub fn validateCallStmt(v: *Validator, s: *Ast.CallStmt) Allocator.Error!void {
    _ = try v.checkCallExpr(s.call);

    // @must_use: builtin functions with return values must not be called as statements
    if (s.call.func) |func| {
        switch (func) {
            .ident => |ident| {
                if (Builtins.lookup(ident.name)) |builtin_fn| {
                    if (builtin_fn.must_use) {
                        v.addErrorWithCodeR(exprRange(.{ .call = s.call }), Diagnostic.Code.must_use_ignored, v.fmtError("return value of '@must_use' builtin '{s}' must be used", .{ident.name}));
                    }
                }
            },
            else => {},
        }
    }
}

pub fn validateDeclStmt(v: *Validator, s: *Ast.DeclStmt) Allocator.Error!void {
    switch (s.decl) {
        // Function-scope `const` demotes abstract types to concrete per §15;
        // see validateConstDecl's `AbstractHandling` knob.
        .@"const" => |d| try v.validateConstDecl(d, .concretize),
        .let => |d| try v.validateLetDecl(d),
        .@"var" => |d| try v.validateVarDecl(d),
        .const_assert => |d| try v.validateConstAssert(d),
        else => {},
    }
}

// Phase 6: Shadow detection ---------------------------------------------

/// Walk the scope tree once and emit W0100 for every symbol declared in a
/// non-module scope whose name is also visible in an ancestor scope.
pub fn detectShadowing(v: *Validator) void {
    walkScopesForShadow(v, v.module.scope);
}

pub fn walkScopesForShadow(v: *Validator, scope: *Ast.Scope) void {
    for (scope.children.items) |child| {
        var it = child.members.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const member = entry.value_ptr.*;
            if (!member.ref.isValid()) continue;
            var ancestor: ?*Ast.Scope = child.parent;
            while (ancestor) |a| {
                if (a.members.get(name)) |outer| {
                    if (outer.ref.isValid() and outer.ref.index() != member.ref.index()) {
                        const kind = symbolKind(v, outer.ref);
                        const label = if (a.kind == .module)
                            "a module-scope declaration"
                        else switch (kind) {
                            .parameter => "a function parameter",
                            else => "an earlier declaration",
                        };
                        v.addWarningWithCodeR(
                            v.symbolRange(member.ref),
                            Diagnostic.Code.shadowing,
                            v.fmtError("'{s}' shadows {s}", .{ name, label }),
                        );
                        break;
                    }
                }
                ancestor = a.parent;
            }
        }
        walkScopesForShadow(v, child);
    }
}

pub fn symbolKind(v: *Validator, sym_idx: Ast.SymbolIndex) Ast.Symbol.Kind {
    if (!sym_idx.isValid()) return .unbound;
    return v.module.symbols.items[sym_idx.index()].kind;
}

// =========================================================================
// Phase 7: Ambiguous operator-precedence mixing (E0213)
// =========================================================================

/// Operator family for precedence-mixing checks. Ops within the same family
/// generally compose freely; ops across the pairs listed in `precedenceConflicts`
/// must be explicitly parenthesised by the author.
pub const OpClass = enum { arithmetic, shift, relational, equality, bitwise, logical, other };

pub fn classOfBinaryOp(op: Ast.BinaryOp) OpClass {
    return switch (op) {
        .add, .sub, .mul, .div, .mod => .arithmetic,
        .shl, .shr => .shift,
        .lt, .le, .gt, .ge => .relational,
        .eq, .ne => .equality,
        .@"and", .@"or", .xor => .bitwise,
        .logical_and, .logical_or => .logical,
    };
}

/// Returns true when a binary op applied to a non-parenthesised binary child
/// of this parent-and-child-op pair produces an expression whose intended
/// grouping is ambiguous under WGSL §8.18 and must be explicitly parenthesised.
/// The check is op-pair-aware for bitwise and logical families (where identical
/// ops are associative and fine, but mixed ones are not).
pub fn isAmbiguousNesting(parent: Ast.BinaryOp, child: Ast.BinaryOp) bool {
    const p = classOfBinaryOp(parent);
    const c = classOfBinaryOp(child);
    if (p == .shift and (c == .arithmetic or c == .relational or c == .equality or c == .shift)) return true;
    if ((p == .relational or p == .equality) and c == .shift) return true;
    // Bitwise `&`, `|`, `^`: each is associative with itself, but mixing any
    // two of them without parens is ambiguous.
    if (p == .bitwise and c == .bitwise and parent != child) return true;
    // Short-circuit `&&` and `||` cannot be mixed without parens.
    if (p == .logical and c == .logical and parent != child) return true;
    return false;
}

pub fn checkOperatorPrecedence(v: *Validator) void {
    for (v.module.declarations.items) |decl| {
        switch (decl) {
            .function => |d| if (d.body) |body| walkStmtForPrecedence(v, .{ .compound = body }),
            .@"const" => |d| if (d.initializer) |e| walkExprForPrecedence(v, e),
            .override => |d| if (d.initializer) |e| walkExprForPrecedence(v, e),
            .@"var" => |d| if (d.initializer) |e| walkExprForPrecedence(v, e),
            .let => |d| if (d.initializer) |e| walkExprForPrecedence(v, e),
            .const_assert => |d| walkExprForPrecedence(v, d.expr),
            else => {},
        }
    }
}

pub fn walkStmtForPrecedence(v: *Validator, stmt: Ast.Stmt) void {
    switch (stmt) {
        .compound => |s| for (s.stmts.items) |sub| walkStmtForPrecedence(v, sub),
        .@"return" => |s| if (s.value) |e| walkExprForPrecedence(v, e),
        .@"if" => |s| {
            walkExprForPrecedence(v, s.condition);
            walkStmtForPrecedence(v, .{ .compound = s.body });
            if (s.else_branch) |eb| walkStmtForPrecedence(v, eb);
        },
        .@"switch" => |s| {
            walkExprForPrecedence(v, s.expr);
            for (s.cases.items) |case| {
                for (case.selectors.items) |sel| walkExprForPrecedence(v, sel);
                walkStmtForPrecedence(v, .{ .compound = case.body });
            }
        },
        .@"for" => |s| {
            if (s.init_stmt) |init| walkStmtForPrecedence(v, init);
            if (s.condition) |c| walkExprForPrecedence(v, c);
            if (s.update) |u| walkStmtForPrecedence(v, u);
            walkStmtForPrecedence(v, .{ .compound = s.body });
        },
        .@"while" => |s| {
            walkExprForPrecedence(v, s.condition);
            walkStmtForPrecedence(v, .{ .compound = s.body });
        },
        .loop => |s| walkStmtForPrecedence(v, .{ .compound = s.body }),
        .break_if => |s| walkExprForPrecedence(v, s.condition),
        .assign => |s| {
            walkExprForPrecedence(v, s.left);
            walkExprForPrecedence(v, s.right);
        },
        .incr_decr => |s| walkExprForPrecedence(v, s.expr),
        .call => |s| walkExprForPrecedence(v, .{ .call = s.call }),
        .decl => |s| switch (s.decl) {
            .@"const" => |d| if (d.initializer) |e| walkExprForPrecedence(v, e),
            .@"var" => |d| if (d.initializer) |e| walkExprForPrecedence(v, e),
            .let => |d| if (d.initializer) |e| walkExprForPrecedence(v, e),
            else => {},
        },
        .@"break", .@"continue", .discard => {},
    }
}

pub fn walkExprForPrecedence(v: *Validator, expr: Ast.Expr) void {
    switch (expr) {
        .binary => |b| {
            checkBinaryPrecedence(v, b);
            walkExprForPrecedence(v, b.left);
            walkExprForPrecedence(v, b.right);
        },
        .unary => |u| walkExprForPrecedence(v, u.operand),
        .call => |c| {
            if (c.func) |f| walkExprForPrecedence(v, f);
            for (c.args.items) |a| walkExprForPrecedence(v, a);
        },
        .index => |i| {
            walkExprForPrecedence(v, i.base);
            walkExprForPrecedence(v, i.idx);
        },
        .member => |m| walkExprForPrecedence(v, m.base),
        .paren => |p| walkExprForPrecedence(v, p.expr),
        .ident, .literal => {},
    }
}

pub fn checkBinaryPrecedence(v: *Validator, b: *Ast.BinaryExpr) void {
    checkOneSide(v, b, b.left);
    checkOneSide(v, b, b.right);
}

pub fn checkOneSide(v: *Validator, b: *Ast.BinaryExpr, side: Ast.Expr) void {
    const child = switch (side) {
        .binary => |cb| cb,
        else => return,
    };
    if (!isAmbiguousNesting(b.op, child.op)) return;
    const range: LocRange = .{ .start = b.loc, .end = b.loc +| @as(u32, @intCast(b.op.string().len)) };
    v.addErrorWithCodeR(
        range,
        Diagnostic.Code.ambiguous_precedence,
        v.fmtError(
            "'{s}' and '{s}' mix without parentheses; WGSL requires explicit grouping",
            .{ b.op.string(), child.op.string() },
        ),
    );
}


// Block-flow helpers ----------------------------------------------------

/// Check if a compound statement block contains any exit (break, return, discard).
/// Check if a compound block contains any exit (break, return, discard).
/// Uses a bounded worklist to avoid unbounded recursion on deep ASTs.
pub fn blockHasExit(block: *Ast.CompoundStmt) bool {
    var stack: [128]Ast.Stmt = undefined;
    var top: usize = 0;

    // Seed the stack with all statements in the block.
    for (block.stmts.items) |stmt| {
        if (top >= stack.len) return false;
        stack[top] = stmt;
        top += 1;
    }

    while (top > 0) {
        top -= 1;
        const stmt = stack[top];
        switch (stmt) {
            .@"break", .@"return", .discard => return true,
            .compound => |s| {
                for (s.stmts.items) |inner| {
                    if (top >= stack.len) return false;
                    stack[top] = inner;
                    top += 1;
                }
            },
            .@"if" => |s| {
                for (s.body.stmts.items) |inner| {
                    if (top >= stack.len) return false;
                    stack[top] = inner;
                    top += 1;
                }
                if (s.else_branch) |eb| {
                    if (top >= stack.len) return false;
                    stack[top] = eb;
                    top += 1;
                }
            },
            .@"switch" => |s| {
                for (s.cases.items) |c| {
                    for (c.body.stmts.items) |inner| {
                        if (top >= stack.len) return false;
                        stack[top] = inner;
                        top += 1;
                    }
                }
            },
            .loop => |s| {
                for (s.body.stmts.items) |inner| {
                    if (top >= stack.len) return false;
                    stack[top] = inner;
                    top += 1;
                }
            },
            .@"for" => |s| {
                for (s.body.stmts.items) |inner| {
                    if (top >= stack.len) return false;
                    stack[top] = inner;
                    top += 1;
                }
            },
            .@"while" => |s| {
                for (s.body.stmts.items) |inner| {
                    if (top >= stack.len) return false;
                    stack[top] = inner;
                    top += 1;
                }
            },
            else => {},
        }
    }
    return false;
}

/// Check if a continuing block has a break_if statement.
pub fn continuingHasBreakIf(continuing: ?*Ast.CompoundStmt) bool {
    const cont = continuing orelse return false;
    for (cont.stmts.items) |stmt| {
        switch (stmt) {
            .break_if => return true,
            else => {},
        }
    }
    return false;
}
