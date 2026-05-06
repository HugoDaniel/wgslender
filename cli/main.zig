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
    source_map_flags: SourceMapFlags = .{},
    subcommand: wgslender.OptionsSpec.Subcommand = .minify,
    validate_options: ValidateOptions = .{},
    reflect_options: ReflectOptions = .{},
    show_help: bool = false,
    lint_options: LintOptions = .{},

    const ValidateFormat = enum { text, json, stylish };

    /// Field names mirror `Config.source_map*` so the spec dispatcher
    /// (`OptionsSpec.matchFlag` against `OptionsSpec.source_map_specs`)
    /// can target this struct directly. `configureSourceMap` reads from
    /// here and folds it into `args.options.source_map_options.*` along
    /// with the basename-derived `source_name` / `file` paths — that
    /// post-step stays hand-rolled because it depends on `input_path` /
    /// `output_path`, not on a single config field.
    const SourceMapFlags = struct {
        source_map: bool = false,
        source_map_inline: bool = false,
        source_map_sources: bool = false,
    };

    /// Targets for the validate-subcommand spec dispatcher arm. `format`
    /// and `line_offset` are also accepted on `lint` (the lint specs
    /// share these two fields and the runLint reader pulls from the same
    /// struct) — `strict` is validate-only, gated by `subcommands` on
    /// the spec entry. Dispatcher writes via `@field(target, spec.field)`.
    const ValidateOptions = struct {
        format: ValidateFormat = .text,
        strict: bool = false,
        line_offset: i32 = 0,
    };

    /// Targets for the reflect-subcommand spec dispatcher arm. Both
    /// fields are reflect-only (the spec entries pin `subcommands` to
    /// `.reflect`), so other subcommands that mention `--compact` /
    /// `--reflect-format` get a wrong-subcommand warning.
    const ReflectOptions = struct {
        compact: bool = false,
        reflect_format: wgslender.Reflect.JsonVersion = .v2,
    };

    /// Field names mirror `Config.lint_extends` / `Config.lint_rules` so
    /// the spec dispatcher (`OptionsSpec.matchFlag` against
    /// `OptionsSpec.lint_specs`) can target this struct directly via
    /// `@field(target, spec.field)`. The downstream `runLint` translator
    /// peels them back into the `extends` / `rules` keys on
    /// `Linter.Options`. `max_warnings` is `?u32` (null = unlimited)
    /// to fit the spec system's `u32_opt` kind cleanly — replaces the
    /// historical `i32 = -1` sentinel.
    const LintOptions = struct {
        lint_extends: []const []const u8 = &.{},
        lint_rules: []const wgslender.Linter.Options.RuleOverride = &.{},
        max_warnings: ?u32 = null,
        quiet: bool = false,
        fix: bool = false,
        fix_dry_run: bool = false,
        report_unused_disable_directives: bool = false,
    };
};

/// CLI-only spec tables. Shape mirrors the JSON-side spec tables in
/// `src/options.zig` (which drive `wgslender.json` parsing), but these
/// flags don't appear in the JSON config — they're per-invocation CLI
/// modifiers. Empty `summary` opts a spec out of `printHelp`; populated
/// summaries flow into `--help` automatically.
const cli_validate_specs = [_]wgslender.OptionsSpec.OptionSpec{
    .{ .field = "format", .kind = .{ .enum_opt = CliArgs.ValidateFormat }, .cli_takes_value = true, .subcommands = &[_]wgslender.OptionsSpec.Subcommand{ .validate, .lint }, .summary = "Output format: text|json|stylish (default: text)" },
    .{ .field = "strict", .kind = .bool_opt, .subcommands = &[_]wgslender.OptionsSpec.Subcommand{.validate}, .summary = "(validate) Treat warnings as errors" },
    .{ .field = "line_offset", .kind = .i32_opt, .cli_takes_value = true, .subcommands = &[_]wgslender.OptionsSpec.Subcommand{ .validate, .lint }, .summary = "Add n to reported line numbers" },
};

const cli_reflect_specs = [_]wgslender.OptionsSpec.OptionSpec{
    .{ .field = "compact", .kind = .bool_opt, .subcommands = &[_]wgslender.OptionsSpec.Subcommand{.reflect}, .summary = "Compact JSON output" },
    .{ .field = "reflect_format", .kind = .{ .enum_opt = wgslender.Reflect.JsonVersion }, .cli_takes_value = true, .subcommands = &[_]wgslender.OptionsSpec.Subcommand{.reflect}, .summary = "Reflect JSON schema: v1|v2 (default: v2)" },
};

