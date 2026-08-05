//! Comptime spec table for wgslender configuration options.
//!
//! Each `OptionSpec` is a single source of truth for one option's three
//! names — Zig snake_case field, camelCase JSON key, kebab-case CLI flag.
//! The spec drives JSON parsing (`applyJson`), CLI flag matching
//! (`matchFlag` + `applyValue`), magic-comment directives
//! (`MagicComment.scan`), and `--help` text (`printHelp`). Holdouts that
//! still need bespoke handling set `cli_simple = false` so the
//! dispatcher skips them: today the `--minify-*` / `--no-mangle` /
//! `--no-whitespace` / `--no-syntax` tri-state cluster (hand-rolled in
//! `cli/main.zig`) and the LSP-only toggles (no CLI surface, JSON only).
//! The source-map basename post-step (`configureSourceMap`) is also
//! hand-rolled but lives outside this spec system — it's not a
//! single-field knob.
//!
//! Conventions:
//!   * Field names are snake_case and must match the corresponding field
//!     on every target struct that consumes the spec (`Config`,
//!     `Minifier.Options`). Targets are expected to use a comptime guard
//!     such as `assertSpecFieldsExist` to catch drift at build time.
//!   * Camel and kebab variants are derived from the snake field unless
//!     the per-spec `json_override` / `cli_override` escape hatches are
//!     set (e.g. `extends` is the JSON key for `lint_extends` because it
//!     is not under a `lint*` namespace in `wgslender.json`).
//!   * `json_override` may name a dotted path (`"minifyInsights.format"`)
//!     to traverse into nested JSON objects — used by the LSP-section
//!     specs to collapse what was a hand-rolled walker.

const std = @import("std");
const Diagnostic = @import("Diagnostic.zig");
const Linter = @import("lint/Linter.zig");

pub const OptionKind = union(enum) {
    /// `?bool` (or `bool`) field. JSON value must be a boolean; non-bool
    /// is silently ignored (matches the permissive shape of the legacy
    /// parser).
    bool_opt,
    /// `[]const []const u8` field. JSON value must be an array; string
    /// elements are duped into the supplied allocator and assigned to the
    /// target field. Non-array / empty array leaves the target unchanged.
    /// CLI value form (`cli_takes_value = true`) is comma-split (single
    /// invocation, multiple entries — matches `--keep-names a,b,c`).
    string_list,
    /// `?u32` (or `u32`) field. JSON value must be a non-negative integer
    /// in `[0, maxInt(u32)]`. Out-of-range / wrong-type silently ignored.
    u32_opt,
    /// `?i32` (or `i32`) field. JSON value must be a signed integer in
    /// `[minInt(i32), maxInt(i32)]`. Out-of-range / wrong-type silently
    /// ignored. CLI value-form parses via `parseInt(i32, …, 10)` —
    /// matches the legacy `--line-offset` behavior (negative offsets
    /// supported, since `Diagnostic.zig` adds the offset in `i64` math).
    i32_opt,
    /// `?E` (or `E`) field, where `E` is the carried type. JSON value
    /// must be a string matching one of the enum's tag names (case-
    /// sensitive, exact match — uses `std.meta.stringToEnum`). Unknown
    /// tags / wrong types silently ignored.
    enum_opt: type,
    /// `[]const []const u8` field with **accumulating** CLI semantics:
    /// each `--flag <value>` invocation appends *one* element (no comma
    /// split). JSON shape matches `string_list` (array of strings).
    /// Used by `--extends` so repeated invocations stack: `--extends @a
    /// --extends @b` ⇒ `[@a, @b]`. Distinct from `string_list` so the
    /// CLI dispatcher knows not to treat the value as CSV.
    string_accum,
    /// `[]const Linter.Options.RuleOverride` field with accumulating CLI
    /// semantics: each `--flag <value>` invocation parses `value` as
    /// `id=severity` (severity ∈ `off|warn|warning|error`) and appends
    /// one `RuleOverride`. JSON shape: `{ "rule-id": "severity" }` or
    /// `{ "rule-id": ["severity", { ...options }] }` — the array form
    /// carries per-rule options (deep-cloned into the supplied allocator
    /// so they outlive the parse tree). Used by `--rule` / the `rules`
    /// JSON key. Targets must own their `id` slices and the per-rule
    /// `options` JSON value; `freeJsonValue` here mirrors the alloc.
    rule_override_accum,
};

/// Subcommands recognized by the wgslender CLI. Used by `subcommands`
/// on `OptionSpec` to gate which flags the dispatcher accepts per
/// subcommand. Mirrors the `CliArgs.subcommand` enum in `cli/main.zig`.
pub const Subcommand = enum { minify, validate, lint, reflect, compile };

pub const OptionSpec = struct {
    /// Snake-case Zig field name. Drives the derived JSON / CLI names.
    field: []const u8,
    kind: OptionKind,
    /// Human-readable description rendered by `printHelp`. Empty string
    /// opts the spec out of `--help` — used by entries whose CLI form is
    /// hand-rolled (the `--minify-*` cluster) or by JSON-only knobs.
    summary: []const u8 = "",
    /// CamelCase JSON key override. Default: `snakeToCamel(field)`.
    json_override: ?[]const u8 = null,
    /// Kebab-case CLI flag override (without leading `--`). Default:
    /// `snakeToKebab(field)`.
    cli_override: ?[]const u8 = null,
    /// True (default) iff `matchFlag` should treat `--<cliFlag>` as the
    /// affirmative form. Set false for options whose CLI form is custom
    /// — the `--minify-*` tri-state cluster, `--no-mangle` and friends,
    /// or fields that target `CliArgs` rather than `Minifier.Options`.
    cli_simple: bool = true,
    /// Inverted-flag spelling (without leading `--`). `"no-tree-shaking"`
    /// on the `tree_shaking` spec means the dispatcher accepts both
    /// `--tree-shaking` (true) and `--no-tree-shaking` (false). Only
    /// honored for `bool_opt` kind.
    cli_inverse: ?[]const u8 = null,
    /// When true, the flag consumes the next argv token as its value.
    /// Parsing is keyed off `kind`:
    ///   * `string_list` — value is comma-separated; trimmed parts go
    ///     into a slice on the supplied arena.
    ///   * `u32_opt` — value is `parseInt(u32, …, 10)`; failures leave
    ///     the field unchanged.
    ///   * `i32_opt` — value is `parseInt(i32, …, 10)`; failures leave
    ///     the field unchanged.
    ///   * `enum_opt: E` — value is `stringToEnum(E, …)`; unknowns leave
    ///     the field unchanged.
    /// `bool_opt` value-form is unsupported (use `cli_simple` /
    /// `cli_inverse` instead).
    cli_takes_value: bool = false,
    /// When true, a parse failure on the value form aborts the CLI with
    /// an error. Default is permissive — most flags silently coerce
    /// (e.g. `--max-warnings garbage` stays at its default), matching
    /// the dispatcher's historical behavior. Set true on flags where a
    /// typo'd value silently invalidates user intent (today: `--rule`,
    /// because a typo'd severity tag would otherwise look like the rule
    /// took effect when it didn't).
    cli_strict_value: bool = false,
    /// Subcommands that honor this flag. Empty (default) = all
    /// subcommands. The dispatcher uses this to filter `--help` output
    /// and decide whether to emit an "ignored flag" warning.
    subcommands: []const Subcommand = &.{},
    /// Whether `MagicComment.scan` accepts this spec as a per-document
    /// override (`// wgslender-minify-<key>=<value>`). Set false for
    /// fields that should remain JSON-only — typically because embedding
    /// them in source would let any contributor change a project-wide
    /// knob (`budget_bytes` mirrors the precedent for `severities`).
    /// The magic-comment scanner only considers specs whose
    /// `json_override` starts with `"minify"`; specs outside that
    /// namespace are out of scope regardless of this flag.
    magic_comment: bool = true,
};

/// Comptime: convert `snake_case` → `camelCase`. Underscores delimit
/// word boundaries; consecutive underscores collapse. Empty input maps to
/// empty output.
///
/// Implementation note: the result is published via a unique type's
/// namespace-level const, which gives the slice stable comptime storage
/// that survives at runtime. A bare `comptime { ... return &final; }`
/// gets caught by Zig 0.16's "value at comptime" return-lifetime check.
pub fn snakeToCamel(comptime snake: []const u8) []const u8 {
    return &SnakeToCamel(snake).value;
}

