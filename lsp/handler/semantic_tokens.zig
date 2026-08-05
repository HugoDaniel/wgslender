//! Semantic Tokens: tokenize the source and emit semantic-token data
//! (deltaLine/deltaChar/length/type/modifiers tuples) so the editor
//! can syntax-highlight beyond grammar rules.

const std = @import("std");
const wgslender = @import("wgslender");

const Handler = @import("../Handler.zig");
const NodeAtOffset = @import("node_at_offset.zig");
const Ast = wgslender.Ast;
const Lexer = wgslender.Lexer;
const Builtins = wgslender.Builtins;

// Token types: indices into the legend
const SemanticTokenType = enum(u32) {
    keyword = 0,
    function = 1,
    @"struct" = 2,
    parameter = 3,
    variable = 4,
    number = 5,
    type_name = 6,
    comment = 7,
    decorator = 8,
};

pub const semantic_token_types = [_][]const u8{
    "keyword", "function", "struct",  "parameter", "variable",
    "number",  "type",     "comment", "decorator",
};

pub const semantic_token_modifiers = [_][]const u8{
    "declaration", "readonly", "defaultLibrary",
};

// Modifier bitmasks
const MOD_DECLARATION: u32 = 1;
const MOD_READONLY: u32 = 2;
const MOD_DEFAULT_LIBRARY: u32 = 4;

const wgsl_type_names = [_][]const u8{
    "bool",               "i32",                      "u32",                           "f32",                     "f16",
    "vec2",               "vec3",                     "vec4",                          "vec2i",                   "vec3i",
    "vec4i",              "vec2u",                    "vec3u",                         "vec4u",                   "vec2f",
    "vec3f",              "vec4f",                    "vec2h",                         "vec3h",                   "vec4h",
    "mat2x2",             "mat2x3",                   "mat2x4",                        "mat3x2",                  "mat3x3",
    "mat3x4",             "mat4x2",                   "mat4x3",                        "mat4x4",                  "mat2x2f",
    "mat2x3f",            "mat2x4f",                  "mat3x2f",                       "mat3x3f",                 "mat3x4f",
    "mat4x2f",            "mat4x3f",                  "mat4x4f",                       "mat2x2h",                 "mat2x3h",
    "mat2x4h",            "mat3x2h",                  "mat3x3h",                       "mat3x4h",                 "mat4x2h",
    "mat4x3h",            "mat4x4h",                  "array",                         "atomic",                  "ptr",
    "sampler",            "sampler_comparison",       "texture_1d",                    "texture_2d",              "texture_2d_array",
    "texture_3d",         "texture_cube",             "texture_cube_array",            "texture_multisampled_2d", "texture_storage_1d",
    "texture_storage_2d", "texture_storage_2d_array", "texture_storage_3d",            "texture_depth_2d",        "texture_depth_2d_array",
    "texture_depth_cube", "texture_depth_cube_array", "texture_depth_multisampled_2d",
};

