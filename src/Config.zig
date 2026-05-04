//! JSON configuration loading for wgslender.
//!
//! Supports wgslender.json / .wgslenderrc config files.
//! Walks up directory tree to find config.
//!
//! Invariants:
//!   - All option fields are `?T` so unset → fallback to `Minifier.Options`
//!     defaults. Layered config (CLI flag > workspace > project) merges
//!     by treating `null` as "inherit"; non-null wins at each layer.
//!   - Auto-discovery walks parent directories until a config file or
//!     filesystem root is hit; symlinks are followed but loops bail out
//!     after a fixed depth budget to avoid infinite recursion.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Minifier = @import("Minifier.zig");
const MinifySettings = @import("MinifySettings.zig");
const Linter = @import("lint/Linter.zig");
const Diagnostic = @import("Diagnostic.zig");
const options = @import("options.zig");

const Config = @This();

comptime {
    // Drift guard: every spec entry must name a real Config field.
    // Renaming or removing a field without updating the spec table
    // surfaces here as a build error. `lsp_toggle_specs` covers the LSP
    // feature toggles that live on `Config` and are applied below the
    // `lsp` namespace.
    options.assertSpecFieldsExist(Config, &options.config_specs);
    options.assertSpecFieldsExist(Config, &options.lsp_toggle_specs);
}

minify_whitespace: ?bool = null,
minify_identifiers: ?bool = null,
minify_syntax: ?bool = null,
mangle_external_bindings: ?bool = null,
tree_shaking: ?bool = null,
preserve_uniform_struct_types: ?bool = null,
keep_names: []const []const u8 = &.{},
sort_declarations: ?bool = null,
scope_local_rename: ?bool = null,
source_map: ?bool = null,
source_map_inline: ?bool = null,
source_map_sources: ?bool = null,
/// Lint shareable-config inheritance list (`extends` JSON key). Empty
/// means "no inherited packs". Parsed only as id strings; unknown packs
/// are silently ignored by the Linter at run time.
lint_extends: []const []const u8 = &.{},
/// Per-rule severity overrides (`rules` JSON key). Each entry maps a
/// public rule id to a severity, optionally with a per-rule options
/// object (`["warn", { "max": 4 }]`). Options are deep-cloned into the
/// supplied allocator and freed by `Config.deinit`.
lint_rules: []const Linter.Options.RuleOverride = &.{},
/// `reportUnusedDisableDirectives` JSON key. `null` means unset →
/// caller falls back to its own default (CLI: false; LSP/FFI: false).
report_unused_disable_directives: ?bool = null,
/// LSP-only minifier-mode settings. Project-config layer of the resolver
/// in `MinifySettings.resolve`. Keys live under a nested `"lsp"` object
/// so they don't collide with the flat `minifyWhitespace` / etc. fields
/// that drive the CLI minifier.
lsp_minify: MinifySettings.Partial = .{},
/// LSP-only feature toggles. `null` = unset → caller falls back to its
/// own default (today: both default to `true`). Both flow from the
/// `lsp.inlayHints.enabled` / `lsp.diagnostics.enabled` JSON keys, in
/// either `wgslender.json` or the LSP `workspace/configuration` payload.
lsp_inlay_hints_enabled: ?bool = null,
lsp_diagnostics_enabled: ?bool = null,

pub const config_file_names = [_][]const u8{
    "wgslender.json",
    ".wgslenderrc",
    ".wgslenderrc.json",
};

/// Load config from a JSON file.
pub fn loadFile(allocator: Allocator, path: []const u8) !Config {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);

    return parseJson(allocator, content);
}

pub fn parseJson(allocator: Allocator, content: []const u8) !Config {
    var config = Config{};
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    try applyJsonValue(allocator, parsed.value, &config);
    return config;
}