/// CLI-only lint flags that don't have a JSON shape. The accumulators
/// (`lint_extends`, `lint_rules`) and `report_unused_disable_directives`
/// stay in `OptionsSpec.lint_specs` because they share their target
/// shape with `Config`. Everything here writes to `LintOptions`.
const cli_lint_extra_specs = [_]wgslender.OptionsSpec.OptionSpec{
    .{ .field = "max_warnings", .kind = .u32_opt, .cli_takes_value = true, .subcommands = &[_]wgslender.OptionsSpec.Subcommand{.lint}, .summary = "Exit non-zero if lint warnings exceed n" },
    .{ .field = "quiet", .kind = .bool_opt, .subcommands = &[_]wgslender.OptionsSpec.Subcommand{.lint}, .summary = "Show errors only; hide warnings" },
    .{ .field = "fix", .kind = .bool_opt, .subcommands = &[_]wgslender.OptionsSpec.Subcommand{.lint}, .summary = "Apply autofixes in place (requires a file input)" },
    .{ .field = "fix_dry_run", .kind = .bool_opt, .subcommands = &[_]wgslender.OptionsSpec.Subcommand{.lint}, .summary = "Print fixed source to stdout without writing" },
};

comptime {
    // Drift guards: every dispatcher arm's target struct must declare each
    // spec field. Catches renames / removals at build time.
    wgslender.OptionsSpec.assertSpecFieldsExist(
        CliArgs.SourceMapFlags,
        &wgslender.OptionsSpec.source_map_specs,
    );
    wgslender.OptionsSpec.assertSpecFieldsExist(CliArgs.ValidateOptions, &cli_validate_specs);
    wgslender.OptionsSpec.assertSpecFieldsExist(CliArgs.ReflectOptions, &cli_reflect_specs);
    wgslender.OptionsSpec.assertSpecFieldsExist(CliArgs.LintOptions, &cli_lint_extra_specs);
}

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
            args.validate_options.format,
            args.validate_options.strict,
            args.validate_options.line_offset,
            args.input_path,
        ),
        .reflect => try runReflect(arena, io, source, args.output_path, args.reflect_options.compact, args.reflect_options.reflect_format),
        .compile => try runCompile(arena, io, source, args.output_path, args.options),
        .lint => try runLint(
            arena,
            io,
            source,
            args.validate_options.format,
            args.validate_options.line_offset,
            args.input_path,
            args.lint_options,
        ),
        .minify => try runMinify(
            arena,
            io,
            source,
            args.options,
            args.output_path,
            args.source_map_flags.source_map,
            args.source_map_flags.source_map_inline,
        ),
    }
}

/// Tracks which flag *categories* the user passed, so we can warn when a
/// flag is ignored by the chosen subcommand. Spec-driven flags emit
/// per-flag warnings via `OptionsSpec.matchFlag`'s `wrong_subcommand`
/// result; the `*_cluster` / `*_flag` fields here cover the multi-flag
/// categories where one consolidated message reads better than N
/// individual ones (minify cluster, source-map suite, lint accumulators).
const Passed = struct {
    minify_cluster: bool = false,
    source_map_flag: bool = false,
    output_path: bool = false,
    config_flag: bool = false,
    lint_flag: bool = false,
};

