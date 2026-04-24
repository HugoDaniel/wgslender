//! CLI entry point for wgslender.
//!
//! Parses command-line arguments and dispatches to the minifier,
//! validator, reflector, or binary shader compiler.

const std = @import("std");
const wgslender = @import("wgslender");

const CliArgs = struct {
    input_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    options: wgslender.Minifier.Options = wgslender.Minifier.defaultOptions(),
    source_map: bool = false,
    source_map_inline: bool = false,
    subcommand: enum { minify, validate, reflect, compile, lint } = .minify,
    validate_format: ValidateFormat = .text,
    strict: bool = false,
    line_offset: i32 = 0,
    compact: bool = false,
    show_help: bool = false,
    lint_options: LintOptions = .{},

    const ValidateFormat = enum { text, json, stylish };

    const LintOptions = struct {
        extends: []const []const u8 = &.{},
        rule_overrides: []const wgslender.Linter.Options.RuleOverride = &.{},
        max_warnings: i32 = -1,
        quiet: bool = false,
        fix: bool = false,
        fix_dry_run: bool = false,
        report_unused_disable_directives: bool = false,
    };
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = parseArgs(arena, init.minimal.args, io) orelse return;

    // Read input
    const source = try readSource(arena, io, args.input_path);

    switch (args.subcommand) {
        .validate => try runValidate(
            arena,
            io,
            source,
            args.validate_format,
            args.strict,
            args.line_offset,
            args.input_path,
        ),
        .reflect => try runReflect(arena, io, source, args.compact),
        .compile => try runCompile(arena, io, source, args.output_path, args.options),
        .lint => try runLint(
            arena,
            io,
            source,
            args.validate_format,
            args.line_offset,
            args.input_path,
            args.lint_options,
        ),
        .minify => try runMinify(
            arena,
            io,
            source,
            args.options,
            args.output_path,
            args.source_map,
            args.source_map_inline,
        ),
    }
}

