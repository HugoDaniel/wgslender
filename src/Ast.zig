//! WGSL Abstract Syntax Tree.
//!
//! Uses a Go-style interface-based AST (via tagged unions) rather than the
//! flat MultiArrayList approach from the Zig compiler. This keeps the port
//! close to the Go original for correctness verification against snapshots.
//! A future optimization pass can flatten to MultiArrayList.
//!
//! Shape:
//!
//!   Module
//!   ├── source       : [:0]const u8     // borrowed; lifetime owned by caller
//!   ├── symbols      : []Symbol         // append-only; SymbolIndex is u32 offset
//!   ├── scope        : *Scope           // module-root scope; child per fn / block
//!   ├── directives   : []Directive      // enable / requires / diagnostic
//!   ├── declarations : []Decl
//!   │     ├── Struct / Alias / Override / Const / Var / Let / Function
//!   │     └── (function bodies own statements which own expressions)
//!   ├── use_counts   : UseCounts        // per-symbol, populated by AstVisit
//!   └── liveness     : Liveness         // per-symbol bits, populated by Dce
//!
//!   Stmt = compound | if | switch | for | while | loop | return | break | …
//!   Expr = literal | ident | unary | binary | call | index | member | paren
//!
//!   Symbols & scopes run in parallel:
//!     - Module.symbols is a flat append-only array; SymbolIndex(u32)
//!       is its offset, with `none` = maxInt(u32) as the sentinel.
//!     - Module.scope is a tree of binding maps (`scope.parent` walks
//!       outward); each scope holds the symbol indices declared in it.
//!
//!   Side-tables (B.M5): the Symbol record is immutable after Pass 1.
//!   Per-pipeline analysis state lives off-record:
//!     - use counts on `Module.use_counts` (UseCounts)
//!     - liveness on `Module.liveness` (Liveness)
//!     - rename pinning on per-call `RenamePolicy`
//!
//! Invariants:
//!   - Every Symbol has a non-empty `original_name` unless `kind == .unbound`.
//!     Asserted at the end of `Parser.parse`.
//!   - SymbolIndex values are always < symbols.len OR equal to `none`.
//!     `.isValid()` returns true exactly when the index is in-bounds.
//!   - The module-root scope has `parent == null`. Every other scope has
//!     a non-null parent forming an acyclic tree.
//!   - `Module.source` is sentinel-terminated and the AST's `loc` and
//!     `span` fields index into it directly.
//!   - Symbol fields are write-once (set by Parser/CstLower at declaration
//!     time, then read-only). Analysis state lives in `Module.use_counts`,
//!     `Module.liveness`, and per-call `RenamePolicy`.

const std = @import("std");
const Lexer = @import("Lexer.zig");
const UseCounts = @import("UseCounts.zig");
const Liveness = @import("Liveness.zig");

// =========================================================================
// Source spans
// =========================================================================

/// Half-open byte range `[start, end)` in the original source. Matches the
/// shape used by `Edits.TextEdit`, `Edits.Reference`, and
/// `StableId.Range` — no mental translation needed at call sites.
pub const Span = struct {
    start: u32 = 0,
    end: u32 = 0,

    pub const empty: Span = .{ .start = 0, .end = 0 };

    pub fn slice(self: Span, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }

    pub fn len(self: Span) u32 {
        return self.end - self.start;
    }

    pub fn isEmpty(self: Span) bool {
        return self.start == self.end;
    }
};

// =========================================================================
// Symbols and References
// =========================================================================

/// Index into the symbol table. Uses `none = maxInt(u32)` as sentinel,
/// avoiding Go's zero-value bug where `Ref{0,0}` passes `IsValid()`.
/// Always check `isValid()` before calling `index()`.
pub const SymbolIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn isValid(self: SymbolIndex) bool {
        return self != .none;
    }

    /// Returns the raw u32 index. Asserts `self != .none`.
    pub fn index(self: SymbolIndex) u32 {
        std.debug.assert(self != .none);
        return @intFromEnum(self);
    }
};

pub const Symbol = struct {
    /// The name as it appears in source. Never empty for valid symbols.
    original_name: []const u8,
    /// Declaration category (var / const / fn / struct / …). Determines
    /// which kinds of references can bind and how Dce treats the symbol.
    kind: Kind,
    /// Packed flag bits (entry point, api facing, builtin, external binding).
    /// B.M5 removed mutable analysis flags (`use_count`, `is_live`,
    /// `must_not_be_renamed`, `parser_wants_no_rename`) — they live on
    /// per-pipeline side-tables (`Module.use_counts`, `Module.liveness`,
    /// per-call `RenamePolicy`) so the symbol record stays immutable past
    /// Pass 1.
    flags: Flags,
    /// For function and struct symbols: index of the scope they introduce
    /// in the parent scope's `children`. Null for symbols that open no
    /// nested scope. Used by `StableId` to stabilize paths across reparses.
    nested_scope_slot: ?u32 = null,
    /// Byte offset in source where this symbol is declared.
    loc: u32 = 0,

    pub const Kind = enum(u4) {
        unbound,
        @"const",
        override,
        let,
        @"var",
        function,
        @"struct",
        alias,
        parameter,
        builtin,
        member,
    };

    /// Bit-packed symbol flags (4 bools + 4-bit padding = 1 byte).
    /// Layout is fixed — see comptime assertion at end of file.
    /// B.M6 shrunk the backing type from `u16` to `u8` after B.M5
    /// removed the four mutable analysis bits.
    pub const Flags = packed struct(u8) {
        is_entry_point: bool = false,
        /// Set for @group/@binding vars and config-preserved names.
        is_api_facing: bool = false,
        is_builtin: bool = false,
        /// Set for @group/@binding vars; enables alias generation in Printer.
        is_external_binding: bool = false,
        _padding: u4 = 0,
    };
};

// =========================================================================
// Scope
// =========================================================================

pub const ScopeMember = struct {
    ref: SymbolIndex,
    loc: u32, // Source position for text-order scoping
};

/// Structural kind of a scope. Used by `StableId` to produce reparse-stable
/// path segments. Kept intentionally coarse — all compound blocks (function
/// body, if body, else body, for body, while body, loop body, loop
/// continuing, switch case body, bare `{ }`) are `.block`. Sibling index is
/// counted among same-kind children, so inserting a statement that does not
/// create a scope — or one that creates a scope of a different kind — does
/// not shift existing indices.
pub const ScopeKind = enum(u8) {
    /// The module root scope. Exactly one per module, no parent.
    module,
    /// A function scope. Holds parameters; the function body opens a child
    /// `.block` scope.
    function,
    /// Any compound `{ ... }` block, including the implicit `for`-init scope.
    block,
};

pub const Scope = struct {
    parent: ?*Scope,
    children: std.ArrayListUnmanaged(*Scope),
    members: std.StringHashMapUnmanaged(ScopeMember),
    kind: ScopeKind,
    /// Index among same-kind children of the parent scope. Zero for the
    /// module scope. Populated when the scope is appended to
    /// `parent.children`.
    sibling_index: u32,

    /// Creates a new scope with the given parent (null for the root scope).
    pub fn init(parent: ?*Scope, kind: ScopeKind) Scope {
        return .{
            .parent = parent,
            .children = .empty,
            .members = .{},
            .kind = kind,
            .sibling_index = 0,
        };
    }
};

// =========================================================================
// Module (top level)
// =========================================================================

pub const Module = struct {
    /// The WGSL source text this AST was parsed from. Sentinel-terminated
    /// so downstream walkers can safely peek without bounds checks. Read
    /// by every consumer that resolves byte offsets (Validator, Printer,
    /// LSP hover, StableId).
    source: [:0]const u8,
    /// Top-level `enable`/`requires`/`diagnostic` directives in source order.
    directives: std.ArrayListUnmanaged(Directive),
    /// Top-level declarations (fn / var / const / override / struct / alias)
    /// in source order. Printer and Dce iterate this list.
    declarations: std.ArrayListUnmanaged(Decl),
    /// Global symbol table. `SymbolIndex` values are indices into this list.
    symbols: std.ArrayListUnmanaged(Symbol),
    /// Root scope. All nested scopes are reachable via `scope.children`.
    scope: *Scope,
    /// Per-symbol use counts produced by AstVisit Pass 2. Length matches
    /// `symbols.items.len` after Pass 2; empty before. Replaces the
    /// per-symbol `use_count` field deleted in B.M5.
    use_counts: UseCounts = .{ .counts = &.{} },
    /// Per-symbol liveness bits. Empty until DCE has run; downstream
    /// readers (Printer tree-shaking, lint, LSP unused warnings) consult
    /// this instead of the per-symbol `is_live` field deleted in B.M5.
    liveness: Liveness = .{ .bits = .{} },

    /// Creates an empty module bound to the given root scope and source text.
    pub fn init(scope: *Scope, source: [:0]const u8) Module {
        return .{
            .source = source,
            .directives = .empty,
            .declarations = .empty,
            .symbols = .empty,
            .scope = scope,
            .use_counts = .{ .counts = &.{} },
            .liveness = .{ .bits = .{} },
        };
    }

    /// Grow `use_counts.counts` to match `n_symbols`, preserving existing
    /// counts and zero-filling new slots. Idempotent if the side-table is
    /// already at least `n_symbols` long. Used by the incremental Splice
    /// after `lowerSubtreeInScope` appends fresh symbols for which the
    /// add-walk needs slots to bump.
    pub fn resizeUseCounts(self: *Module, arena: std.mem.Allocator, n_symbols: usize) !void {
        if (self.use_counts.counts.len >= n_symbols) return;
        const old = self.use_counts.counts;
        const new = try arena.alloc(u32, n_symbols);
        @memcpy(new[0..old.len], old);
        @memset(new[old.len..], 0);
        self.use_counts.counts = new;
    }

    /// Absorb every top-level decl's `interior_pending` bias into its inner
    /// spans (stmt/expr/type/attr/parameter/struct-member). No-op for decls
    /// whose bias is already zero. After this returns, all AST spans are in
    /// current source coordinates — callers can read `.span` / `.loc`
    /// without applying any bias.
    ///
    /// External readers (Validator, LSP features, StableId, Edits, Printer,
    /// Reflect) MUST call this at their entry. Callers *inside* the
    /// incremental hot path generally do NOT — they thread the owning
    /// decl's bias through find walks via the read-only `bias` parameter,
    /// avoiding the mutation cost.
    ///
    /// Amortized O(1) per edit: each bump is O(1); each absorption is
    /// O(decl interior) but only happens once per analyze cycle after a
    /// burst.
    pub fn absorbInteriors(self: *Module) void {
        for (self.declarations.items) |*d| absorbDeclInterior(d);
    }

    /// Debug-mode invariant: true when every decl's `interior_pending == 0`.
    /// Trips if an external reader forgot to call `absorbInteriors`.
    pub fn assertInteriorsAbsorbed(self: *const Module) void {
        if (comptime @import("builtin").mode == .Debug) {
            for (self.declarations.items) |d| {
                std.debug.assert(declInteriorPending(d) == 0);
            }
        }
    }

    /// Apply a single incremental edit's effect to all module span/loc
    /// fields. The interior of the top-level decl containing `splice_end_old`
    /// (the "owner") is walked eagerly — O(owner_decl_size). Non-owner
    /// decls strictly after the edit get `interior_pending += delta` and a
    /// `decl_span` bump — O(1) per decl. Symbols, scope members and
    /// directives are shifted eagerly (flat iteration, cheap).
    ///
    /// Call this AFTER the splice has resolved `old_anchor_span` but BEFORE
    /// the NEW subtree is written into the AST — the owner's old interior
    /// (still in pre-this-edit coords) is the thing being shifted. After
    /// the splice replaces the owner's compound body with NEW contents,
    /// the NEW contents (already in current coords) coexist with the rest
    /// of the owner's interior (now also in current coords). Interior
    /// coherence preserved.
    ///
    /// If the owner already had a non-zero `interior_pending` from earlier
    /// edits (this decl was "after" a prior edit elsewhere), that bias is
    /// absorbed in the same walk before applying this edit's delta.
    pub fn shiftModuleForEdit(self: *Module, splice_end_old: u32, delta: i64) void {
        if (delta == 0) {
            // Even zero-delta can happen for pure-text edits (e.g. let↔var
            // rename with equal length). No shifts to apply anywhere.
            return;
        }

        // Directives are few and always module-level — shift eagerly.
        for (self.directives.items) |*d| shiftDirectiveSpan(d, splice_end_old, delta);

        // Find the owning top-level decl. It's the one whose effective
        // span (decl_span, or expr.span() for const_assert) contains
        // `splice_end_old`. Linear scan; top-level decl count is O(100s).
        var owner_idx: ?usize = null;
        for (self.declarations.items, 0..) |d, i| {
            const eff = declEffectiveSpan(d);
            if (eff.start <= splice_end_old and splice_end_old <= eff.end) {
                owner_idx = i;
                break;
            }
        }

        for (self.declarations.items, 0..) |*d_ptr, i| {
            if (owner_idx != null and owner_idx.? == i) {
                // OWNER: absorb any existing bias, then shift interior for
                // this edit. Two passes are cheaper than a fused pass with
                // different thresholds because the bias absorb phase uses
                // threshold 0 (shift everything) while the edit phase uses
                // splice_end_old.
                const existing_bias: i32 = declInteriorPending(d_ptr.*);
                if (existing_bias != 0) {
                    // Absorb interior only; decl_span was shifted at bump
                    // time so it already sits in current coordinates.
                    shiftDeclInteriorBy(d_ptr, @as(i64, existing_bias));
                    clearDeclInteriorPending(d_ptr);
                }
                shiftDeclInteriorPart(d_ptr, splice_end_old, delta);
                // Shift decl_span boundary: owner's end extends past the
                // edit (owner.decl_span.end >= splice_end_old).
                shiftDeclSpanBoundary(d_ptr, splice_end_old, delta);
            } else {
                const eff = declEffectiveSpan(d_ptr.*);
                if (eff.start >= splice_end_old) {
                    // Strictly AFTER the edit — defer interior walk via
                    // bias bump, and shift the external decl_span.
                    bumpDeclInteriorPending(d_ptr, delta);
                    shiftDeclSpanBoundary(d_ptr, splice_end_old, delta);
                }
                // Strictly BEFORE: leave untouched.
            }
        }

        // Symbol table: shift eagerly. Typical shader has ~1000 symbols;
        // a flat loop is cheap and avoids needing a per-decl association.
        for (self.symbols.items) |*sym| {
            if (sym.loc >= splice_end_old) sym.loc = @intCast(@as(i64, sym.loc) + delta);
        }

        // Scope tree: eager, the structure is small.
        shiftScopeMembers(self.scope, splice_end_old, delta);
    }

    /// Absorb one top-level decl's interior bias, if any. Intended for the
    /// incremental find path (`findCompoundBySpan`, `findAstSlot`) to make
    /// the owner decl's interior spans match `target` coords (in current
    /// source) before descending.
    ///
    /// Identifying the owner by `target.start` (the edit's start byte) is
    /// robust: whatever decl contains the edit's start byte is the one
    /// whose interior we're about to walk.
    pub fn absorbOwnerFor(self: *Module, target: Span) void {
        for (self.declarations.items) |*d_ptr| {
            const eff = declEffectiveSpan(d_ptr.*);
            if (eff.start <= target.start and target.end <= eff.end) {
                absorbDeclInterior(d_ptr);
                return;
            }
        }
    }
};

