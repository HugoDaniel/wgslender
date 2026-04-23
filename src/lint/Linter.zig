//! Lint orchestrator.
//!
//! Runs every registered rule against an analyzed WGSL module, resolves
//! per-rule severity from a config chain (`extends` + `rules`), skips
//! rules the user disabled, and collects diagnostics into a standard
//! `Diagnostic` list.
//!
//! Architecture: each rule implements its own traversal via `AstVisit` or
//! a symbol-table walk (see `Rule.zig`). The Linter simply iterates over
//! the rule registry and calls `.run(ctx)` on each enabled rule. This
//! keeps the rule API trivial and the Linter a thin coordinator. WGSL
//! shaders are small (<50KB typical); the n-rules × one-traversal-each
//! cost is negligible.
//!
//! The `Context` shape is designed so a future single-traversal
//! multiplexed-visitor implementation can slot in without changing rule
//! code — only the Linter internals change.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("../Ast.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Validator = @import("../Validator.zig");
const Dce = @import("../Dce.zig");

pub const Rule = @import("Rule.zig");
pub const Context = @import("Context.zig");
pub const Configs = @import("configs.zig");
pub const Disable = @import("Disable.zig");
pub const Fixer = @import("Fixer.zig");
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

    var fixable: u32 = 0;
    for (&registry.all) |*r| {
        const setting = settings.get(r.meta.id) orelse continue;
        if (setting.severity == .disabled) continue;

        if (r.meta.requires_dce and !dce_done) {
            if (analysis_arena_opt) |aa| {
                _ = Dce.mark(aa, module) catch {};
            }
            dce_done = true;
        }

        const before = diags.diagnostics.items.len;

        var ctx = Context{
            .arena = alloc,
            .analysis = analysis,
            .module = module,
            .source = module.source,
            .diagnostics = diags,
            .current_rule = &r.meta,
            .effective_severity = setting.severity,
            .options = setting.options,
            .line_offset = options.line_offset,
        };
        try r.run(&ctx);

        if (r.meta.fixable) {
            for (diags.diagnostics.items[before..]) |d| {
                if (d.fix != null) fixable += 1;
            }
        }
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
        var tmp: std.ArrayListUnmanaged(Diagnostic.Entry) = .empty;
        try Disable.reportUnused(alloc, module.source, &directives, &tmp);
        for (tmp.items) |e| diags.add(alloc, e);
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
        .rules = &.{ .{ .id = "no-unused-vars", .severity = .warning } },
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.diagnostics.items().len >= 1);
    for (result.diagnostics.items()) |d| {
        try std.testing.expectEqualStrings("wgslender-lint", d.source);
        try std.testing.expectEqualStrings("W0001", d.code);
    }
}