pub fn computeSemanticTokens(handler: *Handler, uri: []const u8) ![]u32 {
    const doc = handler.documents.getPtr(uri) orelse return &.{};
    const source = doc.source;

    // One line index for the whole request: this pass converts one offset
    // per token, and the from-byte-0 scan in `Handler.offsetToLspPosition`
    // made that quadratic (~224 ms on a 70 KB shader, per keystroke).
    var pm = try Handler.PositionMapper.init(handler.gpa, source);
    defer pm.deinit(handler.gpa);

    // Tokenize
    const source_z = try handler.gpa.dupeZ(u8, source);
    defer handler.gpa.free(source_z);
    var tokens_storage = wgslender.Lexer.tokenize(handler.gpa, source_z) catch return &.{};
    defer tokens_storage.deinit(handler.gpa);
    const tags = tokens_storage.items(.tag);
    const starts = tokens_storage.items(.start);

    // Try to get analysis for symbol resolution
    const analysis = handler.analyzeDocument(uri) catch null;
    const module = if (analysis) |a| a.module else null;

    // Build semantic token data (groups of 5: deltaLine, deltaStartChar, length, tokenType, tokenModifiers)
    var data: std.ArrayList(u32) = .empty;
    defer data.deinit(handler.gpa);

    var prev_line: u32 = 0;
    var prev_char: u32 = 0;
    var decl_cursor: DeclCursor = .{};

    // First, scan for comments and collect them
    var comment_ranges: std.ArrayList(struct { start: u32, end: u32 }) = .empty;
    defer comment_ranges.deinit(handler.gpa);
    {
        var i: u32 = 0;
        while (i < source.len) {
            if (source[i] == '/' and i + 1 < source.len) {
                if (source[i + 1] == '/') {
                    // Line comment
                    const cstart = i;
                    while (i < source.len and source[i] != '\n') i += 1;
                    comment_ranges.append(handler.gpa, .{ .start = cstart, .end = i }) catch {};
                } else if (source[i + 1] == '*') {
                    // Block comment (WGSL nests)
                    const cstart = i;
                    i += 2;
                    var depth: u32 = 1;
                    while (i + 1 < source.len and depth > 0) {
                        if (source[i] == '/' and source[i + 1] == '*') {
                            depth += 1;
                            i += 2;
                        } else if (source[i] == '*' and source[i + 1] == '/') {
                            depth -= 1;
                            i += 2;
                        } else i += 1;
                    }
                    comment_ranges.append(handler.gpa, .{ .start = cstart, .end = i }) catch {};
                } else {
                    i += 1;
                }
            } else {
                i += 1;
            }
        }
    }

    // Emit comment tokens first-pass style: interleave with regular tokens
    // For simplicity, process tokens and comments in source order
    var comment_idx: usize = 0;

    for (tags, 0..) |tag, ti| {
        if (tag == .eof or tag == .@"error") break;
        const tok_start = starts[ti];

        // Emit any comments that appear before this token
        while (comment_idx < comment_ranges.items.len and comment_ranges.items[comment_idx].start < tok_start) {
            const cr = comment_ranges.items[comment_idx];
            emitSemanticToken(handler.gpa, &pm, &data, &prev_line, &prev_char, cr.start, cr.end, @intFromEnum(SemanticTokenType.comment), 0);
            comment_idx += 1;
        }

        const tok_len = tokenLength(source_z, tok_start, tag);
        if (tok_len == 0) continue;

        switch (tag) {
            // Keywords
            .keyword_alias,
            .keyword_break,
            .keyword_case,
            .keyword_const,
            .keyword_const_assert,
            .keyword_continue,
            .keyword_continuing,
            .keyword_default,
            .keyword_diagnostic,
            .keyword_discard,
            .keyword_else,
            .keyword_enable,
            .keyword_fn,
            .keyword_for,
            .keyword_if,
            .keyword_let,
            .keyword_loop,
            .keyword_override,
            .keyword_requires,
            .keyword_return,
            .keyword_struct,
            .keyword_switch,
            .keyword_var,
            .keyword_while,
            => {
                emitSemanticToken(handler.gpa, &pm, &data, &prev_line, &prev_char, tok_start, tok_start + tok_len, @intFromEnum(SemanticTokenType.keyword), 0);
            },
            .true_literal, .false_literal => {
                emitSemanticToken(handler.gpa, &pm, &data, &prev_line, &prev_char, tok_start, tok_start + tok_len, @intFromEnum(SemanticTokenType.keyword), MOD_READONLY);
            },
            .int_literal, .float_literal => {
                emitSemanticToken(handler.gpa, &pm, &data, &prev_line, &prev_char, tok_start, tok_start + tok_len, @intFromEnum(SemanticTokenType.number), 0);
            },
            .at => {
                emitSemanticToken(handler.gpa, &pm, &data, &prev_line, &prev_char, tok_start, tok_start + tok_len, @intFromEnum(SemanticTokenType.decorator), 0);
            },
            .ident => {
                const name = identAt(source_z, tok_start);
                if (name.len == 0) continue;

                // Check if it's a builtin function
                if (Builtins.lookup(name) != null) {
                    emitSemanticToken(handler.gpa, &pm, &data, &prev_line, &prev_char, tok_start, tok_start + tok_len, @intFromEnum(SemanticTokenType.function), MOD_DEFAULT_LIBRARY);
                    continue;
                }

                // Try to resolve via AST
                if (module) |m| {
                    if (resolveIdentSymbol(m, &decl_cursor, tok_start, name)) |sym| {
                        const tok_type: u32 = switch (sym.kind) {
                            .function => @intFromEnum(SemanticTokenType.function),
                            .@"struct" => @intFromEnum(SemanticTokenType.@"struct"),
                            .parameter => @intFromEnum(SemanticTokenType.parameter),
                            .@"const", .override => @intFromEnum(SemanticTokenType.variable),
                            .let, .@"var" => @intFromEnum(SemanticTokenType.variable),
                            else => @intFromEnum(SemanticTokenType.variable),
                        };
                        var mods: u32 = 0;
                        if (sym.kind == .@"const" or sym.kind == .override) mods |= MOD_READONLY;
                        if (sym.loc == tok_start) mods |= MOD_DECLARATION;
                        emitSemanticToken(handler.gpa, &pm, &data, &prev_line, &prev_char, tok_start, tok_start + tok_len, tok_type, mods);
                        continue;
                    }
                }

                // Check if it's a builtin type name
                if (isBuiltinTypeName(name)) {
                    emitSemanticToken(handler.gpa, &pm, &data, &prev_line, &prev_char, tok_start, tok_start + tok_len, @intFromEnum(SemanticTokenType.type_name), MOD_DEFAULT_LIBRARY);
                    continue;
                }

                // Unresolved identifier — skip
            },
            else => {},
        }
    }

    // Emit any trailing comments
    while (comment_idx < comment_ranges.items.len) {
        const cr = comment_ranges.items[comment_idx];
        emitSemanticToken(handler.gpa, &pm, &data, &prev_line, &prev_char, cr.start, cr.end, @intFromEnum(SemanticTokenType.comment), 0);
        comment_idx += 1;
    }

    return try handler.gpa.dupe(u32, data.items);
}