/// Read a decl's interior bias regardless of variant.
pub fn declInteriorPending(decl: Decl) i32 {
    return switch (decl) {
        inline else => |d| d.interior_pending,
    };
}

/// Add `delta` to a decl's interior bias. Does not mutate inner spans.
pub fn bumpDeclInteriorPending(decl: *Decl, delta: i64) void {
    switch (decl.*) {
        inline else => |d| d.interior_pending = @intCast(@as(i64, d.interior_pending) + delta),
    }
}

/// Set a decl's interior bias to zero. Does not mutate inner spans.
pub fn clearDeclInteriorPending(decl: *Decl) void {
    switch (decl.*) {
        inline else => |d| d.interior_pending = 0,
    }
}

/// Walk a decl's interior once, adding `bias` to every inner span/loc.
/// Leaves `decl_span` alone (that's always in current coords). Idempotent
/// when `bias == 0`.
///
/// Used by `absorbInteriors` to drain a decl's pending bias, and by the
/// incremental hot path to shift the owning decl's interior in one pass
/// (absorbing any prior bias + applying this edit's delta).
pub fn shiftDeclInteriorBy(decl: *Decl, bias: i64) void {
    if (bias == 0) return;
    // Pass `splice_end_old = 0` so every inner span shifts (we want a
    // uniform absorbed bias, not a splice-end-thresholded shift).
    shiftDeclInteriorPart(decl, 0, bias);
}

/// Shift a decl's interior spans whose value is `>= splice_end_old` by
/// `delta`. Used by the incremental splice to shift the owning decl's
/// interior for this edit (in combination with an absorbing `+bias` pass).
pub fn shiftDeclInteriorPart(decl: *Decl, splice_end_old: u32, delta: i64) void {
    if (delta == 0) return;
    switch (decl.*) {
        .@"const" => |d| {
            if (d.typ) |t| shiftTypeSpans(t, splice_end_old, delta);
            if (d.initializer) |e| shiftExprSpans(e, splice_end_old, delta);
        },
        .override => |d| {
            if (d.typ) |t| shiftTypeSpans(t, splice_end_old, delta);
            if (d.initializer) |e| shiftExprSpans(e, splice_end_old, delta);
            for (d.attributes.items) |*a| shiftAttributeSpans(a, splice_end_old, delta);
        },
        .@"var" => |d| {
            if (d.typ) |t| shiftTypeSpans(t, splice_end_old, delta);
            if (d.initializer) |e| shiftExprSpans(e, splice_end_old, delta);
            for (d.attributes.items) |*a| shiftAttributeSpans(a, splice_end_old, delta);
        },
        .let => |d| {
            if (d.typ) |t| shiftTypeSpans(t, splice_end_old, delta);
            if (d.initializer) |e| shiftExprSpans(e, splice_end_old, delta);
        },
        .function => |d| {
            for (d.attributes.items) |*a| shiftAttributeSpans(a, splice_end_old, delta);
            for (d.parameters.items) |*p| {
                shiftNodeOffsets(p, splice_end_old, delta);
                shiftTypeSpans(p.typ, splice_end_old, delta);
                for (p.attributes.items) |*a| shiftAttributeSpans(a, splice_end_old, delta);
            }
            if (d.return_type) |t| shiftTypeSpans(t, splice_end_old, delta);
            for (d.return_attr.items) |*a| shiftAttributeSpans(a, splice_end_old, delta);
            if (d.body) |body| shiftCompoundStmtSpans(body, splice_end_old, delta);
        },
        .@"struct" => |d| {
            for (d.members.items) |*m| {
                shiftNodeOffsets(m, splice_end_old, delta);
                shiftTypeSpans(m.typ, splice_end_old, delta);
                for (m.attributes.items) |*a| shiftAttributeSpans(a, splice_end_old, delta);
            }
        },
        .alias => |d| {
            shiftTypeSpans(d.typ, splice_end_old, delta);
        },
        .const_assert => |d| {
            shiftExprSpans(d.expr, splice_end_old, delta);
        },
    }
}

/// Drain a single decl's `interior_pending` by applying it to the inner
/// spans (stmt/expr/type/attr/parameter/struct-member) and resetting to
/// 0. No-op when bias is zero.
///
/// Does NOT touch `decl_span` — that field is shifted eagerly at bump
/// time (by `Module.shiftModuleForEdit`) and always sits in current
/// coordinates, regardless of interior_pending.
pub fn absorbDeclInterior(decl: *Decl) void {
    const bias_i32: i32 = declInteriorPending(decl.*);
    if (bias_i32 == 0) return;
    shiftDeclInteriorBy(decl, @as(i64, bias_i32));
    clearDeclInteriorPending(decl);
}

/// Return the effective span used for owner-detection:
/// `decl_span` for most decl kinds, `expr.span()` for `const_assert`
/// (which has no `decl_span`).
pub fn declEffectiveSpan(decl: Decl) Span {
    return switch (decl) {
        .const_assert => |d| d.expr.span(),
        else => decl.declSpan(),
    };
}

/// Threshold-aware `decl_span` shift: only shifts endpoints `>= splice_end_old`
/// by `delta`. Used by `shiftModuleForEdit` on the OWNER (only `end`
/// typically qualifies because `start < splice_end_old`) and on non-owner
/// decls strictly after the edit (both endpoints qualify).
fn shiftDeclSpanBoundary(decl: *Decl, splice_end_old: u32, delta: i64) void {
    if (delta == 0) return;
    switch (decl.*) {
        .const_assert => {},
        inline else => |d| shiftSpan(&d.decl_span, splice_end_old, delta),
    }
}

// =========================================================================
// Directives
// =========================================================================

pub const Directive = union(enum) {
    enable: EnableDirective,
    requires: RequiresDirective,
    diagnostic: DiagnosticDirective,

    /// Byte-range covering the directive from its first keyword through
    /// the terminating `;`. Populated by the parser.
    pub fn span(self: Directive) Span {
        return switch (self) {
            .enable => |d| d.span,
            .requires => |d| d.span,
            .diagnostic => |d| d.span,
        };
    }
};

pub const EnableDirective = struct {
    features: std.ArrayListUnmanaged([]const u8),
    span: Span = .empty,
};

pub const RequiresDirective = struct {
    features: std.ArrayListUnmanaged([]const u8),
    span: Span = .empty,
};

pub const DiagnosticDirective = struct {
    severity: []const u8,
    rule: []const u8,
    span: Span = .empty,
};

// =========================================================================
// Declarations
// =========================================================================

pub const Decl = union(enum) {
    @"const": *ConstDecl,
    override: *OverrideDecl,
    @"var": *VarDecl,
    let: *LetDecl,
    function: *FunctionDecl,
    @"struct": *StructDecl,
    alias: *AliasDecl,
    const_assert: *ConstAssertDecl,

    /// Returns the symbol index of the declaration's name, if any.
    pub fn nameRef(self: Decl) SymbolIndex {
        return switch (self) {
            .@"const" => |d| d.name,
            .override => |d| d.name,
            .@"var" => |d| d.name,
            .let => |d| d.name,
            .function => |d| d.name,
            .@"struct" => |d| d.name,
            .alias => |d| d.name,
            .const_assert => .none,
        };
    }

    /// Returns the full syntactic span of the declaration, including any
    /// leading attributes and the terminating `;`/`}`. Returns
    /// `Span.empty` for `const_assert` (unnamed, not addressable).
    pub fn declSpan(self: Decl) Span {
        return switch (self) {
            .@"const" => |d| d.decl_span,
            .override => |d| d.decl_span,
            .@"var" => |d| d.decl_span,
            .let => |d| d.decl_span,
            .function => |d| d.decl_span,
            .@"struct" => |d| d.decl_span,
            .alias => |d| d.decl_span,
            .const_assert => .empty,
        };
    }
};

pub const ConstDecl = struct {
    name: SymbolIndex,
    typ: ?Type = null,
    initializer: ?Expr = null,
    /// Full syntactic span: from the `const` keyword through the
    /// terminating `;`. Empty on parse-error recovery.
    decl_span: Span = .empty,
    /// Deferred bias applied to inner spans (on `typ`, `initializer`,
    /// etc.). Drained by `absorbDeclInterior` / `Module.absorbInteriors`.
    /// Zero after a fresh parse. Populated by the incremental hot path
    /// for decls strictly after an edit.
    interior_pending: i32 = 0,
};

