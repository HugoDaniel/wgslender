//! Comptime spec table for wgslender configuration options.
//!
//! Each `OptionSpec` is a single source of truth for one option's three
//! names — Zig snake_case field, camelCase JSON key, kebab-case CLI flag.
//! Today the spec drives JSON parsing for `Config`; Cut B of the Phase 2
//! refactor will plug the same spec into the CLI flag parser and the
//! `--help` text generator (see `docs/parser-template-postfix-plan.md`
//! and the §8.1 entry in the audit plan for context).
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

pub const OptionKind = union(enum) {
    /// `?bool` (or `bool`) field. JSON value must be a boolean; non-bool
    /// is silently ignored (matches the permissive shape of the legacy
    /// parser).
    bool_opt,
    /// `[]const []const u8` field. JSON value must be an array; string
    /// elements are duped into the supplied allocator and assigned to the
    /// target field. Non-array / empty array leaves the target unchanged.
    string_list,
    /// `?u32` (or `u32`) field. JSON value must be a non-negative integer
    /// in `[0, maxInt(u32)]`. Out-of-range / wrong-type silently ignored.
    u32_opt,
    /// `?E` (or `E`) field, where `E` is the carried type. JSON value
    /// must be a string matching one of the enum's tag names (case-
    /// sensitive, exact match — uses `std.meta.stringToEnum`). Unknown
    /// tags / wrong types silently ignored.
    enum_opt: type,
};

pub const OptionSpec = struct {
    /// Snake-case Zig field name. Drives the derived JSON / CLI names.
    field: []const u8,
    kind: OptionKind,
    /// Human-readable description used by the future `--help` generator.
    summary: []const u8 = "",
    /// CamelCase JSON key override. Default: `snakeToCamel(field)`.
    json_override: ?[]const u8 = null,
    /// Kebab-case CLI flag override (without leading `--`). Default:
    /// `snakeToKebab(field)`.
    cli_override: ?[]const u8 = null,
    /// True (default) iff `matchBoolFlag` should treat `--<cliFlag>` as
    /// "set field to true". Set false for options whose CLI form is
    /// custom — the `--minify-*` cluster sets a tri-state for
    /// `applyMinifyOverrides`, `--no-tree-shaking` is the inverse form,
    /// `--keep-names` consumes a value, and the source-map switches set
    /// `CliArgs` fields rather than the underlying `Minifier.Options`.
    cli_simple: bool = true,
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
///   * `.enum_opt = E` ⇒ `?E` or `E`
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
            .enum_opt => |E| if (FT != ?E and FT != E) @compileError("OptionSpec '" ++ spec.field ++ "' kind=enum_opt requires ?" ++ @typeName(E) ++ " or " ++ @typeName(E) ++ " field on " ++ @typeName(Target) ++ ", got " ++ @typeName(FT)),
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
                        var names: std.ArrayListUnmanaged([]const u8) = .empty;
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
                .enum_opt => |E| {
                    if (value == .string) {
                        if (std.meta.stringToEnum(E, value.string)) |e| {
                            @field(target, spec.field) = e;
                        }
                    }
                },
            }
        }
    }
}

/// Match a CLI argument against the simple `--<flag>` form derived from
/// each `cli_simple = true` spec in `specs`. On match: write `true` to
/// the corresponding field on `target` and return true so the caller can
/// run any per-flag bookkeeping (e.g. set `passed.minify_flag`). Returns
/// false if no spec matched.
///
/// Specs with `cli_simple = false` or non-`bool_opt` kind are skipped —
/// those need custom dispatch in the caller.
pub fn matchBoolFlag(
    arg: []const u8,
    comptime specs: []const OptionSpec,
    target: anytype,
) bool {
    inline for (specs) |spec| {
        if (comptime !spec.cli_simple) continue;
        comptime switch (spec.kind) {
            .bool_opt => {},
            else => continue,
        };
        const flag = comptime "--" ++ cliFlag(spec);
        if (std.mem.eql(u8, arg, flag)) {
            @field(target, spec.field) = true;
            return true;
        }
    }
    return false;
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
            .enum_opt => {
                if (@field(source, spec.field)) |v| @field(target, spec.field) = v;
            },
        }
    }
}

// =========================================================================
// Spec tables
// =========================================================================

