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
//!   * Only `bool_opt` (Zig type `?bool`) and `string_list` (Zig type
//!     `[]const []const u8`) are supported today. Future kinds (u32,
//!     enum) slot in by extending `OptionKind` and `applyJson`.

const std = @import("std");

pub const OptionKind = enum {
    /// `?bool` field. JSON value must be a boolean; non-bool is silently
    /// ignored (matches the permissive shape of the legacy parser).
    bool_opt,
    /// `[]const []const u8` field. JSON value must be an array; string
    /// elements are duped into the supplied allocator and assigned to the
    /// target field. Non-array / empty array leaves the target unchanged.
    string_list,
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
    /// `snakeToKebab(field)`. Reserved for Cut B; unused today.
    cli_override: ?[]const u8 = null,
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
/// exists on `Target`. Call this from a `comptime { ... }` block in any
/// module that owns the target struct, so a renamed / removed field
/// surfaces as a build error rather than a silently-dropped JSON key.
pub fn assertSpecFieldsExist(comptime Target: type, comptime specs: []const OptionSpec) void {
    inline for (specs) |spec| {
        if (!@hasField(Target, spec.field)) {
            @compileError("OptionSpec '" ++ spec.field ++ "' has no matching field on " ++ @typeName(Target));
        }
    }
}

/// Apply each spec in `specs` to `target` using `root` as the JSON source.
/// `target` must be a pointer to a struct that has each `spec.field`.
/// Missing keys, wrong types, and non-object roots are silently ignored —
/// matching the legacy parser. String-list elements are duped into
/// `allocator`; the new slice replaces the existing field value.
pub fn applyJson(
    allocator: std.mem.Allocator,
    comptime specs: []const OptionSpec,
    root: std.json.Value,
    target: anytype,
) std.mem.Allocator.Error!void {
    if (root != .object) return;
    inline for (specs) |spec| {
        const key = comptime jsonKey(spec);
        if (root.object.get(key)) |value| {
            switch (comptime spec.kind) {
                .bool_opt => {
                    if (value == .bool) @field(target, spec.field) = value.bool;
                },
                .string_list => {
                    if (value == .array) {
                        var names: std.ArrayListUnmanaged([]const u8) = .empty;
                        for (value.array.items) |item| {
                            if (item == .string) {
                                try names.append(allocator, try allocator.dupe(u8, item.string));
                            }
                        }
                        @field(target, spec.field) = names.items;
                    }
                },
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
        }
    }
}

// =========================================================================
// Spec tables
// =========================================================================

/// Minifier-shaped options. These flow from `wgslender.json` →
/// `Config` → `Minifier.Options` via `Config.toOptions`.
///
/// `source_map` and `source_map_sources` are Config-only — they don't go
/// through `toOptions` because the CLI plumbs them via
/// `CliArgs.source_map(_inline)` + `args.options.source_map_options.*`.
/// They are still in the JSON spec so configs can set them.
pub const minifier_specs = [_]OptionSpec{
    .{ .field = "minify_whitespace", .kind = .bool_opt, .summary = "Strip insignificant whitespace from output" },
    .{ .field = "minify_identifiers", .kind = .bool_opt, .summary = "Rename identifiers (frequency-based mangling)" },
    .{ .field = "minify_syntax", .kind = .bool_opt, .summary = "Apply WGSL syntax-level optimizations" },
    .{ .field = "mangle_external_bindings", .kind = .bool_opt, .summary = "Rename @group/@binding vars (otherwise aliased)" },
    .{ .field = "tree_shaking", .kind = .bool_opt, .summary = "Eliminate code unreachable from any entry point" },
    .{ .field = "preserve_uniform_struct_types", .kind = .bool_opt, .summary = "Keep struct types referenced by uniform/storage vars" },
    .{ .field = "keep_names", .kind = .string_list, .summary = "Identifiers that must never be renamed" },
    .{ .field = "sort_declarations", .kind = .bool_opt, .summary = "Sort module-level declarations for better DEFLATE compression" },
    .{ .field = "scope_local_rename", .kind = .bool_opt, .summary = "Rename locals canonically per function for better DEFLATE compression" },
    .{ .field = "source_map", .kind = .bool_opt, .summary = "Generate a source map alongside the minified output" },
    .{ .field = "source_map_sources", .kind = .bool_opt, .summary = "Embed the original source content in the source map" },
};

/// Lint configuration knobs. `lint_rules` is intentionally hand-parsed
/// (severity / per-rule options shape doesn't fit `string_list`) and the
/// LSP-only `lsp` nested object stays hand-parsed too.
pub const lint_specs = [_]OptionSpec{
    .{ .field = "lint_extends", .kind = .string_list, .json_override = "extends", .summary = "Shareable lint config packs to inherit" },
    .{ .field = "report_unused_disable_directives", .kind = .bool_opt, .summary = "Treat unused wgslender-disable comments as warnings" },
};

/// All spec entries that drive the JSON parser today. Any new bool /
/// string-list option should land here so the JSON parser picks it up
/// automatically.
pub const config_specs = minifier_specs ++ lint_specs;

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

test "config_specs covers every supported Config field" {
    // Whitespace: every entry in config_specs must have a unique field
    // name. Drift between minifier_specs and lint_specs would produce
    // double-application during applyJson.
    inline for (config_specs, 0..) |a, i| {
        inline for (config_specs, 0..) |b, j| {
            if (i != j and std.mem.eql(u8, a.field, b.field)) {
                try std.testing.expect(false); // duplicate field
            }
        }
    }
}
