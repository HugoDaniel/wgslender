//! WGSL minification pipeline.
//!
//! Public surface: `minify(arena, source, options)` and
//! `minifyAndReflect(...)`. Internally `minifyCore` builds the standard
//! `Pipeline.Pass` list and feeds it to `Pipeline.run`. The pass list
//! lives in `default_passes` below; downstream tooling that wants a
//! different shape can build its own list and call `Pipeline.run`
//! directly.
//!
//! Standard pass order (see `Pipeline` for per-pass contracts):
//!   tokenize → parse → mark_api_facing → dce → compute_usage →
//!   build_reserved_names → init_source_map → build_renamer → print →
//!   finalize_source_map.
//!
//! Invariants:
//!   - Entry points and `@group/@binding` vars are marked API-facing
//!     BEFORE DCE, so tree-shaking never removes anything a downstream
//!     pipeline binds by name.
//!   - Identifier renaming assigns the shortest names to the most
//!     frequently used symbols (frequency-descending). Ties break by
//!     stable symbol-index order so runs are deterministic.
//!   - `result.minified_size <= result.original_size` when
//!     `options.minify_whitespace` is true — asserted as a post-condition.
//!   - `result.errors.len == 0` on the success path; the error fallback
//!     replaces `result.code` with the original source before returning.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Parser = @import("Parser.zig");
const Printer = @import("Printer.zig");
const RenamerMod = @import("Renamer.zig");
const Dce = @import("Dce.zig");
const RenamePolicy = @import("RenamePolicy.zig");
const SourceMap = @import("SourceMap.zig");
const Pipeline = @import("Pipeline.zig");
// Aliased to avoid shadowing the `options` parameter carried by `minify`,
// `minifyAndReflect`, and `minifyCore`.
const options_spec = @import("options.zig");

const Reflect = @import("Reflect.zig");

const Minifier = @This();

pub const SourceMapOptions = struct {
    file: []const u8 = "",
    source_name: []const u8 = "",
    include_source: bool = false,
};

pub const Options = struct {
    minify_whitespace: bool = true,
    minify_identifiers: bool = true,
    minify_syntax: bool = true,
    mangle_external_bindings: bool = false,
    tree_shaking: bool = true,
    preserve_uniform_struct_types: bool = false,
    keep_names: []const []const u8 = &.{},
    generate_source_map: bool = false,
    source_map_options: SourceMapOptions = .{},
    /// Sort module-level declarations by kind (struct→alias→const→var→fn) then
    /// by size. Groups similar declarations together for better DEFLATE compression.
    /// Safe because WGSL module-level declarations have no text-order dependency.
    sort_declarations: bool = false,
    /// Within each function, rename parameters and locals to a canonical sequence
    /// (a, b, c, ...) restarting per function. Makes structurally similar functions
    /// produce near-identical text, improving DEFLATE compression.
    scope_local_rename: bool = false,
};

comptime {
    // Drift guard: every `minifier_options_specs` entry must name a real
    // `Options` field — the spec table and this struct are two views of the
    // same knobs (options.zig documents both as targets), and renaming one
    // without the other silently drops a JSON/CLI option. The source-map and
    // lint specs target `Config`, not `Options`, so only the minifier subset
    // applies here. This is the install `options.zig` documents as intended
    // but was never wired for `Options` (Config already installs its own).
    options_spec.assertSpecFieldsExist(Options, &options_spec.minifier_options_specs);
}

pub const Result = struct {
    code: []const u8,
    errors: []const Parser.ParseError,
    original_size: usize,
    minified_size: usize,
    symbols_total: usize,
    symbols_dead: u32,
    source_map: ?SourceMap.Result = null,
    /// Internal arena owning all allocated data. Call `deinit()` to free.
    /// Null when called directly (caller manages memory).
    _arena: ?std.heap.ArenaAllocator = null,

    /// Free all memory owned by this result. After calling deinit, all
    /// slices (code, errors, source_map) are invalid.
    pub fn deinit(self: *Result, allocator: Allocator) void {
        _ = allocator;
        var arena = self._arena orelse return;
        arena.deinit();
        self._arena = null;
    }
};

