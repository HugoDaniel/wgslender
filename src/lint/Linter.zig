//! Lint orchestrator.
//!
//! Runs every registered rule against an analyzed WGSL module, resolves
//! per-rule severity from a config chain (`extends` + `rules`), skips
//! rules the user disabled, and collects diagnostics into a standard
//! `Diagnostic` list.
//!
//! Architecture: rules expose either a `listener` (a per-AST-node visitor
//! folded into one shared `MultiVisitor.walk`) or a `run` callback (a
//! free-form post-walk pass for symbol-table scans and tally-based
//! reporting), or both. Run order per call:
//!   1. Build a `Context` per enabled rule and collect every rule's
//!      listener into a single slice.
//!   2. `MultiVisitor.walk` drives one document-order traversal that
//!      dispatches each node to every subscribed listener — so N
//!      listener-bearing rules pay one traversal cost, not N.
//!   3. Per-rule `run` callbacks fire afterwards (hybrid rules see state
//!      collected during the shared walk before reporting).
//!
//! See `Rule.zig` for the per-rule contract; see `MultiVisitor.zig` for
//! the visitor signature and traversal shape.
//!
//! Invariants:
//!   - The rule registry (`registry.all`) is non-empty. Asserted at the
//!     entry of `run` so a comptime gate that excludes every rule fails
//!     loudly instead of producing silent empty reports.
//!   - DCE runs at most once per call (lazily, only if some enabled rule
//!     declares `requires_dce`). Once run, every subsequent rule reuses
//!     the cached `Symbol.is_live` flags.
//!   - `wgslender-disable` directives never silence validator diagnostics
//!     (non-lint codes); they only filter entries whose `code` resolves
//!     to a registered rule id.
//!   - `Result.diagnostics` carries lint output only. Validator diagnostics
//!     stay on `analysis.diagnostics`, which the caller already owns.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("../Ast.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Validator = @import("../Validator.zig");
const Dce = @import("../Dce.zig");
const Liveness = @import("../Liveness.zig");
const MinifyEstimator = @import("../MinifyEstimator.zig");

pub const Rule = @import("Rule.zig");
pub const Context = @import("Context.zig");
pub const Configs = @import("configs.zig");
pub const Disable = @import("Disable.zig");
pub const Fixer = @import("Fixer.zig");
pub const MultiVisitor = @import("MultiVisitor.zig");
pub const registry = @import("registry.zig");

const Severity = Diagnostic.Severity;

/// Per-rule config entry. A bare `"warn"` in JSON lowers to
/// `{ severity: .warning, options: null }`; the array form
/// `["error", { ... }]` lowers to `{ severity: .@"error", options: {...} }`.
pub const RuleSetting = struct {
    severity: Severity,
    options: ?std.json.Value = null,
};

/// Linter invocation options. Resolved from CLI flags + a `wgslender.json`
/// config file (or inline JSON in the WASM / NPM surfaces).
pub const Options = struct {
    /// Names of built-in configs to inherit rules from
    /// (e.g. `@wgslender/recommended`). Unknown names are ignored silently
    /// so a typo in a shared config doesn't blow up the whole lint.
    extends: []const []const u8 = &.{},
    /// User-provided per-rule settings. Takes precedence over every
    /// extended config. Keys are public rule ids (e.g. `"no-unused-vars"`).
    rules: []const RuleOverride = &.{},
    /// Line-number offset applied to every diagnostic. Mirrors
    /// `Validator.Options.line_offset` for snippet linting.
    line_offset: i32 = 0,
    /// Global kill-switch. When true, the Linter produces no diagnostics.
    disabled: bool = false,
    /// When true, emit a W0209 warning for every wgslender-disable
    /// directive that didn't match any diagnostic. Off by default because
    /// dangling directives after a bug-fix are normal; CI lints flip it on.
    report_unused_disable_directives: bool = false,
    /// Optional pre-computed `MinifyEstimator` result the caller has
    /// already produced for this module/version. When set, rules that
    /// would otherwise run the estimator (M0500, future M-rules) reuse
    /// this pointer — letting the LSP coalesce inlay-hint, code-lens and
    /// lint-rule estimator work into a single per-document run.
    ///
    /// The pointer must remain valid for the entire `Linter.run` call;
    /// the Linter does not take ownership and never frees it. Null in
    /// the CLI lint path keeps existing semantics (rule estimates fresh).
    cached_minify_estimate: ?*const MinifyEstimator.EstimateResult = null,

    pub const RuleOverride = struct {
        id: []const u8,
        severity: Severity,
        options: ?std.json.Value = null,
    };
};

