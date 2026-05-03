//! Lint rule definition.
//!
//! Each rule is a Zig struct with compile-time `Meta` (id, code, default
//! severity, category, fixable flag) and a `run` function that walks whatever
//! slice of the AST / symbol table it needs and reports diagnostics through
//! the shared `Context`. Rules live under `src/lint/rules/` and are
//! registered in `src/lint/registry.zig` as a comptime array.
//!
//! See `src/lint/Linter.zig` for the orchestrator and `src/lint/Context.zig`
//! for the per-invocation state passed to each rule.
//!
//! Invariants (apply to every rule under `src/lint/rules/`):
//!   - `meta.id` is unique across the registry; `Linter.run` indexes rules
//!     by id when applying user severity overrides.
//!   - `run` is read-only against `ctx.module`; rules MUST NOT mutate the
//!     AST, the symbol table, or any other shared state. Side effects are
//!     limited to `ctx.report` (and, for fixable rules, `Entry.fix`).
//!   - `meta.fixable = true` implies `run` always attaches an `Entry.fix`
//!     when it reports a diagnostic; `Fixer.applyFixes` requires this.
//!   - `meta.requires_dce = true` implies the rule reads `Symbol.is_live`;
//!     the Linter runs `Dce.mark` before invoking such rules.
//!   - Individual rule files do NOT repeat the above; their `//!` headers
//!     describe what they detect and (for configurable rules) the option
//!     schema. Rules with no further invariants beyond the shared contract
//!     above are intentionally silent on invariants in their headers.

const Diagnostic = @import("../Diagnostic.zig");
const Context = @import("Context.zig");
const MultiVisitor = @import("MultiVisitor.zig");

const Rule = @This();

meta: Meta,
/// Per-rule entry point. Called once with the rule's `Context`. Use for
/// symbol-table walks and post-walk reporting. Optional: rules that
/// only need per-AST-node visits can set `listener` and leave `run` null.
/// At least one of `run` or `listener` must be set, asserted at Linter
/// startup.
run: ?*const fn (ctx: *Context) error{OutOfMemory}!void = null,
/// Optional listener factory. When set, the Linter folds this rule's
/// listener into a single shared `MultiVisitor.walk` over the module so
/// the AST is traversed once for all subscribed rules instead of N
/// times. The factory is called with the rule's `Context`; the returned
/// listener typically uses `ctx` as its `*anyopaque` ctx so callbacks
/// can `@ptrCast(@alignCast(...))` back to `*Context`. Rules that need
/// per-instance scratch state (e.g. a hashmap to dedupe events) allocate
/// it on `ctx.arena` here and propagate `error.OutOfMemory`.
///
/// Both `run` and `listener` may be set. The shared walk fires first;
/// `run` then runs after the walk has completed (useful for rules that
/// collect state in the listener and report based on the tally).
listener: ?*const fn (ctx: *Context) error{OutOfMemory}!MultiVisitor.Listener = null,

pub const Category = enum {
    /// Likely-incorrect code (unused declarations, unreachable functions).
    correctness,
    /// Code that compiles but is stylistically surprising or error-prone.
    suspicious,
    /// Purely cosmetic / convention.
    style,
    /// Patterns that waste GPU cycles, memory, or bandwidth.
    performance,
    /// WGSL variants / extensions that limit portability across backends.
    portability,
};

pub const Meta = struct {
    /// Public rule identifier (`"no-unused-vars"`, `"prefer-mix"`, …). Used
    /// in config (`"rules": { "no-unused-vars": "warn" }`) and disable
    /// comments.
    id: []const u8,
    /// Stable diagnostic code (`"W0001"`). Written into every `Entry`
    /// produced by the rule. Can be overridden by the rule's `report` call
    /// if it emits multiple codes, but the default comes from here.
    code: []const u8,
    /// Severity the rule uses when no config overrides it. `recommended`
    /// configs typically set `warning`; `performance`/`portability` packs
    /// may elevate to `@"error"`.
    default_severity: Diagnostic.Severity = .warning,
    /// Short human description for `--help` / LSP code action titles.
    description: []const u8,
    /// URL pointing at the rule's documentation page. Rendered as
    /// `codeDescription.href` on LSP diagnostics.
    docs_url: []const u8 = "",
    /// True when the rule may attach an `Entry.fix`. Consumed by `Fixer`
    /// and surfaced as a quickfix LSP code action.
    fixable: bool = false,
    /// Category for grouping in rule packs and `--format stylish` output.
    category: Category = .suspicious,
    /// When true, the rule only makes sense if `Dce.mark` has run so the
    /// `Symbol.is_live` flag is populated. `Linter.run` enforces DCE as a
    /// prerequisite for these rules.
    requires_dce: bool = false,
};