fn parseArgs(arena: std.mem.Allocator, raw_args: anytype, io: std.Io) ?CliArgs {
    const File = std.Io.File;
    var args = CliArgs{};
    var config_path: ?[]const u8 = null;
    var cli_no_mangle = false;
    var cli_no_tree_shaking = false;
    var no_config = false;
    var cli_minify_all = false;
    var cli_minify_whitespace: ?bool = null;
    var cli_minify_identifiers: ?bool = null;
    var cli_minify_syntax: ?bool = null;
    var source_map_sources = false;
    var keep_names_raw: ?[]const u8 = null;

    var lint_extends: std.ArrayListUnmanaged([]const u8) = .empty;
    var lint_rule_overrides: std.ArrayListUnmanaged(wgslender.Linter.Options.RuleOverride) = .empty;
    var lint_use_recommended = true;

    var args_iter = std.process.Args.Iterator.init(raw_args);
    _ = args_iter.skip(); // skip program name
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "validate")) {
            args.subcommand = .validate;
        } else if (std.mem.eql(u8, arg, "compile")) {
            args.subcommand = .compile;
        } else if (std.mem.eql(u8, arg, "reflect")) {
            args.subcommand = .reflect;
        } else if (std.mem.eql(u8, arg, "lint")) {
            args.subcommand = .lint;
        } else if (std.mem.eql(u8, arg, "--extends")) {
            if (args_iter.next()) |name| {
                lint_extends.append(arena, name) catch return null;
                lint_use_recommended = false;
            }
        } else if (std.mem.eql(u8, arg, "--no-recommended")) {
            lint_use_recommended = false;
        } else if (std.mem.eql(u8, arg, "--rule")) {
            if (args_iter.next()) |spec| {
                const override = parseRuleOverride(spec) orelse {
                    File.stderr().writeStreamingAll(io, "error: invalid --rule syntax (expected id=severity)\n") catch {};
                    return null;
                };
                lint_rule_overrides.append(arena, override) catch return null;
            }
        } else if (std.mem.eql(u8, arg, "--max-warnings")) {
            if (args_iter.next()) |v| args.lint_options.max_warnings = std.fmt.parseInt(i32, v, 10) catch -1;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            args.lint_options.quiet = true;
        } else if (std.mem.eql(u8, arg, "--fix")) {
            args.lint_options.fix = true;
        } else if (std.mem.eql(u8, arg, "--fix-dry-run")) {
            args.lint_options.fix_dry_run = true;
        } else if (std.mem.eql(u8, arg, "--report-unused-disable-directives")) {
            args.lint_options.report_unused_disable_directives = true;
        } else if (std.mem.eql(u8, arg, "-o")) {
            args.output_path = args_iter.next();
        } else if (std.mem.eql(u8, arg, "--config")) {
            config_path = args_iter.next();
        } else if (std.mem.eql(u8, arg, "--no-config")) {
            no_config = true;
        } else if (std.mem.eql(u8, arg, "--no-mangle")) {
            cli_no_mangle = true;
        } else if (std.mem.eql(u8, arg, "--minify")) {
            cli_minify_all = true;
        } else if (std.mem.eql(u8, arg, "--minify-whitespace")) {
            cli_minify_whitespace = true;
        } else if (std.mem.eql(u8, arg, "--minify-identifiers")) {
            cli_minify_identifiers = true;
        } else if (std.mem.eql(u8, arg, "--minify-syntax")) {
            cli_minify_syntax = true;
        } else if (std.mem.eql(u8, arg, "--mangle-external-bindings")) {
            args.options.mangle_external_bindings = true;
        } else if (std.mem.eql(u8, arg, "--no-tree-shaking")) {
            cli_no_tree_shaking = true;
        } else if (std.mem.eql(u8, arg, "--preserve-uniform-struct-types")) {
            args.options.preserve_uniform_struct_types = true;
        } else if (std.mem.eql(u8, arg, "--sort-declarations")) {
            args.options.sort_declarations = true;
        } else if (std.mem.eql(u8, arg, "--scope-local-rename")) {
            args.options.scope_local_rename = true;
        } else if (std.mem.eql(u8, arg, "--source-map")) {
            args.source_map = true;
        } else if (std.mem.eql(u8, arg, "--source-map-inline")) {
            args.source_map_inline = true;
        } else if (std.mem.eql(u8, arg, "--source-map-sources")) {
            source_map_sources = true;
        } else if (std.mem.eql(u8, arg, "--keep-names")) {
            keep_names_raw = args_iter.next();
        } else if (std.mem.eql(u8, arg, "--format")) {
            if (args_iter.next()) |fmt| {
                if (std.mem.eql(u8, fmt, "json")) {
                    args.validate_format = .json;
                } else if (std.mem.eql(u8, fmt, "text")) {
                    args.validate_format = .text;
                } else if (std.mem.eql(u8, fmt, "stylish")) {
                    args.validate_format = .stylish;
                }
            }
        } else if (std.mem.eql(u8, arg, "--strict")) {
            args.strict = true;
        } else if (std.mem.eql(u8, arg, "--line-offset")) {
            if (args_iter.next()) |val| {
                args.line_offset = std.fmt.parseInt(i32, val, 10) catch 0;
            }
        } else if (std.mem.eql(u8, arg, "--compact")) {
            args.compact = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            File.stdout().writeStreamingAll(io, "wgslender v" ++ wgslender.version ++ "\n") catch {};
            return null;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            File.stdout().writeStreamingAll(io, usage_text) catch {};
            return null;
        } else if (arg.len > 0 and arg[0] != '-') {
            args.input_path = arg;
        }
    }

    if (!loadConfig(&args, arena, io, config_path, no_config)) return null;
    applyMinifyOverrides(
        &args.options,
        cli_minify_all,
        cli_minify_whitespace,
        cli_minify_identifiers,
        cli_minify_syntax,
        cli_no_mangle,
        cli_no_tree_shaking,
    );
    if (keep_names_raw) |raw| args.options.keep_names = parseKeepNames(arena, raw) catch return null;
    configureSourceMap(&args, source_map_sources);
    if (args.subcommand == .lint) {
        if (lint_use_recommended and lint_extends.items.len == 0) {
            lint_extends.append(arena, "@wgslender/recommended") catch return null;
        }
        args.lint_options.extends = lint_extends.items;
        args.lint_options.rule_overrides = lint_rule_overrides.items;
    }

    return args;
}

