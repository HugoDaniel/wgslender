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