fn SnakeToCamel(comptime snake: []const u8) type {
    comptime var out_len: usize = 0;
    inline for (snake) |c| {
        if (c != '_') out_len += 1;
    }
    return struct {
        pub const value: [out_len]u8 = blk: {
            var buf: [out_len]u8 = undefined;
            var i: usize = 0;
            var capitalize = false;
            for (snake) |c| {
                if (c == '_') {
                    capitalize = true;
                    continue;
                }
                buf[i] = if (capitalize) std.ascii.toUpper(c) else c;
                i += 1;
                capitalize = false;
            }
            break :blk buf;
        };
    };
}

/// Comptime: convert `snake_case` → `kebab-case` (`'_'` → `'-'`).
pub fn snakeToKebab(comptime snake: []const u8) []const u8 {
    return &SnakeToKebab(snake).value;
}

fn SnakeToKebab(comptime snake: []const u8) type {
    return struct {
        pub const value: [snake.len]u8 = blk: {
            var buf: [snake.len]u8 = undefined;
            for (snake, 0..) |c, i| buf[i] = if (c == '_') '-' else c;
            break :blk buf;
        };
    };
}

/// Resolved JSON key for `spec` — the override if set, otherwise the
/// camelCase form of the field name.
pub fn jsonKey(comptime spec: OptionSpec) []const u8 {
    return spec.json_override orelse snakeToCamel(spec.field);
}

/// Resolved CLI flag for `spec` (without leading `--`).
pub fn cliFlag(comptime spec: OptionSpec) []const u8 {
    return spec.cli_override orelse snakeToKebab(spec.field);
}

/// Compile-time guard: every spec in `specs` must name a field that
/// exists on `Target` *and* whose Zig type matches the spec's kind. Call
/// this from a `comptime { ... }` block in any module that owns the
/// target struct, so a renamed / removed / mistyped field surfaces as a
/// build error rather than a silently-dropped JSON key.
///
/// Type matching:
///   * `.bool_opt` ⇒ `?bool` or `bool`
///   * `.string_list` ⇒ `[]const []const u8`
///   * `.u32_opt` ⇒ `?u32` or `u32`
///   * `.i32_opt` ⇒ `?i32` or `i32`
///   * `.enum_opt = E` ⇒ `?E` or `E`
///   * `.string_accum` ⇒ `[]const []const u8`
///   * `.rule_override_accum` ⇒ `[]const Linter.Options.RuleOverride`
pub fn assertSpecFieldsExist(comptime Target: type, comptime specs: []const OptionSpec) void {
    inline for (specs) |spec| {
        if (!@hasField(Target, spec.field)) {
            @compileError("OptionSpec '" ++ spec.field ++ "' has no matching field on " ++ @typeName(Target));
        }
        const FT = @FieldType(Target, spec.field);
        switch (spec.kind) {
            .bool_opt => if (FT != ?bool and FT != bool) @compileError("OptionSpec '" ++ spec.field ++ "' kind=bool_opt requires ?bool or bool field on " ++ @typeName(Target) ++ ", got " ++ @typeName(FT)),
            .string_list => if (FT != []const []const u8) @compileError("OptionSpec '" ++ spec.field ++ "' kind=string_list requires []const []const u8 field on " ++ @typeName(Target) ++ ", got " ++ @typeName(FT)),
            .u32_opt => if (FT != ?u32 and FT != u32) @compileError("OptionSpec '" ++ spec.field ++ "' kind=u32_opt requires ?u32 or u32 field on " ++ @typeName(Target) ++ ", got " ++ @typeName(FT)),
            .i32_opt => if (FT != ?i32 and FT != i32) @compileError("OptionSpec '" ++ spec.field ++ "' kind=i32_opt requires ?i32 or i32 field on " ++ @typeName(Target) ++ ", got " ++ @typeName(FT)),
            .enum_opt => |E| if (FT != ?E and FT != E) @compileError("OptionSpec '" ++ spec.field ++ "' kind=enum_opt requires ?" ++ @typeName(E) ++ " or " ++ @typeName(E) ++ " field on " ++ @typeName(Target) ++ ", got " ++ @typeName(FT)),
            .string_accum => if (FT != []const []const u8) @compileError("OptionSpec '" ++ spec.field ++ "' kind=string_accum requires []const []const u8 field on " ++ @typeName(Target) ++ ", got " ++ @typeName(FT)),
            .rule_override_accum => if (FT != []const Linter.Options.RuleOverride) @compileError("OptionSpec '" ++ spec.field ++ "' kind=rule_override_accum requires []const Linter.Options.RuleOverride field on " ++ @typeName(Target) ++ ", got " ++ @typeName(FT)),
        }
    }
}

/// Walk a dotted JSON key (`"a.b.c"`) into `root`, returning the leaf
/// `Value` or null if any intermediate step is missing / not an object.
/// A flat key (no dots) is just a single `object.get`.
fn lookupDotted(root: std.json.Value, key: []const u8) ?std.json.Value {
    var current = root;
    var iter = std.mem.splitScalar(u8, key, '.');
    while (iter.next()) |part| {
        if (current != .object) return null;
        current = current.object.get(part) orelse return null;
    }
    return current;
}

/// Apply each spec in `specs` to `target` using `root` as the JSON source.
/// `target` must be a pointer to a struct that has each `spec.field`.
/// Missing keys, wrong types, and non-object roots are silently ignored —
/// matching the legacy parser. String-list elements are duped into
/// `allocator`; the new slice replaces the existing field value. JSON
/// keys may use dotted paths (`"minifyInsights.format"`) to traverse
/// nested objects; see `lookupDotted`.
pub fn applyJson(
    allocator: std.mem.Allocator,
    comptime specs: []const OptionSpec,
    root: std.json.Value,
    target: anytype,
) std.mem.Allocator.Error!void {
    if (root != .object) return;
    inline for (specs) |spec| {
        const key = comptime jsonKey(spec);
        if (lookupDotted(root, key)) |value| {
            switch (comptime spec.kind) {
                .bool_opt => {
                    if (value == .bool) @field(target, spec.field) = value.bool;
                },
                .string_list => {
                    if (value == .array) {
                        var names: std.ArrayList([]const u8) = .empty;
                        errdefer {
                            for (names.items) |s| allocator.free(s);
                            names.deinit(allocator);
                        }
                        for (value.array.items) |item| {
                            if (item == .string) {
                                try names.append(allocator, try allocator.dupe(u8, item.string));
                            }
                        }
                        // toOwnedSlice shrinks to len so callers that
                        // own the result (e.g. `Config.deinit`) can
                        // `free` the slice without tripping the
                        // allocator's size check.
                        @field(target, spec.field) = try names.toOwnedSlice(allocator);
                    }
                },
                .u32_opt => {
                    if (value == .integer and value.integer >= 0 and value.integer <= std.math.maxInt(u32)) {
                        @field(target, spec.field) = @intCast(value.integer);
                    }
                },
                .i32_opt => {
                    if (value == .integer and value.integer >= std.math.minInt(i32) and value.integer <= std.math.maxInt(i32)) {
                        @field(target, spec.field) = @intCast(value.integer);
                    }
                },
                .enum_opt => |E| {
                    if (value == .string) {
                        if (std.meta.stringToEnum(E, value.string)) |e| {
                            @field(target, spec.field) = e;
                        }
                    }
                },
                .string_accum => {
                    // JSON shape mirrors `string_list`: an array of strings,
                    // each element duped into `allocator`. The "accumulating"
                    // semantic is CLI-only — repeated `--flag <v>` is what
                    // accumulates; the JSON form ships every element in one
                    // array, so a single `applyJson` write is correct.
                    if (value == .array) {
                        var names: std.ArrayList([]const u8) = .empty;
                        errdefer {
                            for (names.items) |s| allocator.free(s);
                            names.deinit(allocator);
                        }
                        for (value.array.items) |item| {
                            if (item == .string) {
                                try names.append(allocator, try allocator.dupe(u8, item.string));
                            }
                        }
                        @field(target, spec.field) = try names.toOwnedSlice(allocator);
                    }
                },
                .rule_override_accum => {
                    // ESLint-style `{ "rule-id": "warn" | ["warn", { ... }] }`.
                    // Each id is duped; per-rule options (array form) are
                    // deep-cloned so they outlive `parseJson`'s temporary
                    // parse tree. Caller must `freeJsonValue` each
                    // `RuleOverride.options` and `allocator.free` each `id`
                    // (see `Config.deinit` for the canonical wind-down).
                    if (value == .object) {
                        var list: std.ArrayList(Linter.Options.RuleOverride) = .empty;
                        errdefer {
                            for (list.items) |r| {
                                allocator.free(r.id);
                                if (r.options) |opts| {
                                    var o = opts;
                                    freeJsonValue(allocator, &o);
                                }
                            }
                            list.deinit(allocator);
                        }
                        var it = value.object.iterator();
                        while (it.next()) |kv| {
                            const sev = parseSeverityValue(kv.value_ptr.*) orelse continue;
                            var opts: ?std.json.Value = null;
                            if (kv.value_ptr.* == .array) {
                                const arr = kv.value_ptr.array;
                                if (arr.items.len > 1) {
                                    opts = try dupeJsonValue(allocator, arr.items[1]);
                                }
                            }
                            errdefer if (opts) |o| {
                                var oo = o;
                                freeJsonValue(allocator, &oo);
                            };
                            const id = try allocator.dupe(u8, kv.key_ptr.*);
                            try list.append(allocator, .{ .id = id, .severity = sev, .options = opts });
                        }
                        @field(target, spec.field) = try list.toOwnedSlice(allocator);
                    }
                },
            }
        }
    }
}