/// Parse a `--rule id=severity` spec. Accepts `off` / `warn` / `error`.
fn parseRuleOverride(spec: []const u8) ?wgslender.Linter.Options.RuleOverride {
    const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return null;
    if (eq == 0 or eq == spec.len - 1) return null;
    const id = spec[0..eq];
    const sev_s = spec[eq + 1 ..];
    const sev: wgslender.Diagnostic.Severity = if (std.mem.eql(u8, sev_s, "off"))
        .disabled
    else if (std.mem.eql(u8, sev_s, "warn") or std.mem.eql(u8, sev_s, "warning"))
        .warning
    else if (std.mem.eql(u8, sev_s, "error"))
        .@"error"
    else
        return null;
    return .{ .id = id, .severity = sev };
}

/// Load config from explicit path or auto-discover from parent directories.
fn loadConfig(
    args: *CliArgs,
    arena: std.mem.Allocator,
    io: std.Io,
    config_path: ?[]const u8,
    no_config: bool,
) bool {
    const File = std.Io.File;
    const Dir = std.Io.Dir;

    if (config_path) |path| {
        const content = Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch {
            File.stderr().writeStreamingAll(io, "error: could not read config file\n") catch {};
            return false;
        };
        const config = wgslender.Config.parseJson(arena, content) catch {
            File.stderr().writeStreamingAll(io, "error: invalid config JSON\n") catch {};
            return false;
        };
        args.options = config.toOptions();
    } else if (!no_config) {
        const start = if (args.input_path) |p| std.fs.path.dirname(p) else null;
        if (wgslender.Config.discover(arena, io, start)) |config| {
            args.options = config.toOptions();
        }
    }
    return true;
}

/// Apply CLI minification flag overrides with correct precedence.
/// Granular flags (--minify-*) disable unspecified passes; --minify forces all on.
fn applyMinifyOverrides(
    options: *wgslender.Minifier.Options,
    cli_minify_all: bool,
    cli_minify_whitespace: ?bool,
    cli_minify_identifiers: ?bool,
    cli_minify_syntax: ?bool,
    cli_no_mangle: bool,
    cli_no_tree_shaking: bool,
) void {
    const has_granular = cli_minify_whitespace != null or
        cli_minify_identifiers != null or cli_minify_syntax != null;
    if (has_granular) {
        options.minify_whitespace = cli_minify_whitespace orelse false;
        options.minify_identifiers = cli_minify_identifiers orelse false;
        options.minify_syntax = cli_minify_syntax orelse false;
    }
    if (cli_minify_all) {
        options.minify_whitespace = true;
        options.minify_identifiers = true;
        options.minify_syntax = true;
    }
    if (cli_no_mangle) options.minify_identifiers = false;
    if (cli_no_tree_shaking) options.tree_shaking = false;
}

fn parseKeepNames(arena: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]const []const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |name| {
        const trimmed = std.mem.trim(u8, name, " ");
        if (trimmed.len > 0) {
            try names.append(arena, trimmed);
        }
    }
    return names.items;
}

fn configureSourceMap(args: *CliArgs, source_map_sources: bool) void {
    const generate = args.source_map or args.source_map_inline;
    if (!generate) return;

    args.options.generate_source_map = true;
    args.options.source_map_options.include_source = source_map_sources;
    if (args.input_path) |path| {
        args.options.source_map_options.source_name = std.fs.path.basename(path);
    }
    if (args.output_path) |path| {
        args.options.source_map_options.file = std.fs.path.basename(path);
    }
}

