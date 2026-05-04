//! Per-pipeline rename-protection policy.
//!
//! Replaces the `Symbol.flags.must_not_be_renamed` and
//! `Symbol.flags.parser_wants_no_rename` fields deleted in B.M5 of the
//! Symbol-immutability arc. Orchestrators (Minifier, Compiler,
//! MinifyEstimator) build a `RenamePolicy` via `Builder` and hand it to
//! the `MinifyRenamer` for the duration of one pipeline run.
//!
//! ## Reason precedence
//!
//! `markIdx` is "first reason wins" — a subsequent mark on a symbol
//! that already has a reason is a no-op. Orchestrators control
//! precedence by ordering Builder calls. The default order
//! (`entry_point` first, then the kind-based reasons, then
//! `keep_names`, then `uniform_struct_type`) was chosen so that the
//! most informative reason wins for diagnostics — but the boolean
//! answer (`mustNotRename`) is order-independent.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");

const RenamePolicy = @This();

/// Why a symbol is rename-protected. Reserved for diagnostics and for
/// future passes that may want to act on the *source* of the protection
/// (e.g., "skip external_binding when --mangle-external-bindings is
/// set"). Today's readers only consult `mustNotRename`.
pub const Reason = enum(u8) {
    none = 0,
    /// Function carries a `@vertex` / `@fragment` / `@compute` attribute.
    entry_point,
    /// `kind == .builtin`.
    builtin,
    /// `kind == .override` — pipeline-overridable constant.
    override_kind,
    /// `@group/@binding` global, when not opted in to mangling.
    external_binding,
    /// User-supplied via `--keep-names` or config.
    keep_names,
    /// Struct type referenced by an external-binding `var`, when
    /// `preserve_uniform_struct_types` is set.
    uniform_struct_type,
};

/// Dense per-symbol reason table, indexed by `SymbolIndex.index()`.
/// Length equals the symbol-table size at `Builder.init`-time. Symbols
/// added after the Builder runs are treated as `Reason.none` — matches
/// the field-side semantics where new symbols default to
/// `must_not_be_renamed = false`.
reasons: []Reason,

pub fn init(arena: Allocator, n_symbols: usize) !RenamePolicy {
    const reasons = try arena.alloc(Reason, n_symbols);
    @memset(reasons, .none);
    return .{ .reasons = reasons };
}

pub fn mustNotRename(self: RenamePolicy, sym: Ast.SymbolIndex) bool {
    if (!sym.isValid()) return false;
    const idx = sym.index();
    if (idx >= self.reasons.len) return false;
    return self.reasons[idx] != .none;
}

pub fn reasonFor(self: RenamePolicy, sym: Ast.SymbolIndex) Reason {
    if (!sym.isValid()) return .none;
    const idx = sym.index();
    if (idx >= self.reasons.len) return .none;
    return self.reasons[idx];
}

pub const Builder = struct {
    policy: RenamePolicy,

    pub fn init(arena: Allocator, n_symbols: usize) !Builder {
        return .{ .policy = try RenamePolicy.init(arena, n_symbols) };
    }

    fn markIdx(self: *Builder, idx: u32, reason: Reason) void {
        if (idx >= self.policy.reasons.len) return;
        if (self.policy.reasons[idx] == .none) self.policy.reasons[idx] = reason;
    }

    pub fn markEntryPoints(self: *Builder, module: *const Ast.Module) void {
        for (module.symbols.items, 0..) |sym, i| {
            if (sym.flags.is_entry_point) self.markIdx(@intCast(i), .entry_point);
        }
    }

    pub fn markBuiltinsAndOverrides(self: *Builder, module: *const Ast.Module) void {
        for (module.symbols.items, 0..) |sym, i| {
            switch (sym.kind) {
                .builtin => self.markIdx(@intCast(i), .builtin),
                .override => self.markIdx(@intCast(i), .override_kind),
                else => {},
            }
        }
    }

    /// Marks every `@group/@binding` global. Caller must check
    /// `!mangle_external_bindings` before calling — this method
    /// unconditionally marks every external binding.
    pub fn markExternalBindings(self: *Builder, module: *const Ast.Module) void {
        for (module.symbols.items, 0..) |sym, i| {
            if (sym.flags.is_external_binding) self.markIdx(@intCast(i), .external_binding);
        }
    }

    pub fn markKeepNames(self: *Builder, module: *const Ast.Module, names: []const []const u8) void {
        if (names.len == 0) return;
        for (module.symbols.items, 0..) |sym, i| {
            for (names) |name| {
                if (std.mem.eql(u8, sym.original_name, name)) {
                    self.markIdx(@intCast(i), .keep_names);
                    break;
                }
            }
        }
    }

    /// For every external-binding `var` whose declared type is a named
    /// struct, marks the struct symbol. Mirrors
    /// `Minifier.markAPIFacingSymbols` when
    /// `preserve_uniform_struct_types` is set.
    pub fn markUniformStructTypes(self: *Builder, module: *const Ast.Module) void {
        for (module.declarations.items) |decl| {
            if (decl != .@"var") continue;
            const var_decl = decl.@"var";
            if (!var_decl.name.isValid()) continue;
            const var_idx = var_decl.name.index();
            if (var_idx >= module.symbols.items.len) continue;
            if (!module.symbols.items[var_idx].flags.is_external_binding) continue;
            const typ = var_decl.typ orelse continue;
            if (typ != .ident) continue;
            if (!typ.ident.ref.isValid()) continue;
            self.markIdx(typ.ident.ref.index(), .uniform_struct_type);
        }
    }

    pub fn build(self: Builder) RenamePolicy {
        return self.policy;
    }
};

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;