/// Apply a pre-parsed JSON `Value` onto an existing `Config`. Shared by
/// `parseJson` (file path) and the LSP `workspace/configuration` handler
/// (wire path) so the on-disk schema and the LSP wire schema are
/// literally the same shape — set a key in `wgslender.json` and you can
/// also set the same key in your editor's LSP settings, with identical
/// semantics.
///
/// Existing string-slice fields on `target` are NOT freed before being
/// overwritten — callers that hand in a non-empty Config (e.g. the LSP
/// replacing its workspace overlay) must call `target.deinit` first to
/// avoid leaking the previous values.
pub fn applyJsonValue(allocator: Allocator, root: std.json.Value, target: *Config) !void {
    if (root != .object) return;

    // Spec-driven parse for every option declared in `options.config_specs`,
    // including the lint accumulators (`extends`, `rules`) which used to be
    // hand-parsed below this call. The `lsp` nested object stays separate
    // because it walks two distinct spec tables (MinifySettings.partial_specs
    // and lsp_toggle_specs) against the inner object as root.
    try options.applyJson(allocator, &options.config_specs, root, target);

    if (root.object.get("lsp")) |lsp| {
        if (lsp == .object) {
            // Spec-driven nested-object parse. `partial_specs` lives next
            // to `MinifySettings.Partial`; `lsp_toggle_specs` covers the
            // Config-level feature toggles. Dotted `json_override` paths
            // (`minifyInsights.format`, `inlayHints.enabled`, ...) walk
            // into the object via `options.lookupDotted`.
            try options.applyJson(allocator, &MinifySettings.partial_specs, lsp, &target.lsp_minify);
            try options.applyJson(allocator, &options.lsp_toggle_specs, lsp, target);
        }
    }
}

/// Free everything `parseJson` / `applyJsonValue` dup'd into `allocator`.
/// Tests / CLI use an arena per call, so they don't need this; the LSP
/// keeps `Config` values around for the session and replaces them on
/// every `workspace/configuration` push, so it must free the previous
/// strings before overwriting them.
pub fn deinit(self: *Config, allocator: Allocator) void {
    for (self.keep_names) |s| allocator.free(s);
    if (self.keep_names.len > 0) allocator.free(self.keep_names);
    for (self.lint_extends) |s| allocator.free(s);
    if (self.lint_extends.len > 0) allocator.free(self.lint_extends);
    for (self.lint_rules) |r| {
        allocator.free(r.id);
        if (r.options) |opts| {
            var o = opts;
            options.freeJsonValue(allocator, &o);
        }
    }
    if (self.lint_rules.len > 0) allocator.free(self.lint_rules);
    self.* = .{};
}

/// Search for a config file starting from `start_dir`, walking up to parent directories.
/// Returns null if no config file is found. Uses `std.Io.Dir` for file access.
pub fn discover(allocator: Allocator, io: std.Io, start_dir: ?[]const u8) ?Config {
    const Dir = std.Io.Dir;
    const cwd = Dir.cwd();

    // AT_FDCWD is a sentinel fd that can't be fstat'd, so open a real handle.
    var dir_handle: Dir = if (start_dir) |sd|
        cwd.openDir(io, sd, .{}) catch return null
    else
        cwd.openDir(io, ".", .{}) catch return null;

    var depth: u32 = 0;
    while (depth < 64) : (depth += 1) {
        for (config_file_names) |name| {
            const content = dir_handle.readFileAlloc(io, name, allocator, .unlimited) catch continue;
            dir_handle.close(io);
            return parseJson(allocator, content) catch null;
        }

        const parent = dir_handle.openDir(io, "..", .{}) catch break;
        // Filesystem root has parent inode == self inode.
        const parent_stat = parent.stat(io) catch {
            parent.close(io);
            break;
        };
        const self_stat = dir_handle.stat(io) catch {
            parent.close(io);
            break;
        };
        dir_handle.close(io);
        if (parent_stat.inode == self_stat.inode) {
            parent.close(io);
            break;
        }
        dir_handle = parent;
    } else {
        dir_handle.close(io);
    }

    return null;
}