fn readSource(arena: std.mem.Allocator, io: std.Io, input_path: ?[]const u8) ![:0]const u8 {
    var source_bytes: []u8 = undefined;
    if (input_path) |path| {
        source_bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    } else {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var tmp: [4096]u8 = undefined;
        // Unbounded by design: input length is whatever the user pipes in.
        // Terminates on EOF (n == 0) or stdin read error.
        while (true) {
            const n = std.Io.File.stdin().readStreaming(io, &.{&tmp}) catch break;
            if (n == 0) break;
            try buf.appendSlice(arena, tmp[0..n]);
        }
        source_bytes = buf.items;
    }
    const sb = try arena.alloc(u8, source_bytes.len + 1);
    @memcpy(sb[0..source_bytes.len], source_bytes);
    sb[source_bytes.len] = 0;
    return sb[0..source_bytes.len :0];
}

fn runMinify(arena: std.mem.Allocator, io: std.Io, source: [:0]const u8, options: wgslender.Minifier.Options, output_path: ?[]const u8, ext_source_map: bool, source_map_inline: bool) !void {
    const result = try wgslender.minifyWithOptions(arena, source, options);
    const File = std.Io.File;
    const Dir = std.Io.Dir;

    if (output_path) |path| {
        const file = try Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, result.code);

        // Append inline source map comment
        if (source_map_inline) {
            if (result.source_map) |sm| {
                var comment_buf: std.ArrayListUnmanaged(u8) = .empty;
                try comment_buf.append(arena, '\n');
                try sm.toComment(&comment_buf, arena, true);
                try file.writeStreamingAll(io, comment_buf.items);
            }
        }
    } else {
        try File.stdout().writeStreamingAll(io, result.code);

        // Append inline source map comment to stdout
        if (source_map_inline) {
            if (result.source_map) |sm| {
                var comment_buf: std.ArrayListUnmanaged(u8) = .empty;
                try comment_buf.append(arena, '\n');
                try sm.toComment(&comment_buf, arena, true);
                try File.stdout().writeStreamingAll(io, comment_buf.items);
            }
        }
    }

    // Write external source map file
    if (ext_source_map and !source_map_inline) {
        if (result.source_map) |sm| {
            if (output_path) |path| {
                var map_path_buf: std.ArrayListUnmanaged(u8) = .empty;
                try map_path_buf.appendSlice(arena, path);
                try map_path_buf.appendSlice(arena, ".map");
                const map_path = map_path_buf.items;

                var json_buf: std.ArrayListUnmanaged(u8) = .empty;
                try sm.toJson(&json_buf, arena);

                const map_file = try Dir.cwd().createFile(io, map_path, .{});
                defer map_file.close(io);
                try map_file.writeStreamingAll(io, json_buf.items);

                try File.stderr().writeStreamingAll(io, "Source map: ");
                try File.stderr().writeStreamingAll(io, map_path);
                try File.stderr().writeStreamingAll(io, "\n");
            }
        }
    }

    if (result.errors.len > 0) {
        for (result.errors) |err| {
            try File.stderr().writeStreamingAll(io, "error: ");
            try File.stderr().writeStreamingAll(io, err.message);
            try File.stderr().writeStreamingAll(io, "\n");
        }
    }
}

fn runValidate(
    arena: std.mem.Allocator,
    io: std.Io,
    source: [:0]const u8,
    format: CliArgs.ValidateFormat,
    strict: bool,
    line_offset: i32,
    input_path: ?[]const u8,
) !void {
    var result = try wgslender.validateWithOptions(arena, source, .{
        .strict_mode = strict,
        .line_offset = line_offset,
    });

    const is_valid = if (strict)
        result.valid and result.diagnostics.warningCount() == 0
    else
        result.valid;

    switch (format) {
        .json => try emitValidateJson(arena, io, &result, is_valid),
        .stylish, .text => try emitValidateText(io, &result, is_valid, input_path),
    }

    if (!is_valid) {
        std.process.exit(1);
    }
}