/// Parse an ESLint-style severity value: `"off"`, `"warn"` / `"warning"`,
/// `"error"`, or a `[severity, options]` array (only the first element is
/// inspected here — `applyJson`'s `rule_override_accum` arm handles the
/// optional second element separately). Returns null for unknown strings
/// or non-string / non-array shapes; the caller drops the entry.
pub fn parseSeverityValue(value: std.json.Value) ?Diagnostic.Severity {
    const s: []const u8 = switch (value) {
        .string => |str| str,
        .array => |arr| if (arr.items.len > 0 and arr.items[0] == .string) arr.items[0].string else return null,
        else => return null,
    };
    return parseSeverityString(s);
}

/// Parse a severity string token (`off|warn|warning|error`). Used by both
/// the JSON-side parser and the CLI `--rule id=severity` parser.
pub fn parseSeverityString(s: []const u8) ?Diagnostic.Severity {
    if (std.mem.eql(u8, s, "off")) return .disabled;
    if (std.mem.eql(u8, s, "warn") or std.mem.eql(u8, s, "warning")) return .warning;
    if (std.mem.eql(u8, s, "error")) return .@"error";
    return null;
}

/// Parse a CLI `--rule id=severity` token into a `RuleOverride`. Returns
/// null on syntax error (missing `=`, empty id, empty severity, unknown
/// severity tag). The `id` slice aliases `spec` directly — the caller owns
/// `spec`'s storage and must keep it alive for the override's lifetime
/// (the CLI passes argv-arena slices, which live for the whole process).
pub fn parseRuleOverrideToken(spec: []const u8) ?Linter.Options.RuleOverride {
    const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return null;
    if (eq == 0 or eq == spec.len - 1) return null;
    const id = spec[0..eq];
    const sev = parseSeverityString(spec[eq + 1 ..]) orelse return null;
    return .{ .id = id, .severity = sev };
}

/// Recursively deep-clone a `std.json.Value` into `allocator`. Used by
/// the `rule_override_accum` JSON arm to lift per-rule `options` out of
/// the temporary parse tree (which `parseJson` deinits before returning)
/// into the long-lived allocator that owns `Config`. Mirror of
/// `freeJsonValue` — allocations from this function must be freed with it.
pub fn dupeJsonValue(allocator: std.mem.Allocator, v: std.json.Value) std.mem.Allocator.Error!std.json.Value {
    return switch (v) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var new_arr = std.json.Array.init(allocator);
            errdefer {
                for (new_arr.items) |*item| freeJsonValue(allocator, item);
                new_arr.deinit();
            }
            try new_arr.ensureTotalCapacity(arr.items.len);
            for (arr.items) |item| {
                new_arr.appendAssumeCapacity(try dupeJsonValue(allocator, item));
            }
            break :blk .{ .array = new_arr };
        },
        .object => |obj| blk: {
            var new_obj: std.json.ObjectMap = .empty;
            errdefer {
                var it = new_obj.iterator();
                while (it.next()) |kv| {
                    allocator.free(kv.key_ptr.*);
                    freeJsonValue(allocator, kv.value_ptr);
                }
                new_obj.deinit(allocator);
            }
            try new_obj.ensureTotalCapacity(allocator, obj.count());
            var it = obj.iterator();
            while (it.next()) |kv| {
                const k = try allocator.dupe(u8, kv.key_ptr.*);
                try new_obj.put(allocator, k, try dupeJsonValue(allocator, kv.value_ptr.*));
            }
            break :blk .{ .object = new_obj };
        },
    };
}

/// Recursive counterpart to `dupeJsonValue` — frees every allocation
/// `dupeJsonValue` made on `allocator`. Idempotency is not supported
/// (caller must not double-free); designed to be called once from
/// `Config.deinit` per per-rule `options` entry.
pub fn freeJsonValue(allocator: std.mem.Allocator, v: *std.json.Value) void {
    switch (v.*) {
        .null, .bool, .integer, .float => {},
        .number_string, .string => |s| allocator.free(s),
        .array => |*arr| {
            for (arr.items) |*item| freeJsonValue(allocator, item);
            arr.deinit();
        },
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |kv| {
                allocator.free(kv.key_ptr.*);
                freeJsonValue(allocator, kv.value_ptr);
            }
            obj.deinit(allocator);
        },
    }
}

/// Outcome of `matchFlag` — distinguishes "didn't recognize" from
/// "recognized but the current subcommand ignores it" so the CLI can
/// emit a UX warning instead of silently dropping the user's flag.
pub const MatchResult = enum {
    /// Flag matched and the field was written.
    matched,
    /// No spec matched the argv token.
    no_match,
    /// Flag matched but the spec's `subcommands` list excludes the
    /// current subcommand. The argv value (if any) was consumed to keep
    /// the parser in sync; the target was *not* written. The caller
    /// should emit a "--<flag> has no effect on <subcommand>" warning.
    wrong_subcommand,
    /// Flag matched and consumed its value, but the value didn't parse.
    /// Only emitted when the spec opts into `cli_strict_value` (most
    /// specs are permissive). Caller is expected to abort the CLI with
    /// a "invalid --<flag> value" error.
    invalid_value,
};

/// True iff `sub` appears in the comptime list `list`. `list` may be
/// empty, in which case this returns true (empty = all subcommands).
fn subcommandIncluded(comptime list: []const Subcommand, sub: Subcommand) bool {
    if (list.len == 0) return true;
    inline for (list) |s| {
        if (s == sub) return true;
    }
    return false;
}

