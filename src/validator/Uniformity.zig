//! Phase 5: Uniformity Analysis.
//!
//! Detects non-uniform control-flow violations per WGSL spec section 15.
//! Driven from `Validator.validate` / `Validator.analyze`; reads the parsed
//! module + diagnostic filters off the live `*Validator` and emits straight
//! into its `Diagnostic` sink. The walker (`UniformityAnalyzer`) holds its
//! own state so it doesn't borrow any of the validator's per-function fields.
//!
//! Block U2 replaced the scalar name-matching approximation with an
//! intra-function dataflow: value uniformity is tracked per `SymbolIndex` in a
//! `values` map (seeded from non-uniform builtin params, updated by local
//! decls / assignments), control-flow uniformity is threaded through the walk
//! as a `Taint`, and statement `Behaviors` (§9.1) drive a reconvergence rule so
//! that a branch which escapes (return/break/continue) keeps control flow
//! non-uniform past the conditional. Every approximation leans false-negative
//! (spec §2.1 of docs/deferred/uniformity-dataflow-upgrade.md): when the
//! analysis cannot prove non-uniformity by a rule it implements exactly, it
//! assumes uniform. Cross-function summaries are Block U3.

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
        .var_info = &v.scratch.var_info,
        .filters = if (v.options.diagnostic_filters) |f| f else null,
    };
    try ua.analyze();
}

/// The origin of a non-uniform value or control-flow, carried so a diagnostic
/// can attach a `related` entry pointing back at it (spec §15's taint chain).
const Source = struct {
    /// Byte offset of the origin (a builtin param, a storage/workgroup load).
    loc: u32,
    /// Human phrase for the related-info message; always contains
    /// "non-uniform" so readers/tests can key on it.
    desc: []const u8,
};

/// Uniformity of a value or of control flow at a program point.
const Taint = union(enum) {
    uniform,
    non_uniform: Source,

    fn isNonUniform(t: Taint) bool {
        return t == .non_uniform;
    }

    /// Non-uniform iff either side is; keeps `a`'s source when both are
    /// (first-origin wins, matching the left-to-right / outer-to-inner walk).
    fn join(a: Taint, b: Taint) Taint {
        return if (a == .non_uniform) a else b;
    }
};

/// Which ways a statement can complete (WGSL spec §9.1 "Behaviors"). Drives the
/// reconvergence rule: control flow reconverges past an `if`/`switch` iff every
/// branch can *only* fall through (behavior set `== {Next}`).
const Behaviors = packed struct(u4) {
    next: bool = false,
    ret: bool = false,
    brk: bool = false,
    cont: bool = false,

    const only_next: Behaviors = .{ .next = true };

    fn onlyNext(b: Behaviors) bool {
        return b.next and !b.ret and !b.brk and !b.cont;
    }

    fn merge(a: Behaviors, b: Behaviors) Behaviors {
        return .{
            .next = a.next or b.next,
            .ret = a.ret or b.ret,
            .brk = a.brk or b.brk,
            .cont = a.cont or b.cont,
        };
    }
};

/// Result of analyzing a statement: how it can complete, and the control-flow
/// uniformity that holds *after* it (differs from the incoming CF only for a
/// conditional whose branches don't all reconverge).
const StmtResult = struct {
    behaviors: Behaviors,
    cf_after: Taint,
};