fn emitValidateJson(
    arena: std.mem.Allocator,
    io: std.Io,
    result: *const wgslender.Validator.Result,
    is_valid: bool,
) !void {
    const File = std.Io.File;
    const Diagnostic = wgslender.Diagnostic;
    var json_buf: std.ArrayListUnmanaged(u8) = .empty;
    try json_buf.appendSlice(arena, "{\"valid\":");
    try json_buf.appendSlice(arena, if (is_valid) "true" else "false");
    try json_buf.appendSlice(arena, ",\"diagnostics\":[");
    for (result.diagnostics.diagnostics.items, 0..) |*entry, i| {
        if (i > 0) try json_buf.append(arena, ',');
        try Diagnostic.entryToJson(&json_buf, arena, entry);
    }
    try json_buf.appendSlice(arena, "],\"errorCount\":");
    try Diagnostic.appendInt(&json_buf, arena, result.diagnostics.errorCount());
    try json_buf.appendSlice(arena, ",\"warningCount\":");
    try Diagnostic.appendInt(&json_buf, arena, result.diagnostics.warningCount());
    try json_buf.appendSlice(arena, "}\n");
    try File.stdout().writeStreamingAll(io, json_buf.items);
}

fn emitValidateText(
    io: std.Io,
    result: *const wgslender.Validator.Result,
    is_valid: bool,
    input_path: ?[]const u8,
) !void {
    const File = std.Io.File;
    const file_prefix = input_path orelse "<stdin>";
    for (result.diagnostics.diagnostics.items) |entry| {
        var tmp: [20]u8 = undefined;
        try File.stderr().writeStreamingAll(io, file_prefix);
        try File.stderr().writeStreamingAll(io, ":");
        const line_s = std.fmt.bufPrint(&tmp, "{d}", .{entry.range.start.line}) catch "";
        try File.stderr().writeStreamingAll(io, line_s);
        try File.stderr().writeStreamingAll(io, ":");
        const col_s = std.fmt.bufPrint(&tmp, "{d}", .{entry.range.start.column}) catch "";
        try File.stderr().writeStreamingAll(io, col_s);
        try File.stderr().writeStreamingAll(io, ": ");
        try File.stderr().writeStreamingAll(io, entry.severity.string());
        try File.stderr().writeStreamingAll(io, ": ");
        try File.stderr().writeStreamingAll(io, entry.message);
        if (entry.code.len > 0) {
            try File.stderr().writeStreamingAll(io, " [");
            try File.stderr().writeStreamingAll(io, entry.code);
            try File.stderr().writeStreamingAll(io, "]");
        }
        try File.stderr().writeStreamingAll(io, "\n");
    }

    if (is_valid) {
        try File.stdout().writeStreamingAll(io, "valid\n");
    } else {
        try File.stdout().writeStreamingAll(io, "invalid\n");
    }
}

fn runReflect(arena: std.mem.Allocator, io: std.Io, source: [:0]const u8, compact: bool) !void {
    const File = std.Io.File;

    // Tokenize + parse
    const tokens = try wgslender.Lexer.tokenize(arena, source);
    var parser = try wgslender.Parser.init(arena, source, tokens);
    const module = parser.parse() catch {
        try File.stderr().writeStreamingAll(io, "error: parse failed\n");
        for (parser.errors.items) |err| {
            try File.stderr().writeStreamingAll(io, "  ");
            try File.stderr().writeStreamingAll(io, err.message);
            try File.stderr().writeStreamingAll(io, "\n");
        }
        return;
    };

    // Reflect
    const result = try wgslender.Reflect.reflect(arena, module);

    // Serialize to JSON
    var json_buf: std.ArrayListUnmanaged(u8) = .empty;
    if (compact) {
        try result.toJson(&json_buf, arena);
    } else {
        try result.toJsonPretty(&json_buf, arena);
    }

    try File.stdout().writeStreamingAll(io, json_buf.items);
    try File.stdout().writeStreamingAll(io, "\n");
}