fn parseArgs(arena: std.mem.Allocator, raw_args: anytype, io: std.Io) ?CliArgs {
    const File = std.Io.File;
    var args = CliArgs{};
    var config_path: ?[]const u8 = null;
    var cli_no_mangle = false;
    var cli_no_whitespace = false;
    var cli_no_syntax = false;
    var no_config = false;
    var cli_minify_all = false;
    var cli_minify_whitespace: ?bool = null;
    var cli_minify_identifiers: ?bool = null;
    var cli_minify_syntax: ?bool = null;
    var passed: Passed = .{};

    // CLI-side accumulators for `--extends` / `--rule` live on
    // `args.lint_options` directly — the spec dispatcher writes there via
    // `OptionsSpec.matchFlag`. `lint_use_recommended` stays a local: it
    // tracks the negative `--no-recommended` flag (no JSON / spec
    // equivalent — auto-recommended is a CLI-only convenience), used by
    // the merge step below to decide whether to seed the empty extends
    // list with `@wgslender/recommended`.
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
        } else if (std.mem.eql(u8, arg, "--no-recommended")) {
            // CLI-only meta-flag: suppresses the "if no extends supplied,
            // auto-add @wgslender/recommended" default. Stays hand-rolled
            // because it has no JSON shape and no spec entry.
            passed.lint_flag = true;
            lint_use_recommended = false;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            passed.output_path = true;
            args.output_path = args_iter.next() orelse warnMissingValue(io, arg);
        } else if (std.mem.eql(u8, arg, "--config")) {
            passed.config_flag = true;
            config_path = args_iter.next() orelse warnMissingValue(io, arg);
        } else if (std.mem.eql(u8, arg, "--no-config")) {
            passed.config_flag = true;
            no_config = true;
        } else if (std.mem.eql(u8, arg, "--no-mangle")) {
            passed.minify_cluster = true;
            cli_no_mangle = true;
        } else if (std.mem.eql(u8, arg, "--no-whitespace")) {
            passed.minify_cluster = true;
            cli_no_whitespace = true;
        } else if (std.mem.eql(u8, arg, "--no-syntax")) {
            passed.minify_cluster = true;
            cli_no_syntax = true;
        } else if (std.mem.eql(u8, arg, "--minify")) {
            passed.minify_cluster = true;
            cli_minify_all = true;
        } else if (std.mem.eql(u8, arg, "--minify-whitespace")) {
            passed.minify_cluster = true;
            cli_minify_whitespace = true;
        } else if (std.mem.eql(u8, arg, "--minify-identifiers")) {
            passed.minify_cluster = true;
            cli_minify_identifiers = true;
        } else if (std.mem.eql(u8, arg, "--minify-syntax")) {
            // The tri-state cluster (--minify, --minify-*, --no-mangle,
            // --no-whitespace, --no-syntax) is intentionally hand-rolled
            // and accepted on every subcommand: warnIgnoredFlags below
            // emits the categorical warning when it doesn't apply.
            passed.minify_cluster = true;
            cli_minify_syntax = true;
        } else if ((dispatchSpecFlag(
            arg,
            &args_iter,
            arena,
            args.subcommand,
            &args.options,
            &args.lint_options,
            &args.source_map_flags,
            &args.validate_options,
            &args.reflect_options,
            &passed,
            io,
        ) catch return null)) {
            // Spec-driven dispatch consumed the flag (matched + applied,
            // or matched + warned for wrong subcommand).
        } else if (std.mem.eql(u8, arg, "--json")) {
            // Sugar for `--format json`. Single-flag alias — too narrow
            // for a spec primitive, so it stays hand-rolled. Subcommand
            // gating mirrors `--format` (validate + lint).
            switch (args.subcommand) {
                .validate, .lint => args.validate_options.format = .json,
                else => warnFlagIgnored(io, arg, args.subcommand),
            }
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            File.stdout().writeStreamingAll(io, "wgslender v" ++ wgslender.version ++ "\n") catch {};
            return null;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage(arena, io) catch {};
            return null;
        } else if (arg.len > 0 and arg[0] != '-') {
            args.input_path = arg;
        }
    }

    const loaded_config: ?wgslender.Config = loadConfig(&args, arena, io, config_path, no_config) catch return null;
    applyMinifyOverrides(
        &args.options,
        cli_minify_all,
        cli_minify_whitespace,
        cli_minify_identifiers,
        cli_minify_syntax,
        cli_no_mangle,
        cli_no_whitespace,
        cli_no_syntax,
    );
    // CLI flag (true) wins; else config value if set; else false. Mirrors
    // the `report_unused_disable_directives` precedence below — kept inline
    // because `configureSourceMap` reads from `args.source_map_flags` next.
    if (loaded_config) |cfg| {
        if (cfg.source_map) |v| args.source_map_flags.source_map = args.source_map_flags.source_map or v;
        if (cfg.source_map_inline) |v| args.source_map_flags.source_map_inline = args.source_map_flags.source_map_inline or v;
        if (cfg.source_map_sources) |v| args.source_map_flags.source_map_sources = args.source_map_flags.source_map_sources or v;
    }
    configureSourceMap(&args);
    if (args.subcommand == .lint) {
        // Merge config-derived lint settings under CLI overrides:
        //   extends: config.lint_extends ++ CLI extends. If neither is
        //     populated and --no-recommended wasn't passed, default to
        //     @wgslender/recommended.
        //   rules: config.lint_rules ++ CLI overrides. The Linter applies
        //     overrides in slice order; CLI rules come last so they win.
        //   report_unused_disable_directives: CLI flag (true) wins; else
        //     config value if set; else false.
        // The CLI accumulators arrive on `args.lint_options.lint_extends`
        // / `.lint_rules` from the spec dispatcher; the merged result is
        // written back to the same fields for `runLint` to read.
        const cli_extends = args.lint_options.lint_extends;
        var merged_extends: std.ArrayList([]const u8) = .empty;
        if (loaded_config) |cfg| {
            merged_extends.appendSlice(arena, cfg.lint_extends) catch return null;
        }
        merged_extends.appendSlice(arena, cli_extends) catch return null;
        if (lint_use_recommended and merged_extends.items.len == 0) {
            merged_extends.append(arena, "@wgslender/recommended") catch return null;
        }
        args.lint_options.lint_extends = merged_extends.items;

        const cli_rules = args.lint_options.lint_rules;
        var merged_rules: std.ArrayList(wgslender.Linter.Options.RuleOverride) = .empty;
        if (loaded_config) |cfg| {
            merged_rules.appendSlice(arena, cfg.lint_rules) catch return null;
        }
        merged_rules.appendSlice(arena, cli_rules) catch return null;
        args.lint_options.lint_rules = merged_rules.items;

        if (loaded_config) |cfg| {
            if (cfg.report_unused_disable_directives) |v| {
                if (!args.lint_options.report_unused_disable_directives) {
                    args.lint_options.report_unused_disable_directives = v;
                }
            }
        }
    }

    warnIgnoredFlags(io, args.subcommand, passed);

    return args;
}

