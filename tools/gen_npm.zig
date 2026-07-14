//! Generator for the npm package's `configs.js` + `configs.d.ts` mirrors.
//!
//! `npm/wgslender/configs.{js,d.ts}` re-export the built-in lint config packs
//! and the LSP settings schema so JS callers can inspect them without reaching
//! into the Zig source. Historically these were hand-maintained and drifted
//! (the `@wgslender/minify` pack was missing entirely). This tool derives them
//! from the single sources of truth:
//!
//!   * pack tables      ← `src/lint/configs.zig` (`Configs.all`)
//!   * schema knobs      ← `src/options.zig` (`minifier_options_specs`)
//!
//! Usage — `zig build gen-npm`:
//!   writes both files in place (a side-effecting build step, so it always
//!   re-runs). Output is byte-for-byte reproducible: same Zig tables → same
//!   files. `tests/npm_generated_test.zig` byte-compares the committed files
//!   against this generator's output and fails with "run `zig build gen-npm`"
//!   on drift (the no-CI freshness gate, mirroring the corpus goldens).
//!
//! Scope note: only the parts that mechanically grow with the Zig tables are
//! generated — the pack objects, their `module.exports` / `export const`
//! lines, and the `lspSettingsSchema` minifier-knob leaves. The bespoke
//! `lsp.*` schema subtree, the ESLint-shaped `rules`/`extends` keys, and the
//! `LspSettings` TS interface are stable prose carried verbatim below.

const std = @import("std");
const wgslender = @import("wgslender");
const File = std.Io.File;

const Allocator = std.mem.Allocator;
const Severity = wgslender.Diagnostic.Severity;
const Configs = wgslender.Linter.Configs;
const options = wgslender.OptionsSpec;

const js_out_path = "npm/wgslender/configs.js";
const dts_out_path = "npm/wgslender/configs.d.ts";

/// Strip the `@wgslender/` namespace from a pack name to get its JS export
/// identifier: `@wgslender/recommended` → `recommended`.
fn exportName(pack_name: []const u8) []const u8 {
    const prefix = "@wgslender/";
    return if (std.mem.startsWith(u8, pack_name, prefix)) pack_name[prefix.len..] else pack_name;
}

/// Map a Zig severity to its ESLint config token (the short form the JS
/// mirror and `wgslender.json` use). `.hint` is faithfully mirrored so the
/// advisory `@wgslender/minify` pack round-trips through the JS object.
fn eslintSeverity(sev: Severity) []const u8 {
    return switch (sev) {
        .disabled => "off",
        .warning => "warn",
        .@"error" => "error",
        .hint => "hint",
        .info => "info",
        .note => "note",
    };
}

/// JSON-Schema leaf for one option spec, keyed off its `OptionKind`. Only the
/// kinds that appear in `minifier_options_specs` are handled; a new kind there
/// fails the build here rather than emitting a silently-wrong schema.
fn schemaLeaf(comptime spec: options.OptionSpec) []const u8 {
    return switch (spec.kind) {
        .bool_opt => "{ type: 'boolean' }",
        .string_list, .string_accum => "{ type: 'array', items: { type: 'string' } }",
        .u32_opt, .i32_opt => "{ type: 'integer' }",
        else => @compileError("gen_npm: no schema leaf for OptionKind ." ++ @tagName(spec.kind)),
    };
}

/// Render the full contents of `npm/wgslender/configs.js`.
pub fn emitConfigsJs(alloc: Allocator) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const w = &out;

    try w.appendSlice(alloc, js_header);

    // Pack objects, in `Configs.all` order.
    for (Configs.all) |cfg| {
        try w.appendSlice(alloc, "/** @type {{name: string, rules: Record<string, string>}} */\n");
        try w.appendSlice(alloc, try std.fmt.allocPrint(alloc, "const {s} = {{\n", .{exportName(cfg.name)}));
        try w.appendSlice(alloc, try std.fmt.allocPrint(alloc, "  name: '{s}',\n", .{cfg.name}));
        try w.appendSlice(alloc, "  rules: {\n");
        for (cfg.rules) |r| {
            try w.appendSlice(alloc, try std.fmt.allocPrint(alloc, "    '{s}': '{s}',\n", .{ r.id, eslintSeverity(r.severity) }));
        }
        try w.appendSlice(alloc, "  },\n};\n\n");
    }

    // LSP settings schema: bespoke prose up to the minifier-knob leaves...
    try w.appendSlice(alloc, js_schema_pre);
    // ...generated leaves (one per minifier option spec)...
    inline for (options.minifier_options_specs) |spec| {
        try w.appendSlice(alloc, try std.fmt.allocPrint(alloc, "    {s}: {s},\n", .{ options.jsonKey(spec), schemaLeaf(spec) }));
    }
    // ...then the closing braces.
    try w.appendSlice(alloc, js_schema_post);

    // module.exports, in `Configs.all` order + the schema.
    try w.appendSlice(alloc, "module.exports = {\n");
    for (Configs.all) |cfg| {
        try w.appendSlice(alloc, try std.fmt.allocPrint(alloc, "  {s},\n", .{exportName(cfg.name)}));
    }
    try w.appendSlice(alloc, "  lspSettingsSchema,\n};\n");

    return out.items;
}