fn emitSemanticToken(
    gpa: std.mem.Allocator,
    pm: *const Handler.PositionMapper,
    data: *std.ArrayList(u32),
    prev_line: *u32,
    prev_char: *u32,
    start: u32,
    end: u32,
    token_type: u32,
    modifiers: u32,
) void {
    const pos = pm.position(start) orelse return;
    // The wire `length` is counted in the negotiated position encoding, so
    // it is derived here rather than taken from the caller: every caller
    // has a byte span, and every one of them used to send it verbatim.
    // `end` comes from the lexer and cannot outrun the source, but clamp
    // rather than risk a highlighting panic on a bad `tokenLength` row.
    const length = Handler.PositionMapper.utf16Len(pm.source[start..@min(end, pm.source.len)]);
    const delta_line = pos.line - prev_line.*;
    const delta_char = if (delta_line == 0) pos.character - prev_char.* else pos.character;
    data.appendSlice(gpa, &.{ delta_line, delta_char, length, token_type, modifiers }) catch return;
    prev_line.* = pos.line;
    prev_char.* = pos.character;
}

fn tokenLength(source: [:0]const u8, start: u32, tag: Lexer.Tag) u32 {
    return switch (tag) {
        .ident, .reserved_ident => @intCast(identAt(source, start).len),
        .int_literal, .float_literal => blk: {
            var i = start;
            while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '.' or source[i] == '_' or source[i] == 'x' or source[i] == 'X' or source[i] == '+' or source[i] == '-')) {
                // Handle hex prefix and exponent signs carefully
                if ((source[i] == '+' or source[i] == '-') and i > start) {
                    const prev = source[i - 1];
                    if (prev != 'e' and prev != 'E' and prev != 'p' and prev != 'P') break;
                }
                i += 1;
            }
            break :blk i - start;
        },
        .true_literal => 4,
        .false_literal => 5,
        .at => 1,
        // Keywords — get length from the keyword string
        .keyword_alias => 5,
        .keyword_break => 5,
        .keyword_case => 4,
        .keyword_const => 5,
        .keyword_const_assert => 12,
        .keyword_continue => 8,
        .keyword_continuing => 10,
        .keyword_default => 7,
        .keyword_diagnostic => 10,
        .keyword_discard => 7,
        .keyword_else => 4,
        .keyword_enable => 6,
        .keyword_fn => 2,
        .keyword_for => 3,
        .keyword_if => 2,
        .keyword_let => 3,
        .keyword_loop => 4,
        .keyword_override => 8,
        .keyword_requires => 8,
        .keyword_return => 6,
        .keyword_struct => 6,
        .keyword_switch => 6,
        .keyword_var => 3,
        .keyword_while => 5,
        else => 0,
    };
}