/// Try to match `arg` against the spec tables, in order:
///   1. `minifier_options_specs` → writes to `Minifier.Options`
///   2. `source_map_specs` → writes to `CliArgs.SourceMapFlags`
///   3. `lint_specs` → writes to `CliArgs.LintOptions` (lint_extends /
///      lint_rules accumulators)
///   4. `cli_lint_extra_specs` → writes to `CliArgs.LintOptions`
///      (--max-warnings, --quiet, --fix, --fix-dry-run)
///   5. `cli_validate_specs` → writes to `CliArgs.ValidateOptions`
///      (--format, --strict, --line-offset; format/line-offset shared
///       with lint)
///   6. `cli_reflect_specs` → writes to `CliArgs.ReflectOptions`
///      (--compact, --reflect-format)
/// Returns true if matched (consumed — caller should not try other arms).
/// Emits a per-flag stderr warning when the flag is recognized but the
/// current subcommand excludes it. When a source-map / lint spec matches
/// successfully, stamps `passed.source_map_flag` / `passed.lint_flag` so
/// the categorical "* flags ignored on …" warning still fires for the
/// other subcommands. Returns `error.InvalidCliValue` when a strict-value
/// spec rejects its argument (today: only `--rule id=severity` opts in
/// via `cli_strict_value`); the caller catches and aborts. The stderr
/// message is emitted here so the error propagation is purely a
/// control-flow signal.
const DispatchError = std.mem.Allocator.Error || error{InvalidCliValue};