/// Returns default minification options (all minification enabled).
pub fn defaultOptions() Options {
    return .{};
}

/// Minify WGSL source code. Returns the minified code and statistics.
/// The returned code is owned by the arena allocator.
pub fn minify(arena: Allocator, source: [:0]const u8, options: Options) !Result {
    const core = try minifyCore(arena, source, options);
    return core.result;
}

pub const MinifyAndReflectResult = struct {
    minify: Result,
    reflect: Reflect.ReflectResult,
    _arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(self: *MinifyAndReflectResult, allocator: Allocator) void {
        _ = allocator;
        var arena = self._arena orelse return;
        arena.deinit();
        self._arena = null;
    }
};

/// Minify and reflect in a single pass, sharing the parsed module and renamer.
/// Reflection uses the minified names so callers can map bindings to the
/// minified output.
pub fn minifyAndReflect(arena: Allocator, source: [:0]const u8, options: Options) !MinifyAndReflectResult {
    const core = try minifyCore(arena, source, options);
    var out: MinifyAndReflectResult = .{ .minify = core.result, .reflect = .{} };
    if (core.extras) |ex| {
        out.reflect = try Reflect.reflectWithRenamer(arena, ex.module, ex.renamer);
    } else {
        for (core.result.errors) |err| {
            try out.reflect.errors.append(arena, err.message);
        }
    }
    return out;
}

const MinifyExtras = struct {
    module: *Ast.Module,
    renamer: *const Printer.Renamer,
};

const MinifyCore = struct {
    result: Result,
    /// Null when the parser-error early-return path was taken; populated on
    /// the success path with the module and renamer needed by reflection.
    extras: ?MinifyExtras,
};

/// Default pass list for the minify pipeline. Conditional steps
/// (`init_source_map`, `finalize_source_map`) read `options` themselves
/// and become no-ops when not requested, so the list shape stays
/// uniform regardless of options.
const default_passes: []const Pipeline.Pass = &.{
    .tokenize,
    .parse,
    .mark_api_facing,
    .dce,
    .compute_usage,
    .build_reserved_names,
    .init_source_map,
    .build_renamer,
    .print,
    .finalize_source_map,
};

fn minifyCore(arena: Allocator, source: [:0]const u8, options: Options) !MinifyCore {
    // Pre-conditions: source is sentinel-terminated (enforced by type),
    // keep_names entries must not be empty strings, and the source size
    // fits the u32 ranges Diagnostic / source-map encoders use throughout.
    std.debug.assert(source.len < std.math.maxInt(u32));
    for (options.keep_names) |name| {
        std.debug.assert(name.len > 0);
    }

    var result = Result{
        .code = "",
        .errors = &.{},
        .original_size = source.len,
        .minified_size = 0,
        .symbols_total = 0,
        .symbols_dead = 0,
    };

    var state = Pipeline.State.init(arena, source);
    try Pipeline.run(&state, default_passes, options);

    // Parse-failure fallback: emit original source and surface errors.
    if (state.errors.len > 0 or state.module == null) {
        result.code = source;
        result.minified_size = source.len;
        result.errors = state.errors;
        return .{ .result = result, .extras = null };
    }

    const module = state.module.?;
    checkModuleInvariants(module);

    result.code = state.output orelse "";
    result.source_map = state.source_map;
    result.symbols_dead = state.symbols_dead;
    result.minified_size = result.code.len;
    result.symbols_total = module.symbols.items.len;

    // Post-conditions
    std.debug.assert(result.minified_size <= result.original_size or !options.minify_whitespace);
    std.debug.assert(result.symbols_dead <= module.symbols.items.len);
    // Successful minify never returns parser errors — the parse-failure
    // branch above replaces `result.code` with `source` and bails before
    // reaching here, so on this path errors must be empty.
    std.debug.assert(result.errors.len == 0);

    return .{
        .result = result,
        .extras = .{ .module = module, .renamer = state.renamer.? },
    };
}

