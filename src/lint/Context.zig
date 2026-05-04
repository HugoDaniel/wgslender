//! Per-invocation state passed to every lint rule.
//!
//! Context wraps:
//!   * The analyzed module (AST, symbols, resolved types, struct layouts).
//!   * The source buffer (so rules can read text ranges directly).
//!   * The shared arena and diagnostic collection the Linter is building.
//!   * The currently-running rule's `Meta` so `report()` can auto-stamp the
//!     code, source, and severity without every rule having to repeat them.
//!   * The resolved `Linter.Config` so rules can honor per-rule options and
//!     query severity overrides.
//!
//! The shape is deliberately chosen so that a future multiplexed-visitor
//! implementation (where one traversal fans out to many rule listeners) can
//! reuse this type unchanged — only `current_rule` would rotate between
//! listeners.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("../Ast.zig");
const Types = @import("../Types.zig");
const Diagnostic = @import("../Diagnostic.zig");
const Validator = @import("../Validator.zig");
const MinifyEstimator = @import("../MinifyEstimator.zig");
const Rule = @import("Rule.zig");

const Context = @This();

arena: Allocator,
analysis: *const Validator.AnalysisResult,
module: *const Ast.Module,
source: []const u8,
/// Diagnostic list the Linter is building up. Rules call `report()` to
/// append to this. Severity on each reported entry is overwritten with the
/// config-resolved severity before insertion.
diagnostics: *Diagnostic,
/// Metadata for the currently-running rule. `report()` uses this to fill
/// missing `code` / `source` / severity fields on emitted entries so each
/// rule doesn't have to repeat them.
current_rule: *const Rule.Meta,
/// Severity this rule was resolved to by the config merger. `.disabled`
/// means the rule should not run (the Linter filters ahead of calling).
effective_severity: Diagnostic.Severity,
/// Rule-specific options, if the user passed any (`["warn", { ... }]`).
/// Null when the rule has no options or the user wrote `"warn"` / `"error"`
/// as a bare string.
options: ?std.json.Value = null,
/// Line-number offset applied to every reported entry. Mirrors
/// `Validator.Options.line_offset`.
line_offset: i32 = 0,
/// Optional pre-computed minify-size estimate the caller produced before
/// running the linter. M-rules read this first and only fall back to a
/// fresh `MinifyEstimator.estimate` call when it's null. Threaded from
/// `Linter.Options.cached_minify_estimate`. The pointer lives in the
/// caller's arena and is read-only here.
cached_minify_estimate: ?*const MinifyEstimator.EstimateResult = null,

/// Append a diagnostic produced by the current rule. Missing fields are
/// filled from the rule's `Meta`: `code`, `source`, and `severity` default
/// to the rule's code, `"wgslender-lint"`, and the config-resolved
/// severity respectively. Callers typically only set `.message` and
/// `.range` (plus `.fix` / `.related` when relevant).
pub fn report(self: *Context, entry: Diagnostic.Entry) void {
    var e = entry;
    if (e.code.len == 0) e.code = self.current_rule.code;
    if (e.source.len == 0) e.source = "wgslender-lint";
    // Always respect the resolved severity — rule authors pick the message,
    // config picks whether it's a warning or an error.
    e.severity = self.effective_severity;
    self.diagnostics.add(self.arena, e);
}

/// Convert a byte range to a 1-based line/column Range. Thin wrapper so
/// rules never have to reach into `diagnostics` for position helpers.
pub fn makeRange(self: *const Context, start: u32, end: u32) Diagnostic.Range {
    return self.diagnostics.makeRange(start, end);
}

/// Return the source slice for `[start, end)`. Safe against out-of-range
/// offsets (returns empty slice).
pub fn sourceSlice(self: *const Context, start: u32, end: u32) []const u8 {
    if (start > end or end > self.source.len) return "";
    return self.source[start..end];
}

/// Format a message on the shared arena. Rules use this for
/// interpolated messages — the string lives as long as the diagnostic
/// collection.
pub fn fmt(self: *Context, comptime f: []const u8, args: anytype) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(self.arena, f, args);
}

/// Return the symbol's reference count as known by the side-table,
/// falling back to the `Symbol.use_count` field when no side-table is
/// attached. B.M4: lint rules call this instead of reading the field
/// directly, so B.M5's field deletion is a one-side rewrite. In debug
/// builds, side-table and field must agree.
pub fn useCount(self: *const Context, sym_idx: u32) u32 {
    const symbols = self.module.symbols.items;
    if (sym_idx >= symbols.len) return 0;
    if (self.analysis.use_counts) |uc| {
        if (std.debug.runtime_safety) {
            std.debug.assert(uc.counts[sym_idx] == symbols[sym_idx].use_count);
        }
        return uc.counts[sym_idx];
    }
    return symbols[sym_idx].use_count;
}

/// Return the symbol's liveness as known by the side-table, falling
/// back to the `Symbol.flags.is_live` field when no side-table is
/// attached (typically because the rule didn't declare `requires_dce`,
/// so DCE never ran for this analysis). B.M4: lint rules call this
/// instead of reading the field directly. In debug builds, side-table
/// and field must agree when both are present.
pub fn isLive(self: *const Context, sym_idx: u32) bool {
    const symbols = self.module.symbols.items;
    if (sym_idx >= symbols.len) return false;
    if (self.analysis.liveness) |liv| {
        const side = liv.isLive(sym_idx);
        if (std.debug.runtime_safety) {
            std.debug.assert(side == symbols[sym_idx].flags.is_live);
        }
        return side;
    }
    return symbols[sym_idx].flags.is_live;
}

/// Mirror of `Ast.Symbol.isUnusedReportable` that consults the
/// side-table for `use_count` instead of the field. The remaining
/// predicate fields are parser-set immutables. B.M4: callers go
/// through this so the field-side method can be deleted in B.M5
/// without a sweep.
pub fn isUnusedReportable(self: *const Context, sym_idx: u32) bool {
    const symbols = self.module.symbols.items;
    if (sym_idx >= symbols.len) return false;
    const sym = symbols[sym_idx];
    if (self.useCount(sym_idx) > 0) return false;
    if (sym.original_name.len == 0) return false;
    if (sym.flags.is_entry_point) return false;
    if (sym.flags.is_api_facing) return false;
    if (sym.flags.is_external_binding) return false;
    return switch (sym.kind) {
        .function, .@"const", .let, .@"var", .override => true,
        else => false,
    };
}
