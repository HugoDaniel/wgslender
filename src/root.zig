//! wgslender — WGSL minifier.
//!
//! Public API. Each function manages memory via an internal arena: all
//! intermediate allocations (tokens, AST nodes, scopes, etc.) are bulk-freed
//! when the caller calls `result.deinit()`. This makes the API safe to use
//! with any allocator, including in long-running processes.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const version = "1.2.1";

// Re-exported modules, grouped by stability tier:
//
//   * Stable — the surface the `minify` / `validate` / `analyze` / `lint` /
//     `reflect` / `compile` entry points below return and consume. Treated
//     as the committed public API.
//   * Experimental — public and supported, but the shape may still shift
//     between versions: the Pipeline extension points, the LSP / incremental
//     front-end, and the minify-mode knobs.
//   * Internal — exposed only so the in-repo CLI / LSP / tests (separate
//     compilation units) and adventurous tooling can reach compiler
//     internals. No compatibility promise; these change freely.
//     `WasmBinary` is deliberately not re-exported — it is a Compiler
//     implementation detail with no external users; its tests are still
//     pulled into the test build below.

// --- Stable ---
pub const Minifier = @import("Minifier.zig");
/// Semantic validator + analyzer. `validate` returns pass/fail + diagnostics;
/// `analyze` additionally retains the resolved-type caches as
/// `Validator.AnalysisResult` — the committed surface the LSP and lint rules
/// read by field name. The orchestrator drives the `src/validator/*`
/// submodules (Declarations / Expressions / Statements / TypeResolve /
/// Uniformity) through a fixed phase sequence; the decomposition and its
/// re-export contract are documented in `docs/deferred/validator-decomposition.md`.
pub const Validator = @import("Validator.zig");
/// Shader reflection. This is the stable façade: the `reflect` entry point
/// below returns `Reflect.ReflectResult`, and the public data vocabulary
/// (`TypeInfo`, `BindingInfo`, `EntryPointInfo`, …) plus the driver all live
/// here. The three implementation seams — `Reflect.Layout` (memory layout),
/// `Reflect.Json` (serialization), `Reflect.CallGraph` (reachability) — are
/// re-exported sub-namespaces, reachable for tooling but not part of the
/// committed surface; their shape may shift. See `docs/deferred/reflect-split.md`.
pub const Reflect = @import("Reflect.zig");
pub const Compiler = @import("Compiler.zig");
pub const Linter = @import("lint/Linter.zig");
pub const Config = @import("Config.zig");
pub const Diagnostic = @import("Diagnostic.zig");
pub const Types = @import("Types.zig");
pub const SourceMap = @import("SourceMap.zig");
pub const Edits = @import("Edits.zig");

// --- Experimental ---
/// Composable pipeline. `Pipeline.Pass` is the public sequence-of-steps
/// API used internally by `Minifier` and `Compiler`; downstream tooling
/// can build custom pass lists or inject `Pass.custom` callbacks that
/// read/write `Pipeline.State`. The side-table types `UseCounts`,
/// `RenamePolicy`, and `Liveness` (below) are the data contracts
/// exchanged between bundled passes and user code. See the
/// `Pipeline.zig` module doc for the stability guarantees and standard
/// pass order.
pub const Pipeline = @import("Pipeline.zig");
pub const UseCounts = @import("UseCounts.zig");
pub const RenamePolicy = @import("RenamePolicy.zig");
pub const Liveness = @import("Liveness.zig");
pub const Cst = @import("Cst.zig");
pub const Incremental = @import("Incremental.zig");
pub const StableId = @import("StableId.zig");
pub const MagicComment = @import("MagicComment.zig");
pub const MinifySettings = @import("MinifySettings.zig");
pub const MinifyEstimator = @import("MinifyEstimator.zig");
pub const MultiVisitor = @import("lint/MultiVisitor.zig");
pub const OptionsSpec = @import("options.zig");
/// Shared const-expression evaluator consumed by `Reflect` (wrapping mode)
/// and the `Validator` const-folding family (saturating mode). See
/// `docs/deferred/consteval-extraction.md`.
pub const ConstEval = @import("ConstEval.zig");