/// Debug-only: verify module invariants after DCE and API marking.
fn checkModuleInvariants(module: *const Ast.Module) void {
    // Every declaration's name ref (if valid) must be in-bounds.
    for (module.declarations.items) |decl| {
        const ref = decl.nameRef();
        if (ref.isValid()) {
            std.debug.assert(ref.index() < module.symbols.items.len);
        }
    }
    // Every live symbol must have a non-empty original name.
    for (module.symbols.items, 0..) |sym, i| {
        if (module.liveness.isLive(@intCast(i))) {
            std.debug.assert(sym.original_name.len > 0);
        }
    }
}

pub fn computeSymbolUsage(arena: Allocator, module: *const Ast.Module) !std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32) {
    var uses: std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32) = .empty;
    for (module.declarations.items) |decl| {
        try countDeclUsage(arena, decl, &uses);
    }
    return uses;
}

/// Build the per-pipeline rename-protection policy. Entry points, builtins,
/// overrides, and — unless `options.mangle_external_bindings` — external
/// bindings are always pinned. `honor_user_pins` additionally pins user
/// `keep_names` and, when `options.preserve_uniform_struct_types` is set,
/// uniform struct types. The full minify pipeline passes `true`; the size
/// estimator passes `false` to model a hypothetical minify that ignores those
/// user pins (it only cares about kind / external-binding marks). Returns an
/// arena-owned policy box so callers can stash the pointer.
pub fn buildRenamePolicy(
    arena: Allocator,
    module: *const Ast.Module,
    options: Options,
    honor_user_pins: bool,
) Allocator.Error!*RenamePolicy {
    var builder = try RenamePolicy.Builder.init(arena, module.symbols.items.len);
    builder.markEntryPoints(module);
    builder.markBuiltinsAndOverrides(module);
    if (!options.mangle_external_bindings) builder.markExternalBindings(module);
    if (honor_user_pins) {
        builder.markKeepNames(module, options.keep_names);
        if (options.preserve_uniform_struct_types) builder.markUniformStructTypes(module);
    }
    const box = try arena.create(RenamePolicy);
    box.* = builder.build();
    return box;
}

fn countDeclUsage(arena: Allocator, decl: Ast.Decl, uses: *std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32)) Allocator.Error!void {
    switch (decl) {
        .@"const" => |d| {
            if (d.initializer) |init_expr| try countExprUsage(arena, init_expr, uses);
        },
        .override => |d| {
            try countAttrUsage(arena, d.attributes.items, uses);
            if (d.initializer) |init_expr| try countExprUsage(arena, init_expr, uses);
        },
        .@"var" => |d| {
            try countAttrUsage(arena, d.attributes.items, uses);
            if (d.initializer) |init_expr| try countExprUsage(arena, init_expr, uses);
        },
        .let => |d| {
            if (d.initializer) |init_expr| try countExprUsage(arena, init_expr, uses);
        },
        .function => |d| {
            // Count function name itself
            if (d.name.isValid()) {
                const entry = try uses.getOrPutValue(arena, d.name, 0);
                entry.value_ptr.* += 1;
            }
            try countAttrUsage(arena, d.attributes.items, uses);
            for (d.parameters.items) |param| {
                try countAttrUsage(arena, param.attributes.items, uses);
            }
            try countAttrUsage(arena, d.return_attr.items, uses);
            if (d.body) |body| try countStmtUsage(arena, .{ .compound = body }, uses);
        },
        .@"struct" => |d| {
            for (d.members.items) |member| {
                try countAttrUsage(arena, member.attributes.items, uses);
            }
        },
        .alias, .const_assert => {},
    }
}