pub const OverrideDecl = struct {
    attributes: std.ArrayListUnmanaged(Attribute),
    name: SymbolIndex,
    typ: ?Type = null,
    initializer: ?Expr = null,
    /// Full syntactic span: from the first `@` attribute (if any) or
    /// `override` keyword through the terminating `;`.
    decl_span: Span = .empty,
    /// See `ConstDecl.interior_pending`.
    interior_pending: i32 = 0,
};

pub const VarDecl = struct {
    attributes: std.ArrayListUnmanaged(Attribute),
    address_space: AddressSpace = .none,
    access_mode: AccessMode = .none,
    name: SymbolIndex,
    typ: ?Type = null,
    initializer: ?Expr = null,
    /// Full syntactic span: from the first `@` attribute (if any) or
    /// `var` keyword through the terminating `;`.
    decl_span: Span = .empty,
    /// See `ConstDecl.interior_pending`.
    interior_pending: i32 = 0,
};

pub const LetDecl = struct {
    name: SymbolIndex,
    typ: ?Type = null,
    initializer: ?Expr = null,
    /// Full syntactic span: from the `let` keyword through the
    /// terminating `;`.
    decl_span: Span = .empty,
    /// See `ConstDecl.interior_pending`.
    interior_pending: i32 = 0,
};

pub const FunctionDecl = struct {
    attributes: std.ArrayListUnmanaged(Attribute),
    name: SymbolIndex,
    parameters: std.ArrayListUnmanaged(Parameter),
    return_type: ?Type = null,
    return_attr: std.ArrayListUnmanaged(Attribute),
    body: ?*CompoundStmt = null,
    /// Full syntactic span: from the first `@` attribute (if any) or
    /// `fn` keyword through the closing `}` of the body.
    decl_span: Span = .empty,
    /// See `ConstDecl.interior_pending`.
    interior_pending: i32 = 0,
};

pub const Parameter = struct {
    attributes: std.ArrayListUnmanaged(Attribute),
    name: SymbolIndex,
    typ: Type,
    /// Byte span from the first attribute or name token through the end of
    /// the type expression. Populated by `CstLower`; `.empty` from the
    /// legacy `Parser` construction path.
    span: Span = .empty,
};

pub const StructDecl = struct {
    name: SymbolIndex,
    members: std.ArrayListUnmanaged(StructMember),
    /// Full syntactic span: from the `struct` keyword through the
    /// closing `}`.
    decl_span: Span = .empty,
    /// See `ConstDecl.interior_pending`.
    interior_pending: i32 = 0,
};

pub const StructMember = struct {
    attributes: std.ArrayListUnmanaged(Attribute),
    name: SymbolIndex,
    typ: Type,
    /// Byte span from the first attribute or name token through the end of
    /// the type expression. Populated by `CstLower`; `.empty` from the
    /// legacy `Parser` construction path.
    span: Span = .empty,
};

pub const AliasDecl = struct {
    name: SymbolIndex,
    typ: Type,
    /// Full syntactic span: from the `alias` keyword through the
    /// terminating `;`.
    decl_span: Span = .empty,
    /// See `ConstDecl.interior_pending`.
    interior_pending: i32 = 0,
};

pub const ConstAssertDecl = struct {
    expr: Expr,
    /// See `ConstDecl.interior_pending`.
    interior_pending: i32 = 0,
};

// =========================================================================
// Address Spaces and Access Modes
// =========================================================================

pub const AddressSpace = enum(u8) {
    none,
    function,
    private,
    workgroup,
    uniform,
    storage,
    handle,

    pub fn string(self: AddressSpace) []const u8 {
        return switch (self) {
            .function => "function",
            .private => "private",
            .workgroup => "workgroup",
            .uniform => "uniform",
            .storage => "storage",
            .handle => "handle",
            .none => "",
        };
    }
};

pub const AccessMode = enum(u8) {
    none,
    read,
    write,
    read_write,

    pub fn string(self: AccessMode) []const u8 {
        return switch (self) {
            .read => "read",
            .write => "write",
            .read_write => "read_write",
            .none => "",
        };
    }
};

// =========================================================================
// Attributes
// =========================================================================

pub const Attribute = struct {
    name: []const u8,
    args: std.ArrayListUnmanaged(Expr),
    loc: u32 = 0,
    /// Byte span from the `@` through the closing `)` (or the identifier
    /// end for argument-less attributes). Populated by `CstLower`.
    span: Span = .empty,
};

/// Whether this attribute's args are const-expressions that may reference
/// user symbols (`@group(BG)`, `@workgroup_size(WG_X, ...)`, `@id(MY_ID)`,
/// `@align(N)`, `@size(N)`, `@location(N)`, `@binding(N)`, `@blend_src(N)`)
/// vs. enum-like keyword args that are NOT user references (`@builtin(...)`,
/// `@interpolate(...)`, `@diagnostic(...)`). The parser builds args as `Expr`
/// for both kinds, so traversers (Pass 2 visit, DCE deps, minifier usage,
/// incremental hot path) must filter explicitly. Default `true` — new
/// attributes walk by default; only the small enum-arg set is denied.
/// No-arg attrs (`@vertex`, `@must_use`, etc.) trivially pass through:
/// `attr.args` is empty so the predicate's answer is moot.
pub fn attributeArgsResolveSymbols(name: []const u8) bool {
    if (std.mem.eql(u8, name, "builtin")) return false;
    if (std.mem.eql(u8, name, "interpolate")) return false;
    if (std.mem.eql(u8, name, "diagnostic")) return false;
    return true;
}

// =========================================================================
// Types
// =========================================================================

pub const Type = union(enum) {
    ident: *IdentType,
    vec: *VecType,
    mat: *MatType,
    array: *ArrayType,
    ptr: *PtrType,
    atomic: *AtomicType,
    sampler: *SamplerType,
    texture: *TextureType,

    /// Byte-range covering the full type expression as written in
    /// source (e.g. `"array<vec3<f32>, 4>"`). Populated by the parser;
    /// may be `Span.empty` on error-recovery paths.
    pub fn span(self: Type) Span {
        return switch (self) {
            inline else => |ptr| ptr.span,
        };
    }
};

pub const IdentType = struct {
    name: []const u8,
    ref: SymbolIndex = .none,
    loc: u32 = 0,
    span: Span = .empty,
};

pub const VecType = struct {
    size: u8, // 2, 3, or 4
    elem_type: ?Type = null,
    shorthand: []const u8 = "",
    loc: u32 = 0,
    span: Span = .empty,
};

pub const MatType = struct {
    cols: u8,
    rows: u8,
    elem_type: ?Type = null,
    shorthand: []const u8 = "",
    loc: u32 = 0,
    span: Span = .empty,
};

pub const ArrayType = struct {
    elem_type: ?Type = null,
    size: ?Expr = null,
    span: Span = .empty,
};

pub const PtrType = struct {
    address_space: AddressSpace,
    elem_type: Type,
    access_mode: AccessMode = .none,
    span: Span = .empty,
};

pub const AtomicType = struct {
    elem_type: Type,
    loc: u32 = 0,
    span: Span = .empty,
};

pub const SamplerType = struct {
    comparison: bool,
    span: Span = .empty,
};

pub const TextureType = struct {
    kind: TextureKind,
    dimension: TextureDimension,
    sampled_type: ?Type = null,
    texel_format: []const u8 = "",
    access_mode: AccessMode = .none,
    span: Span = .empty,
};

pub const TextureKind = enum(u8) {
    sampled,
    multisampled,
    storage,
    depth,
    depth_multisampled,
    external,
};

pub const TextureDimension = enum(u8) {
    @"1d",
    @"2d",
    @"2d_array",
    @"3d",
    cube,
    cube_array,
};

// =========================================================================
// Expressions
// =========================================================================

pub const Expr = union(enum) {
    ident: *IdentExpr,
    literal: *LiteralExpr,
    binary: *BinaryExpr,
    unary: *UnaryExpr,
    call: *CallExpr,
    index: *IndexExpr,
    member: *MemberExpr,
    paren: *ParenExpr,

    /// Byte range covering the full expression as written in source.
    /// Populated by `CstLower`; `.empty` on nodes produced by the legacy
    /// `Parser` path that does not yet stamp expression spans.
    pub fn span(self: Expr) Span {
        return switch (self) {
            inline else => |ptr| ptr.span,
        };
    }
};

pub const IdentExpr = struct {
    loc: u32 = 0,
    name: []const u8,
    ref: SymbolIndex = .none,
    flags: ExprFlags = .{},
    span: Span = .empty,
    /// Set by AstVisit `.add` Pass 2 at the moment the ident's symbol use
    /// count is bumped. The `.sub` pass gates its decrement on this bit
    /// (not on `ref.isValid()`) so an ident resolved by the E0102
    /// "use-before-decl" branch — where `ref` is set for IDE goto-def but
    /// the count is intentionally *not* bumped — is correctly skipped on
    /// subtree removal. Lives directly on `IdentExpr` (rather than
    /// `ExprFlags`) because no other expression variant needs it.
    was_counted: bool = false,
};

pub const LiteralExpr = struct {
    loc: u32 = 0,
    kind: Lexer.Tag,
    value: []const u8,
    flags: ExprFlags = .{},
    span: Span = .empty,
};

pub const BinaryExpr = struct {
    loc: u32 = 0,
    op: BinaryOp,
    left: Expr,
    right: Expr,
    flags: ExprFlags = .{},
    span: Span = .empty,
};

pub const BinaryOp = enum(u8) {
    add, // +
    sub, // -
    mul, // *
    div, // /
    mod, // %
    @"and", // &
    @"or", // |
    xor, // ^
    shl, // <<
    shr, // >>
    logical_and, // &&
    logical_or, // ||
    eq, // ==
    ne, // !=
    lt, // <
    le, // <=
    gt, // >
    ge, // >=

    pub fn string(self: BinaryOp) []const u8 {
        return switch (self) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .mod => "%",
            .@"and" => "&",
            .@"or" => "|",
            .xor => "^",
            .shl => "<<",
            .shr => ">>",
            .logical_and => "&&",
            .logical_or => "||",
            .eq => "==",
            .ne => "!=",
            .lt => "<",
            .le => "<=",
            .gt => ">",
            .ge => ">=",
        };
    }
};

pub const UnaryExpr = struct {
    loc: u32 = 0,
    op: UnaryOp,
    operand: Expr,
    flags: ExprFlags = .{},
    span: Span = .empty,
};

pub const UnaryOp = enum(u8) {
    neg, // -
    not, // !
    bit_not, // ~
    deref, // *
    addr, // &

    pub fn string(self: UnaryOp) []const u8 {
        return switch (self) {
            .neg => "-",
            .not => "!",
            .bit_not => "~",
            .deref => "*",
            .addr => "&",
        };
    }
};

pub const CallExpr = struct {
    loc: u32 = 0,
    end_loc: u32 = 0,
    func: ?Expr = null,
    template_type: ?Type = null,
    args: std.ArrayListUnmanaged(Expr),
    flags: ExprFlags = .{},
    span: Span = .empty,
};

pub const IndexExpr = struct {
    loc: u32 = 0,
    end_loc: u32 = 0,
    base: Expr,
    idx: Expr,
    flags: ExprFlags = .{},
    span: Span = .empty,
};

pub const MemberExpr = struct {
    loc: u32 = 0,
    base: Expr,
    member_name: []const u8,
    member_ref: SymbolIndex = .none,
    flags: ExprFlags = .{},
    span: Span = .empty,
};

pub const ParenExpr = struct {
    expr: Expr,
    flags: ExprFlags = .{},
    span: Span = .empty,
};

/// Flags that drive dead-code elimination for expressions.
/// `can_be_removed_if_unused`: expression has no side effects (e.g., pure math).
/// `call_can_be_unwrapped_if_unused`: call result is unused but the call itself
///   may have side effects — remove the result binding, keep the call.
/// `from_pure_function`: set when the enclosing function is pure (see `pure_builtins`).
pub const ExprFlags = packed struct(u8) {
    can_be_removed_if_unused: bool = false,
    call_can_be_unwrapped_if_unused: bool = false,
    is_constant: bool = false,
    from_pure_function: bool = false,
    _padding: u4 = 0,
};

