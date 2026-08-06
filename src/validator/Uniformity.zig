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
//! assumes uniform.
//!
//! Block U3 added cross-function summaries. A first bottom-up pass over the
//! call graph computes a `FnSummary` per function — `call_site_requirement`
//! (does it reach a uniform-flow builtin while its own control flow is still
//! uniform?) and `ret` (return-value uniformity relative to its parameters,
//! `depends_on_args`). A second declaration-order pass reports, consulting a
//! callee's summary at each user-call site: a call under non-uniform control
//! flow to a function with a requirement is a violation reported at the call
//! site; a call's *result* uniformity comes from `ret` folded against the
//! actual arguments (so an arg-ignoring helper stays uniform even under a
//! non-uniform argument — precise where U2's "non-uniform iff any arg is" was
//! false-positive-leaning).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../Ast.zig");
const Builtins = @import("../Builtins.zig");
const Dce = @import("../Dce.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Validator = @import("../Validator.zig");

pub fn analyzeUniformity(v: *Validator) Allocator.Error!void {
    var ua = UniformityAnalyzer{
        .module = v.module,
        .diags = v.diags,
        .arena = v.arena,
        .var_info = &v.scratch.var_info,
        .base_filter = try mergeBaseFilter(v.arena, v.options.diagnostic_filters, &v.scratch.module_diagnostics),
    };
    try ua.analyze();
}

/// The base diagnostic filter for the whole module: a caller-provided filter
/// (`options.diagnostic_filters`) with any module-scope `diagnostic(...)`
/// directives layered on top — the source directive is the inner scope and wins
/// per spec §2.3. Function-level `@diagnostic` attributes layer on top of this
/// per function (`functionFilter`). Allocates a merged filter only when both
/// sources carry rules; otherwise returns whichever one is populated (or null).
fn mergeBaseFilter(
    arena: Allocator,
    caller: ?*Diagnostic.DiagnosticFilter,
    module: *Diagnostic.DiagnosticFilter,
) Allocator.Error!?*Diagnostic.DiagnosticFilter {
    if (module.rules.count() == 0) return caller; // no source directives
    if (caller == null) return module; // source directives only
    const merged = try arena.create(Diagnostic.DiagnosticFilter);
    merged.* = .{ .rules = .{} };
    try copyRules(arena, merged, caller.?); // outer scope first …
    try copyRules(arena, merged, module); // … inner scope overrides
    return merged;
}

/// Overlay `src`'s rules onto `dst`, overwriting any shared keys (so calling it
/// with successively-inner scopes leaves the innermost severity per rule).
fn copyRules(
    arena: Allocator,
    dst: *Diagnostic.DiagnosticFilter,
    src: *const Diagnostic.DiagnosticFilter,
) Allocator.Error!void {
    var it = src.rules.iterator();
    while (it.next()) |e| try dst.rules.put(arena, e.key_ptr.*, e.value_ptr.*);
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

/// A bitset over a function's parameter positions (param index → bit). `u64`
/// caps precise tracking at 64 params; a return deriving from a parameter
/// beyond that falls back to uniform (false-negative-safe per §2.1). WGSL
/// functions never approach 64 parameters in practice.
const ArgBitset = u64;

/// A uniform-flow requirement reached inside a function: the root builtin whose
/// call must be from uniform control flow. Carries the kind (for E070x code
/// selection), name, and the callee-side loc (for the related-info chain).
const Requirement = struct { kind: Builtins.Kind, name: []const u8, loc: u32 };

/// Uniformity of a function's return value, relative to its parameters.
const RetUniformity = union(enum) {
    uniform,
    /// Non-uniform from a source independent of the arguments (a storage /
    /// workgroup load reached inside the callee).
    non_uniform: Source,
    /// Uniform iff every actual argument named by the bitset is uniform at the
    /// call site. Folded per call in `applyRet`.
    depends_on_args: ArgBitset,
};

/// Bottom-up summary of one function, keyed by its fn `SymbolIndex`. Computed in
/// pass 1 (callees first, so a caller sees its callees' summaries); consulted in
/// pass 2 at call sites — `call_site_requirement` in `checkCalls` (control-flow
/// enforcement) and `ret` in `callUniformity` (return-value uniformity).
const FnSummary = struct {
    /// Set when the function reaches a uniform-flow builtin (directly, or via a
    /// callee that itself has a requirement) while its own control flow is still
    /// uniform (== entry). Calling it from non-uniform control flow is then a
    /// violation, reported at the *call site*.
    call_site_requirement: ?Requirement = null,
    ret: RetUniformity = .uniform,
};

/// Combine two return-value uniformities (fold across an expression's operands
/// or across a function's `return` statements): non-uniform dominates; else the
/// argument-dependence bitsets union; else uniform.
fn combine(a: RetUniformity, b: RetUniformity) RetUniformity {
    if (a == .non_uniform) return a;
    if (b == .non_uniform) return b;
    const abits: ArgBitset = if (a == .depends_on_args) a.depends_on_args else 0;
    const bbits: ArgBitset = if (b == .depends_on_args) b.depends_on_args else 0;
    const bits = abits | bbits;
    return if (bits == 0) .uniform else .{ .depends_on_args = bits };
}

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
    /// Module-wide filter (caller-provided ⊕ module-scope `diagnostic(...)`).
    /// `cur_fn_filter` overlays the current function's `@diagnostic` attributes
    /// on top of this per function; `report` consults `cur_fn_filter`.
    base_filter: ?*Diagnostic.DiagnosticFilter,
    /// Effective filter for the function currently being walked in pass 2:
    /// `base_filter` plus that function's `@diagnostic` attributes. Set by
    /// `walkFunction`; read by `report`.
    cur_fn_filter: ?*Diagnostic.DiagnosticFilter = null,

    /// Per-function value uniformity, keyed by `SymbolIndex.index()`. Seeded at
    /// entry with non-uniform builtin params; updated by local decls and
    /// assignments as the body is walked.
    values: std.AutoHashMapUnmanaged(u32, Taint) = .{},

    /// Cross-function summaries, keyed by fn `SymbolIndex.index()`. Filled by
    /// pass 1 (bottom-up); read by pass 2 at call sites.
    summaries: std.AutoHashMapUnmanaged(u32, FnSummary) = .{},

    /// The function currently being walked: its own summary is accumulated here
    /// and committed by `commitSummary` at the end of the pass-1 walk.
    cur_requirement: ?Requirement = null,
    cur_ret: RetUniformity = .uniform,

    /// Parameters of the current function, in declaration order — resolves an
    /// ident back to its parameter position for `ret`'s `depends_on_args`.
    current_params: []const Ast.Parameter = &.{},

    /// When false, `report` walks but does not emit. Two uses: the pass-1
    /// summary walk (`walkFunction(.., false)`) computes summaries silently, and
    /// the silent value-propagation pre-pass over a loop body (back-edge taint,
    /// `runLoopPasses`) avoids reporting the same barrier twice.
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
        // Pass 1 (silent): compute a `FnSummary` for every function, bottom-up
        // over the call graph so a caller sees its callees' summaries. The graph
        // is acyclic by phase 3.75 (`checkRecursiveFunctions`); the post-order
        // color guard is defensive.
        const order = try ua.bottomUpOrder();
        for (order) |fn_decl| {
            try ua.walkFunction(fn_decl, false);
            try ua.commitSummary(fn_decl);
        }
        // Pass 2 (reporting): emit diagnostics in declaration order (unchanged
        // from U2), now consulting the summaries at user-call sites.
        for (ua.module.declarations.items) |decl| {
            switch (decl) {
                .function => |fn_decl| try ua.walkFunction(fn_decl, true),
                else => {},
            }
        }
    }

    /// Walk one function's body. `emit` selects the pass: false = pass 1
    /// (accumulate the summary in `cur_requirement`/`cur_ret`, emit nothing),
    /// true = pass 2 (emit diagnostics, summaries already computed).
    fn walkFunction(ua: *UniformityAnalyzer, fn_decl: *Ast.FunctionDecl, emit: bool) Allocator.Error!void {
        ua.values = .{};
        ua.reporting = emit;
        ua.loop_depth = 0;
        ua.cur_requirement = null;
        ua.cur_ret = .uniform;
        ua.current_params = fn_decl.parameters.items;
        ua.cur_fn_filter = try ua.functionFilter(fn_decl);

        try ua.seedParameters(fn_decl.parameters.items);

        if (fn_decl.body) |body| {
            // Entry control flow is uniform for every function. A non-entry
            // callee's actual CF is applied by its callers via the summary at
            // each call site; analyzing it at uniform entry CF is
            // false-negative-safe (§2.1).
            _ = try ua.analyzeCompound(body, .uniform);
        }
    }

    /// Commit the current function's accumulated summary (pass 1). Bottom-up
    /// order guarantees any caller walked later reads a complete summary.
    fn commitSummary(ua: *UniformityAnalyzer, fn_decl: *Ast.FunctionDecl) Allocator.Error!void {
        if (fn_decl.name == .none) return;
        try ua.summaries.put(ua.arena, fn_decl.name.index(), .{
            .call_site_requirement = ua.cur_requirement,
            .ret = ua.cur_ret,
        });
    }

    /// The effective diagnostic filter for `fn_decl`: `base_filter` with the
    /// function's own `@diagnostic(severity, rule)` attributes overlaid (the
    /// innermost scope, spec §2.3). Returns `base_filter` untouched — no
    /// allocation — when the function carries no `@diagnostic` attribute.
    /// A violation *reported at a call site* inside this function is scoped by
    /// this function's attributes; statement-level scoping is out of scope (a
    /// documented false-negative — the whole-function severity still applies).
    fn functionFilter(ua: *UniformityAnalyzer, fn_decl: *Ast.FunctionDecl) Allocator.Error!?*Diagnostic.DiagnosticFilter {
        var has_attr = false;
        for (fn_decl.attributes.items) |attr| {
            if (std.mem.eql(u8, attr.name, "diagnostic")) {
                has_attr = true;
                break;
            }
        }
        if (!has_attr) return ua.base_filter;

        const f = try ua.arena.create(Diagnostic.DiagnosticFilter);
        f.* = .{ .rules = .{} };
        if (ua.base_filter) |b| try copyRules(ua.arena, f, b);
        for (fn_decl.attributes.items) |attr| {
            if (!std.mem.eql(u8, attr.name, "diagnostic")) continue;
            if (attr.args.items.len < 2) continue;
            const sev_name = identName(attr.args.items[0]) orelse continue;
            const rule_name = identName(attr.args.items[1]) orelse continue;
            if (Diagnostic.severityFromKeyword(sev_name)) |sev| {
                try f.rules.put(ua.arena, rule_name, sev);
            }
        }
        return f;
    }

    /// The identifier text of an expression, or null if it isn't a bare ident
    /// (a `@diagnostic` severity / rule argument is always an ident).
    fn identName(e: Ast.Expr) ?[]const u8 {
        return switch (e) {
            .ident => |i| i.name,
            else => null,
        };
    }

    /// Functions in bottom-up (callees-first) order. Post-order DFS over the
    /// call graph — the same fn-symbol-indexed edges `checkRecursiveFunctions`
    /// builds (`Dce.collectStmtRefs` filtered to `.function` symbols).
    fn bottomUpOrder(ua: *UniformityAnalyzer) Allocator.Error![]const *Ast.FunctionDecl {
        var by_sym: std.AutoHashMapUnmanaged(u32, *Ast.FunctionDecl) = .{};
        var decls: std.ArrayList(*Ast.FunctionDecl) = .empty;
        for (ua.module.declarations.items) |decl| switch (decl) {
            .function => |fn_decl| {
                try decls.append(ua.arena, fn_decl);
                if (fn_decl.name != .none) try by_sym.put(ua.arena, fn_decl.name.index(), fn_decl);
            },
            else => {},
        };

        var order: std.ArrayList(*Ast.FunctionDecl) = .empty;
        var color: std.AutoHashMapUnmanaged(u32, u2) = .{}; // 0 white, 1 gray, 2 black
        for (decls.items) |fn_decl| {
            if (fn_decl.name == .none) {
                // Nameless (malformed) function: no edges, emit as a leaf.
                try order.append(ua.arena, fn_decl);
                continue;
            }
            try ua.visitPostOrder(fn_decl, &by_sym, &color, &order);
        }
        return order.items;
    }

    fn visitPostOrder(
        ua: *UniformityAnalyzer,
        fn_decl: *Ast.FunctionDecl,
        by_sym: *const std.AutoHashMapUnmanaged(u32, *Ast.FunctionDecl),
        color: *std.AutoHashMapUnmanaged(u32, u2),
        order: *std.ArrayList(*Ast.FunctionDecl),
    ) Allocator.Error!void {
        const idx = fn_decl.name.index();
        // Gray (on the current DFS stack — a back-edge, impossible in valid WGSL)
        // or black (already emitted): stop. Skipping a back-edge is
        // false-negative-safe.
        if ((color.get(idx) orelse 0) != 0) return;
        try color.put(ua.arena, idx, 1);

        if (fn_decl.body) |body| {
            var refs: std.ArrayList(u32) = .empty;
            try Dce.collectStmtRefs(ua.arena, .{ .compound = body }, &refs);
            for (refs.items) |ref| {
                if (ref >= ua.module.symbols.items.len) continue;
                if (ua.module.symbols.items[ref].kind != .function) continue;
                if (by_sym.get(ref)) |callee| try ua.visitPostOrder(callee, by_sym, color, order);
            }
        }

        try color.put(ua.arena, idx, 2);
        try order.append(ua.arena, fn_decl);
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
                if (s.value) |val| {
                    try ua.checkCalls(val, cf);
                    // Fold this return into the function's `ret` summary (pass 1
                    // accumulates it; harmless in pass 2, which never commits).
                    ua.cur_ret = combine(ua.cur_ret, try ua.evalReturnValue(val));
                }
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
            // TODO(block-2): treat the phony RHS as an evaluated expression.
            .phony => return simpleNext(cf),
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
        // A user function's result uniformity comes from its summary (Block U3):
        // precise per-argument dependence, not "non-uniform iff any argument
        // is". This is what keeps an arg-ignoring helper uniform even under a
        // non-uniform argument (§2.1 lean-false-negative), where U2's coarse
        // fold was a false-positive surface.
        if (Builtins.lookup(callee) == null) {
            if (ua.calleeSummary(e)) |summary| return ua.applyRet(summary.ret, e);
        }
        // Builtin (or unresolved) call: uniform iff all its arguments are
        // uniform. Builtins with a genuinely non-uniform result — subgroup
        // ballots and scans — are deferred to Block U5's per-row column.
        for (e.args.items) |arg| {
            const t = try ua.valueUniformity(arg);
            if (t.isNonUniform()) return t;
        }
        return .uniform;
    }

    /// Fold a callee's `ret` summary against the actual arguments at a call site.
    fn applyRet(ua: *UniformityAnalyzer, ret: RetUniformity, e: *Ast.CallExpr) Allocator.Error!Taint {
        switch (ret) {
            .uniform => return .uniform,
            .non_uniform => |src| return .{ .non_uniform = src },
            .depends_on_args => |bits| {
                for (e.args.items, 0..) |arg, i| {
                    if (i >= 64) break;
                    if ((bits >> @intCast(i)) & 1 == 0) continue;
                    const t = try ua.valueUniformity(arg);
                    if (t.isNonUniform()) return t;
                }
                return .uniform;
            },
        }
    }

    /// The return-value uniformity of an expression *relative to the current
    /// function's parameters* — the per-`return` contribution to `ret`. Like
    /// `valueUniformity`, but a parameter read yields `depends_on_args` (deferred
    /// to the call site) instead of resolving through the (unseeded) `values`
    /// map. A non-parameter local is not traced back to its parameter
    /// provenance: it resolves through `identUniformity` and defaults uniform (a
    /// documented false-negative, §2.1).
    fn evalReturnValue(ua: *UniformityAnalyzer, expr: Ast.Expr) Allocator.Error!RetUniformity {
        switch (expr) {
            .literal => return .uniform,
            .ident => |e| {
                if (ua.paramBit(e.ref)) |bit| return .{ .depends_on_args = bit };
                const t = try ua.identUniformity(e);
                return if (t == .non_uniform) .{ .non_uniform = t.non_uniform } else .uniform;
            },
            .call => |e| {
                const callee = calleeName(e);
                if (std.mem.eql(u8, callee, "workgroupUniformLoad")) return .uniform;
                if (Builtins.lookup(callee) == null) {
                    // Compose with the callee's summary: our return depends on
                    // whatever we pass into its arg-dependent slots.
                    if (ua.calleeSummary(e)) |summary| switch (summary.ret) {
                        .uniform => return .uniform,
                        .non_uniform => |src| return .{ .non_uniform = src },
                        .depends_on_args => |bits| {
                            var acc: RetUniformity = .uniform;
                            for (e.args.items, 0..) |arg, i| {
                                if (i >= 64) break;
                                if ((bits >> @intCast(i)) & 1 == 0) continue;
                                acc = combine(acc, try ua.evalReturnValue(arg));
                            }
                            return acc;
                        },
                    };
                    return .uniform;
                }
                // Builtin result: uniform iff all arguments are — fold their
                // parameter provenance through.
                var acc: RetUniformity = .uniform;
                for (e.args.items) |arg| acc = combine(acc, try ua.evalReturnValue(arg));
                return acc;
            },
            .binary => |e| return combine(try ua.evalReturnValue(e.left), try ua.evalReturnValue(e.right)),
            .unary => |e| return ua.evalReturnValue(e.operand),
            .index => |e| return combine(try ua.evalReturnValue(e.base), try ua.evalReturnValue(e.idx)),
            .member => |e| return ua.evalReturnValue(e.base),
            .paren => |e| return ua.evalReturnValue(e.expr),
        }
    }

    /// The single-bit `ArgBitset` for a symbol that is a parameter of the current
    /// function, or null if it is not a parameter (or its position exceeds the
    /// 64-bit tracking width, beyond which `ret` falls back to uniform, §2.1).
    fn paramBit(ua: *UniformityAnalyzer, ref: Ast.SymbolIndex) ?ArgBitset {
        if (ref == .none) return null;
        for (ua.current_params, 0..) |param, i| {
            if (param.name == ref) return if (i < 64) (@as(ArgBitset, 1) << @intCast(i)) else null;
        }
        return null;
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
                const name = calleeName(e);
                if (Builtins.lookup(name)) |builtin| {
                    if (builtin.requiresUniform()) {
                        const loc = calleeLoc(e);
                        try ua.reachRequirement(.{ .kind = builtin.kind, .name = name, .loc = loc }, loc, cf);
                    }
                } else if (ua.calleeSummary(e)) |summary| {
                    // A user call inherits its callee's uniform-flow requirement
                    // (Block U3): reported at *this* call site, chained back to
                    // the callee-side builtin.
                    if (summary.call_site_requirement) |req|
                        try ua.reachRequirement(req, calleeLoc(e), cf);
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

    /// A uniform-flow requirement (a barrier / derivative / texture / subgroup
    /// builtin, or a callee that transitively reaches one) is reached at
    /// `site_loc`. Under non-uniform control flow this is a violation reported
    /// here; under uniform control flow it becomes *this* function's own
    /// `call_site_requirement`, so a caller invoking it from non-uniform flow
    /// inherits it (bottom-up). `root` carries the originating builtin.
    fn reachRequirement(ua: *UniformityAnalyzer, root: Requirement, site_loc: u32, cf: Taint) Allocator.Error!void {
        if (cf.isNonUniform()) {
            // Chain the related-info back to the root builtin — unless the root
            // *is* this site (a direct builtin call needs no extra hop).
            const chain: ?Requirement = if (root.loc == site_loc) null else root;
            try ua.report(site_loc, root.kind, cf, chain);
        } else if (ua.cur_requirement == null) {
            ua.cur_requirement = root;
        }
    }

    fn report(ua: *UniformityAnalyzer, loc: u32, kind: Builtins.Kind, cf: Taint, chain: ?Requirement) Allocator.Error!void {
        if (!ua.reporting) return;

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

        // Check if this rule is filtered. `.synchronization` (barriers) has an
        // empty `rule` and is never filterable — a hard error per spec. The
        // filter is the current function's effective one (base ⊕ its
        // `@diagnostic` attributes).
        if (rule.len > 0 and ua.cur_fn_filter != null) {
            if (ua.cur_fn_filter.?.isDisabled(rule)) return;
        }

        var severity = Diagnostic.Severity.@"error";
        if (rule.len > 0 and ua.cur_fn_filter != null) {
            severity = ua.cur_fn_filter.?.getSeverity(rule, .@"error");
        }

        const message = switch (kind) {
            .derivative => "derivative function must only be called from uniform control flow",
            .synchronization => "barrier function must only be called from uniform control flow",
            .texture => "texture sampling with implicit LOD must only be called from uniform control flow",
            .subgroup => "subgroup operation requires uniform control flow",
            else => "function requires uniform control flow",
        };

        // Attach the taint chain: (a) the source that made control flow
        // non-uniform, and (b) — for a cross-function violation — the
        // callee-side builtin the call chain reaches. Additive `related` on CLI
        // JSON + LSP (the `Diagnostic` wire shape already serializes `related`).
        var infos: std.ArrayList(Diagnostic.RelatedInfo) = .empty;
        if (cf == .non_uniform) {
            const src = cf.non_uniform;
            try infos.append(ua.arena, .{ .range = ua.diags.makeRange(src.loc, src.loc + 1), .message = src.desc });
        }
        if (chain) |root| {
            const msg = try std.fmt.allocPrint(ua.arena, "non-uniform control flow reaches '{s}' here", .{root.name});
            try infos.append(ua.arena, .{ .range = ua.diags.makeRange(root.loc, root.loc + 1), .message = msg });
        }
        const related: []const Diagnostic.RelatedInfo = infos.items;

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

    /// The byte offset of the callee at a call site — the reporting anchor for a
    /// requirement (the builtin's own loc for a direct call, the call
    /// expression's loc for a user function).
    fn calleeLoc(e: *Ast.CallExpr) u32 {
        if (e.func) |func| switch (func) {
            .ident => |ident| return ident.loc,
            else => {},
        };
        return e.loc;
    }

    /// The symbol the callee ident resolves to (`.none` for an unresolved or
    /// non-ident callee), used to look up a user function's summary.
    fn calleeRef(e: *Ast.CallExpr) Ast.SymbolIndex {
        if (e.func) |func| switch (func) {
            .ident => |ident| return ident.ref,
            else => {},
        };
        return .none;
    }

    /// The already-computed summary of the user function a call resolves to, or
    /// null if the callee is unresolved / has no summary (pass 1 computes one for
    /// every named function, so a null here means an unresolved call).
    fn calleeSummary(ua: *UniformityAnalyzer, e: *Ast.CallExpr) ?FnSummary {
        const ref = calleeRef(e);
        if (ref == .none) return null;
        return ua.summaries.get(ref.index());
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