/// Counts symbol-ref usage in attribute args, mirroring `AstVisit`'s
/// `visitAttributes` filter. The renamer's frequency model needs the
/// same view as DCE: bumps for const-expression attrs (`@group`,
/// `@workgroup_size`, etc.), skips for enum-keyword attrs (`@builtin`,
/// `@interpolate`, `@diagnostic`).
fn countAttrUsage(
    arena: Allocator,
    attrs: []const Ast.Attribute,
    uses: *std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32),
) Allocator.Error!void {
    for (attrs) |attr| {
        if (!Ast.attributeArgsResolveSymbols(attr.name)) continue;
        for (attr.args.items) |arg| try countExprUsage(arena, arg, uses);
    }
}

/// Iteratively counts symbol usage in an expression tree using a worklist.
fn countExprUsage(arena: Allocator, expr: Ast.Expr, uses: *std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32)) Allocator.Error!void {
    var stack: std.ArrayList(Ast.Expr) = .empty;
    defer stack.deinit(arena);
    try stack.append(arena, expr);

    for (0..65536) |_| {
        const e = stack.pop() orelse break;
        switch (e) {
            .ident => |ie| {
                if (ie.ref.isValid()) {
                    const entry = try uses.getOrPutValue(arena, ie.ref, 0);
                    entry.value_ptr.* += 1;
                }
            },
            .binary => |be| {
                try stack.append(arena, be.right);
                try stack.append(arena, be.left);
            },
            .unary => |ue| try stack.append(arena, ue.operand),
            .call => |ce| {
                var i = ce.args.items.len;
                while (i > 0) {
                    i -= 1;
                    try stack.append(arena, ce.args.items[i]);
                }
                if (ce.func) |f| try stack.append(arena, f);
            },
            .index => |ie| {
                try stack.append(arena, ie.idx);
                try stack.append(arena, ie.base);
            },
            .member => |me| try stack.append(arena, me.base),
            .paren => |pe| try stack.append(arena, pe.expr),
            .literal => {},
        }
    } else unreachable;
}

/// Iteratively counts symbol usage in a statement tree using a worklist.
fn countStmtUsage(arena: Allocator, stmt: Ast.Stmt, uses: *std.AutoHashMapUnmanaged(Ast.SymbolIndex, u32)) Allocator.Error!void {
    var stack: std.ArrayList(Ast.Stmt) = .empty;
    defer stack.deinit(arena);
    try stack.append(arena, stmt);

    for (0..65536) |_| {
        const s = stack.pop() orelse break;
        switch (s) {
            .compound => |cs| {
                for (cs.stmts.items) |inner| try stack.append(arena, inner);
            },
            .@"return" => |rs| {
                if (rs.value) |v| try countExprUsage(arena, v, uses);
            },
            .@"if" => |is| {
                try countExprUsage(arena, is.condition, uses);
                try stack.append(arena, .{ .compound = is.body });
                if (is.else_branch) |eb| try stack.append(arena, eb);
            },
            .@"switch" => |ss| {
                try countExprUsage(arena, ss.expr, uses);
                for (ss.cases.items) |c| {
                    for (c.selectors.items) |sel| try countExprUsage(arena, sel, uses);
                    try stack.append(arena, .{ .compound = c.body });
                }
            },
            .@"for" => |fs| {
                if (fs.init_stmt) |is| try stack.append(arena, is);
                if (fs.condition) |c| try countExprUsage(arena, c, uses);
                if (fs.update) |u| try stack.append(arena, u);
                try stack.append(arena, .{ .compound = fs.body });
            },
            .@"while" => |ws| {
                try countExprUsage(arena, ws.condition, uses);
                try stack.append(arena, .{ .compound = ws.body });
            },
            .loop => |ls| {
                try stack.append(arena, .{ .compound = ls.body });
                if (ls.continuing) |c| try stack.append(arena, .{ .compound = c });
            },
            .break_if => |bs| try countExprUsage(arena, bs.condition, uses),
            .assign => |as_| {
                try countExprUsage(arena, as_.left, uses);
                try countExprUsage(arena, as_.right, uses);
            },
            .phony => |ps| try countExprUsage(arena, ps.expr, uses),
            .incr_decr => |ids| try countExprUsage(arena, ids.expr, uses),
            .call => |cs| {
                if (cs.call.func) |f| try countExprUsage(arena, f, uses);
                for (cs.call.args.items) |arg| try countExprUsage(arena, arg, uses);
            },
            .decl => |ds| try countDeclUsage(arena, ds.decl, uses),
            .@"break", .@"continue", .discard => {},
        }
    } else unreachable;
}

