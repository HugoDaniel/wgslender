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
    // surfaces here as a build error.
    options.assertSpecFieldsExist(Config, &options.config_specs);
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
source_map_sources: ?bool = null,
/// Lint shareable-config inheritance list (`extends` JSON key). Empty
/// means "no inherited packs". Parsed only as id strings; unknown packs
/// are silently ignored by the Linter at run time.
lint_extends: []const []const u8 = &.{},
/// Per-rule severity overrides (`rules` JSON key). Each entry maps a
/// public rule id to a severity. Per-rule options objects (e.g.
/// `{"max":4}` for max-params) are not yet plumbed through this path —
/// only severity is captured, matching the existing FFI surface in
/// `api_json.parseLintConfig`.
lint_rules: []const Linter.Options.RuleOverride = &.{},
/// `reportUnusedDisableDirectives` JSON key. `null` means unset →
/// caller falls back to its own default (CLI: false; LSP/FFI: false).
report_unused_disable_directives: ?bool = null,
/// LSP-only minifier-mode settings. Project-config layer of the resolver
/// in `MinifySettings.resolve`. Keys live under a nested `"lsp"` object
/// so they don't collide with the flat `minifyWhitespace` / etc. fields
/// that drive the CLI minifier.
lsp_minify: MinifySettings.Partial = .{},

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
    const root = parsed.value;

    if (root != .object) return config;

    // Spec-driven parse for every bool / string-list option declared in
    // `options.config_specs`. Custom-shape fields below this call —
    // `rules` (severity sub-parser) and `lsp` (nested object) — stay
    // hand-parsed because they don't fit the simple kinds.
    try options.applyJson(allocator, &options.config_specs, root, &config);

    if (root.object.get("rules")) |v| {
        if (v == .object) {
            var list: std.ArrayListUnmanaged(Linter.Options.RuleOverride) = .empty;
            var it = v.object.iterator();
            while (it.next()) |kv| {
                const sev = parseSeverity(kv.value_ptr.*) orelse continue;
                const id = try allocator.dupe(u8, kv.key_ptr.*);
                try list.append(allocator, .{ .id = id, .severity = sev });
            }
            config.lint_rules = list.items;
        }
    }

    if (root.object.get("lsp")) |lsp| {
        if (lsp == .object) parseLspSection(&config.lsp_minify, lsp.object);
    }

    return config;
}

/// Parse an ESLint-style severity value: `"off"`, `"warn"` / `"warning"`,
/// `"error"`, or a `[severity, options]` array (only the first element is
/// inspected — options are dropped, matching `api_json.parseLintConfig`).
fn parseSeverity(value: std.json.Value) ?Diagnostic.Severity {
    const s: []const u8 = switch (value) {
        .string => |str| str,
        .array => |arr| if (arr.items.len > 0 and arr.items[0] == .string) arr.items[0].string else return null,
        else => return null,
    };
    if (std.mem.eql(u8, s, "off")) return .disabled;
    if (std.mem.eql(u8, s, "warn") or std.mem.eql(u8, s, "warning")) return .warning;
    if (std.mem.eql(u8, s, "error")) return .@"error";
    return null;
}

fn parseLspSection(out: *MinifySettings.Partial, lsp: std.json.ObjectMap) void {
    if (lsp.get("minifyMode")) |v| {
        if (v == .string) out.mode = MinifySettings.Mode.fromString(v.string);
    }
    if (lsp.get("minifyInsights")) |v| {
        if (v == .object) {
            const ins = v.object;
            if (ins.get("format")) |f| {
                if (f == .string) out.format = MinifySettings.InsightsFormat.fromString(f.string);
            }
            if (ins.get("functionSize")) |b| {
                if (b == .bool) out.function_size = b.bool;
            }
            if (ins.get("declSize")) |b| {
                if (b == .bool) out.decl_size = b.bool;
            }
            if (ins.get("totalSize")) |b| {
                if (b == .bool) out.total_size = b.bool;
            }
        }
    }
    if (lsp.get("minifyLints")) |v| {
        if (v == .object) {
            if (v.object.get("enabled")) |b| {
                if (b == .bool) out.lints_enabled = b.bool;
            }
            if (v.object.get("budgetBytes")) |b| {
                if (b == .integer and b.integer >= 0) {
                    out.budget_bytes = @intCast(b.integer);
                }
            }
        }
    }
    if (lsp.get("mangleExternalBindings")) |v| {
        if (v == .bool) out.mangle_external_bindings = v.bool;
    }
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
pub fn toOptions(self: Config) Minifier.Options {
    var opts = Minifier.defaultOptions();
    if (self.minify_whitespace) |v| opts.minify_whitespace = v;
    if (self.minify_identifiers) |v| opts.minify_identifiers = v;
    if (self.minify_syntax) |v| opts.minify_syntax = v;
    if (self.mangle_external_bindings) |v| opts.mangle_external_bindings = v;
    if (self.tree_shaking) |v| opts.tree_shaking = v;
    if (self.preserve_uniform_struct_types) |v| opts.preserve_uniform_struct_types = v;
    if (self.keep_names.len > 0) opts.keep_names = self.keep_names;
    if (self.sort_declarations) |v| opts.sort_declarations = v;
    if (self.scope_local_rename) |v| opts.scope_local_rename = v;
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
        \\  "sourceMapSources": false
        \\}
    ;
    const cfg = try parseJson(std.testing.allocator, content);
    try std.testing.expectEqual(@as(?bool, true), cfg.source_map);
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