// --- Internal (no compatibility promise) ---
pub const Ast = @import("Ast.zig");
pub const AstVisit = @import("AstVisit.zig");
pub const Lexer = @import("Lexer.zig");
pub const Parser = @import("Parser.zig");
pub const Printer = @import("Printer.zig");
pub const Renamer = @import("Renamer.zig");
pub const Dce = @import("Dce.zig");
pub const Builtins = @import("Builtins.zig");
pub const Overload = @import("Overload.zig");
pub const Operators = @import("Operators.zig");
pub const Predeclared = @import("Predeclared.zig");
pub const api_json = @import("api_json.zig");
pub const ffi = @import("ffi.zig");

test {
    // Belt-and-suspenders: these modules are re-exported above but not called
    // by this library's own functions, so reference them here to keep their
    // `test {}` blocks in the `zig build test` build. (`Incremental`'s real
    // callers live in the LSP layer under `lsp/`, a separate compilation unit.)
    _ = Incremental;
    _ = OptionsSpec;
}

// =========================================================================
// Minify API
// =========================================================================

/// Minify WGSL source with default options.
///
/// - Complexity: linear in source length for parse + DCE; the rename pass
///   is O(N log N) over the symbol table.
/// - Thread-safe: yes — every call gets a private arena under `gpa`.
/// - Memory: returns a result owning an internal ArenaAllocator;
///   `result.deinit(gpa)` bulk-frees every intermediate allocation.
pub fn minify(gpa: Allocator, source: [:0]const u8) !Minifier.Result {
    return minifyWithOptions(gpa, source, Minifier.defaultOptions());
}

/// Minify WGSL source with custom options.
///
/// - Complexity: same as `minify`; `options.sort_declarations` adds an
///   O(N log N) sort over module-level decls.
/// - Thread-safe: yes — private arena per call.
/// - Memory: see `minify`. `options.keep_names` is borrowed for the
///   duration of the call; the result does not retain it.
pub fn minifyWithOptions(gpa: Allocator, source: [:0]const u8, options: Minifier.Options) !Minifier.Result {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var result = try Minifier.minify(arena.allocator(), source, options);
    result._arena = arena;
    return result;
}

/// Minify and reflect in a single pass — shares one parse + analysis
/// between the two outputs.
///
/// - Complexity: dominated by `minify`; reflection adds a linear scan
///   over module declarations.
/// - Thread-safe: yes — private arena per call.
/// - Memory: single arena owns both the minified source and the
///   reflection report; `result.deinit(gpa)` releases both.
pub fn minifyAndReflect(gpa: Allocator, source: [:0]const u8, options: Minifier.Options) !Minifier.MinifyAndReflectResult {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var result = try Minifier.minifyAndReflect(arena.allocator(), source, options);
    result._arena = arena;
    return result;
}

// =========================================================================
// Compile API (WGSL → WASM binary shader)
// =========================================================================

/// Compile WGSL source to a .wasm binary that generates the shader at runtime.
///
/// - Complexity: linear in minified source length for the BPE compressor
///   (single pass over the byte stream, capped at 64 rules).
/// - Thread-safe: yes — private arena per call.
/// - Memory: result owns the WASM binary slice + an internal arena;
///   `result.deinit(gpa)` releases both.
pub fn compile(gpa: Allocator, source: [:0]const u8, options: Compiler.CompileOptions) !Compiler.CompileResult {
    return Compiler.compile(gpa, source, options);
}

// =========================================================================
// Validate API
// =========================================================================