// =========================================================================
// Statements
// =========================================================================

pub const Stmt = union(enum) {
    compound: *CompoundStmt,
    @"return": *ReturnStmt,
    @"if": *IfStmt,
    @"switch": *SwitchStmt,
    @"for": *ForStmt,
    @"while": *WhileStmt,
    loop: *LoopStmt,
    @"break": *BreakStmt,
    break_if: *BreakIfStmt,
    @"continue": *ContinueStmt,
    discard: *DiscardStmt,
    assign: *AssignStmt,
    incr_decr: *IncrDecrStmt,
    call: *CallStmt,
    decl: *DeclStmt,

    /// Byte-range covering the statement from its first token through the
    /// terminator. Populated by the parser; `.empty` on error-recovery.
    pub fn span(self: Stmt) Span {
        return switch (self) {
            .compound => |s| s.span,
            .@"return" => |s| s.span,
            .@"if" => |s| s.span,
            .@"switch" => |s| s.span,
            .@"for" => |s| s.span,
            .@"while" => |s| s.span,
            .loop => |s| s.span,
            .@"break" => |s| s.span,
            .break_if => |s| s.span,
            .@"continue" => |s| s.span,
            .discard => |s| s.span,
            .assign => |s| s.span,
            .incr_decr => |s| s.span,
            .call => |s| s.span,
            .decl => |s| s.span,
        };
    }
};

pub const CompoundStmt = struct {
    stmts: std.ArrayListUnmanaged(Stmt),
    span: Span = .empty,
};

pub const ReturnStmt = struct {
    loc: u32 = 0,
    value: ?Expr = null,
    span: Span = .empty,
};

pub const IfStmt = struct {
    condition: Expr,
    body: *CompoundStmt,
    else_branch: ?Stmt = null,
    span: Span = .empty,
};

pub const SwitchStmt = struct {
    expr: Expr,
    cases: std.ArrayListUnmanaged(SwitchCase),
    span: Span = .empty,
};

pub const SwitchCase = struct {
    selectors: std.ArrayListUnmanaged(Expr),
    body: *CompoundStmt,
};

pub const ForStmt = struct {
    init_stmt: ?Stmt = null,
    condition: ?Expr = null,
    update: ?Stmt = null,
    body: *CompoundStmt,
    span: Span = .empty,
};

pub const WhileStmt = struct {
    condition: Expr,
    body: *CompoundStmt,
    span: Span = .empty,
};

pub const LoopStmt = struct {
    body: *CompoundStmt,
    continuing: ?*CompoundStmt = null,
    span: Span = .empty,
};

pub const BreakStmt = struct {
    loc: u32 = 0,
    span: Span = .empty,
};

pub const BreakIfStmt = struct {
    condition: Expr,
    span: Span = .empty,
};

pub const ContinueStmt = struct {
    loc: u32 = 0,
    span: Span = .empty,
};

pub const DiscardStmt = struct {
    loc: u32 = 0,
    span: Span = .empty,
};

pub const AssignStmt = struct {
    loc: u32 = 0,
    op: AssignOp,
    left: Expr,
    right: Expr,
    span: Span = .empty,
};

pub const AssignOp = enum(u8) {
    simple, // =
    add, // +=
    sub, // -=
    mul, // *=
    div, // /=
    mod, // %=
    @"and", // &=
    @"or", // |=
    xor, // ^=
    shl, // <<=
    shr, // >>=

    pub fn string(self: AssignOp) []const u8 {
        return switch (self) {
            .simple => "=",
            .add => "+=",
            .sub => "-=",
            .mul => "*=",
            .div => "/=",
            .mod => "%=",
            .@"and" => "&=",
            .@"or" => "|=",
            .xor => "^=",
            .shl => "<<=",
            .shr => ">>=",
        };
    }
};

pub const IncrDecrStmt = struct {
    loc: u32 = 0,
    expr: Expr,
    increment: bool, // true = ++, false = --
    span: Span = .empty,
};

pub const CallStmt = struct {
    call: *CallExpr,
    span: Span = .empty,
};

pub const DeclStmt = struct {
    decl: Decl,
    span: Span = .empty,
};

// =========================================================================
// Purity
// =========================================================================

/// WGSL builtin functions with no side effects. Used by DCE to determine
/// which calls are safe to remove when their result is unused.
pub const pure_builtins = std.StaticStringMap(void).initComptime(.{
    // Math functions
    .{ "abs", {} },               .{ "acos", {} },            .{ "acosh", {} },
    .{ "asin", {} },              .{ "asinh", {} },           .{ "atan", {} },
    .{ "atanh", {} },             .{ "atan2", {} },           .{ "ceil", {} },
    .{ "clamp", {} },             .{ "cos", {} },             .{ "cosh", {} },
    .{ "cross", {} },             .{ "degrees", {} },         .{ "determinant", {} },
    .{ "distance", {} },          .{ "dot", {} },             .{ "exp", {} },
    .{ "exp2", {} },              .{ "faceForward", {} },     .{ "floor", {} },
    .{ "fma", {} },               .{ "fract", {} },           .{ "frexp", {} },
    .{ "inverseSqrt", {} },       .{ "ldexp", {} },           .{ "length", {} },
    .{ "log", {} },               .{ "log2", {} },            .{ "max", {} },
    .{ "min", {} },               .{ "mix", {} },             .{ "modf", {} },
    .{ "normalize", {} },         .{ "pow", {} },             .{ "quantizeToF16", {} },
    .{ "radians", {} },           .{ "reflect", {} },         .{ "refract", {} },
    .{ "round", {} },             .{ "saturate", {} },        .{ "sign", {} },
    .{ "sin", {} },               .{ "sinh", {} },            .{ "smoothstep", {} },
    .{ "sqrt", {} },              .{ "step", {} },            .{ "tan", {} },
    .{ "tanh", {} },              .{ "transpose", {} },       .{ "trunc", {} },
    // Integer functions
    .{ "countLeadingZeros", {} }, .{ "countOneBits", {} },    .{ "countTrailingZeros", {} },
    .{ "extractBits", {} },       .{ "firstLeadingBit", {} }, .{ "firstTrailingBit", {} },
    .{ "insertBits", {} },        .{ "reverseBits", {} },
    // Logical
        .{ "all", {} },
    .{ "any", {} },               .{ "select", {} },
    // Constructors
             .{ "vec2", {} },
    .{ "vec3", {} },              .{ "vec4", {} },            .{ "vec2f", {} },
    .{ "vec3f", {} },             .{ "vec4f", {} },           .{ "vec2i", {} },
    .{ "vec3i", {} },             .{ "vec4i", {} },           .{ "vec2u", {} },
    .{ "vec3u", {} },             .{ "vec4u", {} },           .{ "vec2h", {} },
    .{ "vec3h", {} },             .{ "vec4h", {} },           .{ "mat2x2", {} },
    .{ "mat2x3", {} },            .{ "mat2x4", {} },          .{ "mat3x2", {} },
    .{ "mat3x3", {} },            .{ "mat3x4", {} },          .{ "mat4x2", {} },
    .{ "mat4x3", {} },            .{ "mat4x4", {} },          .{ "mat2x2f", {} },
    .{ "mat2x3f", {} },           .{ "mat2x4f", {} },         .{ "mat3x2f", {} },
    .{ "mat3x3f", {} },           .{ "mat3x4f", {} },         .{ "mat4x2f", {} },
    .{ "mat4x3f", {} },           .{ "mat4x4f", {} },         .{ "mat2x2h", {} },
    .{ "mat2x3h", {} },           .{ "mat2x4h", {} },         .{ "mat3x2h", {} },
    .{ "mat3x3h", {} },           .{ "mat3x4h", {} },         .{ "mat4x2h", {} },
    .{ "mat4x3h", {} },           .{ "mat4x4h", {} },         .{ "array", {} },
    .{ "bool", {} },              .{ "i32", {} },             .{ "u32", {} },
    .{ "f32", {} },               .{ "f16", {} },
    // Pack/unpack
                .{ "pack2x16float", {} },
    .{ "pack2x16snorm", {} },     .{ "pack2x16unorm", {} },   .{ "pack4x8snorm", {} },
    .{ "pack4x8unorm", {} },      .{ "pack4xI8", {} },        .{ "pack4xU8", {} },
    .{ "pack4xI8Clamp", {} },     .{ "pack4xU8Clamp", {} },   .{ "unpack2x16float", {} },
    .{ "unpack2x16snorm", {} },   .{ "unpack2x16unorm", {} }, .{ "unpack4x8snorm", {} },
    .{ "unpack4x8unorm", {} },    .{ "unpack4xI8", {} },      .{ "unpack4xU8", {} },
    // Derivatives
    .{ "dpdx", {} },              .{ "dpdxCoarse", {} },      .{ "dpdxFine", {} },
    .{ "dpdy", {} },              .{ "dpdyCoarse", {} },      .{ "dpdyFine", {} },
    .{ "fwidth", {} },            .{ "fwidthCoarse", {} },    .{ "fwidthFine", {} },
});

// =========================================================================
// Purity Analysis
// =========================================================================

/// Returns true if reading the symbol has no side effects.
/// All WGSL symbol kinds are pure to read.
pub fn isSymbolPure(ref: SymbolIndex, symbols: []const Symbol) bool {
    if (!ref.isValid()) return false;
    const idx = ref.index();
    return idx < symbols.len;
}

/// Returns true if the expression can be safely removed when its result is unused.
/// Uses a fixed-size iterative stack instead of recursion.
pub fn exprCanBeRemovedIfUnused(e: Expr, symbols: []const Symbol) bool {
    var stack: [128]Expr = undefined;
    var top: usize = 1;
    stack[0] = e;

    while (top > 0) {
        top -= 1;
        const expr = stack[top];
        switch (expr) {
            .literal => {},
            .ident => |ie| {
                if (!(ie.flags.can_be_removed_if_unused or !ie.ref.isValid() or isSymbolPure(ie.ref, symbols)))
                    return false;
            },
            .binary => |be| {
                if (top + 2 > stack.len) return false;
                stack[top] = be.left;
                top += 1;
                stack[top] = be.right;
                top += 1;
            },
            .unary => |ue| {
                if (top + 1 > stack.len) return false;
                stack[top] = ue.operand;
                top += 1;
            },
            .call => |ce| {
                if (!(ce.flags.can_be_removed_if_unused or ce.flags.from_pure_function)) {
                    // Check if it's a pure builtin call whose args are all removable
                    const is_pure_builtin = if (ce.func) |f| switch (f) {
                        .ident => |ident| pure_builtins.has(ident.name),
                        else => false,
                    } else false;
                    if (!is_pure_builtin) return false;
                }
                // Push all args for purity checking
                if (top + ce.args.items.len > stack.len) return false;
                for (ce.args.items) |arg| {
                    stack[top] = arg;
                    top += 1;
                }
            },
            .index => |ie| {
                if (top + 2 > stack.len) return false;
                stack[top] = ie.base;
                top += 1;
                stack[top] = ie.idx;
                top += 1;
            },
            .member => |me| {
                if (top + 1 > stack.len) return false;
                stack[top] = me.base;
                top += 1;
            },
            .paren => |pe| {
                if (top + 1 > stack.len) return false;
                stack[top] = pe.expr;
                top += 1;
            },
        }
    }
    return true;
}

/// Returns true if the statement can be removed when none of its declared symbols are used.
pub fn stmtCanBeRemovedIfUnused(stmt: Stmt, symbols: []const Symbol) bool {
    return switch (stmt) {
        .decl => |s| declCanBeRemovedIfUnused(s.decl, symbols),
        .@"return" => |s| if (s.value) |v| exprCanBeRemovedIfUnused(v, symbols) else true,
        .call, .assign, .incr_decr => false,
        .@"if", .@"for", .@"while", .loop, .@"switch" => false,
        .@"break", .break_if, .@"continue", .discard => false,
        .compound => false,
    };
}