/// Render the full contents of `npm/wgslender/configs.d.ts`.
pub fn emitConfigsDts(alloc: Allocator) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const w = &out;

    try w.appendSlice(alloc, dts_header);

    // One `export const <name>: SharedConfig;` per pack, in `Configs.all` order.
    for (Configs.all) |cfg| {
        try w.appendSlice(alloc, try std.fmt.allocPrint(alloc, "export const {s}: SharedConfig;\n", .{exportName(cfg.name)}));
    }

    try w.appendSlice(alloc, dts_body);
    return out.items;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const js = try emitConfigsJs(arena);
    const dts = try emitConfigsDts(arena);
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = js_out_path, .data = js });
    try cwd.writeFile(io, .{ .sub_path = dts_out_path, .data = dts });

    try File.stderr().writeStreamingAll(io, try std.fmt.allocPrint(arena,
        "gen-npm: wrote {s} ({d} bytes) and {s} ({d} bytes) from {d} config packs\n",
        .{ js_out_path, js.len, dts_out_path, dts.len, Configs.all.len }));
}

// ===========================================================================
// Prose templates — carried verbatim into the generated files. Kept as raw
// string literals so the freshness test locks them; edit here (not the .js /
// .d.ts) and re-run `zig build gen-npm`.
// ===========================================================================

const js_header =
    \\/**
    \\ * Shareable lint configs for wgslender.
    \\ *
    \\ * GENERATED FILE — do not edit by hand. Regenerate with `zig build gen-npm`
    \\ * (see tools/gen_npm.zig). The pack tables mirror src/lint/configs.zig and
    \\ * the lspSettingsSchema minifier knobs mirror src/options.zig, so this
    \\ * package can never silently drift from the Zig source of truth.
    \\ *
    \\ * Usage:
    \\ *   const { recommended } = require('wgslender/configs');
    \\ *   const { lint } = require('wgslender');
    \\ *   await initialize();
    \\ *   const result = lint(source, { extends: [recommended.name] });
    \\ *
    \\ * JS callers can either pass the config name (the WASM backend resolves it)
    \\ * or merge rules client-side before calling `lint`.
    \\ */
    \\
    \\'use strict';
    \\
    \\
;