/// Convert config to minifier options, using defaults for unset fields.
/// Spec-driven: every field on `minifier_options_specs` flows here. The
/// source-map specs and lint specs intentionally don't — they target
/// `CliArgs` / `Linter.Options` rather than `Minifier.Options`.
pub fn toOptions(self: Config) Minifier.Options {
    var opts = Minifier.defaultOptions();
    options.applyDefaults(&options.minifier_options_specs, self, &opts);
    return opts;
}

// =========================================================================
// Tests
// =========================================================================

test "config: parseJson basic" {
    const content =
        \\{
        \\  "minifyWhitespace": false,
        \\  "minifyIdentifiers": true,
        \\  "mangleExternalBindings": true,
        \\  "keepNames": ["foo", "bar"]
        \\}
    ;
    const cfg = try parseJson(std.testing.allocator, content);
    try std.testing.expectEqual(@as(?bool, false), cfg.minify_whitespace);
    try std.testing.expectEqual(@as(?bool, true), cfg.minify_identifiers);
    try std.testing.expectEqual(@as(?bool, true), cfg.mangle_external_bindings);
    try std.testing.expectEqual(@as(usize, 2), cfg.keep_names.len);
}

test "config: parseJson all fields" {
    const content =
        \\{
        \\  "minifyWhitespace": true,
        \\  "minifyIdentifiers": false,
        \\  "minifySyntax": true,
        \\  "mangleExternalBindings": true,
        \\  "treeShaking": false,
        \\  "preserveUniformStructTypes": true,
        \\  "keepNames": ["name1"],
        \\  "sourceMap": true,
        \\  "sourceMapInline": true,
        \\  "sourceMapSources": false
        \\}
    ;
    const cfg = try parseJson(std.testing.allocator, content);
    try std.testing.expectEqual(@as(?bool, true), cfg.minify_whitespace);
    try std.testing.expectEqual(@as(?bool, false), cfg.minify_identifiers);
    try std.testing.expectEqual(@as(?bool, true), cfg.minify_syntax);
    try std.testing.expectEqual(@as(?bool, true), cfg.mangle_external_bindings);
    try std.testing.expectEqual(@as(?bool, false), cfg.tree_shaking);
    try std.testing.expectEqual(@as(?bool, true), cfg.preserve_uniform_struct_types);
    try std.testing.expectEqual(@as(usize, 1), cfg.keep_names.len);
    try std.testing.expectEqual(@as(?bool, true), cfg.source_map);
    try std.testing.expectEqual(@as(?bool, true), cfg.source_map_inline);
    try std.testing.expectEqual(@as(?bool, false), cfg.source_map_sources);
}

test "config: parseJson empty" {
    const cfg = try parseJson(std.testing.allocator, "{}");
    try std.testing.expectEqual(@as(?bool, null), cfg.minify_whitespace);
    try std.testing.expectEqual(@as(?bool, null), cfg.minify_identifiers);
    try std.testing.expectEqual(@as(?bool, null), cfg.minify_syntax);
    try std.testing.expectEqual(@as(usize, 0), cfg.keep_names.len);
}

test "config: parseJson invalid json" {
    const result = parseJson(std.testing.allocator, "not valid json");
    try std.testing.expect(result == error.SyntaxError or result == error.UnexpectedCharacter);
}

test "config: toOptions defaults" {
    const cfg = Config{};
    const opts = cfg.toOptions();
    try std.testing.expectEqual(true, opts.minify_whitespace);
    try std.testing.expectEqual(true, opts.minify_identifiers);
    try std.testing.expectEqual(true, opts.minify_syntax);
    try std.testing.expectEqual(false, opts.mangle_external_bindings);
    try std.testing.expectEqual(true, opts.tree_shaking);
    try std.testing.expectEqual(false, opts.preserve_uniform_struct_types);
    try std.testing.expectEqual(@as(usize, 0), opts.keep_names.len);
}