// =========================================================================
// Scope-local renaming — canonical per-function naming for compression
// =========================================================================

/// Wraps the global renamer, overriding function-local symbols (parameters,
/// locals) with canonical names (a, b, c, ...) that restart in each function.
///
/// The invariant: inside a function body, every identifier the printer can
/// emit comes from one of two disjoint sets. The first is the canonical names
/// `name` assigns. The second is every name that bypasses this wrapper — the
/// base renamer's names for module-scope declarations, pinned symbols
/// answering with their source name, and the keywords and builtins the
/// pipeline already reserved. `reserve` folds the second set into the
/// pipeline's reserved names before `name` hands out any canonical name, so a
/// declaration position the walker misses keeps its base name and no
/// canonical name can land on it. Struct members are excluded: they are not
/// scope members and never occupy identifier position inside a body, so
/// reserving their names would only burn short ones.
pub const ScopeLocalRenamer = struct {
    overrides: std.AutoHashMapUnmanaged(u32, []const u8),
    base: *const Printer.Renamer,
    ren: Printer.Renamer,
    /// Set by `collect`; read by `reserve` (`all`) and `name`
    /// (`per_function`). Empty until `collect` runs.
    candidates: Candidates = .{},

    /// What `collect` found: the candidate symbols the wrapper may override.
    const Candidates = struct {
        /// One list per function, in function declaration order. Each list is
        /// in the order `name` assigns canonical names: parameters first, then
        /// body declarations in the text order of the statement walk.
        per_function: std.ArrayList(std.ArrayList(u32)) = .empty,
        /// Union of every list — `reserve`'s "the wrapper handles this"
        /// membership test.
        all: std.AutoHashMapUnmanaged(u32, void) = .{},
    };

    pub fn init(
        arena: Allocator,
        module: *const Ast.Module,
        base: *const Printer.Renamer,
        policy: *const RenamePolicy,
        reserved: *const std.StringHashMapUnmanaged(void),
    ) !*ScopeLocalRenamer {
        const self = try arena.create(ScopeLocalRenamer);
        self.* = .{ .overrides = .{}, .base = base, .ren = undefined };

        try self.collect(arena, module, policy);
        const reserved_names = try self.reserve(arena, module, base, reserved);
        try self.name(arena, &reserved_names);

        self.ren = .{ .ptr = @ptrCast(self), .nameForSymbolFn = &nameForSymbol };
        return self;
    }

    /// Walks every function into an ordered list of candidate symbols and the
    /// union of all candidates. A candidate is a parameter or body-local
    /// declaration the wrapper may override; module-scope declarations and
    /// policy-pinned symbols are not candidates, so `reserve` keeps their
    /// base names instead.
    fn collect(self: *ScopeLocalRenamer, arena: Allocator, module: *const Ast.Module, policy: *const RenamePolicy) Allocator.Error!void {
        self.candidates = .{};

        // Module-scope declarations are never candidates: the printer routes
        // global references through this same renamer, so overriding a global
        // symbol would rename it to a per-function name.
        var globals: std.AutoHashMapUnmanaged(u32, void) = .{};
        for (module.declarations.items) |decl| {
            const ref = decl.nameRef();
            if (ref.isValid()) try globals.put(arena, ref.index(), {});
        }

        for (module.declarations.items) |decl| {
            if (decl != .function) continue;
            const func = decl.function;
            var candidates: std.ArrayList(u32) = .empty;

            for (func.parameters.items) |param| {
                try addCandidate(arena, param.name, &globals, &candidates, &self.candidates.all, policy);
            }
            if (func.body) |body| {
                try collectBodyLocals(arena, body, &globals, &candidates, &self.candidates.all, policy);
            }
            try self.candidates.per_function.append(arena, candidates);
        }
    }

    /// Builds the names no canonical name may take: the pipeline's reserved
    /// set (keywords, builtins, `keep_names`) plus the base renamer's name for
    /// every symbol `collect` did not make a candidate. That covers
    /// module-scope declarations, pinned locals, and a declaration position a
    /// future walker misses — the missed symbol keeps its base name, and
    /// reserving that name stops any canonical name from landing on it.
    fn reserve(
        self: *const ScopeLocalRenamer,
        arena: Allocator,
        module: *const Ast.Module,
        base: *const Printer.Renamer,
        inherited: *const std.StringHashMapUnmanaged(void),
    ) Allocator.Error!std.StringHashMapUnmanaged(void) {
        // Copy entry by entry instead of aliasing `inherited.*`: this map is
        // appended to below, and the copy's own `count()` has to stay an
        // exact bound for `allocCanonicalName`'s walk.
        var reserved: std.StringHashMapUnmanaged(void) = .{};
        var inherited_iter = inherited.iterator();
        while (inherited_iter.next()) |entry| try reserved.put(arena, entry.key_ptr.*, {});

        for (module.symbols.items, 0..) |sym, i| {
            if (sym.kind == .member) continue;
            const index: u32 = @intCast(i);
            if (self.candidates.all.contains(index)) continue;
            const base_name = base.nameForSymbol(@enumFromInt(index));
            if (base_name.len == 0) continue;
            try reserved.put(arena, base_name, {});
        }
        return reserved;
    }

    /// Per function, restarts the counter and assigns a canonical name to
    /// each candidate in order, skipping the reserved set.
    fn name(self: *ScopeLocalRenamer, arena: Allocator, reserved: *const std.StringHashMapUnmanaged(void)) Allocator.Error!void {
        var name_buf: [16]u8 = undefined;
        for (self.candidates.per_function.items) |candidates| {
            var name_idx: u32 = 0;
            for (candidates.items) |sym_idx| {
                const canonical = try allocCanonicalName(arena, &name_buf, &name_idx, reserved);
                try self.overrides.put(arena, sym_idx, canonical);
            }
        }
    }

    /// Appends `ref` to the ordered candidate list and the union set unless it
    /// is a module-scope declaration or pinned by the policy.
    fn addCandidate(
        arena: Allocator,
        ref: Ast.SymbolIndex,
        globals: *const std.AutoHashMapUnmanaged(u32, void),
        candidates: *std.ArrayList(u32),
        candidate_set: *std.AutoHashMapUnmanaged(u32, void),
        policy: *const RenamePolicy,
    ) Allocator.Error!void {
        if (!ref.isValid()) return;
        const sym_idx = ref.index();
        if (globals.contains(sym_idx)) return;
        if (policy.mustNotRename(ref)) return;
        try candidates.append(arena, sym_idx);
        try candidate_set.put(arena, sym_idx, {});
    }

    fn allocCanonicalName(arena: Allocator, buf: *[16]u8, idx: *u32, reserved: *const std.StringHashMapUnmanaged(void)) ![]const u8 {
        // At most `reserved.count()` names of the sequence can be reserved,
        // so a walk of `reserved.count() + 1` consecutive indices always
        // reaches a free name — the `unreachable` is now a true statement.
        for (0..reserved.count() + 1) |_| {
            const candidate = RenamerMod.numberToMinifiedName(buf, idx.*);
            idx.* += 1;
            if (reserved.contains(candidate)) continue;
            const copy = try arena.alloc(u8, candidate.len);
            @memcpy(copy, candidate);
            return copy;
        } else unreachable;
    }

    /// Iteratively walks compound statements, recording local declarations in
    /// the walk's naming order. A `for` initialiser declaration is recorded
    /// where the loop appears — the parser keeps it in `Ast.ForStmt.init_stmt`,
    /// outside the body this stack descends into — so the counter takes the
    /// text-order slot among the enclosing body's declarations.
    fn collectBodyLocals(
        arena: Allocator,
        body: *const Ast.CompoundStmt,
        globals: *const std.AutoHashMapUnmanaged(u32, void),
        candidates: *std.ArrayList(u32),
        candidate_set: *std.AutoHashMapUnmanaged(u32, void),
        policy: *const RenamePolicy,
    ) Allocator.Error!void {
        var bodies: std.ArrayList(*const Ast.CompoundStmt) = .empty;
        defer bodies.deinit(arena);
        try bodies.append(arena, body);

        for (0..65536) |_| {
            const current_body = bodies.pop() orelse break;
            for (current_body.stmts.items) |stmt| {
                switch (stmt) {
                    .decl => |ds| try addCandidate(arena, ds.decl.nameRef(), globals, candidates, candidate_set, policy),
                    .@"if" => |s| {
                        try bodies.append(arena, s.body);
                        // Walk else-if chain iteratively
                        var eb_opt = s.else_branch;
                        while (eb_opt) |eb| {
                            switch (eb) {
                                .@"if" => |eif| {
                                    try bodies.append(arena, eif.body);
                                    eb_opt = eif.else_branch;
                                },
                                .compound => |cs| {
                                    try bodies.append(arena, cs);
                                    break;
                                },
                                else => break,
                            }
                        }
                    },
                    .@"for" => |s| {
                        if (s.init_stmt) |is| {
                            if (is == .decl) {
                                try addCandidate(arena, is.decl.decl.nameRef(), globals, candidates, candidate_set, policy);
                            }
                        }
                        try bodies.append(arena, s.body);
                    },
                    .@"while" => |s| try bodies.append(arena, s.body),
                    .loop => |s| {
                        try bodies.append(arena, s.body);
                        if (s.continuing) |c| try bodies.append(arena, c);
                    },
                    .@"switch" => |s| {
                        for (s.cases.items) |case| try bodies.append(arena, case.body);
                    },
                    .compound => |s| try bodies.append(arena, s),
                    else => {},
                }
            }
        } else unreachable;
    }

    fn nameForSymbol(ptr: *const anyopaque, ref: Ast.SymbolIndex) []const u8 {
        const self: *const ScopeLocalRenamer = @ptrCast(@alignCast(ptr));
        if (!ref.isValid()) return "";
        if (self.overrides.get(ref.index())) |override| return override;
        return self.base.nameForSymbol(ref);
    }
};