/// Match a CLI argument against every `cli_simple = true` spec in
/// `specs`. Handles three argv shapes:
///
///   * `--<flag>` (bool affirmative) — writes `true` to the field.
///   * `--<cli_inverse>` (bool inverse) — writes `false` to the field.
///   * `--<flag> <value>` (value-consuming) — pulls the next token from
///     `args_iter`, parses by `kind`, writes the parsed value. CSV split
///     for `string_list`; `parseInt` for `u32_opt`; `stringToEnum` for
///     `enum_opt`. `bool_opt` rejects the value form (use the affirmative
///     / inverse spellings instead).
///
/// Subcommand filtering: when a spec's `subcommands` list is non-empty
/// and excludes `subcommand`, the match is reported as
/// `wrong_subcommand` and the field is not written.
///
/// `args_iter` may be any value with a `.next() ?[]const u8` method.
/// `arena` is used to dupe `string_list` slices.
pub fn matchFlag(
    arg: []const u8,
    args_iter: anytype,
    arena: std.mem.Allocator,
    subcommand: Subcommand,
    comptime specs: []const OptionSpec,
    target: anytype,
) std.mem.Allocator.Error!MatchResult {
    inline for (specs) |spec| {
        if (comptime spec.cli_simple) {
            const flag = comptime "--" ++ cliFlag(spec);
            const is_match = std.mem.eql(u8, arg, flag);

            // Value-consuming form takes precedence over the bool forms
            // when `cli_takes_value` is set — same `--flag` token, but
            // the next argv element supplies the value.
            if (comptime spec.cli_takes_value) {
                if (is_match) {
                    if (!subcommandIncluded(spec.subcommands, subcommand)) {
                        _ = args_iter.next(); // keep parser in sync
                        return .wrong_subcommand;
                    }
                    const value = args_iter.next() orelse return .matched;
                    const ok = try applyValue(spec, value, arena, target);
                    // Permissive by default (matches every other CLI
                    // flag); strict mode lets specs opt into a hard
                    // failure when a typo'd value would silently make
                    // the flag a no-op.
                    if (!ok and comptime spec.cli_strict_value) return .invalid_value;
                    return .matched;
                }
            } else {
                comptime switch (spec.kind) {
                    .bool_opt => {},
                    else => continue,
                };
                if (is_match) {
                    if (!subcommandIncluded(spec.subcommands, subcommand)) return .wrong_subcommand;
                    @field(target, spec.field) = true;
                    return .matched;
                }
                if (comptime spec.cli_inverse) |inv| {
                    const inv_flag = "--" ++ inv;
                    if (std.mem.eql(u8, arg, inv_flag)) {
                        if (!subcommandIncluded(spec.subcommands, subcommand)) return .wrong_subcommand;
                        @field(target, spec.field) = false;
                        return .matched;
                    }
                }
            }
        }
    }
    return .no_match;
}

/// Apply `value` (as a string) to `target`'s `spec.field`, parsed
/// according to `spec.kind`. Used by both the CLI value-form dispatcher
/// and the magic-comment scanner — anywhere a single text value needs
/// to be parsed into the spec's typed field.
///
/// Returns `true` if the value parsed and the field was written. Returns
/// `false` on parse failure (unknown enum tag, non-integer for `u32_opt`,
/// non-`"true"`/`"false"` for `bool_opt`); callers can use the bool to
/// decide whether to emit a diagnostic. CLI matchers historically
/// dropped parse failures silently — they continue to do so by
/// discarding the result.
///
/// `string_list` is comma-split; result slices alias `value` directly
/// (no dupe). `bool_opt` accepts the literals `"true"` and `"false"` —
/// the CLI doesn't use this form (bools use `cli_simple` / `cli_inverse`
/// spellings), but magic-comment grammar does.
pub fn applyValue(
    comptime spec: OptionSpec,
    value: []const u8,
    arena: std.mem.Allocator,
    target: anytype,
) std.mem.Allocator.Error!bool {
    switch (comptime spec.kind) {
        .string_list => {
            // Trimmed comma-split. Slices alias `value` (which lives on
            // the caller's argv arena), so the result borrows for the
            // process lifetime — no dupe.
            var names: std.ArrayList([]const u8) = .empty;
            errdefer names.deinit(arena);
            var it = std.mem.splitScalar(u8, value, ',');
            while (it.next()) |raw| {
                const trimmed = std.mem.trim(u8, raw, " ");
                if (trimmed.len > 0) try names.append(arena, trimmed);
            }
            @field(target, spec.field) = names.items;
            return true;
        },
        .u32_opt => {
            const n = std.fmt.parseInt(u32, value, 10) catch return false;
            @field(target, spec.field) = n;
            return true;
        },
        .i32_opt => {
            const n = std.fmt.parseInt(i32, value, 10) catch return false;
            @field(target, spec.field) = n;
            return true;
        },
        .enum_opt => |E| {
            const e = std.meta.stringToEnum(E, value) orelse return false;
            @field(target, spec.field) = e;
            return true;
        },
        .bool_opt => {
            if (std.mem.eql(u8, value, "true")) {
                @field(target, spec.field) = true;
                return true;
            }
            if (std.mem.eql(u8, value, "false")) {
                @field(target, spec.field) = false;
                return true;
            }
            return false;
        },
        .string_accum => {
            // Each `--flag <v>` invocation appends one element. Reading
            // the existing slice + writing a fresh `toOwnedSlice` is O(n)
            // per append, but n is the count of `--flag` invocations on
            // one CLI line — single digits, not a hot path. The arena
            // reclaims the discarded intermediate slices on process exit.
            // The element aliases `value` directly (caller's argv arena
            // owns the storage) — same lifetime contract as `string_list`.
            const current = @field(target, spec.field);
            var list: std.ArrayList([]const u8) = .empty;
            try list.appendSlice(arena, current);
            try list.append(arena, value);
            @field(target, spec.field) = try list.toOwnedSlice(arena);
            return true;
        },
        .rule_override_accum => {
            const override = parseRuleOverrideToken(value) orelse return false;
            const current = @field(target, spec.field);
            var list: std.ArrayList(Linter.Options.RuleOverride) = .empty;
            try list.appendSlice(arena, current);
            try list.append(arena, override);
            @field(target, spec.field) = try list.toOwnedSlice(arena);
            return true;
        },
    }
}

/// Append `--help`-style lines for every spec in `specs` whose
/// `subcommands` list is empty (universal) OR includes `subcommand`.
/// `subcommand = null` shows every spec — used by the global usage.
/// Each line is `"  --<flag>  <summary>\n"`, padded to column 36 so
/// multiple spec tables stack consistently. Specs with an empty summary
/// (JSON-only knobs) are skipped. `cli_inverse` adds a second line
/// describing the disable form.
pub fn printHelp(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime specs: []const OptionSpec,
    subcommand: ?Subcommand,
) std.mem.Allocator.Error!void {
    const target_col: usize = 36;
    inline for (specs) |spec| {
        // Empty `summary` is the opt-out for --help — used by entries
        // whose CLI form is hand-rolled with a different summary (e.g.
        // the `--minify-*` tri-state cluster, where the CLI behavior
        // differs from the JSON-side bool).
        if (comptime spec.summary.len == 0) continue;
        const include_runtime = if (subcommand) |s|
            subcommandIncluded(spec.subcommands, s)
        else
            true;
        if (include_runtime) {
            const flag = comptime cliFlag(spec);
            const value_hint = comptime if (spec.cli_takes_value) " <value>" else "";
            const line = comptime "  --" ++ flag ++ value_hint;
            try buf.appendSlice(allocator, line);
            const pad: usize = if (line.len < target_col) target_col - line.len else 2;
            try buf.appendNTimes(allocator, ' ', pad);
            try buf.appendSlice(allocator, spec.summary);
            try buf.append(allocator, '\n');
            if (comptime spec.cli_inverse) |inv| {
                const inv_line = comptime "  --" ++ inv;
                try buf.appendSlice(allocator, inv_line);
                const inv_pad: usize = if (inv_line.len < target_col) target_col - inv_line.len else 2;
                try buf.appendNTimes(allocator, ' ', inv_pad);
                try buf.appendSlice(allocator, "Disable: ");
                try buf.appendSlice(allocator, spec.summary);
                try buf.append(allocator, '\n');
            }
        }
    }
}

/// Apply spec entries to a `Minifier.Options`-shaped struct, treating
/// each `?bool` source field as "non-null wins, null means inherit
/// default". String-list entries are copied wholesale when non-empty.
///
/// `source` is whatever struct holds the per-layer state (today: a
/// `Config`); `target` is a `*Minifier.Options`. Both must declare each
/// `spec.field`. Specs whose target field doesn't exist on the Options
/// struct should be omitted from the slice passed in (e.g. `source_map*`
/// is a Config-only knob plumbed via `CliArgs`, not Options).
pub fn applyDefaults(
    comptime specs: []const OptionSpec,
    source: anytype,
    target: anytype,
) void {
    inline for (specs) |spec| {
        switch (comptime spec.kind) {
            .bool_opt => {
                if (@field(source, spec.field)) |v| @field(target, spec.field) = v;
            },
            .string_list => {
                const list = @field(source, spec.field);
                if (list.len > 0) @field(target, spec.field) = list;
            },
            .u32_opt => {
                if (@field(source, spec.field)) |v| @field(target, spec.field) = v;
            },
            .i32_opt => {
                if (@field(source, spec.field)) |v| @field(target, spec.field) = v;
            },
            .enum_opt => {
                if (@field(source, spec.field)) |v| @field(target, spec.field) = v;
            },
            .string_accum, .rule_override_accum => {
                // Lint accumulators (extends, rule overrides) flow into
                // `Linter.Options` via a dedicated CLI merge step in
                // `cli/main.zig`, not through `Minifier.Options`. None of
                // the spec tables passed to `applyDefaults` today carry
                // these kinds — the arms exist only to keep the switch
                // exhaustive.
            },
        }
    }
}