test "config: toOptions with overrides" {
    const cfg = Config{
        .minify_whitespace = false,
        .minify_identifiers = true,
        .mangle_external_bindings = true,
    };
    const opts = cfg.toOptions();
    try std.testing.expectEqual(false, opts.minify_whitespace);
    try std.testing.expectEqual(true, opts.minify_identifiers);
    try std.testing.expectEqual(true, opts.mangle_external_bindings);
    // Unset fields should use defaults
    try std.testing.expectEqual(true, opts.minify_syntax);
}

test "config: parseJson non-object root" {
    const cfg = try parseJson(std.testing.allocator, "[]");
    try std.testing.expectEqual(@as(?bool, null), cfg.minify_whitespace);
}

test "config: parseJson wrong types ignored" {
    const content =
        \\{
        \\  "minifyWhitespace": "string_not_bool",
        \\  "minifyIdentifiers": 42,
        \\  "keepNames": "not_array"
        \\}
    ;
    const cfg = try parseJson(std.testing.allocator, content);
    try std.testing.expectEqual(@as(?bool, null), cfg.minify_whitespace);
    try std.testing.expectEqual(@as(?bool, null), cfg.minify_identifiers);
    try std.testing.expectEqual(@as(usize, 0), cfg.keep_names.len);
}

test "config: parseJson keepNames values" {
    const content =
        \\{
        \\  "keepNames": ["foo", "bar"]
        \\}
    ;
    const cfg = try parseJson(std.testing.allocator, content);
    try std.testing.expectEqual(@as(usize, 2), cfg.keep_names.len);
    try std.testing.expectEqualStrings("foo", cfg.keep_names[0]);
    try std.testing.expectEqualStrings("bar", cfg.keep_names[1]);
}

test "config: toOptions all fields set" {
    const cfg = Config{
        .minify_whitespace = true,
        .minify_identifiers = false,
        .minify_syntax = true,
        .mangle_external_bindings = true,
        .tree_shaking = false,
        .preserve_uniform_struct_types = true,
        .keep_names = &.{ "name1", "name2" },
    };
    const opts = cfg.toOptions();
    try std.testing.expectEqual(true, opts.minify_whitespace);
    try std.testing.expectEqual(false, opts.minify_identifiers);
    try std.testing.expectEqual(true, opts.minify_syntax);
    try std.testing.expectEqual(true, opts.mangle_external_bindings);
    try std.testing.expectEqual(false, opts.tree_shaking);
    try std.testing.expectEqual(true, opts.preserve_uniform_struct_types);
    try std.testing.expectEqual(@as(usize, 2), opts.keep_names.len);
    try std.testing.expectEqualStrings("name1", opts.keep_names[0]);
    try std.testing.expectEqualStrings("name2", opts.keep_names[1]);
}

test "config: parseJson empty array root" {
    // An array root (not object) should return default config
    const cfg = try parseJson(std.testing.allocator, "[1, 2, 3]");
    try std.testing.expectEqual(@as(?bool, null), cfg.minify_whitespace);
    try std.testing.expectEqual(@as(?bool, null), cfg.minify_identifiers);
    try std.testing.expectEqual(@as(usize, 0), cfg.keep_names.len);
}

test "config: parseJson keepNames with mixed types" {
    // Non-string items in keepNames array should be ignored
    const content =
        \\{
        \\  "keepNames": ["valid", 42, "also_valid", true]
        \\}
    ;
    const cfg = try parseJson(std.testing.allocator, content);
    try std.testing.expectEqual(@as(usize, 2), cfg.keep_names.len);
    try std.testing.expectEqualStrings("valid", cfg.keep_names[0]);
    try std.testing.expectEqualStrings("also_valid", cfg.keep_names[1]);
}

test "config: toOptions keep_names passthrough" {
    const cfg = Config{
        .keep_names = &.{"keep1"},
    };
    const opts = cfg.toOptions();
    try std.testing.expectEqual(@as(usize, 1), opts.keep_names.len);
    try std.testing.expectEqualStrings("keep1", opts.keep_names[0]);
}