fn dispatchSpecFlag(
    arg: []const u8,
    args_iter: anytype,
    arena: std.mem.Allocator,
    subcommand: wgslender.OptionsSpec.Subcommand,
    minify_target: *wgslender.Minifier.Options,
    lint_target: *CliArgs.LintOptions,
    source_map_target: *CliArgs.SourceMapFlags,
    validate_target: *CliArgs.ValidateOptions,
    reflect_target: *CliArgs.ReflectOptions,
    passed: *Passed,
    io: std.Io,
) DispatchError!bool {
    const minify_result = try wgslender.OptionsSpec.matchFlag(
        arg,
        args_iter,
        arena,
        subcommand,
        &wgslender.OptionsSpec.minifier_options_specs,
        minify_target,
    );
    switch (minify_result) {
        .matched => return true,
        .wrong_subcommand => {
            warnFlagIgnored(io, arg, subcommand);
            return true;
        },
        .invalid_value => {
            warnInvalidValue(io, arg);
            return error.InvalidCliValue;
        },
        .no_match => {},
    }

    const sm_result = try wgslender.OptionsSpec.matchFlag(
        arg,
        args_iter,
        arena,
        subcommand,
        &wgslender.OptionsSpec.source_map_specs,
        source_map_target,
    );
    switch (sm_result) {
        .matched => {
            passed.source_map_flag = true;
            return true;
        },
        .wrong_subcommand => {
            passed.source_map_flag = true;
            warnFlagIgnored(io, arg, subcommand);
            return true;
        },
        .invalid_value => {
            passed.source_map_flag = true;
            warnInvalidValue(io, arg);
            return error.InvalidCliValue;
        },
        .no_match => {},
    }

    const lint_result = try wgslender.OptionsSpec.matchFlag(
        arg,
        args_iter,
        arena,
        subcommand,
        &wgslender.OptionsSpec.lint_specs,
        lint_target,
    );
    switch (lint_result) {
        .matched => {
            passed.lint_flag = true;
            return true;
        },
        .wrong_subcommand => {
            passed.lint_flag = true;
            warnFlagIgnored(io, arg, subcommand);
            return true;
        },
        .invalid_value => {
            passed.lint_flag = true;
            warnInvalidValue(io, arg);
            return error.InvalidCliValue;
        },
        .no_match => {},
    }

    // CLI-only lint extras (--max-warnings, --quiet, --fix, --fix-dry-run).
    // Same target as `lint_specs`; separate table because these have no
    // JSON shape (live in cli/main.zig, not src/options.zig).
    const lint_extra_result = try wgslender.OptionsSpec.matchFlag(
        arg,
        args_iter,
        arena,
        subcommand,
        &cli_lint_extra_specs,
        lint_target,
    );
    switch (lint_extra_result) {
        .matched => {
            passed.lint_flag = true;
            return true;
        },
        .wrong_subcommand => {
            passed.lint_flag = true;
            warnFlagIgnored(io, arg, subcommand);
            return true;
        },
        .invalid_value => {
            passed.lint_flag = true;
            warnInvalidValue(io, arg);
            return error.InvalidCliValue;
        },
        .no_match => {},
    }

    // Validate-subcommand flags (--format, --strict, --line-offset).
    // `--format` and `--line-offset` also accepted on lint (their spec
    // entries pin both subcommands).
    const validate_result = try wgslender.OptionsSpec.matchFlag(
        arg,
        args_iter,
        arena,
        subcommand,
        &cli_validate_specs,
        validate_target,
    );
    switch (validate_result) {
        .matched => return true,
        .wrong_subcommand => {
            warnFlagIgnored(io, arg, subcommand);
            return true;
        },
        .invalid_value => {
            warnInvalidValue(io, arg);
            return error.InvalidCliValue;
        },
        .no_match => {},
    }

    // Reflect-subcommand flags (--compact, --reflect-format).
    const reflect_result = try wgslender.OptionsSpec.matchFlag(
        arg,
        args_iter,
        arena,
        subcommand,
        &cli_reflect_specs,
        reflect_target,
    );
    switch (reflect_result) {
        .matched => return true,
        .wrong_subcommand => {
            warnFlagIgnored(io, arg, subcommand);
            return true;
        },
        .invalid_value => {
            warnInvalidValue(io, arg);
            return error.InvalidCliValue;
        },
        .no_match => return false,
    }
}

fn warnInvalidValue(io: std.Io, arg: []const u8) void {
    const f = std.Io.File.stderr();
    f.writeStreamingAll(io, "error: invalid value for ") catch {};
    f.writeStreamingAll(io, arg) catch {};
    // Per-flag format hint. Today only `--rule` opts into strict
    // validation, so the lookup table has one entry. If more strict
    // specs land, plumb the hint through `MatchResult` instead.
    if (std.mem.eql(u8, arg, "--rule")) {
        f.writeStreamingAll(io, " (expected id=severity, severity ∈ off|warn|error)") catch {};
    }
    f.writeStreamingAll(io, "\n") catch {};
}

/// Print "<arg> requires a value" and abort with exit code 1.
/// `parseArgs` itself returns `?CliArgs` where `null` is reserved for the
/// successful early-exit paths (`--help`, `--version`), so a missing-value
/// failure can't piggyback on that. Exit directly so the process surfaces
/// a non-zero code to scripts.
fn warnMissingValue(io: std.Io, arg: []const u8) noreturn {
    const f = std.Io.File.stderr();
    f.writeStreamingAll(io, "error: ") catch {};
    f.writeStreamingAll(io, arg) catch {};
    f.writeStreamingAll(io, " requires a value\n") catch {};
    std.process.exit(1);
}