// =========================================================================
// CLI shell logic (housed here so its precedence is unit-testable without a
// full arg parse). `options.zig` is imported by `Minifier` and cannot import
// it back, so the mutating helpers take the `Minifier.Options`-shaped target
// as `anytype` rather than a concrete type.
// =========================================================================

/// State of the hand-rolled minify-cluster flags (`--minify`, `--minify-*`,
/// `--no-mangle`, `--no-whitespace`, `--no-syntax`). This cluster can't fit
/// the derived `--flag` / `--no-flag` spec shape (it's tri-state), so it's
/// parsed by hand in `cli/main.zig` and handed here as an explicit struct.
pub const MinifyClusterFlags = struct {
    /// `--minify` — force all three passes on.
    all: bool = false,
    /// `--minify-whitespace` — `null` = flag absent. Presence of *any*
    /// granular flag resets the unspecified passes off.
    whitespace: ?bool = null,
    identifiers: ?bool = null,
    syntax: ?bool = null,
    /// `--no-mangle` / `--no-whitespace` / `--no-syntax` — force one pass
    /// off as the final word.
    no_mangle: bool = false,
    no_whitespace: bool = false,
    no_syntax: bool = false,
};

/// Resolve the minify-cluster flags onto a `Minifier.Options`-shaped target
/// (any struct with `minify_whitespace` / `minify_identifiers` /
/// `minify_syntax` bool fields). Precedence, low→high:
///   1. any granular `--minify-*` present → unspecified granular passes off
///   2. `--minify` → all three on
///   3. `--no-*` → that one pass off (the final word)
/// `--no-tree-shaking` is a separate spec knob (`cli_inverse`) and never
/// reaches here.
pub fn applyMinifyPrecedence(target: anytype, flags: MinifyClusterFlags) void {
    const has_granular = flags.whitespace != null or
        flags.identifiers != null or flags.syntax != null;
    if (has_granular) {
        target.minify_whitespace = flags.whitespace orelse false;
        target.minify_identifiers = flags.identifiers orelse false;
        target.minify_syntax = flags.syntax orelse false;
    }
    if (flags.all) {
        target.minify_whitespace = true;
        target.minify_identifiers = true;
        target.minify_syntax = true;
    }
    if (flags.no_mangle) target.minify_identifiers = false;
    if (flags.no_whitespace) target.minify_whitespace = false;
    if (flags.no_syntax) target.minify_syntax = false;
}

/// Fold the three source-map toggles into the source-map fields of a
/// `Minifier.Options`-shaped target, returning whether a map will be emitted.
/// Pure: knows nothing about file paths. When this returns `true` the caller
/// derives `source_map_options.source_name` / `.file` from the input/output
/// basenames — that path plumbing stays in `cli/main.zig`.
pub fn applySourceMapFlags(
    target: anytype,
    source_map: bool,
    source_map_inline: bool,
    include_source: bool,
) bool {
    const generate = source_map or source_map_inline;
    if (!generate) return false;
    target.generate_source_map = true;
    target.source_map_options.include_source = include_source;
    return true;
}

// =========================================================================
// Spec tables
// =========================================================================

/// Subcommand sets reused across spec tables.
const minify_subcommands = [_]Subcommand{ .minify, .compile };
const minify_only = [_]Subcommand{.minify};
const lint_only = [_]Subcommand{.lint};

/// Specs that flow `Config` → `Minifier.Options` via `Config.toOptions`.
/// Every entry must name a field on both `Config` and
/// `Minifier.Options`. The `cli_simple = false` entries need custom CLI
/// dispatch (see the `OptionSpec.cli_simple` doc comment).
pub const minifier_options_specs = [_]OptionSpec{
    // The three minify-* sub-pass toggles drive JSON parsing here but
    // their CLI form is the hand-rolled tri-state cluster (--minify,
    // --minify-*, --no-mangle, --no-whitespace, --no-syntax). Empty
    // `summary` opts them out of `printHelp`; the cluster's own help
    // lines live in `usage_minify_outliers` in cli/main.zig.
    .{ .field = "minify_whitespace", .kind = .bool_opt, .cli_simple = false, .subcommands = &minify_subcommands },
    .{ .field = "minify_identifiers", .kind = .bool_opt, .cli_simple = false, .subcommands = &minify_subcommands },
    .{ .field = "minify_syntax", .kind = .bool_opt, .cli_simple = false, .subcommands = &minify_subcommands },
    .{ .field = "mangle_external_bindings", .kind = .bool_opt, .subcommands = &minify_subcommands, .summary = "Rename @group/@binding vars (otherwise aliased)" },
    .{ .field = "tree_shaking", .kind = .bool_opt, .cli_inverse = "no-tree-shaking", .subcommands = &minify_subcommands, .summary = "Eliminate code unreachable from any entry point" },
    .{ .field = "preserve_uniform_struct_types", .kind = .bool_opt, .subcommands = &minify_subcommands, .summary = "Keep struct types referenced by uniform/storage vars" },
    .{ .field = "keep_names", .kind = .string_list, .cli_takes_value = true, .subcommands = &minify_subcommands, .summary = "Comma-separated identifiers that must never be renamed" },
    .{ .field = "sort_declarations", .kind = .bool_opt, .subcommands = &minify_subcommands, .summary = "Sort module-level declarations for better DEFLATE compression" },
    .{ .field = "scope_local_rename", .kind = .bool_opt, .subcommands = &minify_subcommands, .summary = "Rename locals canonically per function for better DEFLATE compression" },
};

/// Source-map switches. JSON layer targets `Config.source_map*` (?bool);
/// CLI layer dispatches to `CliArgs.source_map_flags.*` (bool) via the
/// dispatcher's third arm in `cli/main.zig`. Both targets share the same
/// snake_case field names so a single spec drives both surfaces. The
/// basename-derivation post-step (`configureSourceMap`: `source_name` /
/// `file` from input/output paths) stays hand-rolled — it's CLI plumbing,
/// not a single-field knob.
pub const source_map_specs = [_]OptionSpec{
    .{ .field = "source_map", .kind = .bool_opt, .subcommands = &minify_only, .summary = "Generate a source map alongside the minified output" },
    .{ .field = "source_map_inline", .kind = .bool_opt, .subcommands = &minify_only, .summary = "Embed source map as inline data URI" },
    .{ .field = "source_map_sources", .kind = .bool_opt, .subcommands = &minify_only, .summary = "Embed the original source content in the source map" },
};

/// Lint configuration knobs. Both `lint_extends` (kebab `--extends`) and
/// `lint_rules` (kebab `--rule`) accumulate across repeated CLI
/// invocations — the dispatcher routes through `string_accum` /
/// `rule_override_accum` arms in `applyValue`. JSON keys (`extends`,
/// `rules`) sit at the root of `wgslender.json`, not under a `lint`
/// namespace, hence the explicit `json_override`s.
///
/// `--report-unused-disable-directives` dispatches via the affirmative
/// form (writes `true` to `LintOptions.report_unused_disable_directives:
/// bool`); the CLI-vs-config merge in `cli/main.zig` then folds in the
/// `Config.report_unused_disable_directives: ?bool` value with the
/// standard "CLI true wins, else config value, else false" precedence.
pub const lint_specs = [_]OptionSpec{
    .{ .field = "lint_extends", .kind = .string_accum, .cli_takes_value = true, .subcommands = &lint_only, .json_override = "extends", .cli_override = "extends", .summary = "Inherit rules from a shareable lint config pack (repeatable)" },
    .{ .field = "lint_rules", .kind = .rule_override_accum, .cli_takes_value = true, .cli_strict_value = true, .subcommands = &lint_only, .json_override = "rules", .cli_override = "rule", .summary = "Override a rule severity (id=off|warn|error, repeatable)" },
    .{ .field = "report_unused_disable_directives", .kind = .bool_opt, .subcommands = &lint_only, .summary = "Warn on wgslender-disable comments that never match" },
};

