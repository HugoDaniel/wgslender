//! JSON configuration loading for wgslender.
//!
//! Supports wgslender.json / .wgslenderrc config files.
//! Walks up directory tree to find config.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Minifier = @import("Minifier.zig");
const MinifySettings = @import("MinifySettings.zig");

const Config = @This();

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

    if (root.object.get("minifyWhitespace")) |v| {
        if (v == .bool) config.minify_whitespace = v.bool;
    }
    if (root.object.get("minifyIdentifiers")) |v| {
        if (v == .bool) config.minify_identifiers = v.bool;
    }
    if (root.object.get("minifySyntax")) |v| {
        if (v == .bool) config.minify_syntax = v.bool;
    }
    if (root.object.get("mangleExternalBindings")) |v| {
        if (v == .bool) config.mangle_external_bindings = v.bool;
    }
    if (root.object.get("treeShaking")) |v| {
        if (v == .bool) config.tree_shaking = v.bool;
    }
    if (root.object.get("preserveUniformStructTypes")) |v| {
        if (v == .bool) config.preserve_uniform_struct_types = v.bool;
    }
    if (root.object.get("keepNames")) |v| {
        if (v == .array) {
            var names: std.ArrayListUnmanaged([]const u8) = .empty;
            for (v.array.items) |item| {
                if (item == .string) {
                    try names.append(allocator, try allocator.dupe(u8, item.string));
                }
            }
            config.keep_names = names.items;
        }
    }
    if (root.object.get("sortDeclarations")) |v| {
        if (v == .bool) config.sort_declarations = v.bool;
    }
    if (root.object.get("scopeLocalRename")) |v| {
        if (v == .bool) config.scope_local_rename = v.bool;
    }
    if (root.object.get("sourceMap")) |v| {
        if (v == .bool) config.source_map = v.bool;
    }
    if (root.object.get("sourceMapSources")) |v| {
        if (v == .bool) config.source_map_sources = v.bool;
    }

    if (root.object.get("lsp")) |lsp| {
        if (lsp == .object) parseLspSection(&config.lsp_minify, lsp.object);
    }

    return config;
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
        }
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
