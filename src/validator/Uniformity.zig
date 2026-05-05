//! Phase 5: Uniformity Analysis.
//!
//! Detects non-uniform control-flow violations per WGSL spec section 15.
//! Driven from `Validator.validate` / `Validator.analyze`; reads the parsed
//! module + diagnostic filters off the live `*Validator` and emits straight
//! into its `Diagnostic` sink. The walker (`UniformityAnalyzer`) holds its
//! own state so it doesn't borrow any of the validator's per-function fields.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../Ast.zig");
const Builtins = @import("../Builtins.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Validator = @import("../Validator.zig");

pub fn analyzeUniformity(v: *Validator) Allocator.Error!void {
    var ua = UniformityAnalyzer{
        .module = v.module,
        .diags = v.diags,
        .arena = v.arena,
        .filters = if (v.options.diagnostic_filters) |f| f else null,
    };
    try ua.analyze();
}

/// Uniformity analysis detects non-uniform control flow violations.
/// Implements WGSL spec section 15.
const UniformityAnalyzer = struct {
    module: *Ast.Module,
    diags: *Diagnostic,
    arena: Allocator,
    filters: ?*Diagnostic.DiagnosticFilter,

    // Current function context
    current_func: ?*Ast.FunctionDecl = null,
    current_stage: Validator.ShaderStage = .none,

    // Current uniformity state
    state: UniformityState = .uniform,

    // Sources of non-uniformity
    non_uniform_sources: std.ArrayListUnmanaged(NonUniformSource) = .empty,

    const UniformityState = enum(u8) {
        uniform,
        may_be_non_uniform,
        non_uniform,
    };

    const NonUniformSource = struct {
        loc: u32,
        reason: []const u8,
        builtin_name: []const u8,
    };

    fn analyze(ua: *UniformityAnalyzer) Allocator.Error!void {
        for (ua.module.declarations.items) |decl| {
            switch (decl) {
                .function => |fn_decl| try ua.analyzeFunction(fn_decl),
                else => {},
            }
        }
    }

    fn analyzeFunction(ua: *UniformityAnalyzer, fn_decl: *Ast.FunctionDecl) Allocator.Error!void {
        ua.current_func = fn_decl;
        ua.state = .uniform;
        ua.non_uniform_sources = .empty;

        // Determine shader stage
        ua.current_stage = .none;
        for (fn_decl.attributes.items) |attr| {
            if (std.mem.eql(u8, attr.name, "vertex")) {
                ua.current_stage = .vertex;
            } else if (std.mem.eql(u8, attr.name, "fragment")) {
                ua.current_stage = .fragment;
            } else if (std.mem.eql(u8, attr.name, "compute")) {
                ua.current_stage = .compute;
            }
        }

        // Parameters may introduce non-uniformity
        try ua.analyzeParameters(fn_decl.parameters.items);

        // Analyze function body
        if (fn_decl.body) |body| {
            ua.analyzeCompoundStmt(body);
        }

        ua.current_func = null;
    }

    fn analyzeParameters(ua: *UniformityAnalyzer, params: []const Ast.Parameter) Allocator.Error!void {
        for (params) |param| {
            for (param.attributes.items) |attr| {
                if (std.mem.eql(u8, attr.name, "builtin") and attr.args.items.len > 0) {
                    switch (attr.args.items[0]) {
                        .ident => |ident| {
                            if (isNonUniformBuiltin(ident.name)) {
                                try ua.non_uniform_sources.append(ua.arena, .{
                                    .loc = ident.loc,
                                    .reason = "builtin input is non-uniform",
                                    .builtin_name = ident.name,
                                });
                            }
                        },
                        else => {},
                    }
                }
            }
        }
    }

    fn analyzeCompoundStmt(ua: *UniformityAnalyzer, s: *Ast.CompoundStmt) void {
        for (s.stmts.items) |stmt| {
            ua.analyzeStmt(stmt);
        }
    }

    fn analyzeStmt(ua: *UniformityAnalyzer, stmt: Ast.Stmt) void {
        switch (stmt) {
            .compound => |s| ua.analyzeCompoundStmt(s),
            .@"if" => |s| ua.analyzeIfStmt(s),
            .@"switch" => |s| ua.analyzeSwitchStmt(s),
            .loop => |s| ua.analyzeLoopStmt(s),
            .@"while" => |s| ua.analyzeWhileStmt(s),
            .@"for" => |s| ua.analyzeForStmt(s),
            .@"return" => |s| {
                if (s.value) |val| ua.analyzeExpr(val);
            },
            .assign => |s| {
                ua.analyzeExpr(s.left);
                ua.analyzeExpr(s.right);
            },
            .call => |s| ua.analyzeExpr(.{ .call = s.call }),
            .decl => |s| {
                switch (s.decl) {
                    .@"var" => |d| {
                        if (d.initializer) |init| ua.analyzeExpr(init);
                    },
                    .let => |d| {
                        if (d.initializer) |init| ua.analyzeExpr(init);
                    },
                    .@"const" => |d| {
                        if (d.initializer) |init| ua.analyzeExpr(init);
                    },
                    else => {},
                }
            },
            .incr_decr => |s| ua.analyzeExpr(s.expr),
            .break_if => |s| ua.analyzeExpr(s.condition),
            .@"break", .@"continue", .discard => {},
        }
    }

    fn analyzeIfStmt(ua: *UniformityAnalyzer, s: *Ast.IfStmt) void {
        const cond_non_uniform = ua.analyzeExprUniformity(s.condition);

        const prev_state = ua.state;
        if (cond_non_uniform) {
            ua.state = .non_uniform;
        }

        ua.analyzeCompoundStmt(s.body);
        if (s.else_branch) |else_stmt| {
            ua.analyzeStmt(else_stmt);
        }

        ua.state = prev_state;
    }

    fn analyzeSwitchStmt(ua: *UniformityAnalyzer, s: *Ast.SwitchStmt) void {
        const cond_non_uniform = ua.analyzeExprUniformity(s.expr);

        const prev_state = ua.state;
        if (cond_non_uniform) {
            ua.state = .non_uniform;
        }

        for (s.cases.items) |case| {
            for (case.selectors.items) |sel| {
                ua.analyzeExpr(sel);
            }
            ua.analyzeCompoundStmt(case.body);
        }

        ua.state = prev_state;
    }

    fn analyzeLoopStmt(ua: *UniformityAnalyzer, s: *Ast.LoopStmt) void {
        const prev_state = ua.state;
        ua.analyzeCompoundStmt(s.body);
        if (s.continuing) |cont| {
            ua.analyzeCompoundStmt(cont);
        }
        ua.state = prev_state;
    }

    fn analyzeWhileStmt(ua: *UniformityAnalyzer, s: *Ast.WhileStmt) void {
        const cond_non_uniform = ua.analyzeExprUniformity(s.condition);

        const prev_state = ua.state;
        if (cond_non_uniform) {
            ua.state = .non_uniform;
        }
        ua.analyzeCompoundStmt(s.body);
        ua.state = prev_state;
    }

    fn analyzeForStmt(ua: *UniformityAnalyzer, s: *Ast.ForStmt) void {
        if (s.init_stmt) |init| {
            ua.analyzeStmt(init);
        }

        var cond_non_uniform = false;
        if (s.condition) |cond| {
            cond_non_uniform = ua.analyzeExprUniformity(cond);
        }

        const prev_state = ua.state;
        if (cond_non_uniform) {
            ua.state = .non_uniform;
        }

        ua.analyzeCompoundStmt(s.body);

        if (s.update) |update| {
            ua.analyzeStmt(update);
        }

        ua.state = prev_state;
    }

    fn analyzeExpr(ua: *UniformityAnalyzer, expr: Ast.Expr) void {
        switch (expr) {
            .call => |e| ua.analyzeCallExpr(e),
            .binary => |e| {
                ua.analyzeExpr(e.left);
                ua.analyzeExpr(e.right);
            },
            .unary => |e| ua.analyzeExpr(e.operand),
            .index => |e| {
                ua.analyzeExpr(e.base);
                ua.analyzeExpr(e.idx);
            },
            .member => |e| ua.analyzeExpr(e.base),
            .paren => |e| ua.analyzeExpr(e.expr),
            .ident, .literal => {},
        }
    }

    fn analyzeCallExpr(ua: *UniformityAnalyzer, e: *Ast.CallExpr) void {
        var callee_name: []const u8 = "";
        if (e.func) |func| {
            switch (func) {
                .ident => |ident| callee_name = ident.name,
                else => {},
            }
        }

        // Check arguments
        for (e.args.items) |arg| {
            ua.analyzeExpr(arg);
        }

        // Check if this is a builtin that requires uniform control flow
        if (Builtins.lookup(callee_name)) |builtin| {
            if (builtin.requiresUniform() and ua.state != .uniform) {
                ua.reportUniformityError(e, callee_name, builtin.kind);
            }
        }
    }

    fn analyzeExprUniformity(ua: *UniformityAnalyzer, expr: Ast.Expr) bool {
        switch (expr) {
            .ident => |e| {
                // Check if identifier refers to non-uniform source
                for (ua.non_uniform_sources.items) |src| {
                    if (std.mem.eql(u8, src.builtin_name, e.name)) {
                        return true;
                    }
                }
                if (isNonUniformBuiltin(e.name)) {
                    return true;
                }
                return false;
            },
            .call => |e| {
                // Some builtins produce non-uniform results
                var callee_name: []const u8 = "";
                if (e.func) |func| {
                    switch (func) {
                        .ident => |ident| callee_name = ident.name,
                        else => {},
                    }
                }
                if (Builtins.lookup(callee_name)) |builtin| {
                    if (builtin.kind == .texture) {
                        return true; // Simplified
                    }
                }
                for (e.args.items) |arg| {
                    if (ua.analyzeExprUniformity(arg)) {
                        return true;
                    }
                }
                return false;
            },
            .binary => |e| {
                return ua.analyzeExprUniformity(e.left) or ua.analyzeExprUniformity(e.right);
            },
            .unary => |e| return ua.analyzeExprUniformity(e.operand),
            .index => |e| {
                return ua.analyzeExprUniformity(e.base) or ua.analyzeExprUniformity(e.idx);
            },
            .member => |e| return ua.analyzeExprUniformity(e.base),
            .paren => |e| return ua.analyzeExprUniformity(e.expr),
            .literal => return false,
        }
    }

    fn reportUniformityError(ua: *UniformityAnalyzer, e: *Ast.CallExpr, func_name: []const u8, kind: Builtins.Kind) void {
        // Determine the location
        var loc: u32 = 0;
        if (e.func) |func| {
            switch (func) {
                .ident => |ident| loc = ident.loc,
                else => {},
            }
        }

        // Determine the diagnostic rule and code
        var rule: []const u8 = "";
        var code: []const u8 = "";

        switch (kind) {
            .derivative => {
                rule = Diagnostic.rule_derivative_uniformity;
                code = Diagnostic.Code.non_uniform_derivative;
            },
            .synchronization => {
                rule = ""; // Always an error, cannot be filtered
                code = Diagnostic.Code.non_uniform_barrier;
            },
            .texture => {
                rule = Diagnostic.rule_derivative_uniformity;
                code = Diagnostic.Code.non_uniform_texture;
            },
            .subgroup => {
                rule = Diagnostic.rule_subgroup_uniformity;
                code = Diagnostic.Code.non_uniform_subgroup;
            },
            else => return,
        }

        // Check if this rule is filtered
        if (rule.len > 0 and ua.filters != null) {
            if (ua.filters.?.isDisabled(rule)) {
                return;
            }
        }

        // Determine severity
        var severity = Diagnostic.Severity.@"error";
        if (rule.len > 0 and ua.filters != null) {
            severity = ua.filters.?.getSeverity(rule, .@"error");
        }

        // Build message
        const message = switch (kind) {
            .derivative => "derivative function must only be called from uniform control flow",
            .synchronization => "barrier function must only be called from uniform control flow",
            .texture => "texture sampling with implicit LOD must only be called from uniform control flow",
            .subgroup => "subgroup operation requires uniform control flow",
            else => "function requires uniform control flow",
        };

        _ = func_name;

        ua.diags.add(ua.arena, .{
            .severity = severity,
            .code = code,
            .message = message,
            .range = ua.diags.makeRange(loc, loc + 1),
        });
    }
};

/// Returns true if the builtin input is known to be non-uniform.
fn isNonUniformBuiltin(name: []const u8) bool {
    const non_uniform = std.StaticStringMap(void).initComptime(.{
        .{ "vertex_index", {} },
        .{ "instance_index", {} },
        .{ "position", {} },
        .{ "front_facing", {} },
        .{ "sample_index", {} },
        .{ "sample_mask", {} },
        .{ "local_invocation_id", {} },
        .{ "local_invocation_index", {} },
        .{ "global_invocation_id", {} },
    });
    return non_uniform.has(name);
}

test "validator: isNonUniformBuiltin" {
    try std.testing.expect(isNonUniformBuiltin("vertex_index"));
    try std.testing.expect(isNonUniformBuiltin("instance_index"));
    try std.testing.expect(isNonUniformBuiltin("position"));
    try std.testing.expect(isNonUniformBuiltin("front_facing"));
    try std.testing.expect(isNonUniformBuiltin("sample_index"));
    try std.testing.expect(isNonUniformBuiltin("local_invocation_id"));
    try std.testing.expect(isNonUniformBuiltin("global_invocation_id"));
    // Uniform builtins
    try std.testing.expect(!isNonUniformBuiltin("workgroup_id"));
    try std.testing.expect(!isNonUniformBuiltin("num_workgroups"));
    try std.testing.expect(!isNonUniformBuiltin("not_a_builtin"));
}