/// Returns true if the declaration can be removed when its symbol is unused.
pub fn declCanBeRemovedIfUnused(decl: Decl, symbols: []const Symbol) bool {
    return switch (decl) {
        .@"const" => |d| if (d.initializer) |init| exprCanBeRemovedIfUnused(init, symbols) else true,
        .let => |d| if (d.initializer) |init| exprCanBeRemovedIfUnused(init, symbols) else true,
        .@"var" => |d| if (d.initializer) |init| exprCanBeRemovedIfUnused(init, symbols) else true,
        .override => false,
        .function, .@"struct", .alias => true,
        .const_assert => false,
    };
}

/// Checks if an expression has the can_be_removed_if_unused flag set.
fn exprFlagPure(e: Expr) bool {
    return switch (e) {
        inline else => |expr| expr.flags.can_be_removed_if_unused,
    };
}

/// Marks purity flags on a single expression (non-recursive).
/// Children must already be marked (call in post-order from visitExpr).
pub fn markExprPurity(e: Expr, symbols: []const Symbol) void {
    switch (e) {
        .literal => |expr| {
            expr.flags.can_be_removed_if_unused = true;
            expr.flags.is_constant = true;
        },
        .ident => |expr| {
            if (!expr.ref.isValid() or isSymbolPure(expr.ref, symbols)) {
                expr.flags.can_be_removed_if_unused = true;
            }
            if (expr.ref.isValid()) {
                const idx = expr.ref.index();
                if (idx < symbols.len and symbols[idx].kind == .@"const") {
                    expr.flags.is_constant = true;
                }
            }
        },
        .binary => |expr| {
            if (exprFlagPure(expr.left) and exprFlagPure(expr.right)) {
                expr.flags.can_be_removed_if_unused = true;
            }
        },
        .unary => |expr| {
            if (exprFlagPure(expr.operand)) {
                expr.flags.can_be_removed_if_unused = true;
            }
        },
        .call => |expr| {
            if (expr.func) |f| {
                switch (f) {
                    .ident => |ident| {
                        if (pure_builtins.has(ident.name)) {
                            expr.flags.from_pure_function = true;
                            var all_pure = true;
                            for (expr.args.items) |arg| {
                                if (!exprFlagPure(arg)) {
                                    all_pure = false;
                                    break;
                                }
                            }
                            if (all_pure) {
                                expr.flags.can_be_removed_if_unused = true;
                            }
                        }
                    },
                    else => {},
                }
            }
        },
        .index => |expr| {
            if (exprFlagPure(expr.base) and exprFlagPure(expr.idx)) {
                expr.flags.can_be_removed_if_unused = true;
            }
        },
        .member => |expr| {
            if (exprFlagPure(expr.base)) {
                expr.flags.can_be_removed_if_unused = true;
            }
        },
        .paren => |expr| {
            if (exprFlagPure(expr.expr)) {
                expr.flags.can_be_removed_if_unused = true;
            }
        },
    }
}

// =========================================================================
// Span-shift walks (used by Module.flushShifts)
// =========================================================================
//
// Pure structural traversal of every span/loc field. Kept private to
// `Ast.zig` because the journal is the only legitimate caller — every
// other consumer should go through `Module.flushShifts` /
// `Module.applyPending`.
//
// Boundary convention: `>=` (a span whose `start == splice_end_old`
// shifts). Matches the eager `shiftAstSpans` semantics this replaced.

fn shiftSpan(sp: *Span, splice_end_old: u32, delta: i64) void {
    if (sp.start >= splice_end_old) sp.start = @intCast(@as(i64, sp.start) + delta);
    if (sp.end >= splice_end_old) sp.end = @intCast(@as(i64, sp.end) + delta);
}

fn shiftLoc(loc: *u32, splice_end_old: u32, delta: i64) void {
    if (loc.* >= splice_end_old) loc.* = @intCast(@as(i64, loc.*) + delta);
}

/// Shift any `span`/`loc`/`decl_span`/`end_loc` field present on `node`
/// (comptime). AST structs have heterogeneous shapes — some carry only
/// `span`, some only `loc`, some both, some additionally `end_loc`.
/// This helper papers over the differences without a match arm per
/// struct.
fn shiftNodeOffsets(node: anytype, splice_end_old: u32, delta: i64) void {
    const T = @TypeOf(node.*);
    if (@hasField(T, "span")) shiftSpan(&node.span, splice_end_old, delta);
    if (@hasField(T, "loc")) shiftLoc(&node.loc, splice_end_old, delta);
    if (@hasField(T, "decl_span")) shiftSpan(&node.decl_span, splice_end_old, delta);
    if (@hasField(T, "end_loc")) shiftLoc(&node.end_loc, splice_end_old, delta);
}

fn shiftScopeMembers(scope: *Scope, splice_end_old: u32, delta: i64) void {
    var it = scope.members.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.loc >= splice_end_old) {
            e.value_ptr.loc = @intCast(@as(i64, e.value_ptr.loc) + delta);
        }
    }
    for (scope.children.items) |c| shiftScopeMembers(c, splice_end_old, delta);
}

fn shiftDirectiveSpan(dir: *Directive, splice_end_old: u32, delta: i64) void {
    switch (dir.*) {
        inline else => |*d| shiftNodeOffsets(d, splice_end_old, delta),
    }
}

fn shiftDeclSpans(decl: *Decl, splice_end_old: u32, delta: i64) void {
    switch (decl.*) {
        .@"const" => |d| {
            shiftNodeOffsets(d, splice_end_old, delta);
            if (d.typ) |t| shiftTypeSpans(t, splice_end_old, delta);
            if (d.initializer) |e| shiftExprSpans(e, splice_end_old, delta);
        },
        .override => |d| {
            shiftNodeOffsets(d, splice_end_old, delta);
            if (d.typ) |t| shiftTypeSpans(t, splice_end_old, delta);
            if (d.initializer) |e| shiftExprSpans(e, splice_end_old, delta);
            for (d.attributes.items) |*a| shiftAttributeSpans(a, splice_end_old, delta);
        },
        .@"var" => |d| {
            shiftNodeOffsets(d, splice_end_old, delta);
            if (d.typ) |t| shiftTypeSpans(t, splice_end_old, delta);
            if (d.initializer) |e| shiftExprSpans(e, splice_end_old, delta);
            for (d.attributes.items) |*a| shiftAttributeSpans(a, splice_end_old, delta);
        },
        .let => |d| {
            shiftNodeOffsets(d, splice_end_old, delta);
            if (d.typ) |t| shiftTypeSpans(t, splice_end_old, delta);
            if (d.initializer) |e| shiftExprSpans(e, splice_end_old, delta);
        },
        .function => |d| {
            shiftNodeOffsets(d, splice_end_old, delta);
            for (d.attributes.items) |*a| shiftAttributeSpans(a, splice_end_old, delta);
            for (d.parameters.items) |*p| {
                shiftNodeOffsets(p, splice_end_old, delta);
                shiftTypeSpans(p.typ, splice_end_old, delta);
                for (p.attributes.items) |*a| shiftAttributeSpans(a, splice_end_old, delta);
            }
            if (d.return_type) |t| shiftTypeSpans(t, splice_end_old, delta);
            for (d.return_attr.items) |*a| shiftAttributeSpans(a, splice_end_old, delta);
            if (d.body) |body| shiftCompoundStmtSpans(body, splice_end_old, delta);
        },
        .@"struct" => |d| {
            shiftNodeOffsets(d, splice_end_old, delta);
            for (d.members.items) |*m| {
                shiftNodeOffsets(m, splice_end_old, delta);
                shiftTypeSpans(m.typ, splice_end_old, delta);
                for (m.attributes.items) |*a| shiftAttributeSpans(a, splice_end_old, delta);
            }
        },
        .alias => |d| {
            shiftNodeOffsets(d, splice_end_old, delta);
            shiftTypeSpans(d.typ, splice_end_old, delta);
        },
        .const_assert => |d| {
            shiftNodeOffsets(d, splice_end_old, delta);
            shiftExprSpans(d.expr, splice_end_old, delta);
        },
    }
}

fn shiftAttributeSpans(attr: *Attribute, splice_end_old: u32, delta: i64) void {
    shiftNodeOffsets(attr, splice_end_old, delta);
    for (attr.args.items) |e| shiftExprSpans(e, splice_end_old, delta);
}

fn shiftCompoundStmtSpans(body: *CompoundStmt, splice_end_old: u32, delta: i64) void {
    shiftNodeOffsets(body, splice_end_old, delta);
    for (body.stmts.items) |*s| shiftStmtSpans(s, splice_end_old, delta);
}

fn shiftStmtSpans(stmt: *Stmt, splice_end_old: u32, delta: i64) void {
    switch (stmt.*) {
        .compound => |s| shiftCompoundStmtSpans(s, splice_end_old, delta),
        .@"return" => |s| {
            shiftNodeOffsets(s, splice_end_old, delta);
            if (s.value) |e| shiftExprSpans(e, splice_end_old, delta);
        },
        .@"if" => |s| {
            shiftNodeOffsets(s, splice_end_old, delta);
            shiftExprSpans(s.condition, splice_end_old, delta);
            shiftCompoundStmtSpans(s.body, splice_end_old, delta);
            if (s.else_branch) |_| shiftStmtSpans(&s.else_branch.?, splice_end_old, delta);
        },
        .@"switch" => |s| {
            shiftNodeOffsets(s, splice_end_old, delta);
            shiftExprSpans(s.expr, splice_end_old, delta);
            for (s.cases.items) |*c| {
                for (c.selectors.items) |e| shiftExprSpans(e, splice_end_old, delta);
                shiftCompoundStmtSpans(c.body, splice_end_old, delta);
            }
        },
        .@"for" => |s| {
            shiftNodeOffsets(s, splice_end_old, delta);
            if (s.init_stmt) |_| shiftStmtSpans(&s.init_stmt.?, splice_end_old, delta);
            if (s.condition) |e| shiftExprSpans(e, splice_end_old, delta);
            if (s.update) |_| shiftStmtSpans(&s.update.?, splice_end_old, delta);
            shiftCompoundStmtSpans(s.body, splice_end_old, delta);
        },
        .@"while" => |s| {
            shiftNodeOffsets(s, splice_end_old, delta);
            shiftExprSpans(s.condition, splice_end_old, delta);
            shiftCompoundStmtSpans(s.body, splice_end_old, delta);
        },
        .loop => |s| {
            shiftNodeOffsets(s, splice_end_old, delta);
            shiftCompoundStmtSpans(s.body, splice_end_old, delta);
            if (s.continuing) |c| shiftCompoundStmtSpans(c, splice_end_old, delta);
        },
        .@"break" => |s| shiftNodeOffsets(s, splice_end_old, delta),
        .break_if => |s| {
            shiftNodeOffsets(s, splice_end_old, delta);
            shiftExprSpans(s.condition, splice_end_old, delta);
        },
        .@"continue" => |s| shiftNodeOffsets(s, splice_end_old, delta),
        .discard => |s| shiftNodeOffsets(s, splice_end_old, delta),
        .assign => |s| {
            shiftNodeOffsets(s, splice_end_old, delta);
            shiftExprSpans(s.left, splice_end_old, delta);
            shiftExprSpans(s.right, splice_end_old, delta);
        },
        .incr_decr => |s| {
            shiftNodeOffsets(s, splice_end_old, delta);
            shiftExprSpans(s.expr, splice_end_old, delta);
        },
        .call => |s| {
            shiftNodeOffsets(s, splice_end_old, delta);
            if (s.call.func) |f| shiftExprSpans(f, splice_end_old, delta);
            if (s.call.template_type) |t| shiftTypeSpans(t, splice_end_old, delta);
            for (s.call.args.items) |a| shiftExprSpans(a, splice_end_old, delta);
        },
        .decl => |s| {
            shiftNodeOffsets(s, splice_end_old, delta);
            var inner = s.decl;
            shiftDeclSpans(&inner, splice_end_old, delta);
            s.decl = inner;
        },
    }
}