/// Validate WGSL source with default options.
///
/// - Complexity: linear in source length for parse; the type-check + uniformity
///   pass is roughly linear in AST node count.
/// - Thread-safe: yes — private arena per call.
/// - Memory: result owns an internal arena; `result.deinit(gpa)` releases
///   the diagnostics list and the parsed AST it indexes into.
pub fn validate(gpa: Allocator, source: [:0]const u8) !Validator.Result {
    return validateWithOptions(gpa, source, .{});
}

/// Validate WGSL source with custom options.
///
/// - Complexity: same as `validate`.
/// - Thread-safe: yes — private arena per call.
/// - Memory: see `validate`.
pub fn validateWithOptions(gpa: Allocator, source: [:0]const u8, options: Validator.Options) !Validator.Result {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    const alloc = arena.allocator();
    const tokens = try Lexer.tokenize(alloc, source);
    var parser = try Parser.init(alloc, source, tokens);
    const module = parser.parse() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const diags = try alloc.create(Diagnostic);
            diags.* = try Diagnostic.init(alloc, source);
            diags.line_offset = options.line_offset;
            Parser.mergeErrorsInto(parser.errors.items, diags, alloc);
            return .{ .valid = false, .diagnostics = diags, ._arena = arena };
        },
    };
    var result = try Validator.validate(alloc, module, options);
    Parser.mergeErrorsInto(parser.errors.items, result.diagnostics, alloc);
    if (parser.errors.items.len > 0) result.valid = false;
    result._arena = arena;
    return result;
}

// =========================================================================
// Analyze API (validation + retained semantic state for LSP)
// =========================================================================

/// Analyze WGSL source with default options, retaining semantic state.
/// Returns resolved types, struct layouts, and the full AST module.
///
/// - Complexity: same as `validate` plus retention of the typed-symbol
///   tables — no extra pass.
/// - Thread-safe: yes — private arena per call.
/// - Memory: result holds the AST module + symbol/type tables alive in
///   the arena. The LSP layers retain analysis between requests; call
///   `result.deinit(gpa)` exactly once when the document closes.
pub fn analyze(gpa: Allocator, source: [:0]const u8) !Validator.AnalysisResult {
    return analyzeWithOptions(gpa, source, .{});
}

/// Analyze WGSL source with custom options, retaining semantic state.
///
/// - Complexity: same as `analyze`.
/// - Thread-safe: yes — private arena per call.
/// - Memory: see `analyze`.
pub fn analyzeWithOptions(gpa: Allocator, source: [:0]const u8, options: Validator.Options) !Validator.AnalysisResult {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    const alloc = arena.allocator();
    const tokens = try Lexer.tokenize(alloc, source);
    var parser = try Parser.init(alloc, source, tokens);
    const module = parser.parse() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const diags = try alloc.create(Diagnostic);
            diags.* = try Diagnostic.init(alloc, source);
            diags.line_offset = options.line_offset;
            Parser.mergeErrorsInto(parser.errors.items, diags, alloc);
            return .{
                .valid = false,
                .diagnostics = diags,
                ._arena = arena,
            };
        },
    };
    var result = try Validator.analyze(alloc, module, options);
    Parser.mergeErrorsInto(parser.errors.items, result.diagnostics, alloc);
    if (parser.errors.items.len > 0) result.valid = false;
    result._arena = arena;
    return result;
}

// =========================================================================
// Lint API
// =========================================================================

/// Lint WGSL source. Runs the analyzer, then every enabled lint rule
/// against the resolved module. Returns the lint diagnostics separately
/// from any validation errors surfaced on `result.analysis.diagnostics`.
///
/// - Complexity: `analyze` cost plus one read-only walk per enabled rule.
///   Most rules are O(N) over the AST; complexity-bounded rules walk
///   each function body once.
/// - Thread-safe: yes — private arenas per call (one for analysis, one
///   for lint diagnostics + fixes).
/// - Memory: result owns two arenas; `result.deinit(gpa)` releases both.
pub fn lint(gpa: Allocator, source: [:0]const u8, options: Linter.Options) !LintResult {
    var analysis = try analyzeWithOptions(gpa, source, .{
        .line_offset = options.line_offset,
    });
    errdefer analysis.deinit();
    var lint_result = try Linter.run(gpa, &analysis, options);
    errdefer lint_result.deinit(gpa);
    return .{ .analysis = analysis, .lint = lint_result };
}