/// Linter result. Owns its diagnostics; caller must `deinit` to release
/// memory.
pub const Result = struct {
    diagnostics: *Diagnostic,
    error_count: u32 = 0,
    warning_count: u32 = 0,
    fixable_count: u32 = 0,
    _arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Result, gpa: Allocator) void {
        if (self._arena) |*a| {
            a.deinit();
            self._arena = null;
        }
        _ = gpa;
    }
};

/// Resolve per-rule settings by merging `extends` configs left-to-right,
/// then overlaying user `rules`. Rules not mentioned anywhere default to
/// `.disabled` (linter opt-in per rule — a blank config produces zero lint
/// warnings, matching ESLint's "no plugins = no rules" baseline).
fn resolveSettings(
    arena: Allocator,
    options: Options,
) Allocator.Error!std.StringHashMapUnmanaged(RuleSetting) {
    var settings: std.StringHashMapUnmanaged(RuleSetting) = .empty;

    for (options.extends) |name| {
        const cfg = Configs.byName(name) orelse continue;
        for (cfg.rules) |entry| {
            try settings.put(arena, entry.id, .{ .severity = entry.severity });
        }
    }

    for (options.rules) |override| {
        try settings.put(arena, override.id, .{
            .severity = override.severity,
            .options = override.options,
        });
    }

    return settings;
}

/// Run all enabled rules against an already-analyzed module.
///
/// The caller owns `analysis`; the Linter only reads from it. DCE is run
/// on demand if any enabled rule declares `requires_dce` and the
/// analysis hasn't been DCE-marked yet.
pub fn run(
    gpa: Allocator,
    analysis: *Validator.AnalysisResult,
    options: Options,
) !Result {
    // Pre: at least one rule must be present in the registry, otherwise
    // the loop body never runs and the lint report is silently empty.
    // This catches a build that accidentally compiles registry.all to a
    // zero-length array (e.g. a comptime gate excluded every rule).
    std.debug.assert(registry.all.len > 0);

    // Pre: every rule must define at least one of `run` or `listener`,
    // otherwise it's a no-op that quietly passes config gates without
    // ever firing.
    comptime {
        for (registry.all) |r| {
            if (r.run == null and r.listener == null) {
                @compileError("Rule '" ++ r.meta.id ++ "' has neither run nor listener");
            }
        }
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const module = analysis.module orelse {
        // Parse / analysis failed before a module was produced. Return an
        // empty lint result — the caller's validator diagnostics already
        // describe why.
        const diags = try alloc.create(Diagnostic);
        diags.* = try Diagnostic.init(alloc, "");
        diags.line_offset = options.line_offset;
        return .{
            .diagnostics = diags,
            ._arena = arena,
        };
    };

    const diags = try alloc.create(Diagnostic);
    diags.* = try Diagnostic.init(alloc, module.source);
    diags.line_offset = options.line_offset;

    if (options.disabled) {
        return .{ .diagnostics = diags, ._arena = arena };
    }

    var settings = try resolveSettings(alloc, options);

    // DCE is lazily run if any enabled rule needs it. Running DCE mutates
    // `Symbol.is_live` on the analysis's module, which is fine because the
    // caller already owns the analysis and expects no further changes
    // beyond advisory flagging.
    var dce_done = false;
    const analysis_arena_opt: ?Allocator = if (analysis._arena) |*a| a.allocator() else null;

    // Phase 1: build per-enabled-rule contexts and collect listeners. Rules
    // with a non-null `listener` are folded into one shared `MultiVisitor.walk`
    // so the AST is traversed once for all of them instead of N times.
    var contexts: std.ArrayListUnmanaged(*Context) = .empty;
    var rule_indices: std.ArrayListUnmanaged(usize) = .empty;
    var listeners: std.ArrayListUnmanaged(MultiVisitor.Listener) = .empty;
    try contexts.ensureTotalCapacity(alloc, registry.all.len);
    try rule_indices.ensureTotalCapacity(alloc, registry.all.len);

    for (&registry.all, 0..) |*r, idx| {
        const setting = settings.get(r.meta.id) orelse continue;
        if (setting.severity == .disabled) continue;

        if (r.meta.requires_dce and !dce_done) {
            if (analysis_arena_opt) |aa| {
                // B.M3: side-table allocated alongside the field write.
                // It's discarded today; B.M4 will stash it on
                // `AnalysisResult.liveness` so DCE-aware rules can read
                // it instead of `Symbol.flags.is_live`. OOM here is
                // swallowed to match the original `Dce.mark catch {}`
                // semantics — rules tolerate stale liveness rather
                // than abort the whole lint.
                if (Liveness.init(aa, module.symbols.items.len)) |liveness_init| {
                    var liveness = liveness_init;
                    _ = Dce.mark(aa, module, &liveness) catch {};
                } else |_| {}
            }
            dce_done = true;
        }

        const ctx = try alloc.create(Context);
        ctx.* = .{
            .arena = alloc,
            .analysis = analysis,
            .module = module,
            .source = module.source,
            .diagnostics = diags,
            .current_rule = &r.meta,
            .effective_severity = setting.severity,
            .options = setting.options,
            .line_offset = options.line_offset,
            .cached_minify_estimate = options.cached_minify_estimate,
        };
        contexts.appendAssumeCapacity(ctx);
        rule_indices.appendAssumeCapacity(idx);

        if (r.listener) |make| try listeners.append(alloc, try make(ctx));
    }

    // Phase 2: one combined walk for every subscribed rule. Listeners fire
    // in subscription order at each node, so per-rule diagnostic ordering
    // mirrors registry order within each visited node.
    if (listeners.items.len > 0) {
        try MultiVisitor.walk(alloc, module, listeners.items);
    }

    // Phase 3: per-rule `run` callbacks for rules that opted in. Runs after
    // the shared walk so a hybrid rule (both `listener` and `run`) sees
    // state collected by its listener before reporting.
    for (contexts.items, rule_indices.items) |ctx, idx| {
        const r = &registry.all[idx];
        if (r.run) |run_fn| try run_fn(ctx);
    }

    // Count fixes once at the end. `meta.fixable` is documentation; the
    // truth is whether an entry actually carries a `fix`. Listener-driven
    // rules interleave during the shared walk, so per-rule index ranges
    // wouldn't isolate them anyway.
    var fixable: u32 = 0;
    for (diags.diagnostics.items) |d| {
        if (d.fix != null) fixable += 1;
    }

    // Parse wgslender-disable directives and filter the diagnostics list.
    // Validator diagnostics (non-lint codes) are never silenced — only
    // entries whose code resolves to a registered rule id.
    var directives = try Disable.parse(alloc, module.source);
    const filtered = try Disable.filter(alloc, diags.diagnostics.items, &directives, codeToRuleId);

    // Replace the diag list's items with the filtered slice. We're in a
    // fresh arena so dropping the old backing memory is a no-op.
    diags.diagnostics = .empty;
    try diags.diagnostics.appendSlice(alloc, filtered);
    diags.has_errors = false;
    for (diags.diagnostics.items) |d| {
        if (d.severity == .@"error") {
            diags.has_errors = true;
            break;
        }
    }

    if (options.report_unused_disable_directives) {
        var scratch: std.ArrayListUnmanaged(Diagnostic.Entry) = .empty;
        try Disable.reportUnused(alloc, module.source, &directives, &scratch);
        for (scratch.items) |e| diags.add(alloc, e);
    }

    return .{
        .diagnostics = diags,
        .error_count = diags.errorCount(),
        .warning_count = diags.warningCount(),
        .fixable_count = fixable,
        ._arena = arena,
    };
}

/// Map a diagnostic code (`"W0001"`) back to its public rule id
/// (`"no-unused-vars"`). Returns null for non-lint codes (validator
/// errors / warnings) so the Disable filter passes them through
/// untouched.
fn codeToRuleId(code: []const u8) ?[]const u8 {
    const r = registry.byCode(code) orelse return null;
    return r.meta.id;
}

// =========================================================================
// Tests
// =========================================================================

test "Linter: empty options produces no diagnostics" {
    const root = @import("../root.zig");
    const src: [:0]const u8 = "fn unused_fn() {}";
    var analysis = try root.analyzeWithOptions(std.testing.allocator, src, .{});
    defer analysis.deinit(std.testing.allocator);

    var result = try run(std.testing.allocator, &analysis, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), result.warning_count);
    try std.testing.expectEqual(@as(u32, 0), result.error_count);
}