fn shiftExprSpans(expr: Expr, splice_end_old: u32, delta: i64) void {
    switch (expr) {
        .literal => |e| shiftNodeOffsets(e, splice_end_old, delta),
        .ident => |e| shiftNodeOffsets(e, splice_end_old, delta),
        .paren => |e| {
            shiftNodeOffsets(e, splice_end_old, delta);
            shiftExprSpans(e.expr, splice_end_old, delta);
        },
        .binary => |e| {
            shiftNodeOffsets(e, splice_end_old, delta);
            shiftExprSpans(e.left, splice_end_old, delta);
            shiftExprSpans(e.right, splice_end_old, delta);
        },
        .unary => |e| {
            shiftNodeOffsets(e, splice_end_old, delta);
            shiftExprSpans(e.operand, splice_end_old, delta);
        },
        .call => |e| {
            shiftNodeOffsets(e, splice_end_old, delta);
            if (e.func) |f| shiftExprSpans(f, splice_end_old, delta);
            if (e.template_type) |t| shiftTypeSpans(t, splice_end_old, delta);
            for (e.args.items) |a| shiftExprSpans(a, splice_end_old, delta);
        },
        .index => |e| {
            shiftNodeOffsets(e, splice_end_old, delta);
            shiftExprSpans(e.base, splice_end_old, delta);
            shiftExprSpans(e.idx, splice_end_old, delta);
        },
        .member => |e| {
            shiftNodeOffsets(e, splice_end_old, delta);
            shiftExprSpans(e.base, splice_end_old, delta);
        },
    }
}

fn shiftTypeSpans(typ: Type, splice_end_old: u32, delta: i64) void {
    switch (typ) {
        .ident => |t| shiftNodeOffsets(t, splice_end_old, delta),
        .sampler => |t| shiftNodeOffsets(t, splice_end_old, delta),
        .vec => |t| {
            shiftNodeOffsets(t, splice_end_old, delta);
            if (t.elem_type) |et| shiftTypeSpans(et, splice_end_old, delta);
        },
        .mat => |t| {
            shiftNodeOffsets(t, splice_end_old, delta);
            if (t.elem_type) |et| shiftTypeSpans(et, splice_end_old, delta);
        },
        .array => |t| {
            shiftNodeOffsets(t, splice_end_old, delta);
            if (t.elem_type) |et| shiftTypeSpans(et, splice_end_old, delta);
            if (t.size) |e| shiftExprSpans(e, splice_end_old, delta);
        },
        .ptr => |t| {
            shiftNodeOffsets(t, splice_end_old, delta);
            shiftTypeSpans(t.elem_type, splice_end_old, delta);
        },
        .atomic => |t| {
            shiftNodeOffsets(t, splice_end_old, delta);
            shiftTypeSpans(t.elem_type, splice_end_old, delta);
        },
        .texture => |t| {
            shiftNodeOffsets(t, splice_end_old, delta);
            if (t.sampled_type) |st| shiftTypeSpans(st, splice_end_old, delta);
        },
    }
}

// =========================================================================
// Comptime assertions
// =========================================================================

// These sizes are load-bearing: Symbol.Flags and ExprFlags are bit-packed
// for memory efficiency, and SymbolIndex uses maxInt(u32) as sentinel.
// Adding fields may break the packed layout or sentinel checks.
comptime {
    // Bit-packed types: adding fields may break the packed layout.
    // Symbol.Flags is `u8` after B.M6 (was `u16` while it carried the
    // mutable bits removed in B.M5). ExprFlags has been `u8` throughout.
    std.debug.assert(@sizeOf(Symbol.Flags) == 1);
    std.debug.assert(@sizeOf(ExprFlags) == 1);

    // SymbolIndex uses maxInt(u32) as sentinel — must be exactly 4 bytes.
    std.debug.assert(@sizeOf(SymbolIndex) == 4);
    std.debug.assert(@alignOf(SymbolIndex) == @alignOf(u32));

    // Symbol.Kind fits in a nibble (4 bits).
    std.debug.assert(@sizeOf(Symbol.Kind) == 1);

    // Total Symbol size on 64-bit targets — locked to make growth visible.
    // Layout: original_name (16) + kind (1) + flags (1) + 2 pad +
    //         nested_scope_slot (8) + loc (4) = 32 bytes.
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(Symbol) == 32);
    }
}

// =========================================================================
// Tests
// =========================================================================

test "SymbolIndex: none is max u32" {
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), @intFromEnum(SymbolIndex.none));
}

test "SymbolIndex: valid index is accessible" {
    const s: SymbolIndex = @enumFromInt(5);
    try std.testing.expect(s.isValid());
    try std.testing.expectEqual(@as(u32, 5), s.index());
}

test "SymbolIndex: none is not valid" {
    try std.testing.expect(!SymbolIndex.none.isValid());
}

test "Symbol.Flags: packed size is 1 byte" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(Symbol.Flags));
}

test "Symbol.Flags: bitwise operations" {
    var flags = Symbol.Flags{};
    try std.testing.expect(!flags.is_api_facing);
    try std.testing.expect(!flags.is_entry_point);
    try std.testing.expect(!flags.is_external_binding);

    flags.is_api_facing = true;
    flags.is_entry_point = true;
    try std.testing.expect(flags.is_api_facing);
    try std.testing.expect(flags.is_entry_point);
    try std.testing.expect(!flags.is_external_binding);
}

test "AddressSpace: string conversion" {
    try std.testing.expectEqualStrings("function", AddressSpace.function.string());
    try std.testing.expectEqualStrings("private", AddressSpace.private.string());
    try std.testing.expectEqualStrings("workgroup", AddressSpace.workgroup.string());
    try std.testing.expectEqualStrings("uniform", AddressSpace.uniform.string());
    try std.testing.expectEqualStrings("storage", AddressSpace.storage.string());
    try std.testing.expectEqualStrings("handle", AddressSpace.handle.string());
    try std.testing.expectEqualStrings("", AddressSpace.none.string());
}

test "AccessMode: string conversion" {
    try std.testing.expectEqualStrings("read", AccessMode.read.string());
    try std.testing.expectEqualStrings("write", AccessMode.write.string());
    try std.testing.expectEqualStrings("read_write", AccessMode.read_write.string());
    try std.testing.expectEqualStrings("", AccessMode.none.string());
}

test "Scope: init with parent" {
    var parent = Scope.init(null, .module);
    try std.testing.expect(parent.parent == null);
    try std.testing.expectEqual(ScopeKind.module, parent.kind);

    var child = Scope.init(&parent, .block);
    try std.testing.expect(child.parent == &parent);
    try std.testing.expectEqual(@as(usize, 0), child.members.count());
    try std.testing.expectEqual(ScopeKind.block, child.kind);
}

test "SymbolIndex: design avoids Go zero-value bug" {
    // In Go, Ref{0,0} passes IsValid() — the zero-value bug.
    // In Zig, SymbolIndex uses enum(u32) with none = maxInt(u32).
    // Index 0 IS valid (it's a real symbol index), and none is NOT valid.
    const zero_idx: SymbolIndex = @enumFromInt(0);
    try std.testing.expect(zero_idx.isValid()); // 0 is a valid index
    try std.testing.expect(!SymbolIndex.none.isValid()); // none is not valid
    try std.testing.expect(@intFromEnum(SymbolIndex.none) != 0); // none != 0
}

// =========================================================================
// Purity Tests
// =========================================================================

test "isSymbolPure: returns false for invalid ref" {
    const symbols = [_]Symbol{.{ .original_name = "x", .kind = .@"const", .flags = .{} }};
    try std.testing.expect(!isSymbolPure(.none, &symbols));
}

test "isSymbolPure: returns false for out-of-bounds ref" {
    const symbols = [_]Symbol{.{ .original_name = "x", .kind = .@"const", .flags = .{} }};
    try std.testing.expect(!isSymbolPure(@enumFromInt(999), &symbols));
}

test "isSymbolPure: returns true for const symbol" {
    const symbols = [_]Symbol{.{ .original_name = "x", .kind = .@"const", .flags = .{} }};
    try std.testing.expect(isSymbolPure(@enumFromInt(0), &symbols));
}

test "isSymbolPure: returns true for let symbol" {
    const symbols = [_]Symbol{.{ .original_name = "x", .kind = .let, .flags = .{} }};
    try std.testing.expect(isSymbolPure(@enumFromInt(0), &symbols));
}

test "isSymbolPure: returns true for var symbol" {
    const symbols = [_]Symbol{.{ .original_name = "x", .kind = .@"var", .flags = .{} }};
    try std.testing.expect(isSymbolPure(@enumFromInt(0), &symbols));
}

test "isSymbolPure: returns true for parameter symbol" {
    const symbols = [_]Symbol{.{ .original_name = "x", .kind = .parameter, .flags = .{} }};
    try std.testing.expect(isSymbolPure(@enumFromInt(0), &symbols));
}

test "isSymbolPure: returns true for function symbol" {
    const symbols = [_]Symbol{.{ .original_name = "f", .kind = .function, .flags = .{} }};
    try std.testing.expect(isSymbolPure(@enumFromInt(0), &symbols));
}

test "isSymbolPure: returns true for struct symbol" {
    const symbols = [_]Symbol{.{ .original_name = "S", .kind = .@"struct", .flags = .{} }};
    try std.testing.expect(isSymbolPure(@enumFromInt(0), &symbols));
}

test "isSymbolPure: returns true for alias symbol" {
    const symbols = [_]Symbol{.{ .original_name = "T", .kind = .alias, .flags = .{} }};
    try std.testing.expect(isSymbolPure(@enumFromInt(0), &symbols));
}

test "isSymbolPure: returns true for member symbol" {
    const symbols = [_]Symbol{.{ .original_name = "field", .kind = .member, .flags = .{} }};
    try std.testing.expect(isSymbolPure(@enumFromInt(0), &symbols));
}

test "isSymbolPure: returns true for unbound symbol" {
    const symbols = [_]Symbol{.{ .original_name = "unknown", .kind = .unbound, .flags = .{} }};
    try std.testing.expect(isSymbolPure(@enumFromInt(0), &symbols));
}

test "exprCanBeRemovedIfUnused: literal" {
    var lit = LiteralExpr{ .kind = .int_literal, .value = "42" };
    try std.testing.expect(exprCanBeRemovedIfUnused(.{ .literal = &lit }, &.{}));
}

test "exprCanBeRemovedIfUnused: ident with valid pure symbol" {
    const symbols = [_]Symbol{.{ .original_name = "x", .kind = .@"var", .flags = .{} }};
    var id = IdentExpr{ .name = "x", .ref = @enumFromInt(0) };
    try std.testing.expect(exprCanBeRemovedIfUnused(.{ .ident = &id }, &symbols));
}

test "exprCanBeRemovedIfUnused: ident with invalid ref (builtin)" {
    var id = IdentExpr{ .name = "f32", .ref = .none };
    try std.testing.expect(exprCanBeRemovedIfUnused(.{ .ident = &id }, &.{}));
}

test "exprCanBeRemovedIfUnused: ident with flag set" {
    var id = IdentExpr{ .name = "x", .ref = @enumFromInt(999), .flags = .{ .can_be_removed_if_unused = true } };
    try std.testing.expect(exprCanBeRemovedIfUnused(.{ .ident = &id }, &.{}));
}

test "exprCanBeRemovedIfUnused: binary with pure children" {
    var left = LiteralExpr{ .kind = .int_literal, .value = "1" };
    var right = LiteralExpr{ .kind = .int_literal, .value = "2" };
    var bin = BinaryExpr{ .op = .add, .left = .{ .literal = &left }, .right = .{ .literal = &right } };
    try std.testing.expect(exprCanBeRemovedIfUnused(.{ .binary = &bin }, &.{}));
}

test "exprCanBeRemovedIfUnused: unary with pure child" {
    var operand = LiteralExpr{ .kind = .int_literal, .value = "42" };
    var un = UnaryExpr{ .op = .neg, .operand = .{ .literal = &operand } };
    try std.testing.expect(exprCanBeRemovedIfUnused(.{ .unary = &un }, &.{}));
}