fn warnFlagIgnored(
    io: std.Io,
    arg: []const u8,
    subcommand: wgslender.OptionsSpec.Subcommand,
) void {
    const f = std.Io.File.stderr();
    f.writeStreamingAll(io, "warning: ") catch {};
    f.writeStreamingAll(io, arg) catch {};
    f.writeStreamingAll(io, " has no effect on ") catch {};
    f.writeStreamingAll(io, @tagName(subcommand)) catch {};
    f.writeStreamingAll(io, "\n") catch {};
}

/// Emit a stderr warning for each flag passed by the user that the chosen
/// subcommand ignores. Best-effort UX hint, never aborts.
fn warnIgnoredFlags(
    io: std.Io,
    subcommand: @TypeOf(@as(CliArgs, undefined).subcommand),
    passed: Passed,
) void {
    const W = struct {
        fn warn(io_: std.Io, msg: []const u8) void {
            const f = std.Io.File.stderr();
            f.writeStreamingAll(io_, "warning: ") catch {};
            f.writeStreamingAll(io_, msg) catch {};
            f.writeStreamingAll(io_, "\n") catch {};
        }
    };

    // Per-flag wrong-subcommand warnings fire from the spec dispatcher
    // (`OptionsSpec.matchFlag`); only the multi-flag categorical
    // warnings live here, where one consolidated message reads better
    // than N individual ones (minify cluster, source-map suite, lint
    // accumulators).
    switch (subcommand) {
        .minify => {
            if (passed.lint_flag) W.warn(io, "lint flags (--extends/--rule/--fix/...) have no effect on minify");
        },
        .compile => {
            if (passed.source_map_flag) W.warn(io, "--source-map* has no effect on compile (source maps are not embedded in the binary)");
            if (passed.lint_flag) W.warn(io, "lint flags have no effect on compile");
        },
        .validate => {
            if (passed.minify_cluster) W.warn(io, "minify flags (--minify-*/--no-*/--keep-names/...) have no effect on validate");
            if (passed.source_map_flag) W.warn(io, "--source-map* has no effect on validate");
            if (passed.output_path) W.warn(io, "-o/--output has no effect on validate (diagnostics go to stderr/stdout)");
            if (passed.lint_flag) W.warn(io, "lint flags have no effect on validate");
        },
        .reflect => {
            if (passed.minify_cluster) W.warn(io, "minify flags have no effect on reflect");
            if (passed.source_map_flag) W.warn(io, "--source-map* has no effect on reflect");
            if (passed.lint_flag) W.warn(io, "lint flags have no effect on reflect");
        },
        .lint => {
            if (passed.minify_cluster) W.warn(io, "minify flags have no effect on lint");
            if (passed.source_map_flag) W.warn(io, "--source-map* has no effect on lint");
            if (passed.output_path) W.warn(io, "-o/--output has no effect on lint (--fix rewrites the input file in place)");
        },
    }
}

/// Load config from explicit path or auto-discover from parent directories.
/// On hard error (bad path / invalid JSON), prints to stderr and returns
/// `error.ConfigError`. On no config / `--no-config`, returns `null`.
fn loadConfig(
    args: *CliArgs,
    arena: std.mem.Allocator,
    io: std.Io,
    config_path: ?[]const u8,
    no_config: bool,
) !?wgslender.Config {
    const File = std.Io.File;
    const Dir = std.Io.Dir;

    if (config_path) |path| {
        const content = Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch {
            File.stderr().writeStreamingAll(io, "error: could not read config file\n") catch {};
            return error.ConfigError;
        };
        const config = wgslender.Config.parseJson(arena, content) catch {
            File.stderr().writeStreamingAll(io, "error: invalid config JSON\n") catch {};
            return error.ConfigError;
        };
        args.options = config.toOptions();
        return config;
    } else if (!no_config) {
        const start = if (args.input_path) |p| std.fs.path.dirname(p) else null;
        if (wgslender.Config.discover(arena, io, start)) |config| {
            args.options = config.toOptions();
            return config;
        }
    }
    return null;
}

/// Apply CLI minification flag overrides with correct precedence.
/// Granular flags (--minify-*) disable unspecified passes; --minify forces all on.
/// `--no-*` post-overrides force a single pass off regardless of granular state.
/// `--no-tree-shaking` is dispatched directly via the `tree_shaking` spec's
/// `cli_inverse` and does not pass through here.
fn applyMinifyOverrides(
    options: *wgslender.Minifier.Options,
    cli_minify_all: bool,
    cli_minify_whitespace: ?bool,
    cli_minify_identifiers: ?bool,
    cli_minify_syntax: ?bool,
    cli_no_mangle: bool,
    cli_no_whitespace: bool,
    cli_no_syntax: bool,
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
    if (cli_no_whitespace) options.minify_whitespace = false;
    if (cli_no_syntax) options.minify_syntax = false;
}