fn makeSym(name: []const u8, kind: Ast.Symbol.Kind, flags: Ast.Symbol.Flags) Ast.Symbol {
    return .{ .original_name = name, .kind = kind, .flags = flags };
}

fn newTestModule(arena: Allocator) !Ast.Module {
    const root = try arena.create(Ast.Scope);
    root.* = Ast.Scope.init(null, .module);
    return Ast.Module.init(root, "");
}

test "init: zero-fills the slice" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const policy = try RenamePolicy.init(arena_inst.allocator(), 4);
    for (policy.reasons) |r| try testing.expectEqual(Reason.none, r);
}

test "Builder: markEntryPoints picks up is_entry_point" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var module = try newTestModule(arena);
    try module.symbols.append(arena, makeSym("a", .function, .{ .is_entry_point = true }));
    try module.symbols.append(arena, makeSym("b", .function, .{}));

    var builder = try Builder.init(arena, module.symbols.items.len);
    builder.markEntryPoints(&module);
    const policy = builder.build();

    try testing.expectEqual(Reason.entry_point, policy.reasonFor(@enumFromInt(0)));
    try testing.expectEqual(Reason.none, policy.reasonFor(@enumFromInt(1)));
    try testing.expect(policy.mustNotRename(@enumFromInt(0)));
    try testing.expect(!policy.mustNotRename(@enumFromInt(1)));
}

test "Builder: markBuiltinsAndOverrides distinguishes kinds" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var module = try newTestModule(arena);
    try module.symbols.append(arena, makeSym("min", .builtin, .{}));
    try module.symbols.append(arena, makeSym("OVR", .override, .{}));
    try module.symbols.append(arena, makeSym("user_fn", .function, .{}));

    var builder = try Builder.init(arena, module.symbols.items.len);
    builder.markBuiltinsAndOverrides(&module);
    const policy = builder.build();

    try testing.expectEqual(Reason.builtin, policy.reasonFor(@enumFromInt(0)));
    try testing.expectEqual(Reason.override_kind, policy.reasonFor(@enumFromInt(1)));
    try testing.expectEqual(Reason.none, policy.reasonFor(@enumFromInt(2)));
}

test "Builder: markExternalBindings + markKeepNames" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var module = try newTestModule(arena);
    try module.symbols.append(arena, makeSym("uniforms", .@"var", .{ .is_external_binding = true }));
    try module.symbols.append(arena, makeSym("keepMe", .function, .{}));
    try module.symbols.append(arena, makeSym("internal", .function, .{}));

    var builder = try Builder.init(arena, module.symbols.items.len);
    builder.markExternalBindings(&module);
    const keep = [_][]const u8{"keepMe"};
    builder.markKeepNames(&module, &keep);
    const policy = builder.build();

    try testing.expectEqual(Reason.external_binding, policy.reasonFor(@enumFromInt(0)));
    try testing.expectEqual(Reason.keep_names, policy.reasonFor(@enumFromInt(1)));
    try testing.expectEqual(Reason.none, policy.reasonFor(@enumFromInt(2)));
}

test "Builder: first reason wins" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var module = try newTestModule(arena);
    try module.symbols.append(arena, makeSym("main", .function, .{ .is_entry_point = true }));

    var builder = try Builder.init(arena, module.symbols.items.len);
    builder.markEntryPoints(&module); // entry_point
    builder.markBuiltinsAndOverrides(&module); // would not match (kind=function), no-op
    const keep = [_][]const u8{"main"};
    builder.markKeepNames(&module, &keep); // would-be keep_names — but entry_point wins
    const policy = builder.build();

    try testing.expectEqual(Reason.entry_point, policy.reasonFor(@enumFromInt(0)));
    try testing.expect(policy.mustNotRename(@enumFromInt(0)));
}

test "mustNotRename: .none and out-of-range are silent false" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const policy = try RenamePolicy.init(arena_inst.allocator(), 2);
    try testing.expect(!policy.mustNotRename(.none));
    try testing.expect(!policy.mustNotRename(@enumFromInt(99)));
}