// =========================================================================
// Declaration sorting — group by kind + size for better compression
// =========================================================================

/// Sort module-level declarations by kind (struct→alias→const→var→fn) then
/// by estimated size. Filters to live declarations.
pub fn sortDeclarations(arena: Allocator, module: *const Ast.Module) ![]Ast.Decl {
    var live: std.ArrayList(Ast.Decl) = .empty;
    for (module.declarations.items) |decl| {
        if (Dce.isDeclarationLive(decl, module.liveness)) {
            try live.append(arena, decl);
        }
    }

    const SortCtx = struct {
        fn lessThan(_: void, a: Ast.Decl, b: Ast.Decl) bool {
            const ka = declKind(a);
            const kb = declKind(b);
            if (ka != kb) return ka < kb;
            return declSize(a) < declSize(b);
        }

        fn declKind(d: Ast.Decl) u8 {
            return switch (d) {
                .@"struct" => 0,
                .alias => 1,
                .const_assert => 2,
                .@"const" => 3,
                .override => 4,
                .@"var" => 5,
                .let => 5,
                .function => 6,
            };
        }

        fn declSize(d: Ast.Decl) u32 {
            return switch (d) {
                .function => |f| @as(u32, @intCast(f.parameters.items.len)) * 10 + if (f.body) |b| @as(u32, @intCast(b.stmts.items.len)) * 5 else 0,
                .@"struct" => |s| @as(u32, @intCast(s.members.items.len)) * 8,
                else => 1,
            };
        }
    };

    std.mem.sort(Ast.Decl, live.items, {}, SortCtx.lessThan);
    return live.items;
}