test "exprCanBeRemovedIfUnused: pure call with pure args" {
    var func_id = IdentExpr{ .name = "sin" };
    var arg = LiteralExpr{ .kind = .float_literal, .value = "1.0" };
    var call = CallExpr{ .func = .{ .ident = &func_id }, .args = .empty };
    call.args = .empty;
    // Manually build args list using a fixed buffer
    var arg_buf = [_]Expr{.{ .literal = &arg }};
    call.args = .{ .items = &arg_buf, .capacity = 1 };
    try std.testing.expect(exprCanBeRemovedIfUnused(.{ .call = &call }, &.{}));
}

test "exprCanBeRemovedIfUnused: impure call" {
    var func_id = IdentExpr{ .name = "impureFunc" };
    var call = CallExpr{ .func = .{ .ident = &func_id }, .args = .empty };
    try std.testing.expect(!exprCanBeRemovedIfUnused(.{ .call = &call }, &.{}));
}

test "exprCanBeRemovedIfUnused: call with can_be_removed flag" {
    var func_id = IdentExpr{ .name = "unknownFunc" };
    var call = CallExpr{ .func = .{ .ident = &func_id }, .args = .empty, .flags = .{ .can_be_removed_if_unused = true } };
    try std.testing.expect(exprCanBeRemovedIfUnused(.{ .call = &call }, &.{}));
}

test "exprCanBeRemovedIfUnused: call with from_pure_function flag" {
    var func_id = IdentExpr{ .name = "unknownFunc" };
    var call = CallExpr{ .func = .{ .ident = &func_id }, .args = .empty, .flags = .{ .from_pure_function = true } };
    try std.testing.expect(exprCanBeRemovedIfUnused(.{ .call = &call }, &.{}));
}

test "exprCanBeRemovedIfUnused: index with pure children" {
    var base = LiteralExpr{ .kind = .int_literal, .value = "0" };
    var idx_expr = LiteralExpr{ .kind = .int_literal, .value = "1" };
    var index = IndexExpr{ .base = .{ .literal = &base }, .idx = .{ .literal = &idx_expr } };
    try std.testing.expect(exprCanBeRemovedIfUnused(.{ .index = &index }, &.{}));
}

test "exprCanBeRemovedIfUnused: member with pure base" {
    var base = LiteralExpr{ .kind = .int_literal, .value = "0" };
    var mem = MemberExpr{ .base = .{ .literal = &base }, .member_name = "x" };
    try std.testing.expect(exprCanBeRemovedIfUnused(.{ .member = &mem }, &.{}));
}

test "exprCanBeRemovedIfUnused: paren with pure inner" {
    var inner = LiteralExpr{ .kind = .int_literal, .value = "42" };
    var paren = ParenExpr{ .expr = .{ .literal = &inner } };
    try std.testing.expect(exprCanBeRemovedIfUnused(.{ .paren = &paren }, &.{}));
}

test "stmtCanBeRemovedIfUnused: return without value" {
    var ret = ReturnStmt{};
    try std.testing.expect(stmtCanBeRemovedIfUnused(.{ .@"return" = &ret }, &.{}));
}

test "stmtCanBeRemovedIfUnused: return with pure value" {
    var lit = LiteralExpr{ .kind = .int_literal, .value = "42" };
    var ret = ReturnStmt{ .value = .{ .literal = &lit } };
    try std.testing.expect(stmtCanBeRemovedIfUnused(.{ .@"return" = &ret }, &.{}));
}

test "stmtCanBeRemovedIfUnused: return with impure value" {
    var func_id = IdentExpr{ .name = "impureFunc" };
    var call = CallExpr{ .func = .{ .ident = &func_id }, .args = .empty };
    var ret = ReturnStmt{ .value = .{ .call = &call } };
    try std.testing.expect(!stmtCanBeRemovedIfUnused(.{ .@"return" = &ret }, &.{}));
}

test "stmtCanBeRemovedIfUnused: call stmt" {
    var func_id = IdentExpr{ .name = "f" };
    var call_expr = CallExpr{ .func = .{ .ident = &func_id }, .args = .empty };
    var call_stmt = CallStmt{ .call = &call_expr };
    try std.testing.expect(!stmtCanBeRemovedIfUnused(.{ .call = &call_stmt }, &.{}));
}

test "stmtCanBeRemovedIfUnused: assign stmt" {
    var left = IdentExpr{ .name = "x" };
    var right = LiteralExpr{ .kind = .int_literal, .value = "1" };
    var assign = AssignStmt{ .op = .simple, .left = .{ .ident = &left }, .right = .{ .literal = &right } };
    try std.testing.expect(!stmtCanBeRemovedIfUnused(.{ .assign = &assign }, &.{}));
}

test "stmtCanBeRemovedIfUnused: incr_decr stmt" {
    var id = IdentExpr{ .name = "x" };
    var incr = IncrDecrStmt{ .expr = .{ .ident = &id }, .increment = true };
    try std.testing.expect(!stmtCanBeRemovedIfUnused(.{ .incr_decr = &incr }, &.{}));
}

test "stmtCanBeRemovedIfUnused: control flow" {
    var cond = LiteralExpr{ .kind = .true_literal, .value = "true" };
    var body = CompoundStmt{ .stmts = .empty };
    var if_stmt = IfStmt{ .condition = .{ .literal = &cond }, .body = &body };
    try std.testing.expect(!stmtCanBeRemovedIfUnused(.{ .@"if" = &if_stmt }, &.{}));

    var for_stmt = ForStmt{ .body = &body };
    try std.testing.expect(!stmtCanBeRemovedIfUnused(.{ .@"for" = &for_stmt }, &.{}));

    var while_stmt = WhileStmt{ .condition = .{ .literal = &cond }, .body = &body };
    try std.testing.expect(!stmtCanBeRemovedIfUnused(.{ .@"while" = &while_stmt }, &.{}));

    var loop_stmt = LoopStmt{ .body = &body };
    try std.testing.expect(!stmtCanBeRemovedIfUnused(.{ .loop = &loop_stmt }, &.{}));

    var break_stmt = BreakStmt{};
    try std.testing.expect(!stmtCanBeRemovedIfUnused(.{ .@"break" = &break_stmt }, &.{}));

    var continue_stmt = ContinueStmt{};
    try std.testing.expect(!stmtCanBeRemovedIfUnused(.{ .@"continue" = &continue_stmt }, &.{}));

    var discard_stmt = DiscardStmt{};
    try std.testing.expect(!stmtCanBeRemovedIfUnused(.{ .discard = &discard_stmt }, &.{}));
}

test "declCanBeRemovedIfUnused: const with pure init" {
    var lit = LiteralExpr{ .kind = .int_literal, .value = "42" };
    var decl = ConstDecl{ .name = @enumFromInt(0), .initializer = .{ .literal = &lit } };
    try std.testing.expect(declCanBeRemovedIfUnused(.{ .@"const" = &decl }, &.{}));
}

test "declCanBeRemovedIfUnused: const with impure init" {
    var func_id = IdentExpr{ .name = "impureFunc" };
    var call = CallExpr{ .func = .{ .ident = &func_id }, .args = .empty };
    var decl = ConstDecl{ .name = @enumFromInt(0), .initializer = .{ .call = &call } };
    try std.testing.expect(!declCanBeRemovedIfUnused(.{ .@"const" = &decl }, &.{}));
}

test "declCanBeRemovedIfUnused: let with pure init" {
    var lit = LiteralExpr{ .kind = .int_literal, .value = "1" };
    var decl = LetDecl{ .name = @enumFromInt(0), .initializer = .{ .literal = &lit } };
    try std.testing.expect(declCanBeRemovedIfUnused(.{ .let = &decl }, &.{}));
}

test "declCanBeRemovedIfUnused: var with no init" {
    var decl = VarDecl{ .name = @enumFromInt(0), .attributes = .empty };
    try std.testing.expect(declCanBeRemovedIfUnused(.{ .@"var" = &decl }, &.{}));
}

test "declCanBeRemovedIfUnused: var with pure init" {
    var lit = LiteralExpr{ .kind = .int_literal, .value = "5" };
    var decl = VarDecl{ .name = @enumFromInt(0), .attributes = .empty, .initializer = .{ .literal = &lit } };
    try std.testing.expect(declCanBeRemovedIfUnused(.{ .@"var" = &decl }, &.{}));
}

test "declCanBeRemovedIfUnused: function" {
    var decl = FunctionDecl{ .name = @enumFromInt(0), .attributes = .empty, .parameters = .empty, .return_attr = .empty };
    try std.testing.expect(declCanBeRemovedIfUnused(.{ .function = &decl }, &.{}));
}

test "declCanBeRemovedIfUnused: struct" {
    var decl = StructDecl{ .name = @enumFromInt(0), .members = .empty };
    try std.testing.expect(declCanBeRemovedIfUnused(.{ .@"struct" = &decl }, &.{}));
}

test "declCanBeRemovedIfUnused: alias" {
    var ident_type = IdentType{ .name = "f32" };
    var decl = AliasDecl{ .name = @enumFromInt(0), .typ = .{ .ident = &ident_type } };
    try std.testing.expect(declCanBeRemovedIfUnused(.{ .alias = &decl }, &.{}));
}

test "declCanBeRemovedIfUnused: override" {
    var decl = OverrideDecl{ .name = @enumFromInt(0), .attributes = .empty };
    try std.testing.expect(!declCanBeRemovedIfUnused(.{ .override = &decl }, &.{}));
}

test "declCanBeRemovedIfUnused: const_assert" {
    var lit = LiteralExpr{ .kind = .true_literal, .value = "true" };
    var decl = ConstAssertDecl{ .expr = .{ .literal = &lit } };
    try std.testing.expect(!declCanBeRemovedIfUnused(.{ .const_assert = &decl }, &.{}));
}

test "markExprPurity: literal sets both flags" {
    var lit = LiteralExpr{ .kind = .int_literal, .value = "42" };
    markExprPurity(.{ .literal = &lit }, &.{});
    try std.testing.expect(lit.flags.can_be_removed_if_unused);
    try std.testing.expect(lit.flags.is_constant);
}

test "markExprPurity: ident with const symbol sets both flags" {
    const symbols = [_]Symbol{.{ .original_name = "MY_CONST", .kind = .@"const", .flags = .{} }};
    var id = IdentExpr{ .name = "MY_CONST", .ref = @enumFromInt(0) };
    markExprPurity(.{ .ident = &id }, &symbols);
    try std.testing.expect(id.flags.can_be_removed_if_unused);
    try std.testing.expect(id.flags.is_constant);
}

test "markExprPurity: ident with var symbol sets removable only" {
    const symbols = [_]Symbol{.{ .original_name = "myVar", .kind = .@"var", .flags = .{} }};
    var id = IdentExpr{ .name = "myVar", .ref = @enumFromInt(0) };
    markExprPurity(.{ .ident = &id }, &symbols);
    try std.testing.expect(id.flags.can_be_removed_if_unused);
    try std.testing.expect(!id.flags.is_constant);
}

test "markExprPurity: ident with invalid ref sets removable" {
    var id = IdentExpr{ .name = "f32", .ref = .none };
    markExprPurity(.{ .ident = &id }, &.{});
    try std.testing.expect(id.flags.can_be_removed_if_unused);
    try std.testing.expect(!id.flags.is_constant);
}

test "markExprPurity: binary with pure children" {
    var left = LiteralExpr{ .kind = .int_literal, .value = "1", .flags = .{ .can_be_removed_if_unused = true } };
    var right = LiteralExpr{ .kind = .int_literal, .value = "2", .flags = .{ .can_be_removed_if_unused = true } };
    var bin = BinaryExpr{ .op = .add, .left = .{ .literal = &left }, .right = .{ .literal = &right } };
    markExprPurity(.{ .binary = &bin }, &.{});
    try std.testing.expect(bin.flags.can_be_removed_if_unused);
}