/// Uniformity analysis detects non-uniform control flow violations.
/// Implements WGSL spec section 15.
const UniformityAnalyzer = struct {
    module: *Ast.Module,
    diags: *Diagnostic,
    arena: Allocator,
    /// Per-var address-space / access-mode, keyed by `SymbolIndex.index()`.
    /// Populated in Phase 3 (`validateVarDecl`); read here to classify module
    /// `var` loads (storage-read_write / workgroup => non-uniform).
    var_info: *const std.AutoHashMapUnmanaged(u32, Validator.VarInfo),
    filters: ?*Diagnostic.DiagnosticFilter,

    /// Per-function value uniformity, keyed by `SymbolIndex.index()`. Seeded at
    /// entry with non-uniform builtin params; updated by local decls and
    /// assignments as the body is walked.
    values: std.AutoHashMapUnmanaged(u32, Taint) = .{},

    /// When false, `checkCalls` walks but does not emit — used for the silent
    /// value-propagation pre-pass over loop bodies (back-edge taint) so a
    /// barrier isn't reported twice.
    reporting: bool = true,

    /// Nesting depth of loop bodies currently being re-walked. Caps the
    /// exponential blow-up of the fixed-point (see `runLoopPasses`).
    loop_depth: u8 = 0,

    /// Re-walks of a loop body for the value fixed point. Two passes (one
    /// silent seed + one reporting) catch a single back-edge taint; the lattice
    /// is two-point and monotone so this converges (spec note: "in practice 2
    /// passes"). Beyond `max_fixed_point_depth` nested loops we fall to a single
    /// pass — deeper back-edge taint is a false-negative (safe per §2.1), and
    /// re-walking 2^depth bodies isn't worth it.
    const loop_passes = 2;
    const max_fixed_point_depth = 4;

    fn analyze(ua: *UniformityAnalyzer) Allocator.Error!void {
        for (ua.module.declarations.items) |decl| {
            switch (decl) {
                .function => |fn_decl| try ua.analyzeFunction(fn_decl),
                else => {},
            }
        }
    }

    fn analyzeFunction(ua: *UniformityAnalyzer, fn_decl: *Ast.FunctionDecl) Allocator.Error!void {
        ua.values = .{};
        ua.reporting = true;
        ua.loop_depth = 0;

        try ua.seedParameters(fn_decl.parameters.items);

        if (fn_decl.body) |body| {
            // Entry control flow is uniform for every function. (Non-entry
            // callees get the caller's CF applied via summaries in Block U3;
            // analyzing them at uniform entry CF is false-negative-safe.)
            _ = try ua.analyzeCompound(body, .uniform);
        }
    }

    /// Seed `values` with the non-uniform builtin parameters (U1's set). This
    /// is the one place a builtin's *name* is consulted; everything downstream
    /// resolves through `SymbolIndex`, so a renamed builtin param still taints
    /// and a user variable sharing a builtin's name does not.
    fn seedParameters(ua: *UniformityAnalyzer, params: []const Ast.Parameter) Allocator.Error!void {
        for (params) |param| {
            if (param.name == .none) continue;
            for (param.attributes.items) |attr| {
                if (!std.mem.eql(u8, attr.name, "builtin")) continue;
                if (attr.args.items.len == 0) continue;
                switch (attr.args.items[0]) {
                    .ident => |ident| {
                        if (!isNonUniformBuiltin(ident.name)) continue;
                        const desc = try std.fmt.allocPrint(ua.arena, "non-uniform builtin input '{s}'", .{ident.name});
                        try ua.values.put(ua.arena, param.name.index(), .{
                            .non_uniform = .{ .loc = ua.symbolLoc(param.name), .desc = desc },
                        });
                    },
                    else => {},
                }
            }
        }
    }

    // ---------------------------------------------------------------------
    // Statements
    // ---------------------------------------------------------------------

    fn analyzeCompound(ua: *UniformityAnalyzer, s: *Ast.CompoundStmt, cf_in: Taint) Allocator.Error!StmtResult {
        var cf = cf_in;
        var acc = Behaviors.only_next; // empty block falls through
        for (s.stmts.items) |stmt| {
            // A statement following a prefix that can't fall through is
            // unreachable (§9.1); it can't introduce a violation, so stop.
            if (!acc.next) break;
            const res = try ua.analyzeStmt(stmt, cf);
            acc.next = false; // consume the prefix's fall-through …
            acc = acc.merge(res.behaviors); // … and replace it with this stmt's
            cf = res.cf_after;
        }
        return .{ .behaviors = acc, .cf_after = cf };
    }

    fn analyzeStmt(ua: *UniformityAnalyzer, stmt: Ast.Stmt, cf: Taint) Allocator.Error!StmtResult {
        switch (stmt) {
            .compound => |s| return ua.analyzeCompound(s, cf),
            .@"if" => |s| return ua.analyzeIf(s, cf),
            .@"switch" => |s| return ua.analyzeSwitch(s, cf),
            .loop => |s| return ua.analyzeLoop(s, cf),
            .@"while" => |s| return ua.analyzeWhile(s, cf),
            .@"for" => |s| return ua.analyzeFor(s, cf),
            .@"return" => |s| {
                if (s.value) |val| try ua.checkCalls(val, cf);
                return .{ .behaviors = .{ .ret = true }, .cf_after = cf };
            },
            .assign => |s| {
                try ua.checkCalls(s.left, cf);
                try ua.checkCalls(s.right, cf);
                try ua.recordAssign(s);
                return simpleNext(cf);
            },
            .call => |s| {
                try ua.checkCalls(.{ .call = s.call }, cf);
                return simpleNext(cf);
            },
            .decl => |s| {
                try ua.recordDecl(s.decl, cf);
                return simpleNext(cf);
            },
            .incr_decr => |s| {
                try ua.checkCalls(s.expr, cf);
                return simpleNext(cf);
            },
            .break_if => |s| {
                try ua.checkCalls(s.condition, cf);
                // `break if (c)` conditionally exits the loop.
                return .{ .behaviors = .{ .next = true, .brk = true }, .cf_after = cf };
            },
            .@"break" => return .{ .behaviors = .{ .brk = true }, .cf_after = cf },
            .@"continue" => return .{ .behaviors = .{ .cont = true }, .cf_after = cf },
            // `discard` demotes to a helper invocation so derivatives stay
            // defined; per §9.1 it is Next, not a divergence, for uniformity.
            .discard => return simpleNext(cf),
        }
    }

    fn simpleNext(cf: Taint) StmtResult {
        return .{ .behaviors = Behaviors.only_next, .cf_after = cf };
    }

    fn analyzeIf(ua: *UniformityAnalyzer, s: *Ast.IfStmt, cf: Taint) Allocator.Error!StmtResult {
        // The condition is evaluated in the incoming CF.
        try ua.checkCalls(s.condition, cf);
        const inner_cf = cf.join(try ua.valueUniformity(s.condition));

        const then_res = try ua.analyzeCompound(s.body, inner_cf);
        const else_res: StmtResult = if (s.else_branch) |e|
            try ua.analyzeStmt(e, inner_cf)
        else
            .{ .behaviors = Behaviors.only_next, .cf_after = inner_cf };

        const behaviors = then_res.behaviors.merge(else_res.behaviors);
        // Reconvergence: CF returns to the pre-`if` CF iff both branches can
        // only fall through; otherwise a branch escaped (return/break/continue)
        // and control past the `if` stays at the branched CF. This one rule
        // both fixes divergent-exit false-negatives and keeps balanced-`if`
        // reconvergence valid.
        const reconverges = then_res.behaviors.onlyNext() and else_res.behaviors.onlyNext();
        return .{ .behaviors = behaviors, .cf_after = if (reconverges) cf else inner_cf };
    }

    fn analyzeSwitch(ua: *UniformityAnalyzer, s: *Ast.SwitchStmt, cf: Taint) Allocator.Error!StmtResult {
        try ua.checkCalls(s.expr, cf);
        const inner_cf = cf.join(try ua.valueUniformity(s.expr));

        var behaviors = Behaviors{};
        var reconverges = true;
        for (s.cases.items) |case| {
            for (case.selectors.items) |sel| try ua.checkCalls(sel, cf);
            const cres = try ua.analyzeCompound(case.body, inner_cf);
            // A `break` inside a switch case just exits the switch → it
            // contributes Next to the switch's behavior; other exits propagate.
            var cb = cres.behaviors;
            if (cb.brk) {
                cb.brk = false;
                cb.next = true;
            }
            behaviors = behaviors.merge(cb);
            if (!cb.onlyNext()) reconverges = false;
        }
        if (s.cases.items.len == 0) behaviors = Behaviors.only_next;
        return .{ .behaviors = behaviors, .cf_after = if (reconverges) cf else inner_cf };
    }

    fn analyzeLoop(ua: *UniformityAnalyzer, s: *Ast.LoopStmt, cf: Taint) Allocator.Error!StmtResult {
        // Bare `loop {}` has no header condition; the body runs at the incoming
        // CF. Divergence from an inner `if (c) { break; }` is handled by the
        // reconvergence rule, so barriers reached only by the non-breaking
        // invocations still fire. Post-loop CF is conservatively the incoming
        // CF (see analyzeWhile note).
        try ua.runLoopPasses(s.body, s.continuing, null, cf);
        return .{ .behaviors = Behaviors.only_next, .cf_after = cf };
    }

    fn analyzeWhile(ua: *UniformityAnalyzer, s: *Ast.WhileStmt, cf: Taint) Allocator.Error!StmtResult {
        try ua.checkCalls(s.condition, cf);
        const body_cf = cf.join(try ua.valueUniformity(s.condition));
        try ua.runLoopPasses(s.body, null, null, body_cf);
        // Post-loop CF is left at the incoming CF (reconverge). The spec's
        // "break/continue under non-uniform CF taints the post-loop CF" is a
        // deliberate false-negative here (safe per §2.1): no fixture needs it
        // and propagating it risks corpus false-positives. Revisit if triage
        // shows real shaders relying on post-loop non-uniformity.
        return .{ .behaviors = Behaviors.only_next, .cf_after = cf };
    }

    fn analyzeFor(ua: *UniformityAnalyzer, s: *Ast.ForStmt, cf: Taint) Allocator.Error!StmtResult {
        // The init runs once in the enclosing CF (may declare/taint a loop var).
        if (s.init_stmt) |init_s| _ = try ua.analyzeStmt(init_s, cf);

        var body_cf = cf;
        if (s.condition) |c| {
            try ua.checkCalls(c, cf);
            body_cf = cf.join(try ua.valueUniformity(c));
        }
        // The update runs each iteration; fold it into the re-walked body.
        try ua.runLoopPasses(s.body, null, s.update, body_cf);
        return .{ .behaviors = Behaviors.only_next, .cf_after = cf };
    }

    /// Re-walk a loop body (+ optional `continuing` block / `for` update) to a
    /// bounded value fixed point. Only the final pass reports — earlier passes
    /// silently seed back-edge value taint so a barrier isn't double-reported
    /// (`Diagnostic.deduplicate` would fold the copies anyway, but suppressing
    /// keeps the emit path clean and the related-info deterministic).
    fn runLoopPasses(
        ua: *UniformityAnalyzer,
        body: *Ast.CompoundStmt,
        continuing: ?*Ast.CompoundStmt,
        update: ?Ast.Stmt,
        body_cf: Taint,
    ) Allocator.Error!void {
        const outer_reporting = ua.reporting;
        const passes: u8 = if (ua.loop_depth >= max_fixed_point_depth) 1 else loop_passes;
        ua.loop_depth += 1;
        defer ua.loop_depth -= 1;

        var pass: u8 = 0;
        while (pass < passes) : (pass += 1) {
            ua.reporting = outer_reporting and (pass == passes - 1);
            _ = try ua.analyzeCompound(body, body_cf);
            if (continuing) |c| _ = try ua.analyzeCompound(c, body_cf);
            if (update) |u| _ = try ua.analyzeStmt(u, body_cf);
        }
        ua.reporting = outer_reporting;
    }

    /// Record the uniformity of a `let`/`var`/`const` local binding.
    fn recordDecl(ua: *UniformityAnalyzer, decl: Ast.Decl, cf: Taint) Allocator.Error!void {
        switch (decl) {
            .@"var" => |d| try ua.recordBinding(d.name, d.initializer, cf),
            .let => |d| try ua.recordBinding(d.name, d.initializer, cf),
            .@"const" => |d| try ua.recordBinding(d.name, d.initializer, cf),
            else => {},
        }
    }

    fn recordBinding(ua: *UniformityAnalyzer, name: Ast.SymbolIndex, initializer: ?Ast.Expr, cf: Taint) Allocator.Error!void {
        const init = initializer orelse return;
        try ua.checkCalls(init, cf);
        // An uninitialized local `var` is left absent from `values` (defaults to
        // uniform); a later assignment records its taint.
        if (name != .none) try ua.values.put(ua.arena, name.index(), try ua.valueUniformity(init));
    }

    fn recordAssign(ua: *UniformityAnalyzer, s: *Ast.AssignStmt) Allocator.Error!void {
        // Track only whole-variable assignments to a simple ident. Compound
        // targets (`a[i] = …`, `s.f = …`) are left untracked: element-level
        // taint would need alias analysis, and not tracking is false-negative-
        // safe (it can never manufacture a false positive).
        switch (s.left) {
            .ident => |lhs| {
                if (lhs.ref == .none) return;
                const rhs = try ua.valueUniformity(s.right);
                const new_taint: Taint = if (s.op == .simple)
                    rhs
                else blk: {
                    // Compound assign (`+=` etc.) reads the prior value too, so
                    // join with what `x` already held. Plain `=` overwrites.
                    const old = ua.values.get(lhs.ref.index()) orelse Taint.uniform;
                    break :blk old.join(rhs);
                };
                try ua.values.put(ua.arena, lhs.ref.index(), new_taint);
            },
            else => {},
        }
    }

    // ---------------------------------------------------------------------
    // Value uniformity
    // ---------------------------------------------------------------------

    fn valueUniformity(ua: *UniformityAnalyzer, expr: Ast.Expr) Allocator.Error!Taint {
        switch (expr) {
            .ident => |e| return ua.identUniformity(e),
            .literal => return .uniform,
            .call => |e| return ua.callUniformity(e),
            .binary => |e| {
                const l = try ua.valueUniformity(e.left);
                if (l.isNonUniform()) return l;
                return ua.valueUniformity(e.right);
            },
            .unary => |e| return ua.valueUniformity(e.operand),
            .index => |e| {
                const b = try ua.valueUniformity(e.base);
                if (b.isNonUniform()) return b;
                return ua.valueUniformity(e.idx);
            },
            .member => |e| return ua.valueUniformity(e.base),
            .paren => |e| return ua.valueUniformity(e.expr),
        }
    }

    fn identUniformity(ua: *UniformityAnalyzer, e: *Ast.IdentExpr) Allocator.Error!Taint {
        if (e.ref == .none) return .uniform;
        const idx = e.ref.index();
        // 1. Local dataflow: params (seeded) + local let/var/const + tracked
        //    assignments. Checked first so a function-local `var` shadowing a
        //    module var resolves to its dataflow entry.
        if (ua.values.get(idx)) |t| return t;
        // 2. Module variable classified by address space (§15).
        if (ua.var_info.get(idx)) |info| {
            if (!addressSpaceNonUniform(info)) return .uniform;
            const name = ua.symbolName(e.ref);
            const kind_word: []const u8 = if (info.address_space == .workgroup)
                "workgroup variable"
            else
                "storage buffer";
            const desc = try std.fmt.allocPrint(ua.arena, "non-uniform read of {s} '{s}'", .{ kind_word, name });
            return .{ .non_uniform = .{ .loc = e.loc, .desc = desc } };
        }
        // 3. Module const / override / unresolved: uniform (§2.1 default).
        return .uniform;
    }

    fn callUniformity(ua: *UniformityAnalyzer, e: *Ast.CallExpr) Allocator.Error!Taint {
        const callee = calleeName(e);
        // `workgroupUniformLoad` synchronizes then returns a uniform value by
        // definition — that's its whole purpose (§15). Its own uniform-flow
        // requirement is still enforced at the call site in `checkCalls`.
        if (std.mem.eql(u8, callee, "workgroupUniformLoad")) return .uniform;
        // Otherwise a call result is uniform iff all its arguments are uniform.
        // (Builtins with a genuinely non-uniform result — subgroup ballots and
        // scans — are Block U3's per-row column.)
        for (e.args.items) |arg| {
            const t = try ua.valueUniformity(arg);
            if (t.isNonUniform()) return t;
        }
        return .uniform;
    }

    // ---------------------------------------------------------------------
    // Call-site checks
    // ---------------------------------------------------------------------

    /// Walk an expression and, at each builtin call that requires uniform
    /// control flow, report if the current CF is non-uniform.
    fn checkCalls(ua: *UniformityAnalyzer, expr: Ast.Expr, cf: Taint) Allocator.Error!void {
        switch (expr) {
            .call => |e| {
                for (e.args.items) |arg| try ua.checkCalls(arg, cf);
                if (Builtins.lookup(calleeName(e))) |builtin| {
                    if (builtin.requiresUniform() and cf.isNonUniform()) {
                        try ua.report(e, builtin.kind, cf);
                    }
                }
            },
            .binary => |e| {
                try ua.checkCalls(e.left, cf);
                try ua.checkCalls(e.right, cf);
            },
            .unary => |e| try ua.checkCalls(e.operand, cf),
            .index => |e| {
                try ua.checkCalls(e.base, cf);
                try ua.checkCalls(e.idx, cf);
            },
            .member => |e| try ua.checkCalls(e.base, cf),
            .paren => |e| try ua.checkCalls(e.expr, cf),
            .ident, .literal => {},
        }
    }

    fn report(ua: *UniformityAnalyzer, e: *Ast.CallExpr, kind: Builtins.Kind, cf: Taint) Allocator.Error!void {
        if (!ua.reporting) return;

        var loc: u32 = 0;
        if (e.func) |func| switch (func) {
            .ident => |ident| loc = ident.loc,
            else => {},
        };

        // Determine the diagnostic rule and code.
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

        // Check if this rule is filtered.
        if (rule.len > 0 and ua.filters != null) {
            if (ua.filters.?.isDisabled(rule)) return;
        }

        var severity = Diagnostic.Severity.@"error";
        if (rule.len > 0 and ua.filters != null) {
            severity = ua.filters.?.getSeverity(rule, .@"error");
        }

        const message = switch (kind) {
            .derivative => "derivative function must only be called from uniform control flow",
            .synchronization => "barrier function must only be called from uniform control flow",
            .texture => "texture sampling with implicit LOD must only be called from uniform control flow",
            .subgroup => "subgroup operation requires uniform control flow",
            else => "function requires uniform control flow",
        };

        // Attach the taint chain: point back at the source that made control
        // flow non-uniform. Additive `related` on CLI JSON + LSP (the
        // `Diagnostic` wire shape already serializes `related`).
        var related: []const Diagnostic.RelatedInfo = &.{};
        if (cf == .non_uniform) {
            const src = cf.non_uniform;
            const infos = try ua.arena.alloc(Diagnostic.RelatedInfo, 1);
            infos[0] = .{ .range = ua.diags.makeRange(src.loc, src.loc + 1), .message = src.desc };
            related = infos;
        }

        ua.diags.add(ua.arena, .{
            .severity = severity,
            .code = code,
            .message = message,
            .range = ua.diags.makeRange(loc, loc + 1),
            .related = related,
        });
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    fn calleeName(e: *Ast.CallExpr) []const u8 {
        if (e.func) |func| switch (func) {
            .ident => |ident| return ident.name,
            else => {},
        };
        return "";
    }

    fn symbolLoc(ua: *UniformityAnalyzer, sym: Ast.SymbolIndex) u32 {
        if (sym == .none) return 0;
        return ua.module.symbols.items[sym.index()].loc;
    }

    fn symbolName(ua: *UniformityAnalyzer, sym: Ast.SymbolIndex) []const u8 {
        if (sym == .none) return "";
        return ua.module.symbols.items[sym.index()].original_name;
    }
};

/// True when a load from a variable in this address space / access mode is
/// non-uniform per WGSL §15's value-uniformity table.
fn addressSpaceNonUniform(info: Validator.VarInfo) bool {
    return switch (info.address_space) {
        .workgroup => true,
        .storage => info.access_mode == .read_write,
        // uniform, storage-read, handle, function, none => uniform.
        // NB: `var<private>` is treated as uniform here (lean false-negative).
        // The spec's per-invocation private taint — non-uniform iff some store
        // writes a non-uniform value — needs a module pre-scan; it is deferred
        // (no fixture exercises it and tainting risks corpus false positives).
        // See docs/deferred/uniformity-dataflow-upgrade.md §2.2 calibration.
        else => false,
    };
}

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