/// Hand-rolled post-step: the spec dispatcher writes the three boolean
/// toggles into `args.source_map_flags`, but the resulting
/// `source_map_options.source_name` / `.file` are derived from the
/// input/output basenames — that's CLI plumbing, not a single-field knob,
/// so it stays here.
fn configureSourceMap(args: *CliArgs) void {
    const flags = args.source_map_flags;
    const generate = flags.source_map or flags.source_map_inline;
    if (!generate) return;

    args.options.generate_source_map = true;
    args.options.source_map_options.include_source = flags.source_map_sources;
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
        var buf: std.ArrayList(u8) = .empty;
        var scratch: [4096]u8 = undefined;
        // Unbounded by design: input length is whatever the user pipes in.
        // Terminates on EOF (n == 0) or stdin read error.
        while (true) {
            const n = std.Io.File.stdin().readStreaming(io, &.{&scratch}) catch break;
            if (n == 0) break;
            try buf.appendSlice(arena, scratch[0..n]);
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
                var comment_buf: std.ArrayList(u8) = .empty;
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
                var comment_buf: std.ArrayList(u8) = .empty;
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
                var map_path_buf: std.ArrayList(u8) = .empty;
                try map_path_buf.appendSlice(arena, path);
                try map_path_buf.appendSlice(arena, ".map");
                const map_path = map_path_buf.items;

                var json_buf: std.ArrayList(u8) = .empty;
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
    var json_buf: std.ArrayList(u8) = .empty;
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
        var scratch: [20]u8 = undefined;
        try File.stderr().writeStreamingAll(io, file_prefix);
        try File.stderr().writeStreamingAll(io, ":");
        const line_s = std.fmt.bufPrint(&scratch, "{d}", .{entry.range.start.line}) catch "";
        try File.stderr().writeStreamingAll(io, line_s);
        try File.stderr().writeStreamingAll(io, ":");
        const col_s = std.fmt.bufPrint(&scratch, "{d}", .{entry.range.start.column}) catch "";
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

fn runReflect(
    arena: std.mem.Allocator,
    io: std.Io,
    source: [:0]const u8,
    output_path: ?[]const u8,
    compact: bool,
    version: wgslender.Reflect.JsonVersion,
) !void {
    const File = std.Io.File;
    const Dir = std.Io.Dir;

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
    var json_buf: std.ArrayList(u8) = .empty;
    if (compact) {
        try result.toJsonVersion(&json_buf, arena, version);
    } else {
        try result.toJsonPrettyVersion(&json_buf, arena, version);
    }

    if (output_path) |path| {
        const file = try Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, json_buf.items);
        try file.writeStreamingAll(io, "\n");
    } else {
        try File.stdout().writeStreamingAll(io, json_buf.items);
        try File.stdout().writeStreamingAll(io, "\n");
    }
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
    var scratch: [64]u8 = undefined;
    try File.stderr().writeStreamingAll(io, "Original: ");
    var s = std.fmt.bufPrint(&scratch, "{d}", .{result.original_size}) catch "";
    try File.stderr().writeStreamingAll(io, s);
    try File.stderr().writeStreamingAll(io, " bytes -> WASM: ");
    s = std.fmt.bufPrint(&scratch, "{d}", .{result.wasm_size}) catch "";
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
        .extends = lint_opts.lint_extends,
        .rules = lint_opts.lint_rules,
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
    var combined: std.ArrayList(Diagnostic.Entry) = .empty;
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
    const exceeds_max_warnings = if (lint_opts.max_warnings) |max| lint_warnings > max else false;
    if (analysis_errors > 0 or lint_errors > 0 or exceeds_max_warnings) {
        std.process.exit(1);
    }
}

fn filterErrorsOnly(
    arena: std.mem.Allocator,
    entries: []const wgslender.Diagnostic.Entry,
) ![]wgslender.Diagnostic.Entry {
    var out: std.ArrayList(wgslender.Diagnostic.Entry) = .empty;
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
        var scratch: [32]u8 = undefined;
        try File.stderr().writeStreamingAll(io, file_prefix);
        try File.stderr().writeStreamingAll(io, ":");
        const ls = std.fmt.bufPrint(&scratch, "{d}", .{entry.range.start.line}) catch "";
        try File.stderr().writeStreamingAll(io, ls);
        try File.stderr().writeStreamingAll(io, ":");
        const cs = std.fmt.bufPrint(&scratch, "{d}", .{entry.range.start.column}) catch "";
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
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "\n");
    try out.appendSlice(arena, file_prefix);
    try out.appendSlice(arena, "\n");
    for (entries) |entry| {
        var scratch: [32]u8 = undefined;
        try out.appendSlice(arena, "  ");
        const ls = std.fmt.bufPrint(&scratch, "{d}:{d}", .{ entry.range.start.line, entry.range.start.column }) catch "";
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
    var buf: std.ArrayList(u8) = .empty;
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

/// Write `wgslender --help` to stdout. Every section pulls its body
/// from spec tables via `OptionsSpec.printHelp`; only the prologue,
/// command list, the minify-cluster outliers (hand-rolled tri-state),
/// and the `--no-recommended` outlier remain as static text.
fn printUsage(arena: std.mem.Allocator, io: std.Io) !void {
    var buf: std.ArrayList(u8) = .empty;

    try buf.appendSlice(arena, usage_prologue);

    try buf.appendSlice(arena, "\nMinification (minify, compile):\n");
    try wgslender.OptionsSpec.printHelp(&buf, arena, &wgslender.OptionsSpec.minifier_options_specs, null);
    try buf.appendSlice(arena, usage_minify_outliers);

    try buf.appendSlice(arena, "\nSource maps (minify):\n");
    try wgslender.OptionsSpec.printHelp(&buf, arena, &wgslender.OptionsSpec.source_map_specs, null);

    try buf.appendSlice(arena, "\nReflect:\n");
    try wgslender.OptionsSpec.printHelp(&buf, arena, &cli_reflect_specs, null);

    try buf.appendSlice(arena, "\nValidate / lint:\n");
    try wgslender.OptionsSpec.printHelp(&buf, arena, &cli_validate_specs, null);
    try buf.appendSlice(arena, usage_validate_outliers);

    try buf.appendSlice(arena, "\nLint:\n");
    try wgslender.OptionsSpec.printHelp(&buf, arena, &wgslender.OptionsSpec.lint_specs, null);
    try wgslender.OptionsSpec.printHelp(&buf, arena, &cli_lint_extra_specs, null);
    try buf.appendSlice(arena, usage_lint_outliers);

    try buf.appendSlice(arena, usage_epilogue);

    try std.Io.File.stdout().writeStreamingAll(io, buf.items);
}

const usage_prologue =
    \\Usage: wgslender [command] [options] [file.wgsl]
    \\
    \\Commands:
    \\  (default)                         Minify WGSL source
    \\  validate                          Validate WGSL source
    \\  reflect                           Extract bindings, layouts, and entry points as JSON
    \\  compile                           Compile WGSL to a .wasm binary shader
    \\  lint                              Run lint rules and emit diagnostics
    \\
    \\Common:
    \\  -o, --output <path>               Output file
    \\  --config <path>                   Config file (JSON)
    \\  --no-config                       Ignore config files
;

const usage_minify_outliers =
    \\  --minify                          Enable all minification (default)
    \\  --minify-whitespace               Only minify whitespace
    \\  --minify-identifiers              Only minify identifiers
    \\  --minify-syntax                   Only minify syntax
    \\  --no-mangle                       Don't rename identifiers
    \\  --no-whitespace                   Don't minify whitespace
    \\  --no-syntax                       Don't apply syntax-level optimizations
;

// Hand-rolled outliers (single-line, no JSON shape) appended below the
// spec-driven `--format`/`--strict`/`--line-offset` block. `--json` is
// an alias for `--format json` so it lives here, not in the spec table.
const usage_validate_outliers =
    \\  --json                            Shorthand for --format json
;

// `--no-recommended` has no JSON shape and no spec entry (CLI-only meta-flag
// suppressing the auto-recommended default), so it stays static here.
const usage_lint_outliers =
    \\  --no-recommended                  Do not auto-apply @wgslender/recommended
;

const usage_epilogue =
    \\
    \\Misc:
    \\  -v, --version                     Show version
    \\  -h, --help                        Show this help
    \\
    \\If no input file is given, reads from stdin.
    \\
;