/// LSP-only feature toggles that live on `Config` directly. Applied to
/// the inner `lsp` JSON object (caller supplies `lsp` as the root), so
/// the dotted paths start at `inlayHints.enabled` etc. — not
/// `lsp.inlayHints.enabled`. The MinifySettings.Partial knobs use a
/// parallel spec table colocated with `Partial` itself.
pub const lsp_toggle_specs = [_]OptionSpec{
    .{ .field = "lsp_inlay_hints_enabled", .kind = .bool_opt, .cli_simple = false, .json_override = "inlayHints.enabled", .summary = "Enable LSP inlay hints (struct sizes, type echoes)" },
    .{ .field = "lsp_diagnostics_enabled", .kind = .bool_opt, .cli_simple = false, .json_override = "diagnostics.enabled", .summary = "Publish diagnostics from the LSP server" },
    .{ .field = "lsp_lint_enabled", .kind = .bool_opt, .cli_simple = false, .json_override = "lint.enabled", .summary = "Run the configured lint packs in LSP diagnostics" },
};

/// All spec entries that drive the JSON parser today. Any new bool /
/// string-list option should land here so the JSON parser picks it up
/// automatically.
pub const config_specs = minifier_options_specs ++ source_map_specs ++ lint_specs;

// =========================================================================
// Tests
// =========================================================================

test "snakeToCamel basic" {
    try std.testing.expectEqualStrings("minifyWhitespace", snakeToCamel("minify_whitespace"));
    try std.testing.expectEqualStrings("a", snakeToCamel("a"));
    try std.testing.expectEqualStrings("foo", snakeToCamel("foo"));
    try std.testing.expectEqualStrings("fooBar", snakeToCamel("foo_bar"));
    try std.testing.expectEqualStrings("fooBarBaz", snakeToCamel("foo_bar_baz"));
    try std.testing.expectEqualStrings("", snakeToCamel(""));
}

test "snakeToKebab basic" {
    try std.testing.expectEqualStrings("minify-whitespace", snakeToKebab("minify_whitespace"));
    try std.testing.expectEqualStrings("foo", snakeToKebab("foo"));
    try std.testing.expectEqualStrings("foo-bar-baz", snakeToKebab("foo_bar_baz"));
    try std.testing.expectEqualStrings("", snakeToKebab(""));
}

test "jsonKey + cliFlag derivation and overrides" {
    const a: OptionSpec = .{ .field = "minify_whitespace", .kind = .bool_opt };
    try std.testing.expectEqualStrings("minifyWhitespace", jsonKey(a));
    try std.testing.expectEqualStrings("minify-whitespace", cliFlag(a));

    const b: OptionSpec = .{ .field = "lint_extends", .kind = .string_list, .json_override = "extends", .cli_override = "extends" };
    try std.testing.expectEqualStrings("extends", jsonKey(b));
    try std.testing.expectEqualStrings("extends", cliFlag(b));
}

