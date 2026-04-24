//! Fast byte-size estimator for minified WGSL output.
//!
//! Phase 3 strategy: Option B (dry-run Printer with length-only renamer).
//! The estimator reuses the production `Printer` and substitutes a
//! `LengthRenamer` that returns dummy 'x'-filled slices whose lengths
//! match what the real `MinifyRenamer` would have assigned. Since the
//! Printer is the authority on minified output, total_min matches
//! `Minifier.minify(...).code.len` exactly on well-formed shaders (tighter
//! than the plan's 5% parity guard).
//!
//! The gzip total is a documented heuristic: `total_gz ≈ total_min * 0.35`.
//! BPE integration (phase 8+) may replace this with a histogram-based
//! approximation; the shape of `EstimateResult` won't change.
//!
//! Mutation policy: the estimator does NOT mutate `must_not_be_renamed`
//! (that side-effect is inlined via `isRenameable`). It DOES invoke
//! `Dce.mark` when `options.tree_shaking` is set — idempotent, matches the
//! real pipeline, and necessary so `Printer.tree_shaking` + `sortDeclarations`
//! see correct `is_live` flags.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const Dce = @import("Dce.zig");
const Minifier = @import("Minifier.zig");
const Printer = @import("Printer.zig");
const Renamer = @import("Renamer.zig");

// =========================================================================
// Public API
// =========================================================================

pub const Options = struct {
    /// Rename `@group/@binding` vars. Mirrors `Minifier.Options.mangle_external_bindings`.
    mangle_external_bindings: bool = false,
    /// Sort module-level declarations by kind/size. Mirrors
    /// `Minifier.Options.sort_declarations`.
    sort_declarations: bool = false,
    /// Assign per-function canonical names to parameters and locals.
    /// Mirrors `Minifier.Options.scope_local_rename`.
    scope_local_rename: bool = false,
    /// Tree-shake unreachable declarations. Mirrors
    /// `Minifier.Options.tree_shaking`.
    tree_shaking: bool = true,
};

pub const PerFunction = struct {
    min: u32,
    gz: u32,
};

pub const PerDecl = struct {
    min: u32,
};

pub const EstimateResult = struct {
    total_min: u32,
    total_gz: u32,
    per_function: std.AutoHashMapUnmanaged(Ast.SymbolIndex, PerFunction),
    per_decl: std.AutoHashMapUnmanaged(Ast.SymbolIndex, PerDecl),
};

/// Gzip ratio heuristic. Replace with a BPE/histogram-based estimator when
/// the compile-pipeline integration lands; the public API stays the same.
const gz_ratio: f32 = 0.35;