test "Linter: extends @wgslender/recommended catches unused" {
    const root = @import("../root.zig");
    const src: [:0]const u8 = "fn unused_fn() {}";
    var analysis = try root.analyzeWithOptions(std.testing.allocator, src, .{});
    defer analysis.deinit(std.testing.allocator);

    var result = try run(std.testing.allocator, &analysis, .{
        .extends = &.{"@wgslender/recommended"},
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.warning_count >= 1);
}

test "Linter: rule override to error elevates severity" {
    const root = @import("../root.zig");
    const src: [:0]const u8 = "fn unused_fn() {}";
    var analysis = try root.analyzeWithOptions(std.testing.allocator, src, .{});
    defer analysis.deinit(std.testing.allocator);

    var result = try run(std.testing.allocator, &analysis, .{
        .rules = &.{
            .{ .id = "no-unused-vars", .severity = .@"error" },
        },
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.error_count >= 1);
    try std.testing.expectEqual(@as(u32, 0), result.warning_count);
}

test "Linter: rule override to disabled silences extended pack" {
    const root = @import("../root.zig");
    const src: [:0]const u8 = "fn unused_fn() {}";
    var analysis = try root.analyzeWithOptions(std.testing.allocator, src, .{});
    defer analysis.deinit(std.testing.allocator);

    var result = try run(std.testing.allocator, &analysis, .{
        .extends = &.{"@wgslender/recommended"},
        .rules = &.{
            .{ .id = "no-unused-vars", .severity = .disabled },
        },
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), result.warning_count);
    try std.testing.expectEqual(@as(u32, 0), result.error_count);
}

test "Linter: disabled flag suppresses all diagnostics" {
    const root = @import("../root.zig");
    const src: [:0]const u8 = "fn unused_fn() {}";
    var analysis = try root.analyzeWithOptions(std.testing.allocator, src, .{});
    defer analysis.deinit(std.testing.allocator);

    var result = try run(std.testing.allocator, &analysis, .{
        .extends = &.{"@wgslender/recommended"},
        .disabled = true,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), result.warning_count);
}

test "Linter: unknown extends name is ignored" {
    const root = @import("../root.zig");
    const src: [:0]const u8 = "fn unused_fn() {}";
    var analysis = try root.analyzeWithOptions(std.testing.allocator, src, .{});
    defer analysis.deinit(std.testing.allocator);

    var result = try run(std.testing.allocator, &analysis, .{
        .extends = &.{ "@wgslender/nope", "@wgslender/recommended" },
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.warning_count >= 1);
}

test "Linter: unknown rule id in rules is ignored" {
    const root = @import("../root.zig");
    const src: [:0]const u8 = "fn unused_fn() {}";
    var analysis = try root.analyzeWithOptions(std.testing.allocator, src, .{});
    defer analysis.deinit(std.testing.allocator);

    var result = try run(std.testing.allocator, &analysis, .{
        .rules = &.{
            .{ .id = "does-not-exist", .severity = .@"error" },
            .{ .id = "no-unused-vars", .severity = .warning },
        },
    });
    defer result.deinit(std.testing.allocator);
    // unknown rule is silently skipped; no-unused-vars still fires
    try std.testing.expect(result.warning_count >= 1);
}

test "Linter: Diagnostic.source stamped on every entry" {
    const root = @import("../root.zig");
    const src: [:0]const u8 = "fn unused_fn() {}";
    var analysis = try root.analyzeWithOptions(std.testing.allocator, src, .{});
    defer analysis.deinit(std.testing.allocator);

    var result = try run(std.testing.allocator, &analysis, .{
        .rules = &.{.{ .id = "no-unused-vars", .severity = .warning }},
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.diagnostics.items().len >= 1);
    for (result.diagnostics.items()) |d| {
        try std.testing.expectEqualStrings("wgslender-lint", d.source);
        try std.testing.expectEqualStrings("W0001", d.code);
    }
}

test "Linter: listener-driven rule fires via shared MultiVisitor walk" {
    const root = @import("../root.zig");
    // Two redundant casts on the same line — both must be reported by
    // the listener-driven `no-redundant-casts` rule.
    const src: [:0]const u8 = "fn f(x: f32, y: f32) -> f32 { return f32(x) + f32(y); }";
    var analysis = try root.analyzeWithOptions(std.testing.allocator, src, .{});
    defer analysis.deinit(std.testing.allocator);

    var result = try run(std.testing.allocator, &analysis, .{
        .rules = &.{.{ .id = "no-redundant-casts", .severity = .warning }},
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2), result.warning_count);
    try std.testing.expectEqual(@as(u32, 2), result.fixable_count);
    for (result.diagnostics.items()) |d| {
        try std.testing.expectEqualStrings("W0201", d.code);
    }
}

test "Linter: two listener-driven rules share one walk and both fire" {
    const root = @import("../root.zig");
    // A single source that triggers BOTH no-redundant-casts (W0201) and
    // prefer-mix (W0203). The Linter must collect both listeners,
    // dispatch them in the same walk, and report both diagnostics.
    const src: [:0]const u8 =
        "fn f(a: f32, b: f32, t: f32) -> f32 { return f32(a + (b - a) * t); }";
    var analysis = try root.analyzeWithOptions(std.testing.allocator, src, .{});
    defer analysis.deinit(std.testing.allocator);

    var result = try run(std.testing.allocator, &analysis, .{
        .rules = &.{
            .{ .id = "no-redundant-casts", .severity = .warning },
            .{ .id = "prefer-mix", .severity = .warning },
        },
    });
    defer result.deinit(std.testing.allocator);

    var saw_redundant = false;
    var saw_mix = false;
    for (result.diagnostics.items()) |d| {
        if (std.mem.eql(u8, d.code, "W0201")) saw_redundant = true;
        if (std.mem.eql(u8, d.code, "W0203")) saw_mix = true;
    }
    try std.testing.expect(saw_redundant);
    try std.testing.expect(saw_mix);
}