fn runCompile(arena: std.mem.Allocator, io: std.Io, source: [:0]const u8, output_path: ?[]const u8, minify_options: wgslender.Minifier.Options) !void {
    const File = std.Io.File;
    const Dir = std.Io.Dir;

    var result = try wgslender.compile(arena, source, .{
        .minify = true,
        .minify_options = minify_options,
    });
    defer result.deinit(arena);

    if (output_path) |path| {
        const file = try Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, result.wasm);
    } else {
        try File.stdout().writeStreamingAll(io, result.wasm);
    }

    // Print stats to stderr
    var tmp: [64]u8 = undefined;
    try File.stderr().writeStreamingAll(io, "Original: ");
    var s = std.fmt.bufPrint(&tmp, "{d}", .{result.original_size}) catch "";
    try File.stderr().writeStreamingAll(io, s);
    try File.stderr().writeStreamingAll(io, " bytes -> WASM: ");
    s = std.fmt.bufPrint(&tmp, "{d}", .{result.wasm_size}) catch "";
    try File.stderr().writeStreamingAll(io, s);
    try File.stderr().writeStreamingAll(io, " bytes\n");
}

fn runLint(
    arena: std.mem.Allocator,
    io: std.Io,
    source: [:0]const u8,
    format: CliArgs.ValidateFormat,
    line_offset: i32,
    input_path: ?[]const u8,
    lint_opts: CliArgs.LintOptions,
) !void {
    const Diagnostic = wgslender.Diagnostic;
    var result = try wgslender.lint(arena, source, .{
        .extends = lint_opts.extends,
        .rules = lint_opts.rule_overrides,
        .line_offset = line_offset,
        .report_unused_disable_directives = lint_opts.report_unused_disable_directives,
    });
    defer result.deinit(arena);

    if (lint_opts.fix or lint_opts.fix_dry_run) {
        const File = std.Io.File;
        const Dir = std.Io.Dir;
        const fix_result = try wgslender.Linter.Fixer.apply(
            arena,
            source,
            result.lint.diagnostics.items(),
        );
        if (lint_opts.fix_dry_run) {
            try File.stdout().writeStreamingAll(io, fix_result.fixed);
            return;
        }
        // --fix writes to input_path; stdin cannot be rewritten safely.
        if (input_path) |path| {
            const f = try Dir.cwd().createFile(io, path, .{});
            defer f.close(io);
            try f.writeStreamingAll(io, fix_result.fixed);
            try File.stderr().writeStreamingAll(io, "Applied fixes to ");
            try File.stderr().writeStreamingAll(io, path);
            try File.stderr().writeStreamingAll(io, "\n");
            return;
        } else {
            try File.stderr().writeStreamingAll(io, "error: --fix requires a file input; use --fix-dry-run for stdin\n");
            std.process.exit(2);
        }
    }

    // A lint run surfaces three diagnostic streams: parse/validator errors
    // (on `result.analysis.diagnostics`), and lint warnings
    // (on `result.lint.diagnostics`). The CLI merges them so the user
    // sees one unified list ordered by severity.
    var combined: std.ArrayListUnmanaged(Diagnostic.Entry) = .empty;
    for (result.analysis.diagnostics.items()) |d| try combined.append(arena, d);
    for (result.lint.diagnostics.items()) |d| try combined.append(arena, d);

    const analysis_errors: u32 = result.analysis.diagnostics.errorCount();
    const lint_errors: u32 = result.lint.error_count;
    const lint_warnings: u32 = result.lint.warning_count;

    const filtered = if (lint_opts.quiet)
        try filterErrorsOnly(arena, combined.items)
    else
        combined.items;

    const file_prefix = input_path orelse "<stdin>";
    switch (format) {
        .json => try emitJson(arena, io, filtered, analysis_errors, lint_errors, lint_warnings, result.lint.fixable_count, file_prefix),
        .stylish => try emitStylish(arena, io, filtered, file_prefix),
        .text => try emitText(arena, io, filtered, file_prefix),
    }

    // Exit-code policy:
    //   0  — no parse/validator errors AND lint error_count == 0 AND
    //        (--max-warnings unset OR warning_count <= --max-warnings)
    //   1  — any parse/validator error, any lint error, or warnings exceed
    //        --max-warnings threshold
    const exceeds_max_warnings = lint_opts.max_warnings >= 0 and lint_warnings > @as(u32, @intCast(lint_opts.max_warnings));
    if (analysis_errors > 0 or lint_errors > 0 or exceeds_max_warnings) {
        std.process.exit(1);
    }
}