/// Estimate minified byte counts for `module` under the given options.
/// Allocations live in `arena`; the result becomes invalid when the arena
/// is deinit'd. Safe to call multiple times on the same module.
pub fn estimate(arena: Allocator, module: *Ast.Module, options: Options) !EstimateResult {
    // Step 1: populate `is_live` so both Printer.tree_shaking and
    // sortDeclarations see accurate liveness. Mirrors Minifier.minify
    // lines 136-143.
    if (options.tree_shaking) {
        _ = try Dce.mark(arena, module);
    } else {
        for (module.symbols.items) |*sym| sym.flags.is_live = true;
    }

    // Step 2: usage counts. Shared helper with the real minifier so rank
    // ordering is byte-identical.
    var uses = try Minifier.computeSymbolUsage(arena, module);
    defer uses.deinit(arena);

    // Step 3: reserved name set. Language keywords + every non-renameable
    // symbol's original name — the latter mirrors MinifyRenamer's
    // `reserveUnrenamedSymbolNames`, so the estimator doesn't pick a
    // short name that would collide with an un-renamed symbol.
    var reserved = try Renamer.computeReservedNames(arena);
    for (module.symbols.items) |*sym| {
        if (!isRenameable(sym, options)) {
            try reserved.put(arena, sym.original_name, {});
        }
    }

    // Step 4: rank renameable symbols by use_count DESC, breaking ties on
    // symbol index ASC. Same rule as MinifyRenamer.allocateSlots, with the
    // accumulate-use-counts step inlined: parser Pass 2 already populated
    // `sym.use_count` for identifier/type bindings, and
    // `computeSymbolUsage` adds references the parser didn't walk (e.g.,
    // function-name call sites). Their sum is the quantity the real
    // renamer ranks against.
    const RankedSym = struct { idx: u32, count: u32 };
    var ranked: std.ArrayListUnmanaged(RankedSym) = .empty;
    for (module.symbols.items, 0..) |*sym, i| {
        if (!isRenameable(sym, options)) continue;
        const ref: Ast.SymbolIndex = @enumFromInt(@as(u32, @intCast(i)));
        const uses_delta = uses.get(ref) orelse 0;
        const total_count = sym.use_count + uses_delta;
        if (total_count == 0) continue;
        try ranked.append(arena, .{ .idx = @intCast(i), .count = total_count });
    }
    std.mem.sort(RankedSym, ranked.items, {}, struct {
        fn lessThan(_: void, a: RankedSym, b: RankedSym) bool {
            if (a.count != b.count) return a.count > b.count;
            return a.idx < b.idx;
        }
    }.lessThan);

    // Step 5: per-rank lengths via the shared helper. Same
    // skip-reserved-word policy as MinifyRenamer.assignNames.
    const rank_lengths = try arena.alloc(u32, ranked.items.len);
    Renamer.estimateRenameLength(&reserved, rank_lengths);

    // Step 6: per-symbol byte lengths. Non-ranked symbols (unused,
    // non-renameable) print their original name, so use its byte length.
    const sym_lengths = try arena.alloc(u32, module.symbols.items.len);
    for (module.symbols.items, 0..) |*sym, i| {
        sym_lengths[i] = @intCast(sym.original_name.len);
    }
    for (ranked.items, 0..) |rs, rank| {
        sym_lengths[rs.idx] = rank_lengths[rank];
    }

    // Step 7: scratch buffer the LengthRenamer slices into. Content is
    // irrelevant — Printer.emit just appends bytes and emitSpace adjacency
    // depends on token state, not identifier content.
    var max_len: u32 = 1;
    for (sym_lengths) |len| {
        if (len > max_len) max_len = len;
    }
    const scratch = try arena.alloc(u8, max_len);
    @memset(scratch, 'x');

    const length_renamer = try arena.create(LengthRenamer);
    length_renamer.* = .{
        .sym_lengths = sym_lengths,
        .scratch = scratch,
        .ren = undefined,
    };
    length_renamer.ren = .{
        .ptr = @ptrCast(length_renamer),
        .nameForSymbolFn = &lengthRenamerNameFor,
    };

    // Optional scope-local wrapping. Mirrors Minifier.printWithRenamer
    // lines 336-339. ScopeLocalRenamer produces real canonical names for
    // locals/params; their lengths match what a real minify run produces,
    // so byte counts stay accurate.
    var active_renamer: *const Printer.Renamer = &length_renamer.ren;
    if (options.scope_local_rename) {
        const scope = try Minifier.ScopeLocalRenamer.init(arena, module, &length_renamer.ren);
        active_renamer = &scope.ren;
    }

    // Step 8: Printer set up identically to the real minify's minimum
    // configuration (whitespace + identifier + syntax minification on,
    // tree-shaking from options). `sort_declarations` is handled by the
    // per-decl loop below.
    var printer = Printer.init(arena, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .tree_shaking = if (options.sort_declarations) false else options.tree_shaking,
        .renamer = active_renamer,
    }, module.symbols.items);

    var result = EstimateResult{
        .total_min = 0,
        .total_gz = 0,
        .per_function = .empty,
        .per_decl = .empty,
    };

    // Directives first (enable/requires/diagnostic).
    for (module.directives.items) |dir| {
        printer.buf.clearRetainingCapacity();
        try printer.printDirective(dir);
        result.total_min += @intCast(printer.buf.items.len);
    }

    // Declarations. When sort_declarations is on, use Minifier's sort
    // helper (already filters to live decls); otherwise iterate the
    // module's order and filter dead decls inline — matches
    // Printer.printModule's behaviour under tree_shaking.
    const decl_list: []const Ast.Decl = if (options.sort_declarations)
        try Minifier.sortDeclarations(arena, module)
    else
        module.declarations.items;

    for (decl_list) |decl| {
        if (!options.sort_declarations and options.tree_shaking) {
            if (!Dce.isDeclarationLive(decl, module.symbols.items)) continue;
        }

        printer.buf.clearRetainingCapacity();
        try printer.printDecl(decl);
        const size: u32 = @intCast(printer.buf.items.len);
        result.total_min += size;

        const name_ref = decl.nameRef();
        if (name_ref.isValid()) {
            try result.per_decl.put(arena, name_ref, .{ .min = size });
            if (decl == .function) {
                try result.per_function.put(arena, name_ref, .{
                    .min = size,
                    .gz = estimateGz(size),
                });
            }
        }
    }

    result.total_gz = estimateGz(result.total_min);
    return result;
}

// =========================================================================
// Internals
// =========================================================================

fn isRenameable(sym: *const Ast.Symbol, options: Options) bool {
    if (sym.flags.must_not_be_renamed or sym.flags.is_entry_point) return false;
    if (sym.kind == .builtin or sym.kind == .override) return false;
    if (sym.flags.is_external_binding and !options.mangle_external_bindings) return false;
    return true;
}

fn estimateGz(min: u32) u32 {
    return @intFromFloat(@as(f32, @floatFromInt(min)) * gz_ratio);
}

const LengthRenamer = struct {
    sym_lengths: []const u32,
    scratch: []const u8,
    ren: Printer.Renamer,
};

fn lengthRenamerNameFor(ptr: *const anyopaque, ref: Ast.SymbolIndex) []const u8 {
    const self: *const LengthRenamer = @ptrCast(@alignCast(ptr));
    if (!ref.isValid()) return "";
    const idx = ref.index();
    if (idx >= self.sym_lengths.len) return "";
    const len = self.sym_lengths[idx];
    if (len == 0) return "";
    return self.scratch[0..len];
}

// =========================================================================
// Tests
// =========================================================================

test "estimate: empty module produces zero total" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Lexer = @import("Lexer.zig");
    const Parser = @import("Parser.zig");

    const source: [:0]const u8 = "";
    const tokens = try Lexer.tokenize(a, source);
    var parser = try Parser.init(a, source, tokens);
    const module = try parser.parse();

    const result = try estimate(a, module, .{});
    try std.testing.expectEqual(@as(u32, 0), result.total_min);
    try std.testing.expectEqual(@as(u32, 0), result.total_gz);
}

test "estimate: total_gz is 35% of total_min" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Lexer = @import("Lexer.zig");
    const Parser = @import("Parser.zig");

    const source: [:0]const u8 = "fn main() {}";
    const tokens = try Lexer.tokenize(a, source);
    var parser = try Parser.init(a, source, tokens);
    const module = try parser.parse();

    const result = try estimate(a, module, .{});
    const expected: u32 = @intFromFloat(@as(f32, @floatFromInt(result.total_min)) * gz_ratio);
    try std.testing.expectEqual(expected, result.total_gz);
}