/// The identifier token beginning at `start`.
///
/// Defers to the lexer's own scanner rather than re-deriving the identifier
/// grammar: WGSL §2.4 identifiers are `XID_Start XID_Continue*`, so an
/// ASCII-only scan stops dead at the first non-ASCII byte. That truncated
/// the name used for symbol and builtin lookup, and — since a zero-length
/// name is skipped outright — dropped every identifier *starting* with a
/// non-ASCII character.
fn identAt(source: [:0]const u8, start: u32) []const u8 {
    return source[start..Lexer.scanIdentEnd(source, start)];
}

/// The declaration that contained the previously resolved token.
///
/// `NodeAtOffset.find` does no span pruning — it recurses every
/// declaration's whole subtree and only tests containment at leaf
/// identifiers. That is fine at one call per request (hover, definition),
/// but semantic tokens resolve one node per identifier token, which would
/// make the pass O(tokens × AST nodes). Tokens arrive in increasing source
/// order, so the declaration covering the previous one almost always
/// covers the next: remembering it turns the common case into a single
/// `Ast.Decl.declSpan` containment test.
const DeclCursor = struct {
    idx: usize = 0,

    fn find(self: *DeclCursor, module: *const Ast.Module, loc: u32) NodeAtOffset.NodeAtPosition {
        const decls = module.declarations.items;
        if (self.idx < decls.len and spanContains(decls[self.idx].declSpan(), loc)) {
            return NodeAtOffset.findInDeclaration(module, decls[self.idx], loc);
        }
        for (decls, 0..) |decl, i| {
            if (!spanContains(decl.declSpan(), loc)) continue;
            self.idx = i;
            return NodeAtOffset.findInDeclaration(module, decl, loc);
        }
        // No declaration claims this offset — `const_assert` has an empty
        // `declSpan`, and directives aren't declarations at all. Rare
        // enough to pay for the unpruned walk.
        return NodeAtOffset.find(module, loc);
    }
};

fn spanContains(span: Ast.Span, offset: u32) bool {
    return !span.isEmpty() and offset >= span.start and offset < span.end;
}

/// Resolve the symbol an identifier token refers to.
///
/// The AST is the scope-correct source of truth: `Ast.Ident.ref` was bound
/// by `AstVisit` Pass 2, so it names the declaration actually visible at
/// that offset. A whole-module name scan cannot do this — with two
/// same-named symbols it returns whichever comes first in
/// `module.symbols.items`, so a local reference could be colored as some
/// other function's parameter.
///
/// The name scan survives as a fallback because semantic tokens are
/// recomputed on every keystroke, including versions where parser error
/// recovery has dropped the half-typed statement containing this token —
/// there the AST has no node at this offset and only the name is left to
/// go on. Approximate coloring beats none while typing.
fn resolveIdentSymbol(module: *const Ast.Module, cursor: *DeclCursor, loc: u32, name: []const u8) ?Ast.Symbol {
    const ref: Ast.SymbolIndex = switch (cursor.find(module, loc)) {
        // `findInExpr` already falls back to a by-name lookup for idents
        // whose `ref` never bound, so an invalid one here means the name
        // scan has run and failed — repeating it would be pure cost.
        .ident => |id| return symbolAt(module, id.ref),
        .decl_name => |dn| return symbolAt(module, dn.sym_idx),
        // An unbound type ref is a builtin (`f32`) or an unknown type;
        // either way no user symbol carries the name.
        .type_ref => |tr| return symbolAt(module, tr.ref),
        // The member name in `s.field` is an `.ident` lexer token too, and
        // `member_ref` is populated by the validator, which the LSP always
        // runs. Dropping it here would uncolor every member access.
        .member_access => |ma| ma.ref,
        .binary_expr, .none => .none,
    };
    if (ref.isValid()) return module.symbols.items[ref.index()];

    for (module.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.original_name, name)) return sym;
    }
    return null;
}

fn symbolAt(module: *const Ast.Module, ref: Ast.SymbolIndex) ?Ast.Symbol {
    if (!ref.isValid()) return null;
    return module.symbols.items[ref.index()];
}

fn isBuiltinTypeName(name: []const u8) bool {
    for (&wgsl_type_names) |tn| {
        if (std.mem.eql(u8, name, tn)) return true;
    }
    return false;
}
