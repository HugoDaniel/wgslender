//! WGSL Abstract Syntax Tree.
//!
//! Uses a Go-style interface-based AST (via tagged unions) rather than the
//! flat MultiArrayList approach from the Zig compiler. This keeps the port
//! close to the Go original for correctness verification against snapshots.
//! A future optimization pass can flatten to MultiArrayList.

const std = @import("std");
const Lexer = @import("Lexer.zig");

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
    kind: Kind,
    flags: Flags,
    nested_scope_slot: ?u32 = null,
    /// Number of references found during the visit pass. Only symbols with
    /// `use_count > 0` are candidates for renaming.
    use_count: u32 = 0,
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

    /// Bit-packed symbol flags (6 bools + padding = 2 bytes).
    /// Layout is fixed — see comptime assertion at end of file.
    pub const Flags = packed struct(u16) {
        must_not_be_renamed: bool = false,
        is_entry_point: bool = false,
        /// Set for @group/@binding vars and config-preserved names.
        is_api_facing: bool = false,
        is_builtin: bool = false,
        /// Set for @group/@binding vars; enables alias generation in Printer.
        is_external_binding: bool = false,
        /// Set by DCE; false means this symbol is dead and can be omitted.
        is_live: bool = false,
        _padding: u10 = 0,
    };
};

// =========================================================================
// Scope
// =========================================================================

pub const ScopeMember = struct {
    ref: SymbolIndex,
    loc: u32, // Source position for text-order scoping
};

pub const Scope = struct {
    parent: ?*Scope,
    children: std.ArrayListUnmanaged(*Scope),
    members: std.StringHashMapUnmanaged(ScopeMember),

    /// Creates a new scope with the given parent (null for the root scope).
    pub fn init(parent: ?*Scope) Scope {
        return .{
            .parent = parent,
            .children = .empty,
            .members = .{},
        };
    }
};

// =========================================================================
// Module (top level)
// =========================================================================

pub const Module = struct {
    source: [:0]const u8,
    directives: std.ArrayListUnmanaged(Directive),
    declarations: std.ArrayListUnmanaged(Decl),
    /// Global symbol table. `SymbolIndex` values are indices into this list.
    symbols: std.ArrayListUnmanaged(Symbol),
    /// Root scope. All nested scopes are reachable via `scope.children`.
    scope: *Scope,

    /// Creates an empty module bound to the given root scope and source text.
    pub fn init(scope: *Scope, source: [:0]const u8) Module {
        return .{
            .source = source,
            .directives = .empty,
            .declarations = .empty,
            .symbols = .empty,
            .scope = scope,
        };
    }
};

// =========================================================================
// Directives
// =========================================================================

pub const Directive = union(enum) {
    enable: EnableDirective,
    requires: RequiresDirective,
    diagnostic: DiagnosticDirective,
};

pub const EnableDirective = struct {
    features: std.ArrayListUnmanaged([]const u8),
};

pub const RequiresDirective = struct {
    features: std.ArrayListUnmanaged([]const u8),
};

pub const DiagnosticDirective = struct {
    severity: []const u8,
    rule: []const u8,
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
};

pub const ConstDecl = struct {
    name: SymbolIndex,
    typ: ?Type = null,
    initializer: ?Expr = null,
};

pub const OverrideDecl = struct {
    attributes: std.ArrayListUnmanaged(Attribute),
    name: SymbolIndex,
    typ: ?Type = null,
    initializer: ?Expr = null,
};

pub const VarDecl = struct {
    attributes: std.ArrayListUnmanaged(Attribute),
    address_space: AddressSpace = .none,
    access_mode: AccessMode = .none,
    name: SymbolIndex,
    typ: ?Type = null,
    initializer: ?Expr = null,
};

pub const LetDecl = struct {
    name: SymbolIndex,
    typ: ?Type = null,
    initializer: ?Expr = null,
};

pub const FunctionDecl = struct {
    attributes: std.ArrayListUnmanaged(Attribute),
    name: SymbolIndex,
    parameters: std.ArrayListUnmanaged(Parameter),
    return_type: ?Type = null,
    return_attr: std.ArrayListUnmanaged(Attribute),
    body: ?*CompoundStmt = null,
};

pub const Parameter = struct {
    attributes: std.ArrayListUnmanaged(Attribute),
    name: SymbolIndex,
    typ: Type,
};

pub const StructDecl = struct {
    name: SymbolIndex,
    members: std.ArrayListUnmanaged(StructMember),
};

pub const StructMember = struct {
    attributes: std.ArrayListUnmanaged(Attribute),
    name: SymbolIndex,
    typ: Type,
};

pub const AliasDecl = struct {
    name: SymbolIndex,
    typ: Type,
};

pub const ConstAssertDecl = struct {
    expr: Expr,
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
};

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
};

pub const IdentType = struct {
    name: []const u8,
    ref: SymbolIndex = .none,
    loc: u32 = 0,
};