test "applyJson bool + string_list parsing" {
    const Target = struct {
        minify_whitespace: ?bool = null,
        keep_names: []const []const u8 = &.{},
    };
    const specs = [_]OptionSpec{
        .{ .field = "minify_whitespace", .kind = .bool_opt },
        .{ .field = "keep_names", .kind = .string_list },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const content =
        \\{
        \\  "minifyWhitespace": false,
        \\  "keepNames": ["foo", "bar"]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, content, .{});
    defer parsed.deinit();

    var target: Target = .{};
    try applyJson(alloc, &specs, parsed.value, &target);

    try std.testing.expectEqual(@as(?bool, false), target.minify_whitespace);
    try std.testing.expectEqual(@as(usize, 2), target.keep_names.len);
    try std.testing.expectEqualStrings("foo", target.keep_names[0]);
    try std.testing.expectEqualStrings("bar", target.keep_names[1]);
}

test "applyJson ignores wrong types and missing keys" {
    const Target = struct {
        minify_whitespace: ?bool = null,
        keep_names: []const []const u8 = &.{},
    };
    const specs = [_]OptionSpec{
        .{ .field = "minify_whitespace", .kind = .bool_opt },
        .{ .field = "keep_names", .kind = .string_list },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const content =
        \\{
        \\  "minifyWhitespace": "not a bool",
        \\  "keepNames": "not an array"
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, content, .{});
    defer parsed.deinit();

    var target: Target = .{};
    try applyJson(alloc, &specs, parsed.value, &target);

    // Wrong types → fields stay at their defaults.
    try std.testing.expectEqual(@as(?bool, null), target.minify_whitespace);
    try std.testing.expectEqual(@as(usize, 0), target.keep_names.len);
}

test "applyJson skips non-string array entries" {
    const Target = struct { keep_names: []const []const u8 = &.{} };
    const specs = [_]OptionSpec{.{ .field = "keep_names", .kind = .string_list }};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const content =
        \\{ "keepNames": ["valid", 42, "also_valid", true] }
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, content, .{});
    defer parsed.deinit();

    var target: Target = .{};
    try applyJson(alloc, &specs, parsed.value, &target);

    try std.testing.expectEqual(@as(usize, 2), target.keep_names.len);
    try std.testing.expectEqualStrings("valid", target.keep_names[0]);
    try std.testing.expectEqualStrings("also_valid", target.keep_names[1]);
}

test "applyDefaults forwards non-null bools and non-empty lists" {
    const Source = struct {
        minify_whitespace: ?bool = null,
        keep_names: []const []const u8 = &.{},
    };
    const Target = struct {
        minify_whitespace: bool = true,
        keep_names: []const []const u8 = &.{},
    };
    const specs = [_]OptionSpec{
        .{ .field = "minify_whitespace", .kind = .bool_opt },
        .{ .field = "keep_names", .kind = .string_list },
    };

    var target: Target = .{};
    applyDefaults(&specs, Source{}, &target);
    // Null source → target untouched.
    try std.testing.expectEqual(true, target.minify_whitespace);
    try std.testing.expectEqual(@as(usize, 0), target.keep_names.len);

    var target2: Target = .{};
    applyDefaults(&specs, Source{ .minify_whitespace = false, .keep_names = &.{ "x", "y" } }, &target2);
    try std.testing.expectEqual(false, target2.minify_whitespace);
    try std.testing.expectEqual(@as(usize, 2), target2.keep_names.len);
}

test "assertSpecFieldsExist accepts matching fields" {
    const T = struct { minify_whitespace: ?bool = null };
    comptime assertSpecFieldsExist(T, &[_]OptionSpec{
        .{ .field = "minify_whitespace", .kind = .bool_opt },
    });
}

test "config_specs has no duplicate fields" {
    // Drift between minifier_options_specs / source_map_specs / lint_specs
    // would silently double-apply during `applyJson`.
    inline for (config_specs, 0..) |a, i| {
        inline for (config_specs, 0..) |b, j| {
            if (i != j and std.mem.eql(u8, a.field, b.field)) {
                try std.testing.expect(false); // duplicate field
            }
        }
    }
}

test "applyJson u32_opt parses non-negative integers" {
    const Target = struct {
        budget_bytes: ?u32 = null,
        clamped_high: ?u32 = null,
        clamped_negative: ?u32 = null,
    };
    const specs = [_]OptionSpec{
        .{ .field = "budget_bytes", .kind = .u32_opt, .json_override = "budgetBytes" },
        .{ .field = "clamped_high", .kind = .u32_opt, .json_override = "clampedHigh" },
        .{ .field = "clamped_negative", .kind = .u32_opt, .json_override = "clampedNegative" },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // 5_000_000_000 > maxInt(u32); -1 is negative — both ignored.
    const content =
        \\{ "budgetBytes": 4096, "clampedHigh": 5000000000, "clampedNegative": -1 }
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, content, .{});
    defer parsed.deinit();

    var target: Target = .{};
    try applyJson(alloc, &specs, parsed.value, &target);

    try std.testing.expectEqual(@as(?u32, 4096), target.budget_bytes);
    try std.testing.expectEqual(@as(?u32, null), target.clamped_high);
    try std.testing.expectEqual(@as(?u32, null), target.clamped_negative);
}

test "applyJson + applyValue i32_opt parse signed integers" {
    const Target = struct {
        line_offset: ?i32 = null,
        clamped_high: ?i32 = null,
        clamped_low: ?i32 = null,
        from_value: i32 = 0,
    };
    const specs = [_]OptionSpec{
        .{ .field = "line_offset", .kind = .i32_opt, .json_override = "lineOffset" },
        .{ .field = "clamped_high", .kind = .i32_opt, .json_override = "clampedHigh" },
        .{ .field = "clamped_low", .kind = .i32_opt, .json_override = "clampedLow" },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Positive, beyond maxInt(i32), and below minInt(i32) — last two ignored.
    const content =
        \\{ "lineOffset": -47, "clampedHigh": 3000000000, "clampedLow": -3000000000 }
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, content, .{});
    defer parsed.deinit();

    var target: Target = .{};
    try applyJson(alloc, &specs, parsed.value, &target);

    try std.testing.expectEqual(@as(?i32, -47), target.line_offset);
    try std.testing.expectEqual(@as(?i32, null), target.clamped_high);
    try std.testing.expectEqual(@as(?i32, null), target.clamped_low);

    // CLI value-form path: parses negative literal into a non-optional i32 field.
    const value_spec: OptionSpec = .{ .field = "from_value", .kind = .i32_opt };
    try std.testing.expect(try applyValue(value_spec, "-12", alloc, &target));
    try std.testing.expectEqual(@as(i32, -12), target.from_value);
    try std.testing.expect(!try applyValue(value_spec, "garbage", alloc, &target));
    try std.testing.expectEqual(@as(i32, -12), target.from_value); // unchanged on parse fail
}

test "applyJson enum_opt parses tag names by string match" {
    const Mode = enum { default, strict, insights };
    const Format = enum { text, json };
    const Target = struct {
        mode: ?Mode = null,
        format: ?Format = null,
        bad_mode: ?Mode = null,
    };
    const specs = [_]OptionSpec{
        .{ .field = "mode", .kind = .{ .enum_opt = Mode } },
        .{ .field = "format", .kind = .{ .enum_opt = Format } },
        .{ .field = "bad_mode", .kind = .{ .enum_opt = Mode }, .json_override = "badMode" },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const content =
        \\{ "mode": "strict", "format": "json", "badMode": "not_a_mode" }
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, content, .{});
    defer parsed.deinit();

    var target: Target = .{};
    try applyJson(alloc, &specs, parsed.value, &target);

    try std.testing.expectEqual(@as(?Mode, .strict), target.mode);
    try std.testing.expectEqual(@as(?Format, .json), target.format);
    // Unknown tag silently ignored — keeps default.
    try std.testing.expectEqual(@as(?Mode, null), target.bad_mode);
}

test "applyJson dotted json_override walks nested objects" {
    const Format = enum { text, json };
    const Target = struct {
        format: ?Format = null,
        function_size: ?bool = null,
        budget_bytes: ?u32 = null,
        missing_branch: ?bool = null,
    };
    const specs = [_]OptionSpec{
        .{ .field = "format", .kind = .{ .enum_opt = Format }, .json_override = "minifyInsights.format" },
        .{ .field = "function_size", .kind = .bool_opt, .json_override = "minifyInsights.functionSize" },
        .{ .field = "budget_bytes", .kind = .u32_opt, .json_override = "minifyLints.budgetBytes" },
        .{ .field = "missing_branch", .kind = .bool_opt, .json_override = "absent.deeply.nested" },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const content =
        \\{
        \\  "minifyInsights": { "format": "json", "functionSize": true },
        \\  "minifyLints": { "budgetBytes": 8192 }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, content, .{});
    defer parsed.deinit();

    var target: Target = .{};
    try applyJson(alloc, &specs, parsed.value, &target);

    try std.testing.expectEqual(@as(?Format, .json), target.format);
    try std.testing.expectEqual(@as(?bool, true), target.function_size);
    try std.testing.expectEqual(@as(?u32, 8192), target.budget_bytes);
    try std.testing.expectEqual(@as(?bool, null), target.missing_branch);
}

test "applyDefaults forwards new kinds" {
    const Mode = enum { default, strict };
    const Source = struct {
        budget_bytes: ?u32 = null,
        mode: ?Mode = null,
    };
    const Target = struct {
        budget_bytes: u32 = 1024,
        mode: Mode = .default,
    };
    const specs = [_]OptionSpec{
        .{ .field = "budget_bytes", .kind = .u32_opt },
        .{ .field = "mode", .kind = .{ .enum_opt = Mode } },
    };

    var t1: Target = .{};
    applyDefaults(&specs, Source{}, &t1);
    try std.testing.expectEqual(@as(u32, 1024), t1.budget_bytes);
    try std.testing.expectEqual(Mode.default, t1.mode);

    var t2: Target = .{};
    applyDefaults(&specs, Source{ .budget_bytes = 9999, .mode = .strict }, &t2);
    try std.testing.expectEqual(@as(u32, 9999), t2.budget_bytes);
    try std.testing.expectEqual(Mode.strict, t2.mode);
}

// Tiny iterator stub — matchFlag's value-form arms call .next() on the
// supplied iterator. None of the bool-only tests below exercise the
// value form, so a no-op iterator suffices.
const NoopIter = struct {
    pub fn next(_: *@This()) ?[]const u8 {
        return null;
    }
};

test "matchFlag dispatches simple bool specs" {
    const Target = struct {
        sort_declarations: bool = false,
        scope_local_rename: bool = false,
        keep_names: []const []const u8 = &.{},
    };
    const specs = [_]OptionSpec{
        .{ .field = "sort_declarations", .kind = .bool_opt },
        .{ .field = "scope_local_rename", .kind = .bool_opt },
        // `cli_simple = false` → matchFlag must skip.
        .{ .field = "keep_names", .kind = .string_list, .cli_simple = false },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var target: Target = .{};
    var it = NoopIter{};

    try std.testing.expectEqual(MatchResult.matched, try matchFlag("--sort-declarations", &it, arena.allocator(), .minify, &specs, &target));
    try std.testing.expectEqual(true, target.sort_declarations);
    try std.testing.expectEqual(false, target.scope_local_rename);

    try std.testing.expectEqual(MatchResult.matched, try matchFlag("--scope-local-rename", &it, arena.allocator(), .minify, &specs, &target));
    try std.testing.expectEqual(true, target.scope_local_rename);

    // Unknown flag → no match.
    try std.testing.expectEqual(MatchResult.no_match, try matchFlag("--unknown", &it, arena.allocator(), .minify, &specs, &target));

    // `cli_simple = false` spec must not be auto-dispatched even though
    // its derived flag (`--keep-names`) would syntactically match.
    try std.testing.expectEqual(MatchResult.no_match, try matchFlag("--keep-names", &it, arena.allocator(), .minify, &specs, &target));
    try std.testing.expectEqual(@as(usize, 0), target.keep_names.len);
}

test "matchFlag rejects flags whose subcommands list excludes the current subcommand" {
    const Target = struct { sort_declarations: bool = false };
    const specs = [_]OptionSpec{
        .{ .field = "sort_declarations", .kind = .bool_opt, .subcommands = &.{ .minify, .compile } },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var target: Target = .{};
    var it = NoopIter{};

    // Allowed subcommand: target written, .matched returned.
    try std.testing.expectEqual(MatchResult.matched, try matchFlag("--sort-declarations", &it, arena.allocator(), .minify, &specs, &target));
    try std.testing.expectEqual(true, target.sort_declarations);

    // Disallowed subcommand: returns wrong_subcommand, target unchanged.
    target.sort_declarations = false;
    try std.testing.expectEqual(MatchResult.wrong_subcommand, try matchFlag("--sort-declarations", &it, arena.allocator(), .lint, &specs, &target));
    try std.testing.expectEqual(false, target.sort_declarations);
}

// Two-element iterator stub for value-form matchFlag tests.
fn ValueIter(comptime n: usize) type {
    return struct {
        values: [n][]const u8,
        idx: usize = 0,
        pub fn next(self: *@This()) ?[]const u8 {
            if (self.idx >= self.values.len) return null;
            defer self.idx += 1;
            return self.values[self.idx];
        }
    };
}

test "matchFlag string_accum: repeated invocations append" {
    const Target = struct { lint_extends: []const []const u8 = &.{} };
    const specs = [_]OptionSpec{
        .{ .field = "lint_extends", .kind = .string_accum, .cli_takes_value = true, .cli_override = "extends" },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var target: Target = .{};

    // First invocation appends one element.
    var it1 = ValueIter(1){ .values = .{"@wgslender/recommended"} };
    try std.testing.expectEqual(MatchResult.matched, try matchFlag("--extends", &it1, arena.allocator(), .lint, &specs, &target));
    try std.testing.expectEqual(@as(usize, 1), target.lint_extends.len);
    try std.testing.expectEqualStrings("@wgslender/recommended", target.lint_extends[0]);

    // Second invocation appends a second element (does not overwrite).
    var it2 = ValueIter(1){ .values = .{"@wgslender/strict"} };
    try std.testing.expectEqual(MatchResult.matched, try matchFlag("--extends", &it2, arena.allocator(), .lint, &specs, &target));
    try std.testing.expectEqual(@as(usize, 2), target.lint_extends.len);
    try std.testing.expectEqualStrings("@wgslender/recommended", target.lint_extends[0]);
    try std.testing.expectEqualStrings("@wgslender/strict", target.lint_extends[1]);

    // Third invocation extends to three.
    var it3 = ValueIter(1){ .values = .{"@wgslender/style"} };
    try std.testing.expectEqual(MatchResult.matched, try matchFlag("--extends", &it3, arena.allocator(), .lint, &specs, &target));
    try std.testing.expectEqual(@as(usize, 3), target.lint_extends.len);
}

test "matchFlag rule_override_accum: parses id=severity and accumulates" {
    const Target = struct { lint_rules: []const Linter.Options.RuleOverride = &.{} };
    const specs = [_]OptionSpec{
        .{ .field = "lint_rules", .kind = .rule_override_accum, .cli_takes_value = true, .cli_strict_value = true, .cli_override = "rule" },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var target: Target = .{};

    // Each invocation appends one RuleOverride; severity vocabulary is
    // off|warn|warning|error.
    var it1 = ValueIter(1){ .values = .{"no-unused-vars=warn"} };
    try std.testing.expectEqual(MatchResult.matched, try matchFlag("--rule", &it1, arena.allocator(), .lint, &specs, &target));
    var it2 = ValueIter(1){ .values = .{"no-magic-numbers=off"} };
    try std.testing.expectEqual(MatchResult.matched, try matchFlag("--rule", &it2, arena.allocator(), .lint, &specs, &target));
    var it3 = ValueIter(1){ .values = .{"max-params=error"} };
    try std.testing.expectEqual(MatchResult.matched, try matchFlag("--rule", &it3, arena.allocator(), .lint, &specs, &target));

    try std.testing.expectEqual(@as(usize, 3), target.lint_rules.len);
    try std.testing.expectEqualStrings("no-unused-vars", target.lint_rules[0].id);
    try std.testing.expectEqual(Diagnostic.Severity.warning, target.lint_rules[0].severity);
    try std.testing.expectEqualStrings("no-magic-numbers", target.lint_rules[1].id);
    try std.testing.expectEqual(Diagnostic.Severity.disabled, target.lint_rules[1].severity);
    try std.testing.expectEqualStrings("max-params", target.lint_rules[2].id);
    try std.testing.expectEqual(Diagnostic.Severity.@"error", target.lint_rules[2].severity);
}

test "matchFlag rule_override_accum: strict mode rejects bad value" {
    const Target = struct { lint_rules: []const Linter.Options.RuleOverride = &.{} };
    const specs = [_]OptionSpec{
        .{ .field = "lint_rules", .kind = .rule_override_accum, .cli_takes_value = true, .cli_strict_value = true, .cli_override = "rule" },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var target: Target = .{};

    // Missing `=` → invalid_value (strict opt-in).
    var it1 = ValueIter(1){ .values = .{"garbage"} };
    try std.testing.expectEqual(MatchResult.invalid_value, try matchFlag("--rule", &it1, arena.allocator(), .lint, &specs, &target));
    try std.testing.expectEqual(@as(usize, 0), target.lint_rules.len);

    // Unknown severity tag → invalid_value.
    var it2 = ValueIter(1){ .values = .{"no-foo=bogus"} };
    try std.testing.expectEqual(MatchResult.invalid_value, try matchFlag("--rule", &it2, arena.allocator(), .lint, &specs, &target));
    try std.testing.expectEqual(@as(usize, 0), target.lint_rules.len);

    // Empty id → invalid_value.
    var it3 = ValueIter(1){ .values = .{"=warn"} };
    try std.testing.expectEqual(MatchResult.invalid_value, try matchFlag("--rule", &it3, arena.allocator(), .lint, &specs, &target));
    try std.testing.expectEqual(@as(usize, 0), target.lint_rules.len);
}

test "matchFlag rule_override_accum: permissive mode silently drops bad value" {
    // Same kind, but `cli_strict_value` left at its default (false). A
    // bad value still consumes the argv token but reports `.matched` and
    // leaves the field untouched — matches the dispatcher's permissive
    // historical behavior for value-form flags.
    const Target = struct { lint_rules: []const Linter.Options.RuleOverride = &.{} };
    const specs = [_]OptionSpec{
        .{ .field = "lint_rules", .kind = .rule_override_accum, .cli_takes_value = true, .cli_override = "rule" },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var target: Target = .{};

    var it1 = ValueIter(1){ .values = .{"garbage"} };
    try std.testing.expectEqual(MatchResult.matched, try matchFlag("--rule", &it1, arena.allocator(), .lint, &specs, &target));
    try std.testing.expectEqual(@as(usize, 0), target.lint_rules.len);
}

test "applyJson rule_override_accum: object form with severities + per-rule options" {
    const Target = struct { lint_rules: []const Linter.Options.RuleOverride = &.{} };
    const specs = [_]OptionSpec{
        .{ .field = "lint_rules", .kind = .rule_override_accum, .json_override = "rules" },
    };

    const alloc = std.testing.allocator;
    const content =
        \\{
        \\  "rules": {
        \\    "no-unused-vars": "error",
        \\    "no-magic-numbers": "off",
        \\    "max-params": ["warn", { "max": 4 }],
        \\    "bogus-not-a-severity": "loud"
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, content, .{});
    defer parsed.deinit();

    var target: Target = .{};
    try applyJson(alloc, &specs, parsed.value, &target);
    defer {
        for (target.lint_rules) |r| {
            alloc.free(r.id);
            if (r.options) |opts| {
                var o = opts;
                freeJsonValue(alloc, &o);
            }
        }
        if (target.lint_rules.len > 0) alloc.free(target.lint_rules);
    }

    // Three valid entries; bogus severity drops out.
    try std.testing.expectEqual(@as(usize, 3), target.lint_rules.len);

    // Severities must round-trip; `max-params` carries a deep-cloned options object.
    var saw_max_params_opts = false;
    for (target.lint_rules) |r| {
        if (std.mem.eql(u8, r.id, "max-params")) {
            try std.testing.expectEqual(Diagnostic.Severity.warning, r.severity);
            try std.testing.expect(r.options != null);
            try std.testing.expectEqual(@as(i64, 4), r.options.?.object.get("max").?.integer);
            saw_max_params_opts = true;
        }
    }
    try std.testing.expect(saw_max_params_opts);
}

test "parseRuleOverrideToken: accepts off|warn|warning|error and rejects malformed input" {
    try std.testing.expectEqual(@as(?Linter.Options.RuleOverride, null), parseRuleOverrideToken("garbage"));
    try std.testing.expectEqual(@as(?Linter.Options.RuleOverride, null), parseRuleOverrideToken("=warn"));
    try std.testing.expectEqual(@as(?Linter.Options.RuleOverride, null), parseRuleOverrideToken("foo="));
    try std.testing.expectEqual(@as(?Linter.Options.RuleOverride, null), parseRuleOverrideToken("foo=bogus"));

    const off = parseRuleOverrideToken("foo=off").?;
    try std.testing.expectEqual(Diagnostic.Severity.disabled, off.severity);
    const warn = parseRuleOverrideToken("foo=warn").?;
    try std.testing.expectEqual(Diagnostic.Severity.warning, warn.severity);
    const warning = parseRuleOverrideToken("foo=warning").?;
    try std.testing.expectEqual(Diagnostic.Severity.warning, warning.severity);
    const err = parseRuleOverrideToken("foo=error").?;
    try std.testing.expectEqual(Diagnostic.Severity.@"error", err.severity);
}