/// Combined analysis + lint result. Holds two arenas: the analysis owns
/// the AST and validator diagnostics; the lint owns the advisory
/// diagnostics produced by rules. `deinit` releases both.
pub const LintResult = struct {
    analysis: Validator.AnalysisResult,
    lint: Linter.Result,

    pub fn deinit(self: *LintResult, gpa: Allocator) void {
        self.lint.deinit(gpa);
        self.analysis.deinit();
    }
};

// =========================================================================
// Reflect API
// =========================================================================

/// Reflect WGSL source (extract bindings, layouts, entry points).
///
/// - Complexity: parse cost + a single linear scan over module decls
///   that compute layouts and group entries.
/// - Thread-safe: yes — private arena per call.
/// - Memory: result owns the reflection report + an internal arena;
///   `result.deinit(gpa)` releases both.
pub fn reflect(gpa: Allocator, source: [:0]const u8) !Reflect.ReflectResult {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    const alloc = arena.allocator();
    const tokens = try Lexer.tokenize(alloc, source);
    var parser = try Parser.init(alloc, source, tokens);
    const module = parser.parse() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            var result = Reflect.ReflectResult{};
            try appendParseErrors(&result, alloc, parser.errors.items);
            if (result.errors.items.len == 0) try result.errors.append(alloc, "parse error");
            result._arena = arena;
            return result;
        },
    };
    var result = try Reflect.reflect(alloc, module);
    if (parser.errors.items.len > 0) {
        try appendParseErrors(&result, alloc, parser.errors.items);
    }
    result._arena = arena;
    return result;
}

fn appendParseErrors(
    result: *Reflect.ReflectResult,
    arena: Allocator,
    errors: []const Parser.ParseError,
) !void {
    for (errors) |err| {
        try result.errors.append(arena, try arena.dupe(u8, err.message));
    }
}

// =========================================================================
// Tests
// =========================================================================

test "minify: deinit frees all memory" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "const x = 1; fn main() { let y = x; }";
    var result = try minifyWithOptions(a, source, .{});
    defer result.deinit(a);
    try std.testing.expect(result.code.len > 0);
}

test "minify: deinit frees on parse error" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "fn { invalid }";
    var result = try minifyWithOptions(a, source, .{});
    defer result.deinit(a);
    try std.testing.expect(result.errors.len > 0);
}

test "validate: deinit frees all memory" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "@compute @workgroup_size(1) fn main() {}";
    var result = try validateWithOptions(a, source, .{});
    defer result.deinit();
    try std.testing.expect(result.valid);
}

test "validate: deinit frees on invalid source" {
    const a = std.testing.allocator;
    // Use source with undeclared identifier to trigger validation error
    const source: [:0]const u8 = "fn f() { let x = undeclared_var; }";
    var result = try validateWithOptions(a, source, .{});
    defer result.deinit();
    try std.testing.expect(!result.valid);
}

test "reflect: deinit frees all memory" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "@group(0) @binding(0) var<uniform> u: f32; @compute @workgroup_size(1) fn main() {}";
    var result = try reflect(a, source);
    defer result.deinit(a);
    try std.testing.expect(result.bindings.items.len > 0);
}

test "reflect: deinit frees on parse error" {
    const a = std.testing.allocator;
    // Empty source — no entry points or bindings to reflect
    const source: [:0]const u8 = "";
    var result = try reflect(a, source);
    defer result.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), result.entry_points.items.len);
}

test "minifyAndReflect: deinit frees all memory" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "@group(0) @binding(0) var<uniform> u: f32; @compute @workgroup_size(1) fn main() { let x = u; }";
    var result = try minifyAndReflect(a, source, .{});
    defer result.deinit(a);
    try std.testing.expect(result.minify.code.len > 0);
}