const js_schema_pre =
    \\/**
    \\ * Shape of the `wgslender.*` settings object the LSP reads. Identical
    \\ * to `wgslender.json`'s schema (one parser serves both, see
    \\ * `src/Config.zig::applyJsonValue`). Documented here so editor
    \\ * configurations (VS Code `contributes.configuration`, CodeMirror
    \\ * lsp-client wrappers) can synthesise UI without reaching into the
    \\ * Zig source.
    \\ *
    \\ * Severity overrides live at the top level under `rules` (id-keyed,
    \\ * ESLint-shape). LSP-only knobs are namespaced under `lsp.*`. Each
    \\ * `workspace/configuration` push replaces the workspace overlay
    \\ * wholesale.
    \\ */
    \\const lspSettingsSchema = Object.freeze({
    \\  type: 'object',
    \\  properties: {
    \\    // LSP-only knobs.
    \\    lsp: {
    \\      type: 'object',
    \\      properties: {
    \\        inlayHints: { type: 'object', properties: { enabled: { type: 'boolean' } } },
    \\        diagnostics: { type: 'object', properties: { enabled: { type: 'boolean' } } },
    \\        minifyMode: { type: 'string', enum: ['off', 'insights', 'strict'] },
    \\        minifyInsights: {
    \\          type: 'object',
    \\          properties: {
    \\            format: { type: 'string', enum: ['delta', 'bytes', 'both'] },
    \\            functionSize: { type: 'boolean' },
    \\            declSize: { type: 'boolean' },
    \\            totalSize: { type: 'boolean' },
    \\          },
    \\        },
    \\        minifyLints: {
    \\          type: 'object',
    \\          properties: {
    \\            enabled: { type: 'boolean' },
    \\            budgetBytes: { type: ['integer', 'null'] },
    \\          },
    \\        },
    \\        minifyEstimator: {
    \\          type: 'object',
    \\          properties: {
    \\            // Phase 8 — opt-in ground-truth estimator. Slower to
    \\            // recompute on every edit (runs the production
    \\            // MinifyRenamer + gzip-of-output), but produces exact
    \\            // byte and gzip counts instead of the cheap length-only
    \\            // heuristic.
    \\            useFullMinify: { type: 'boolean', default: false },
    \\          },
    \\        },
    \\      },
    \\    },
    \\    // Per-rule severity overrides, id-keyed (ESLint-shape).
    \\    rules: {
    \\      type: 'object',
    \\      additionalProperties: {
    \\        type: 'string',
    \\        enum: ['off', 'warn', 'warning', 'error'],
    \\      },
    \\    },
    \\    extends: { type: 'array', items: { type: 'string' } },
    \\    reportUnusedDisableDirectives: { type: 'boolean' },
    \\    // CLI-minifier knobs (also accepted in wgslender.json).
    \\
;

const js_schema_post =
    \\  },
    \\});
    \\
    \\
;

const dts_header =
    \\/**
    \\ * Shareable lint configs. GENERATED FILE — do not edit by hand.
    \\ * Regenerate with `zig build gen-npm` (see tools/gen_npm.zig).
    \\ * Mirrors src/lint/configs.zig.
    \\ */
    \\
    \\export interface SharedConfig {
    \\  name: string;
    \\  rules: Record<string, 'off' | 'warn' | 'error' | 'hint'>;
    \\}
    \\
    \\
;

const dts_body =
    \\
    \\/**
    \\ * Shape of the `wgslender.*` settings object the LSP reads via
    \\ * `workspace/configuration` (or `initializationOptions`). The schema is
    \\ * identical to `wgslender.json` — set a key in the file and the same
    \\ * key works in your editor's LSP settings with identical semantics.
    \\ *
    \\ * Each `workspace/configuration` push replaces the workspace overlay
    \\ * wholesale; clients omitting a key reset it to the project-layer
    \\ * (or default) value. The Zig parser is permissive: unknown keys and
    \\ * wrong types are accepted without effect.
    \\ */
    \\export interface LspSettings {
    \\  /**
    \\   * LSP-only knobs live under this namespace. CLI/file users set
    \\   * these too — they're forwarded into the LSP layer when discovered
    \\   * from `wgslender.json`.
    \\   */
    \\  lsp?: {
    \\    inlayHints?: { enabled?: boolean };
    \\    diagnostics?: { enabled?: boolean };
    \\    minifyMode?: 'off' | 'insights' | 'strict';
    \\    minifyInsights?: {
    \\      format?: 'delta' | 'bytes' | 'both';
    \\      functionSize?: boolean;
    \\      declSize?: boolean;
    \\      totalSize?: boolean;
    \\    };
    \\    minifyLints?: {
    \\      enabled?: boolean;
    \\      /** M0500 budget in bytes; null/missing = rule no-ops. */
    \\      budgetBytes?: number | null;
    \\    };
    \\    /**
    \\     * Phase 8 — opt-in: when true, the LSP runs the heavy full-minify
    \\     * estimator (production renamer + gzip-of-output) for ground-truth
    \\     * byte and gzip counts. Slower to recompute on every edit;
    \\     * defaults to false (the cheap length-only estimator).
    \\     */
    \\    minifyEstimator?: { useFullMinify?: boolean };
    \\  };
    \\  /**
    \\   * Per-rule severity overrides keyed by rule id (e.g.
    \\   * `"minify/external-binding-blocks-rename"`). Same shape as
    \\   * ESLint's `rules` field; same shape as `wgslender.json`'s.
    \\   * Both project (`wgslender.json`) and workspace
    \\   * (`workspace/configuration`) layers contribute; workspace wins.
    \\   */
    \\  rules?: Record<string, 'off' | 'warn' | 'warning' | 'error'>;
    \\  /** Lint pack inheritance, e.g. `["@wgslender/recommended"]`. */
    \\  extends?: string[];
    \\  /**
    \\   * Treat unused `wgslender-disable` comments as warnings. Flows through
    \\   * to the linter via `Linter.Options.report_unused_disable_directives`.
    \\   */
    \\  reportUnusedDisableDirectives?: boolean;
    \\  /**
    \\   * CLI-minifier knobs (also live in `wgslender.json`). The LSP
    \\   * forwards these to the `wgslender.showMinifiedOutput` command and
    \\   * uses them to key the per-document estimator cache, so flipping
    \\   * any of them invalidates the displayed insights.
    \\   */
    \\  minifyWhitespace?: boolean;
    \\  minifyIdentifiers?: boolean;
    \\  minifySyntax?: boolean;
    \\  treeShaking?: boolean;
    \\  preserveUniformStructTypes?: boolean;
    \\  /**
    \\   * Rename `@group/@binding` vars directly. Same field drives both the
    \\   * minifier output and the LSP M0100 hint gate — to silence the hint
    \\   * without changing minifier behavior, set the rule to `off` via
    \\   * `rules: { "minify/external-binding-blocks-rename": "off" }`.
    \\   */
    \\  mangleExternalBindings?: boolean;
    \\  keepNames?: string[];
    \\  sortDeclarations?: boolean;
    \\  scopeLocalRename?: boolean;
    \\}
    \\
    \\/**
    \\ * JSON Schema-shaped descriptor for `LspSettings`. Editors that build
    \\ * a `package.json` `contributes.configuration` schema from a JS object
    \\ * (or VS Code language-server-protocol clients that synthesize
    \\ * settings UI) can require this to populate dropdowns.
    \\ */
    \\export const lspSettingsSchema: {
    \\  readonly type: 'object';
    \\  readonly properties: Readonly<Record<string, unknown>>;
    \\};
    \\