test "markExprPurity: unary with pure child" {
    var operand = LiteralExpr{ .kind = .int_literal, .value = "42", .flags = .{ .can_be_removed_if_unused = true } };
    var un = UnaryExpr{ .op = .neg, .operand = .{ .literal = &operand } };
    markExprPurity(.{ .unary = &un }, &.{});
    try std.testing.expect(un.flags.can_be_removed_if_unused);
}

test "markExprPurity: call to pure function with pure args" {
    var func_id = IdentExpr{ .name = "sin" };
    var arg = LiteralExpr{ .kind = .float_literal, .value = "1.0", .flags = .{ .can_be_removed_if_unused = true } };
    var arg_buf = [_]Expr{.{ .literal = &arg }};
    var call = CallExpr{ .func = .{ .ident = &func_id }, .args = .{ .items = &arg_buf, .capacity = 1 } };
    markExprPurity(.{ .call = &call }, &.{});
    try std.testing.expect(call.flags.from_pure_function);
    try std.testing.expect(call.flags.can_be_removed_if_unused);
}

test "markExprPurity: call to pure function with impure arg" {
    var func_id = IdentExpr{ .name = "sin" };
    var impure_func = IdentExpr{ .name = "impureFunc" };
    var impure_call = CallExpr{ .func = .{ .ident = &impure_func }, .args = .empty };
    var arg_buf = [_]Expr{.{ .call = &impure_call }};
    var call = CallExpr{ .func = .{ .ident = &func_id }, .args = .{ .items = &arg_buf, .capacity = 1 } };
    markExprPurity(.{ .call = &call }, &.{});
    try std.testing.expect(call.flags.from_pure_function);
    try std.testing.expect(!call.flags.can_be_removed_if_unused);
}

test "markExprPurity: index with pure children" {
    var base = LiteralExpr{ .kind = .int_literal, .value = "0", .flags = .{ .can_be_removed_if_unused = true } };
    var idx_expr = LiteralExpr{ .kind = .int_literal, .value = "1", .flags = .{ .can_be_removed_if_unused = true } };
    var index = IndexExpr{ .base = .{ .literal = &base }, .idx = .{ .literal = &idx_expr } };
    markExprPurity(.{ .index = &index }, &.{});
    try std.testing.expect(index.flags.can_be_removed_if_unused);
}

test "markExprPurity: member with pure base" {
    var base = LiteralExpr{ .kind = .int_literal, .value = "0", .flags = .{ .can_be_removed_if_unused = true } };
    var mem = MemberExpr{ .base = .{ .literal = &base }, .member_name = "x" };
    markExprPurity(.{ .member = &mem }, &.{});
    try std.testing.expect(mem.flags.can_be_removed_if_unused);
}

test "markExprPurity: paren with pure inner" {
    var inner = LiteralExpr{ .kind = .int_literal, .value = "42", .flags = .{ .can_be_removed_if_unused = true } };
    var paren = ParenExpr{ .expr = .{ .literal = &inner } };
    markExprPurity(.{ .paren = &paren }, &.{});
    try std.testing.expect(paren.flags.can_be_removed_if_unused);
}

// =========================================================================
// interior_pending / absorbInteriors tests
// =========================================================================

fn newTestModule(arena: std.mem.Allocator) !Module {
    const root = try arena.create(Scope);
    root.* = Scope.init(null, .module);
    return Module.init(root, "");
}

test "interior_pending: fresh decls start at zero bias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = try newTestModule(arena.allocator());

    const let = try arena.allocator().create(LetDecl);
    let.* = .{ .name = .none, .decl_span = .{ .start = 10, .end = 30 } };
    try m.declarations.append(arena.allocator(), .{ .let = let });

    try std.testing.expectEqual(@as(i32, 0), declInteriorPending(m.declarations.items[0]));
}

test "interior_pending: bump adds to stored bias without touching inner spans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = try newTestModule(arena.allocator());

    // LetDecl with an inner literal at offset 100.
    const lit = try arena.allocator().create(LiteralExpr);
    lit.* = .{ .kind = .int_literal, .value = "42", .loc = 100 };
    const let = try arena.allocator().create(LetDecl);
    let.* = .{
        .name = .none,
        .initializer = .{ .literal = lit },
        .decl_span = .{ .start = 50, .end = 110 },
    };
    try m.declarations.append(arena.allocator(), .{ .let = let });

    bumpDeclInteriorPending(&m.declarations.items[0], 5);
    try std.testing.expectEqual(@as(i32, 5), declInteriorPending(m.declarations.items[0]));
    // Inner loc untouched — bias is stored, not applied.
    try std.testing.expectEqual(@as(u32, 100), lit.loc);
}

test "interior_pending: absorbDeclInterior drains bias and shifts inner loc" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = try newTestModule(arena.allocator());

    const lit = try arena.allocator().create(LiteralExpr);
    lit.* = .{ .kind = .int_literal, .value = "42", .loc = 100 };
    const let = try arena.allocator().create(LetDecl);
    let.* = .{
        .name = .none,
        .initializer = .{ .literal = lit },
        .decl_span = .{ .start = 50, .end = 110 },
    };
    try m.declarations.append(arena.allocator(), .{ .let = let });
    bumpDeclInteriorPending(&m.declarations.items[0], 5);

    absorbDeclInterior(&m.declarations.items[0]);
    try std.testing.expectEqual(@as(i32, 0), declInteriorPending(m.declarations.items[0]));
    try std.testing.expectEqual(@as(u32, 105), lit.loc);
}

test "interior_pending: absorb is idempotent after drain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = try newTestModule(arena.allocator());

    const lit = try arena.allocator().create(LiteralExpr);
    lit.* = .{ .kind = .int_literal, .value = "42", .loc = 100 };
    const let = try arena.allocator().create(LetDecl);
    let.* = .{
        .name = .none,
        .initializer = .{ .literal = lit },
        .decl_span = .{ .start = 50, .end = 110 },
    };
    try m.declarations.append(arena.allocator(), .{ .let = let });
    bumpDeclInteriorPending(&m.declarations.items[0], 5);

    absorbDeclInterior(&m.declarations.items[0]);
    absorbDeclInterior(&m.declarations.items[0]);
    // Only shifted once.
    try std.testing.expectEqual(@as(u32, 105), lit.loc);
}

test "interior_pending: absorb with zero bias is no-op" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = try newTestModule(arena.allocator());

    const lit = try arena.allocator().create(LiteralExpr);
    lit.* = .{ .kind = .int_literal, .value = "42", .loc = 100 };
    const let = try arena.allocator().create(LetDecl);
    let.* = .{
        .name = .none,
        .initializer = .{ .literal = lit },
        .decl_span = .{ .start = 50, .end = 110 },
    };
    try m.declarations.append(arena.allocator(), .{ .let = let });

    absorbDeclInterior(&m.declarations.items[0]);
    try std.testing.expectEqual(@as(u32, 100), lit.loc);
    try std.testing.expectEqual(@as(i32, 0), declInteriorPending(m.declarations.items[0]));
}

test "interior_pending: Module.absorbInteriors drains every decl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = try newTestModule(arena.allocator());

    const lit_a = try arena.allocator().create(LiteralExpr);
    lit_a.* = .{ .kind = .int_literal, .value = "1", .loc = 100 };
    const let_a = try arena.allocator().create(LetDecl);
    let_a.* = .{
        .name = .none,
        .initializer = .{ .literal = lit_a },
        .decl_span = .{ .start = 50, .end = 110 },
    };

    const lit_b = try arena.allocator().create(LiteralExpr);
    lit_b.* = .{ .kind = .int_literal, .value = "2", .loc = 300 };
    const let_b = try arena.allocator().create(LetDecl);
    let_b.* = .{
        .name = .none,
        .initializer = .{ .literal = lit_b },
        .decl_span = .{ .start = 250, .end = 310 },
    };

    try m.declarations.append(arena.allocator(), .{ .let = let_a });
    try m.declarations.append(arena.allocator(), .{ .let = let_b });

    bumpDeclInteriorPending(&m.declarations.items[0], 3);
    bumpDeclInteriorPending(&m.declarations.items[1], 7);

    m.absorbInteriors();

    try std.testing.expectEqual(@as(u32, 103), lit_a.loc);
    try std.testing.expectEqual(@as(u32, 307), lit_b.loc);
    try std.testing.expectEqual(@as(i32, 0), declInteriorPending(m.declarations.items[0]));
    try std.testing.expectEqual(@as(i32, 0), declInteriorPending(m.declarations.items[1]));
}

test "interior_pending: bump composition accumulates before absorb" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = try newTestModule(arena.allocator());

    const lit = try arena.allocator().create(LiteralExpr);
    lit.* = .{ .kind = .int_literal, .value = "42", .loc = 100 };
    const let = try arena.allocator().create(LetDecl);
    let.* = .{
        .name = .none,
        .initializer = .{ .literal = lit },
        .decl_span = .{ .start = 50, .end = 110 },
    };
    try m.declarations.append(arena.allocator(), .{ .let = let });

    // Three bumps: +5, -2, +4 → net +7.
    bumpDeclInteriorPending(&m.declarations.items[0], 5);
    bumpDeclInteriorPending(&m.declarations.items[0], -2);
    bumpDeclInteriorPending(&m.declarations.items[0], 4);
    try std.testing.expectEqual(@as(i32, 7), declInteriorPending(m.declarations.items[0]));
    try std.testing.expectEqual(@as(u32, 100), lit.loc);

    absorbDeclInterior(&m.declarations.items[0]);
    try std.testing.expectEqual(@as(u32, 107), lit.loc);
}

test "interior_pending: shiftDeclInteriorPart only touches spans >= splice_end_old" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = try newTestModule(arena.allocator());

    // Function with a body containing two statements at different offsets.
    const left_lit = try arena.allocator().create(LiteralExpr);
    left_lit.* = .{ .kind = .int_literal, .value = "1", .loc = 80 };
    const right_lit = try arena.allocator().create(LiteralExpr);
    right_lit.* = .{ .kind = .int_literal, .value = "2", .loc = 140 };
    const ret1 = try arena.allocator().create(ReturnStmt);
    ret1.* = .{ .loc = 75, .value = .{ .literal = left_lit }, .span = .{ .start = 75, .end = 90 } };
    const ret2 = try arena.allocator().create(ReturnStmt);
    ret2.* = .{ .loc = 135, .value = .{ .literal = right_lit }, .span = .{ .start = 135, .end = 150 } };
    const body = try arena.allocator().create(CompoundStmt);
    body.* = .{
        .stmts = .empty,
        .span = .{ .start = 60, .end = 160 },
    };
    try body.stmts.append(arena.allocator(), .{ .@"return" = ret1 });
    try body.stmts.append(arena.allocator(), .{ .@"return" = ret2 });

    const fn_decl = try arena.allocator().create(FunctionDecl);
    fn_decl.* = .{
        .attributes = .empty,
        .name = .none,
        .parameters = .empty,
        .return_attr = .empty,
        .body = body,
        .decl_span = .{ .start = 50, .end = 160 },
    };
    try m.declarations.append(arena.allocator(), .{ .function = fn_decl });

    // Shift only spans >= 100 by +5. The first return (at 75–90) is
    // untouched; the second (at 135–150) shifts to 140–155.
    shiftDeclInteriorPart(&m.declarations.items[0], 100, 5);

    try std.testing.expectEqual(@as(u32, 80), left_lit.loc);
    try std.testing.expectEqual(@as(u32, 75), ret1.loc);
    try std.testing.expectEqual(@as(u32, 75), ret1.span.start);
    try std.testing.expectEqual(@as(u32, 90), ret1.span.end);

    try std.testing.expectEqual(@as(u32, 145), right_lit.loc);
    try std.testing.expectEqual(@as(u32, 140), ret2.loc);
    try std.testing.expectEqual(@as(u32, 140), ret2.span.start);
    try std.testing.expectEqual(@as(u32, 155), ret2.span.end);

    // Compound span: start 60 (< 100, unchanged), end 160 (≥ 100, +5).
    try std.testing.expectEqual(@as(u32, 60), body.span.start);
    try std.testing.expectEqual(@as(u32, 165), body.span.end);
}
