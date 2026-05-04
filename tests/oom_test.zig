//! Exhaustive OOM tests using std.testing.checkAllAllocationFailures.
//!
//! For every allocation point in a function, verifies that:
//!   - OOM is propagated (not swallowed)
//!   - No memory is leaked when OOM occurs
//!   - Allocation count is deterministic across runs
//!
//! Functions designed for arena allocators (Parser, Validator, Reflect,
//! SourceMap, Minifier.minify) are tested by wrapping the failing allocator
//! in an ArenaAllocator inside the test function. This matches production
//! usage and avoids false leak reports from arena-managed memory.

const std = @import("std");
const wgslender = @import("wgslender");

const Lexer = wgslender.Lexer;
const Parser = wgslender.Parser;
const Ast = wgslender.Ast;
const Dce = wgslender.Dce;
const Liveness = wgslender.Liveness;
const Renamer = wgslender.Renamer;
const Validator = wgslender.Validator;
const Reflect = wgslender.Reflect;
const SourceMap = wgslender.SourceMap;
const Diagnostic = wgslender.Diagnostic;
const Compiler = wgslender.Compiler;
const Minifier = wgslender.Minifier;
const Printer = wgslender.Printer;

// =========================================================================
// Test inputs
// =========================================================================

const simple_fn: [:0]const u8 = "fn main() { let x = 1; }";

const struct_binding: [:0]const u8 =
    \\struct Uniforms { time: f32, resolution: vec2f }
    \\@group(0) @binding(0) var<uniform> u: Uniforms;
    \\@compute @workgroup_size(1) fn main() { let t = u.time; }
;

const multi_fn: [:0]const u8 =
    \\fn helper(x: f32) -> f32 { return x * 2.0; }
    \\fn other(a: f32, b: f32) -> f32 { return a + b; }
    \\@compute @workgroup_size(1) fn main() { let v = helper(1.0); let w = other(v, 2.0); }
;

const dead_code: [:0]const u8 =
    \\fn unused() -> f32 { return 42.0; }
    \\fn also_unused(x: f32) -> f32 { return x; }
    \\@compute @workgroup_size(1) fn main() { let x = 1; }
;

const invalid_source: [:0]const u8 = "fn { invalid }";

const multi_line: [:0]const u8 =
    \\const a = 1;
    \\const b = 2;
    \\const c = 3;
    \\fn f() { let x = a + b + c; }
;

// =========================================================================
// Helpers
// =========================================================================

/// Parse a module from source using the given allocator (setup for module-level tests).
fn parseTestModule(arena: std.mem.Allocator, source: [:0]const u8) !*Ast.Module {
    var tokens = try Lexer.tokenize(arena, source);
    defer tokens.deinit(arena);
    var parser = try Parser.init(arena, source, tokens);
    return try parser.parse();
}

// =========================================================================
// Tier 1: Public API exhaustive OOM tests
//
// These test the complete pipeline through the internal ArenaAllocator.
// The ArenaAllocator allocates pages from our failing allocator.
// =========================================================================

fn testMinifyDefault(allocator: std.mem.Allocator) !void {
    var result = wgslender.minifyWithOptions(allocator, simple_fn, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    result.deinit(allocator);
}

test "public API: minify default options — exhaustive OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testMinifyDefault, .{});
}

fn testMinifyStructBinding(allocator: std.mem.Allocator) !void {
    var result = wgslender.minifyWithOptions(allocator, struct_binding, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    result.deinit(allocator);
}

test "public API: minify struct+binding shader — exhaustive OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testMinifyStructBinding, .{});
}

fn testMinifyWithSourceMap(allocator: std.mem.Allocator) !void {
    var result = wgslender.minifyWithOptions(allocator, simple_fn, .{
        .generate_source_map = true,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    result.deinit(allocator);
}

test "public API: minify with source map — exhaustive OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testMinifyWithSourceMap, .{});
}

fn testMinifySortAndScopeLocal(allocator: std.mem.Allocator) !void {
    var result = wgslender.minifyWithOptions(allocator, multi_fn, .{
        .sort_declarations = true,
        .scope_local_rename = true,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    result.deinit(allocator);
}

test "public API: minify sort+scope-local — exhaustive OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testMinifySortAndScopeLocal, .{});
}

fn testMinifyTreeShaking(allocator: std.mem.Allocator) !void {
    var result = wgslender.minifyWithOptions(allocator, dead_code, .{
        .tree_shaking = true,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    result.deinit(allocator);
}

test "public API: minify with tree shaking — exhaustive OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testMinifyTreeShaking, .{});
}

fn testValidateValid(allocator: std.mem.Allocator) !void {
    var result = wgslender.validateWithOptions(allocator, struct_binding, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    result.deinit(allocator);
}

test "public API: validate valid shader — exhaustive OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testValidateValid, .{});
}

fn testValidateInvalid(allocator: std.mem.Allocator) !void {
    var result = wgslender.validateWithOptions(allocator, invalid_source, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    result.deinit(allocator);
}

test "public API: validate invalid shader — exhaustive OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testValidateInvalid, .{});
}

fn testReflect(allocator: std.mem.Allocator) !void {
    var result = wgslender.reflect(allocator, struct_binding) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    result.deinit(allocator);
}

test "public API: reflect — exhaustive OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testReflect, .{});
}

fn testMinifyAndReflect(allocator: std.mem.Allocator) !void {
    var result = wgslender.minifyAndReflect(allocator, struct_binding, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    result.deinit(allocator);
}

test "public API: minifyAndReflect — exhaustive OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testMinifyAndReflect, .{});
}

fn testCompile(allocator: std.mem.Allocator) !void {
    var result = Compiler.compile(allocator, simple_fn, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    result.deinit(allocator);
}

test "public API: compile — exhaustive OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testCompile, .{});
}

// =========================================================================
// Tier 2: Module-level exhaustive OOM tests
//
// Functions designed for arena allocators (Parser, Validator, Reflect,
// SourceMap, Minifier.minify) wrap the failing allocator in an ArenaAllocator
// to match production usage and ensure proper cleanup.
// =========================================================================

// --- Lexer (uses allocator directly for MultiArrayList) ---

fn testLexerTokenize(allocator: std.mem.Allocator, source: [:0]const u8) !void {
    var tokens = Lexer.tokenize(allocator, source) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    tokens.deinit(allocator);
}

test "Lexer.tokenize: simple fn — exhaustive OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testLexerTokenize, .{simple_fn});
}

test "Lexer.tokenize: complex shader — exhaustive OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testLexerTokenize, .{struct_binding});
}