fn filterErrorsOnly(
    arena: std.mem.Allocator,
    entries: []const wgslender.Diagnostic.Entry,
) ![]wgslender.Diagnostic.Entry {
    var out: std.ArrayListUnmanaged(wgslender.Diagnostic.Entry) = .empty;
    for (entries) |e| if (e.severity == .@"error") try out.append(arena, e);
    return out.items;
}

fn emitText(
    arena: std.mem.Allocator,
    io: std.Io,
    entries: []const wgslender.Diagnostic.Entry,
    file_prefix: []const u8,
) !void {
    const File = std.Io.File;
    _ = arena;
    for (entries) |entry| {
        var tmp: [32]u8 = undefined;
        try File.stderr().writeStreamingAll(io, file_prefix);
        try File.stderr().writeStreamingAll(io, ":");
        const ls = std.fmt.bufPrint(&tmp, "{d}", .{entry.range.start.line}) catch "";
        try File.stderr().writeStreamingAll(io, ls);
        try File.stderr().writeStreamingAll(io, ":");
        const cs = std.fmt.bufPrint(&tmp, "{d}", .{entry.range.start.column}) catch "";
        try File.stderr().writeStreamingAll(io, cs);
        try File.stderr().writeStreamingAll(io, ": ");
        try File.stderr().writeStreamingAll(io, entry.severity.string());
        try File.stderr().writeStreamingAll(io, ": ");
        try File.stderr().writeStreamingAll(io, entry.message);
        if (entry.code.len > 0) {
            try File.stderr().writeStreamingAll(io, " [");
            try File.stderr().writeStreamingAll(io, entry.code);
            try File.stderr().writeStreamingAll(io, "]");
        }
        try File.stderr().writeStreamingAll(io, "\n");
    }
}

fn emitStylish(
    arena: std.mem.Allocator,
    io: std.Io,
    entries: []const wgslender.Diagnostic.Entry,
    file_prefix: []const u8,
) !void {
    const File = std.Io.File;
    if (entries.len == 0) return;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(arena, "\n");
    try out.appendSlice(arena, file_prefix);
    try out.appendSlice(arena, "\n");
    for (entries) |entry| {
        var tmp: [32]u8 = undefined;
        try out.appendSlice(arena, "  ");
        const ls = std.fmt.bufPrint(&tmp, "{d}:{d}", .{ entry.range.start.line, entry.range.start.column }) catch "";
        try out.appendSlice(arena, ls);
        // Pad so messages align
        const pad = if (ls.len < 8) 8 - ls.len else 1;
        var i: usize = 0;
        while (i < pad) : (i += 1) try out.append(arena, ' ');
        try out.appendSlice(arena, entry.severity.string());
        try out.appendSlice(arena, "  ");
        try out.appendSlice(arena, entry.message);
        if (entry.code.len > 0) {
            try out.appendSlice(arena, "  ");
            try out.appendSlice(arena, entry.code);
        }
        try out.append(arena, '\n');
    }
    try File.stderr().writeStreamingAll(io, out.items);
}

