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

const Diagnostic = @import("../Diagnostic.zig");
const Context = @import("Context.zig");

const Rule = @This();

meta: Meta,
run: *const fn (ctx: *Context) error{OutOfMemory}!void,

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