// --- Parser (arena-designed: wraps failing allocator in ArenaAllocator) ---

fn testParserParseArena(allocator: std.mem.Allocator, source: [:0]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const tokens = Lexer.tokenize(alloc, source) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    var parser = Parser.init(alloc, source, tokens) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    _ = parser.parse() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return, // parse errors are fine
    };
}

test "Parser.parse: simple fn — exhaustive OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testParserParseArena, .{simple_fn});
}

test "Parser.parse: struct+binding — exhaustive OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testParserParseArena, .{struct_binding});
}

test "Parser.parse: multi-function — exhaustive OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testParserParseArena, .{multi_fn});
}

// --- Dce (uses allocator directly with proper defer/errdefer) ---

fn testDceMark(allocator: std.mem.Allocator, module: *Ast.Module) !void {
    var liveness = Liveness.init(allocator, module.symbols.items.len) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    // Liveness uses the test allocator (not an arena), so it must be
    // freed explicitly on every exit path — including the DCE OOM path.
    defer liveness.bits.deinit(allocator);
    _ = Dce.mark(allocator, module, &liveness) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
}

test "Dce.mark: shader with dead code — exhaustive OOM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = try parseTestModule(arena.allocator(), dead_code);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testDceMark, .{module});
}

// --- Renamer (uses allocator directly, returns owned map) ---

fn testComputeReservedNames(allocator: std.mem.Allocator) !void {
    var reserved = Renamer.computeReservedNames(allocator) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    reserved.deinit(allocator);
}

test "Renamer.computeReservedNames — exhaustive OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testComputeReservedNames, .{});
}

// --- Validator (arena-designed: wraps in ArenaAllocator) ---

fn testValidatorValidate(allocator: std.mem.Allocator, source: [:0]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const tokens = Lexer.tokenize(alloc, source) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    var parser = Parser.init(alloc, source, tokens) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    const module = parser.parse() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    _ = Validator.validate(alloc, module, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
}

test "Validator.validate: valid shader — exhaustive OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testValidatorValidate, .{struct_binding});
}

// --- Reflect (arena-designed: wraps in ArenaAllocator) ---

fn testReflectModule(allocator: std.mem.Allocator, source: [:0]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const tokens = Lexer.tokenize(alloc, source) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    var parser = Parser.init(alloc, source, tokens) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    const module = parser.parse() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    _ = Reflect.reflect(alloc, module) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
}

test "Reflect.reflect: shader with bindings — exhaustive OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testReflectModule, .{struct_binding});
}

// --- Printer (arena-designed: wraps in ArenaAllocator) ---

fn testPrinterPrint(allocator: std.mem.Allocator, source: [:0]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const tokens = Lexer.tokenize(alloc, source) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    var parser = Parser.init(alloc, source, tokens) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    const module = parser.parse() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    var printer = Printer.init(alloc, .{}, module.symbols.items);
    _ = printer.print(module) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
}

test "Printer.print: struct+binding shader — exhaustive OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testPrinterPrint, .{struct_binding});
}

test "Printer.print: multi-function shader — exhaustive OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testPrinterPrint, .{multi_fn});
}

// --- SourceMap (uses allocator for LineIndex) ---

fn testSourceMapInit(allocator: std.mem.Allocator, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = SourceMap.Generator.init(arena.allocator(), source) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
}

test "SourceMap.Generator.init — exhaustive OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testSourceMapInit, .{@as([]const u8, multi_line)});
}

// --- Diagnostic (uses allocator for LineIndex, has deinit) ---

fn testDiagnosticInit(allocator: std.mem.Allocator, source: []const u8) !void {
    var diag = Diagnostic.init(allocator, source) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    diag.deinit(allocator);
}

test "Diagnostic.init: multi-line source — exhaustive OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testDiagnosticInit, .{@as([]const u8, multi_line)});
}

// --- Minifier.minify (arena-designed: wraps in ArenaAllocator) ---

fn testMinifierMinify(allocator: std.mem.Allocator, source: [:0]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = Minifier.minify(arena.allocator(), source, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
}

test "Minifier.minify: simple fn — exhaustive OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testMinifierMinify, .{simple_fn});
}

test "Minifier.minify: struct+binding — exhaustive OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testMinifierMinify, .{struct_binding});
}