fn emitJson(
    arena: std.mem.Allocator,
    io: std.Io,
    entries: []const wgslender.Diagnostic.Entry,
    analysis_errors: u32,
    lint_errors: u32,
    lint_warnings: u32,
    fixable_count: u32,
    file_prefix: []const u8,
) !void {
    const Diagnostic = wgslender.Diagnostic;
    const File = std.Io.File;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(arena, "{\"results\":[{\"filePath\":\"");
    try Diagnostic.appendJsonEscaped(&buf, arena, file_prefix);
    try buf.appendSlice(arena, "\",\"diagnostics\":[");
    for (entries, 0..) |*entry, i| {
        if (i > 0) try buf.append(arena, ',');
        try Diagnostic.entryToJson(&buf, arena, entry);
    }
    try buf.appendSlice(arena, "],\"errorCount\":");
    try Diagnostic.appendInt(&buf, arena, lint_errors + analysis_errors);
    try buf.appendSlice(arena, ",\"warningCount\":");
    try Diagnostic.appendInt(&buf, arena, lint_warnings);
    try buf.appendSlice(arena, ",\"fixableCount\":");
    try Diagnostic.appendInt(&buf, arena, fixable_count);
    try buf.appendSlice(arena, "}],\"errorCount\":");
    try Diagnostic.appendInt(&buf, arena, lint_errors + analysis_errors);
    try buf.appendSlice(arena, ",\"warningCount\":");
    try Diagnostic.appendInt(&buf, arena, lint_warnings);
    try buf.appendSlice(arena, ",\"fixableCount\":");
    try Diagnostic.appendInt(&buf, arena, fixable_count);
    try buf.appendSlice(arena, "}\n");
    try File.stdout().writeStreamingAll(io, buf.items);
}

const usage_text =
    \\Usage: wgslender [command] [options] [file.wgsl]
    \\
    \\Commands:
    \\  (default)                        Minify WGSL source
    \\  validate                         Validate WGSL source
    \\  reflect                          Extract bindings, layouts, and entry points as JSON
    \\  compile                          Compile WGSL to a .wasm binary shader
    \\  lint                             Run lint rules and emit diagnostics
    \\
    \\Options:
    \\  -o <path>                        Output file
    \\  --config <path>                  Config file (JSON)
    \\  --no-config                      Ignore config files
    \\  --minify                         Enable all minification (default)
    \\  --minify-whitespace              Only minify whitespace
    \\  --minify-identifiers             Only minify identifiers
    \\  --minify-syntax                  Only minify syntax
    \\  --no-mangle                      Don't rename identifiers
    \\  --mangle-external-bindings       Rename uniform/storage variables
    \\  --no-tree-shaking                Keep all declarations
    \\  --preserve-uniform-struct-types   Keep struct names used in uniforms
    \\  --sort-declarations              Sort declarations by kind for compression
    \\  --scope-local-rename             Per-function canonical naming for compression
    \\  --keep-names <names>             Comma-separated names to preserve
    \\  --source-map                     Generate source map file (.map)
    \\  --source-map-inline              Embed source map as inline data URI
    \\  --source-map-sources             Include original source in source map
    \\  --compact                        Compact JSON output (reflect)
    \\  --format <text|json|stylish>      Output format for validate/lint (default: text)
    \\  --strict                         Treat warnings as errors (validate)
    \\  --line-offset <n>                Add n to reported line numbers (validate/lint)
    \\  --extends <config>               (lint) Inherit rules from a shareable config
    \\                                     (@wgslender/recommended, @wgslender/performance,
    \\                                      @wgslender/portability). Repeatable.
    \\  --no-recommended                 (lint) Do not auto-apply @wgslender/recommended
    \\  --rule <id>=<severity>           (lint) Override a rule (severity: off|warn|error)
    \\  --max-warnings <n>               (lint) Exit non-zero if lint warnings exceed n
    \\  --quiet                          (lint) Show errors only; hide warnings
    \\  --fix                            (lint) Apply autofixes in place (requires a file input)
    \\  --fix-dry-run                    (lint) Print fixed source to stdout without writing
    \\  --report-unused-disable-directives  (lint) Warn on wgslender-disable comments that never match
    \\  --version                        Show version
    \\  -h, --help                       Show this help
    \\
    \\If no input file is given, reads from stdin.
    \\
;