pub const VecType = struct {
    size: u8, // 2, 3, or 4
    elem_type: ?Type = null,
    shorthand: []const u8 = "",
    loc: u32 = 0,
};

pub const MatType = struct {
    cols: u8,
    rows: u8,
    elem_type: ?Type = null,
    shorthand: []const u8 = "",
    loc: u32 = 0,
};

pub const ArrayType = struct {
    elem_type: ?Type = null,
    size: ?Expr = null,
};

pub const PtrType = struct {
    address_space: AddressSpace,
    elem_type: Type,
    access_mode: AccessMode = .none,
};

pub const AtomicType = struct {
    elem_type: Type,
    loc: u32 = 0,
};

pub const SamplerType = struct {
    comparison: bool,
};

pub const TextureType = struct {
    kind: TextureKind,
    dimension: TextureDimension,
    sampled_type: ?Type = null,
    texel_format: []const u8 = "",
    access_mode: AccessMode = .none,
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
};

pub const IdentExpr = struct {
    loc: u32 = 0,
    name: []const u8,
    ref: SymbolIndex = .none,
    flags: ExprFlags = .{},
};

pub const LiteralExpr = struct {
    loc: u32 = 0,
    kind: Lexer.Tag,
    value: []const u8,
    flags: ExprFlags = .{},
};

pub const BinaryExpr = struct {
    loc: u32 = 0,
    op: BinaryOp,
    left: Expr,
    right: Expr,
    flags: ExprFlags = .{},
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
    func: ?Expr = null,
    template_type: ?Type = null,
    args: std.ArrayListUnmanaged(Expr),
    flags: ExprFlags = .{},
};

pub const IndexExpr = struct {
    loc: u32 = 0,
    base: Expr,
    idx: Expr,
    flags: ExprFlags = .{},
};

pub const MemberExpr = struct {
    loc: u32 = 0,
    base: Expr,
    member_name: []const u8,
    flags: ExprFlags = .{},
};

pub const ParenExpr = struct {
    expr: Expr,
    flags: ExprFlags = .{},
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
};

pub const CompoundStmt = struct {
    stmts: std.ArrayListUnmanaged(Stmt),
};

pub const ReturnStmt = struct {
    loc: u32 = 0,
    value: ?Expr = null,
};

pub const IfStmt = struct {
    condition: Expr,
    body: *CompoundStmt,
    else_branch: ?Stmt = null,
};

pub const SwitchStmt = struct {
    expr: Expr,
    cases: std.ArrayListUnmanaged(SwitchCase),
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
};

pub const WhileStmt = struct {
    condition: Expr,
    body: *CompoundStmt,
};

pub const LoopStmt = struct {
    body: *CompoundStmt,
    continuing: ?*CompoundStmt = null,
};

pub const BreakStmt = struct {
    loc: u32 = 0,
};

pub const BreakIfStmt = struct {
    condition: Expr,
};

pub const ContinueStmt = struct {
    loc: u32 = 0,
};

pub const DiscardStmt = struct {
    loc: u32 = 0,
};

pub const AssignStmt = struct {
    loc: u32 = 0,
    op: AssignOp,
    left: Expr,
    right: Expr,
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
};

pub const CallStmt = struct {
    call: *CallExpr,
};

pub const DeclStmt = struct {
    decl: Decl,
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
// Comptime assertions
// =========================================================================

// These sizes are load-bearing: Symbol.Flags and ExprFlags are bit-packed
// for memory efficiency, and SymbolIndex uses maxInt(u32) as sentinel.
// Adding fields may break the packed layout or sentinel checks.
comptime {
    // Bit-packed types: adding fields may break the packed layout.
    std.debug.assert(@sizeOf(Symbol.Flags) == 2);
    std.debug.assert(@sizeOf(ExprFlags) == 1);

    // SymbolIndex uses maxInt(u32) as sentinel — must be exactly 4 bytes.
    std.debug.assert(@sizeOf(SymbolIndex) == 4);
    std.debug.assert(@alignOf(SymbolIndex) == @alignOf(u32));

    // Symbol.Kind fits in a nibble (4 bits).
    std.debug.assert(@sizeOf(Symbol.Kind) == 1);
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

test "Symbol.Flags: packed size is 2 bytes" {
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(Symbol.Flags));
}

test "Symbol.Flags: bitwise operations" {
    var flags = Symbol.Flags{};
    try std.testing.expect(!flags.must_not_be_renamed);
    try std.testing.expect(!flags.is_entry_point);
    try std.testing.expect(!flags.is_external_binding);

    flags.must_not_be_renamed = true;
    flags.is_entry_point = true;
    try std.testing.expect(flags.must_not_be_renamed);
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
    var parent = Scope.init(null);
    try std.testing.expect(parent.parent == null);

    var child = Scope.init(&parent);
    try std.testing.expect(child.parent == &parent);
    try std.testing.expectEqual(@as(usize, 0), child.members.count());
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