test "minify: repeated calls no accumulation" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "const x = 1; fn main() { let y = x; }";
    for (0..10) |_| {
        var result = try minify(a, source);
        result.deinit(a);
    }
}

test "minify: propagates OOM" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const result = minifyWithOptions(failing.allocator(), "fn main() { let x = 1; }", .{});
    try std.testing.expect(result == error.OutOfMemory);
}

test "validate: propagates OOM" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const result = validateWithOptions(failing.allocator(), "@compute @workgroup_size(1) fn main() {}", .{});
    try std.testing.expect(result == error.OutOfMemory);
}

test "reflect: propagates OOM" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const result = reflect(failing.allocator(), "@group(0) @binding(0) var<uniform> u: f32;");
    try std.testing.expect(result == error.OutOfMemory);
}

test "analyze: returns symbol_types for valid shader" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "fn f() { let x: f32 = 1.0; let y: i32 = 2; }";
    var result = try analyzeWithOptions(a, source, .{});
    defer result.deinit();
    try std.testing.expect(result.valid);
    // The validator should have resolved types for the declared symbols
    try std.testing.expect(result.symbol_types.count() > 0);
}

test "analyze: returns struct_types" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "struct MyStruct { x: f32, y: f32 }";
    var result = try analyzeWithOptions(a, source, .{});
    defer result.deinit();
    try std.testing.expect(result.struct_types.get("MyStruct") != null);
}

test "analyze: deinit frees all memory" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "@compute @workgroup_size(1) fn main() {}";
    var result = try analyzeWithOptions(a, source, .{});
    defer result.deinit();
    try std.testing.expect(result.valid);
    try std.testing.expect(result.module != null);
    try std.testing.expect(result.module.?.declarations.items.len > 0);
}

test "analyze: parse error returns partial result" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "fn { invalid }";
    var result = try analyzeWithOptions(a, source, .{});
    defer result.deinit();
    try std.testing.expect(!result.valid);
    try std.testing.expect(result.diagnostics.diagnostics.items.len > 0);
}

test "analyze: propagates OOM" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const result = analyzeWithOptions(failing.allocator(), "@compute @workgroup_size(1) fn main() {}", .{});
    try std.testing.expect(result == error.OutOfMemory);
}

test "analyze: module symbols accessible" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "const MY_CONST: f32 = 3.14; fn my_func() -> f32 { return MY_CONST; }";
    var result = try analyzeWithOptions(a, source, .{});
    defer result.deinit();
    try std.testing.expect(result.valid);
    const module = result.module orelse return error.TestUnexpectedResult;
    // Should have symbols for both declarations
    try std.testing.expect(module.symbols.items.len >= 2);
}

test "analyze: const_values populated" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "const N: i32 = 42;";
    var result = try analyzeWithOptions(a, source, .{});
    defer result.deinit();
    // The const value 42 should be tracked
    try std.testing.expect(result.const_values.count() > 0);
}

// Re-export tests from all modules
comptime {
    _ = Ast;
    _ = AstVisit;
    _ = UseCounts;
    _ = RenamePolicy;
    _ = Liveness;
    _ = Lexer;
    _ = Parser;
    _ = Renamer;
    _ = Builtins;
    _ = Overload;
    _ = Operators;
    _ = Diagnostic;
    _ = Types;
    _ = Validator;
    _ = Reflect;
    _ = ConstEval;
    _ = SourceMap;
    _ = Dce;
    _ = Compiler;
    _ = api_json;
    _ = Pipeline;
    _ = @import("WasmBinary.zig");
    _ = Edits;
    _ = StableId;
    _ = Linter;
    _ = MultiVisitor;
    _ = MagicComment;
    _ = MinifyEstimator;
    _ = @import("unicode_xid.zig");
}