test "config: parseJson keepNames strings are independent copies" {
    // Verify that keep_names strings are owned copies, not borrowed
    // from the JSON parse tree (which is freed inside parseJson).
    // Use an ArenaAllocator so all memory is cleanly freed — no leaks.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const content =
        \\{
        \\  "keepNames": ["myUniform", "lightPos"]
        \\}
    ;
    const cfg = try parseJson(alloc, content);

    // Strings must be valid and readable after parseJson returns
    // (the JSON parse tree was freed by defer parsed.deinit() inside parseJson).
    try std.testing.expectEqual(@as(usize, 2), cfg.keep_names.len);
    try std.testing.expectEqualStrings("myUniform", cfg.keep_names[0]);
    try std.testing.expectEqualStrings("lightPos", cfg.keep_names[1]);

    // Verify strings are not zero-length (would indicate a broken dupe)
    try std.testing.expect(cfg.keep_names[0].len == 9);
    try std.testing.expect(cfg.keep_names[1].len == 8);
}

test "config: parseJson source map fields" {
    const content =
        \\{
        \\  "sourceMap": true,
        \\  "sourceMapInline": false,
        \\  "sourceMapSources": false
        \\}
    ;
    const cfg = try parseJson(std.testing.allocator, content);
    try std.testing.expectEqual(@as(?bool, true), cfg.source_map);
    try std.testing.expectEqual(@as(?bool, false), cfg.source_map_inline);
    try std.testing.expectEqual(@as(?bool, false), cfg.source_map_sources);
}

test "config: parseJson lint extends + rules + reportUnusedDisableDirectives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const content =
        \\{
        \\  "extends": ["@wgslender/recommended", "@wgslender/strict"],
        \\  "rules": {
        \\    "no-unused-vars": "error",
        \\    "no-magic-numbers": "off",
        \\    "max-params": ["warn", { "max": 4 }],
        \\    "bogus-not-a-severity": "loud"
        \\  },
        \\  "reportUnusedDisableDirectives": true
        \\}
    ;
    const cfg = try parseJson(alloc, content);

    try std.testing.expectEqual(@as(usize, 2), cfg.lint_extends.len);
    try std.testing.expectEqualStrings("@wgslender/recommended", cfg.lint_extends[0]);
    try std.testing.expectEqualStrings("@wgslender/strict", cfg.lint_extends[1]);

    // Three valid entries; the bogus severity drops out.
    try std.testing.expectEqual(@as(usize, 3), cfg.lint_rules.len);

    // Severities must round-trip correctly.
    var saw_unused = false;
    var saw_magic = false;
    var saw_params = false;
    for (cfg.lint_rules) |r| {
        if (std.mem.eql(u8, r.id, "no-unused-vars")) {
            try std.testing.expectEqual(Diagnostic.Severity.@"error", r.severity);
            saw_unused = true;
        } else if (std.mem.eql(u8, r.id, "no-magic-numbers")) {
            try std.testing.expectEqual(Diagnostic.Severity.disabled, r.severity);
            saw_magic = true;
        } else if (std.mem.eql(u8, r.id, "max-params")) {
            try std.testing.expectEqual(Diagnostic.Severity.warning, r.severity);
            saw_params = true;
        }
    }
    try std.testing.expect(saw_unused and saw_magic and saw_params);
    try std.testing.expectEqual(@as(?bool, true), cfg.report_unused_disable_directives);
}

test "config: parseJson lint keys absent → defaults" {
    const cfg = try parseJson(std.testing.allocator, "{}");
    try std.testing.expectEqual(@as(usize, 0), cfg.lint_extends.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.lint_rules.len);
    try std.testing.expectEqual(@as(?bool, null), cfg.report_unused_disable_directives);
}

