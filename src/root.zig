//! wgslender — WGSL minifier.
//!
//! Public API. Each function manages memory via an internal arena: all
//! intermediate allocations (tokens, AST nodes, scopes, etc.) are bulk-freed
//! when the caller calls `result.deinit()`. This makes the API safe to use
//! with any allocator, including in long-running processes.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const version = "1.0.0";

pub const Ast = @import("Ast.zig");
pub const AstVisit = @import("AstVisit.zig");
pub const Lexer = @import("Lexer.zig");
pub const Parser = @import("Parser.zig");
pub const Printer = @import("Printer.zig");
pub const Renamer = @import("Renamer.zig");
pub const Dce = @import("Dce.zig");
pub const Builtins = @import("Builtins.zig");
pub const Overload = @import("Overload.zig");
pub const Diagnostic = @import("Diagnostic.zig");
pub const Types = @import("Types.zig");
pub const Validator = @import("Validator.zig");
pub const Minifier = @import("Minifier.zig");
pub const Config = @import("Config.zig");
pub const Reflect = @import("Reflect.zig");
pub const SourceMap = @import("SourceMap.zig");
pub const Compiler = @import("Compiler.zig");
pub const WasmBinary = @import("WasmBinary.zig");
pub const Edits = @import("Edits.zig");
pub const StableId = @import("StableId.zig");
pub const Cst = @import("Cst.zig");
pub const CstLower = @import("CstLower.zig");
pub const Incremental = @import("Incremental.zig");
pub const Linter = @import("lint/Linter.zig");
pub const MinifySettings = @import("MinifySettings.zig");
pub const MagicComment = @import("MagicComment.zig");
pub const MinifyEstimator = @import("MinifyEstimator.zig");

test {
    // Force test discovery for modules that have no call-site references
    // inside the library surface yet. Once stage 7 wires `Incremental` into
    // the LSP handler, this hook stays correct but becomes redundant.
    _ = Incremental;
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
            for (parser.errors.items) |err| {
                const end = if (err.end > err.pos) err.end else err.pos + 1;
                if (err.code.len > 0) {
                    diags.addErrorWithCodeRange(alloc, err.pos, end, err.code, err.message);
                } else {
                    diags.addErrorRange(alloc, err.pos, end, err.message);
                }
            }
            return .{ .valid = false, .diagnostics = diags, ._arena = arena };
        },
    };
    var result = try Validator.validate(alloc, module, options);
    // Inject parser errors (e.g. reserved word usage) into validation diagnostics
    for (parser.errors.items) |err| {
        const end = if (err.end > err.pos) err.end else err.pos + 1;
        if (err.code.len > 0) {
            result.diagnostics.addErrorWithCodeRange(alloc, err.pos, end, err.code, err.message);
        } else {
            result.diagnostics.addErrorRange(alloc, err.pos, end, err.message);
        }
        result.valid = false;
    }
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
            for (parser.errors.items) |err| {
                const end = if (err.end > err.pos) err.end else err.pos + 1;
                if (err.code.len > 0) {
                    diags.addErrorWithCodeRange(alloc, err.pos, end, err.code, err.message);
                } else {
                    diags.addErrorRange(alloc, err.pos, end, err.message);
                }
            }
            return .{
                .valid = false,
                .diagnostics = diags,
                ._arena = arena,
            };
        },
    };
    var result = try Validator.analyze(alloc, module, options);
    // Inject parser errors (e.g. reserved word usage) into analysis diagnostics
    for (parser.errors.items) |err| {
        const end = if (err.end > err.pos) err.end else err.pos + 1;
        if (err.code.len > 0) {
            result.diagnostics.addErrorWithCodeRange(alloc, err.pos, end, err.code, err.message);
        } else {
            result.diagnostics.addErrorRange(alloc, err.pos, end, err.message);
        }
        result.valid = false;
    }
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
    errdefer analysis.deinit(gpa);
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
        self.analysis.deinit(gpa);
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
            try result.errors.append(alloc, "parse error");
            result._arena = arena;
            return result;
        },
    };
    var result = try Reflect.reflect(alloc, module);
    result._arena = arena;
    return result;
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
    defer result.deinit(a);
    try std.testing.expect(result.valid);
}

test "validate: deinit frees on invalid source" {
    const a = std.testing.allocator;
    // Use source with undeclared identifier to trigger validation error
    const source: [:0]const u8 = "fn f() { let x = undeclared_var; }";
    var result = try validateWithOptions(a, source, .{});
    defer result.deinit(a);
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
    defer result.deinit(a);
    try std.testing.expect(result.valid);
    // The validator should have resolved types for the declared symbols
    try std.testing.expect(result.symbol_types.count() > 0);
}

test "analyze: returns struct_types" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "struct MyStruct { x: f32, y: f32 }";
    var result = try analyzeWithOptions(a, source, .{});
    defer result.deinit(a);
    try std.testing.expect(result.struct_types.get("MyStruct") != null);
}

test "analyze: deinit frees all memory" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "@compute @workgroup_size(1) fn main() {}";
    var result = try analyzeWithOptions(a, source, .{});
    defer result.deinit(a);
    try std.testing.expect(result.valid);
    try std.testing.expect(result.module != null);
    try std.testing.expect(result.module.?.declarations.items.len > 0);
}

test "analyze: parse error returns partial result" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "fn { invalid }";
    var result = try analyzeWithOptions(a, source, .{});
    defer result.deinit(a);
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
    defer result.deinit(a);
    try std.testing.expect(result.valid);
    const module = result.module orelse return error.TestUnexpectedResult;
    // Should have symbols for both declarations
    try std.testing.expect(module.symbols.items.len >= 2);
}

test "analyze: const_values populated" {
    const a = std.testing.allocator;
    const source: [:0]const u8 = "const N: i32 = 42;";
    var result = try analyzeWithOptions(a, source, .{});
    defer result.deinit(a);
    // The const value 42 should be tracked
    try std.testing.expect(result.const_values.count() > 0);
}

// Re-export tests from all modules
comptime {
    _ = Ast;
    _ = AstVisit;
    _ = CstLower;
    _ = Lexer;
    _ = Parser;
    _ = Renamer;
    _ = Builtins;
    _ = Overload;
    _ = Diagnostic;
    _ = Types;
    _ = Validator;
    _ = Reflect;
    _ = SourceMap;
    _ = Dce;
    _ = Compiler;
    _ = WasmBinary;
    _ = Edits;
    _ = StableId;
    _ = Linter;
    _ = MagicComment;
    _ = MinifyEstimator;
    _ = @import("unicode_xid.zig");
}