// =========================================================================
// Tests
// =========================================================================

test "minifier: basic smoke test" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn main() { let x = 1; }";
    const result = try minify(arena.allocator(), source, .{});
    try std.testing.expect(result.code.len > 0);
    try std.testing.expect(result.errors.len == 0);
}

// The fallback guarantee behind `ScopeLocalRenamer.reserve`: a declaration
// position `collect` misses must keep its base name, and that name must be
// in the reserved set `name` skips. It cannot be driven from the public API
// — nothing public misses a declaration — so this removes the `for` counter
// from the candidate lists by hand and then runs reserve and name.
test "minifier: scope-local reserve keeps a missed declaration's base name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source: [:0]const u8 =
        \\fn f(x: i32) -> i32 {
        \\  let base = x * 2;
        \\  var total = 0;
        \\  for (var idx = 0; idx < 4; idx++) {
        \\    total = total + base + idx;
        \\  }
        \\  return total;
        \\}
    ;

    // The five passes `Compiler.prepareRenamer` runs, so `base` is the real
    // frequency renamer: the missed local's base name is a short canonical
    // name the wrapper's own sequence can land on.
    var state = Pipeline.State.init(arena, source);
    try Pipeline.run(&state, &.{
        .tokenize,
        .parse,
        .mark_api_facing,
        .dce,
        .compute_usage,
        .build_reserved_names,
        .build_renamer,
    }, .{});
    const module = state.module.?;
    const base = state.renamer.?;
    const policy = state.rename_policy.?;
    const inherited = if (state.reserved) |*r| r else return error.MissingReservedNames;

    const scope = try arena.create(ScopeLocalRenamer);
    scope.* = .{ .overrides = .{}, .base = base, .ren = undefined };
    try scope.collect(arena, module, policy);

    // Simulate a walker that misses the `for` initialiser: drop the counter
    // from the ordered lists and the union set before `reserve` runs.
    var missed: ?u32 = null;
    for (module.symbols.items, 0..) |sym, i| {
        if (std.mem.eql(u8, sym.original_name, "idx")) {
            missed = @intCast(i);
            break;
        }
    }
    const missed_idx = missed orelse return error.FixtureSymbolNotFound;
    try std.testing.expect(scope.candidates.all.remove(missed_idx));
    var removed_from_list = false;
    for (scope.candidates.per_function.items) |*candidates| {
        for (candidates.items, 0..) |sym_idx, pos| {
            if (sym_idx == missed_idx) {
                _ = candidates.orderedRemove(pos);
                removed_from_list = true;
                break;
            }
        }
    }
    try std.testing.expect(removed_from_list);

    const reserved = try scope.reserve(arena, module, base, inherited);
    try scope.name(arena, &reserved);

    // The missed declaration's base name is reserved, and no canonical name
    // was handed out on top of it.
    const base_name = base.nameForSymbol(@enumFromInt(missed_idx));
    try std.testing.expect(base_name.len > 0);
    try std.testing.expect(reserved.contains(base_name));
    var override_iter = scope.overrides.valueIterator();
    while (override_iter.next()) |name| {
        try std.testing.expect(!std.mem.eql(u8, name.*, base_name));
    }
    try std.testing.expect(scope.overrides.count() > 0);
}