;

// ===========================================================================
// Tests (pure; no repo files needed — the always-on gate for generator logic).
// ===========================================================================

const testing = std.testing;

test "exportName strips the @wgslender/ namespace" {
    try testing.expectEqualStrings("recommended", exportName("@wgslender/recommended"));
    try testing.expectEqualStrings("minify", exportName("@wgslender/minify"));
    try testing.expectEqualStrings("plain", exportName("plain"));
}

test "eslintSeverity maps every pack severity to its short token" {
    try testing.expectEqualStrings("warn", eslintSeverity(.warning));
    try testing.expectEqualStrings("error", eslintSeverity(.@"error"));
    try testing.expectEqualStrings("hint", eslintSeverity(.hint));
    try testing.expectEqualStrings("off", eslintSeverity(.disabled));
}

test "emitConfigsJs mirrors every pack, including the advisory minify pack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const js = try emitConfigsJs(arena.allocator());

    // Every pack in the Zig table is exported.
    inline for (Configs.all) |cfg| {
        const decl = "const " ++ comptime exportName(cfg.name) ++ " = {";
        try testing.expect(std.mem.indexOf(u8, js, decl) != null);
    }
    // The drift that motivated the generator: the minify pack and its hint
    // severity are present.
    try testing.expect(std.mem.indexOf(u8, js, "'@wgslender/minify'") != null);
    try testing.expect(std.mem.indexOf(u8, js, "'minify/unused-const': 'hint'") != null);
    // Schema minifier knobs come from the option specs (camelCase JSON keys).
    try testing.expect(std.mem.indexOf(u8, js, "scopeLocalRename: { type: 'boolean' },") != null);
    try testing.expect(std.mem.indexOf(u8, js, "keepNames: { type: 'array', items: { type: 'string' } },") != null);
    try testing.expect(std.mem.endsWith(u8, js, "  lspSettingsSchema,\n};\n"));
}

test "emitConfigsDts declares one SharedConfig export per pack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const dts = try emitConfigsDts(arena.allocator());

    inline for (Configs.all) |cfg| {
        const decl = "export const " ++ comptime exportName(cfg.name) ++ ": SharedConfig;";
        try testing.expect(std.mem.indexOf(u8, dts, decl) != null);
    }
    // The union must admit `hint` for the advisory minify pack.
    try testing.expect(std.mem.indexOf(u8, dts, "'off' | 'warn' | 'error' | 'hint'") != null);
}