test "config: parseJson lsp section populates lsp_minify partial" {
    const content =
        \\{
        \\  "lsp": {
        \\    "minifyMode": "strict",
        \\    "minifyInsights": { "format": "bytes", "functionSize": false, "declSize": true, "totalSize": true },
        \\    "minifyLints": { "enabled": true, "budgetBytes": 4096 },
        \\    "minifyEstimator": { "useFullMinify": true },
        \\    "inlayHints": { "enabled": false },
        \\    "diagnostics": { "enabled": false }
        \\  }
        \\}
    ;
    const cfg = try parseJson(std.testing.allocator, content);
    try std.testing.expectEqual(MinifySettings.Mode.strict, cfg.lsp_minify.mode.?);
    try std.testing.expectEqual(MinifySettings.InsightsFormat.bytes, cfg.lsp_minify.format.?);
    try std.testing.expectEqual(false, cfg.lsp_minify.function_size.?);
    try std.testing.expectEqual(true, cfg.lsp_minify.decl_size.?);
    try std.testing.expectEqual(true, cfg.lsp_minify.total_size.?);
    try std.testing.expectEqual(true, cfg.lsp_minify.lints_enabled.?);
    try std.testing.expectEqual(@as(?u32, 4096), cfg.lsp_minify.budget_bytes);
    try std.testing.expectEqual(true, cfg.lsp_minify.use_full_minify.?);
    try std.testing.expectEqual(false, cfg.lsp_inlay_hints_enabled.?);
    try std.testing.expectEqual(false, cfg.lsp_diagnostics_enabled.?);
}

test "config: top-level mangleExternalBindings parses (no lsp.* equivalent)" {
    const cfg = try parseJson(std.testing.allocator, "{\"mangleExternalBindings\": true}");
    try std.testing.expectEqual(@as(?bool, true), cfg.mangle_external_bindings);
}

test "config: parseJson lsp section absent → empty partial" {
    const cfg = try parseJson(std.testing.allocator, "{}");
    try std.testing.expectEqual(@as(?MinifySettings.Mode, null), cfg.lsp_minify.mode);
    try std.testing.expectEqual(@as(?bool, null), cfg.lsp_minify.lints_enabled);
    try std.testing.expectEqual(@as(?bool, null), cfg.lsp_minify.use_full_minify);
    try std.testing.expectEqual(@as(?bool, null), cfg.lsp_inlay_hints_enabled);
    try std.testing.expectEqual(@as(?bool, null), cfg.lsp_diagnostics_enabled);
}

test "config: applyJsonValue is idempotent merge over existing config" {
    const alloc = std.testing.allocator;

    var cfg: Config = .{};
    defer cfg.deinit(alloc);

    // First push: project layer.
    var first = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{ "lsp": { "minifyMode": "insights" }, "minifyWhitespace": false }
    , .{});
    defer first.deinit();
    try applyJsonValue(alloc, first.value, &cfg);
    try std.testing.expectEqual(MinifySettings.Mode.insights, cfg.lsp_minify.mode.?);
    try std.testing.expectEqual(@as(?bool, false), cfg.minify_whitespace);

    // Second push: only changes minify mode; minifyWhitespace stays.
    var second = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{ "lsp": { "minifyMode": "strict" } }
    , .{});
    defer second.deinit();
    try applyJsonValue(alloc, second.value, &cfg);
    try std.testing.expectEqual(MinifySettings.Mode.strict, cfg.lsp_minify.mode.?);
    try std.testing.expectEqual(@as(?bool, false), cfg.minify_whitespace);
}

test "config: deinit frees dup'd strings without leaking" {
    const alloc = std.testing.allocator;

    var cfg = try parseJson(alloc,
        \\{
        \\  "keepNames": ["a", "b"],
        \\  "extends": ["@wgslender/recommended"],
        \\  "rules": { "no-unused-vars": "error" }
        \\}
    );
    cfg.deinit(alloc);
    // No leak assertion needed — std.testing.allocator panics on leak.
    try std.testing.expectEqual(@as(usize, 0), cfg.keep_names.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.lint_extends.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.lint_rules.len);
}
