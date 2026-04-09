//! wgslender — WGSL minifier.
//!
//! Public API. Each function manages memory via an internal arena: all
//! intermediate allocations (tokens, AST nodes, scopes, etc.) are bulk-freed
//! when the caller calls `result.deinit()`. This makes the API safe to use
//! with any allocator, including in long-running processes.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const version = "0.4.0";

pub const Ast = @import("Ast.zig");
pub const Lexer = @import("Lexer.zig");
pub const Parser = @import("Parser.zig");
pub const Printer = @import("Printer.zig");
pub const Renamer = @import("Renamer.zig");
pub const Dce = @import("Dce.zig");
pub const Builtins = @import("Builtins.zig");
pub const Diagnostic = @import("Diagnostic.zig");
pub const Types = @import("Types.zig");
pub const Validator = @import("Validator.zig");
pub const Minifier = @import("Minifier.zig");
pub const Config = @import("Config.zig");
pub const Reflect = @import("Reflect.zig");
pub const SourceMap = @import("SourceMap.zig");
pub const Compiler = @import("Compiler.zig");
pub const WasmBinary = @import("WasmBinary.zig");

// =========================================================================
// Minify API
// =========================================================================

/// Minify WGSL source with default options.
/// Call `result.deinit(allocator)` to free all memory.
pub fn minify(allocator: Allocator, source: [:0]const u8) !Minifier.Result {
    return minifyWithOptions(allocator, source, Minifier.defaultOptions());
}

/// Minify WGSL source with custom options.
/// Call `result.deinit(allocator)` to free all memory.
pub fn minifyWithOptions(allocator: Allocator, source: [:0]const u8, options: Minifier.Options) !Minifier.Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var result = try Minifier.minify(arena.allocator(), source, options);
    result._arena = arena;
    return result;
}

/// Minify and reflect in a single pass.
/// Call `result.deinit(allocator)` to free all memory.
pub fn minifyAndReflect(allocator: Allocator, source: [:0]const u8, options: Minifier.Options) !Minifier.MinifyAndReflectResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var result = try Minifier.minifyAndReflect(arena.allocator(), source, options);
    result._arena = arena;
    return result;
}

// =========================================================================
// Compile API (WGSL → WASM binary shader)
// =========================================================================

/// Compile WGSL source to a .wasm binary that generates the shader at runtime.
/// Call `result.deinit(allocator)` to free all memory.
pub fn compile(allocator: Allocator, source: [:0]const u8, options: Compiler.CompileOptions) !Compiler.CompileResult {
    return Compiler.compile(allocator, source, options);
}

// =========================================================================
// Validate API
// =========================================================================

/// Validate WGSL source with default options.
/// Call `result.deinit(allocator)` to free all memory.
pub fn validate(allocator: Allocator, source: [:0]const u8) !Validator.Result {
    return validateWithOptions(allocator, source, .{});
}

/// Validate WGSL source with custom options.
/// Call `result.deinit(allocator)` to free all memory.
pub fn validateWithOptions(allocator: Allocator, source: [:0]const u8, options: Validator.Options) !Validator.Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const alloc = arena.allocator();
    const tokens = try Lexer.tokenize(alloc, source);
    var parser = try Parser.init(alloc, source, tokens);
    const module = parser.parse() catch {
        const diags = try alloc.create(Diagnostic);
        diags.* = Diagnostic.init(alloc, source);
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
// Reflect API
// =========================================================================

/// Reflect WGSL source (extract bindings, layouts, entry points).
/// Call `result.deinit(allocator)` to free all memory.
pub fn reflect(allocator: Allocator, source: [:0]const u8) !Reflect.ReflectResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const alloc = arena.allocator();
    const tokens = try Lexer.tokenize(alloc, source);
    var parser = try Parser.init(alloc, source, tokens);
    const module = parser.parse() catch {
        var result = Reflect.ReflectResult{};
        result.errors.append(alloc, "parse error") catch {};
        result._arena = arena;
        return result;
    };
    var result = Reflect.reflect(alloc, module);
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

// Re-export tests from all modules
comptime {
    _ = Ast;
    _ = Lexer;
    _ = Parser;
    _ = Renamer;
    _ = Builtins;
    _ = Diagnostic;
    _ = Types;
    _ = Validator;
    _ = Reflect;
    _ = SourceMap;
    _ = Dce;
    _ = Compiler;
    _ = WasmBinary;
}