/// Specs that flow `Config` → `Minifier.Options` via `Config.toOptions`.
/// Every entry must name a field on both `Config` and
/// `Minifier.Options`. The `cli_simple = false` entries need custom CLI
/// dispatch (see the `OptionSpec.cli_simple` doc comment).
pub const minifier_options_specs = [_]OptionSpec{
    .{ .field = "minify_whitespace", .kind = .bool_opt, .cli_simple = false, .summary = "Strip insignificant whitespace from output" },
    .{ .field = "minify_identifiers", .kind = .bool_opt, .cli_simple = false, .summary = "Rename identifiers (frequency-based mangling)" },
    .{ .field = "minify_syntax", .kind = .bool_opt, .cli_simple = false, .summary = "Apply WGSL syntax-level optimizations" },
    .{ .field = "mangle_external_bindings", .kind = .bool_opt, .summary = "Rename @group/@binding vars (otherwise aliased)" },
    .{ .field = "tree_shaking", .kind = .bool_opt, .cli_simple = false, .summary = "Eliminate code unreachable from any entry point" },
    .{ .field = "preserve_uniform_struct_types", .kind = .bool_opt, .summary = "Keep struct types referenced by uniform/storage vars" },
    .{ .field = "keep_names", .kind = .string_list, .cli_simple = false, .summary = "Identifiers that must never be renamed" },
    .{ .field = "sort_declarations", .kind = .bool_opt, .summary = "Sort module-level declarations for better DEFLATE compression" },
    .{ .field = "scope_local_rename", .kind = .bool_opt, .summary = "Rename locals canonically per function for better DEFLATE compression" },
};

/// Source-map switches. Live on `Config` and feed `CliArgs.source_map` /
/// `CliArgs.source_map_options.*` — they don't flow through `toOptions`
/// because the CLI orchestrates source-map plumbing separately. JSON
/// parsing uses these specs; CLI dispatch is hand-rolled for the
/// `--source-map` / `--source-map-inline` / `--source-map-sources`
/// trio because they target `CliArgs` instead of `Minifier.Options`.
pub const source_map_specs = [_]OptionSpec{
    .{ .field = "source_map", .kind = .bool_opt, .cli_simple = false, .summary = "Generate a source map alongside the minified output" },
    .{ .field = "source_map_sources", .kind = .bool_opt, .cli_simple = false, .summary = "Embed the original source content in the source map" },
};

/// Lint configuration knobs. `lint_rules` is intentionally hand-parsed
/// (severity / per-rule options shape doesn't fit `string_list`) and the
/// LSP-only `lsp` nested object stays hand-parsed too.
pub const lint_specs = [_]OptionSpec{
    .{ .field = "lint_extends", .kind = .string_list, .cli_simple = false, .json_override = "extends", .summary = "Shareable lint config packs to inherit" },
    .{ .field = "report_unused_disable_directives", .kind = .bool_opt, .cli_simple = false, .summary = "Treat unused wgslender-disable comments as warnings" },
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

test "matchBoolFlag dispatches simple bool specs" {
    const Target = struct {
        sort_declarations: bool = false,
        scope_local_rename: bool = false,
        keep_names: []const []const u8 = &.{},
    };
    const specs = [_]OptionSpec{
        .{ .field = "sort_declarations", .kind = .bool_opt },
        .{ .field = "scope_local_rename", .kind = .bool_opt },
        // `cli_simple = false` → matchBoolFlag must skip.
        .{ .field = "keep_names", .kind = .string_list, .cli_simple = false },
    };

    var target: Target = .{};

    try std.testing.expect(matchBoolFlag("--sort-declarations", &specs, &target));
    try std.testing.expectEqual(true, target.sort_declarations);
    try std.testing.expectEqual(false, target.scope_local_rename);

    try std.testing.expect(matchBoolFlag("--scope-local-rename", &specs, &target));
    try std.testing.expectEqual(true, target.scope_local_rename);

    // Unknown flag → no match.
    try std.testing.expect(!matchBoolFlag("--unknown", &specs, &target));

    // `cli_simple = false` spec must not be auto-dispatched even though
    // its derived flag (`--keep-names`) would syntactically match.
    try std.testing.expect(!matchBoolFlag("--keep-names", &specs, &target));
    try std.testing.expectEqual(@as(usize, 0), target.keep_names.len);
}
