//! WGSL tokenizer.
//!
//! Converts WGSL source text into a sequence of tokens using a
//! labeled-switch state machine with comptime lookup tables for
//! fast ASCII classification. Sentinel-terminated input ([:0]const u8)
//! eliminates bounds checks in the hot path.

const std = @import("std");
const Ast = @import("Ast.zig");

const Lexer = @This();

source: [:0]const u8,
pos: u32,
tokens: std.MultiArrayList(Token),

pub const Token = struct {
    tag: Tag,
    start: u32,
    /// One past the last source byte of the token (half-open). For trivia
    /// tokens this covers the whole trivia run (not per-character). For
    /// `.eof`, `end == start`.
    end: u32,
};

/// Token tags. Values ≤ keyword_end are keywords, used for StaticStringMap.
pub const Tag = enum(u8) {
    // Sentinel / error
    eof,
    @"error",

    // Literals
    int_literal,
    float_literal,
    true_literal,
    false_literal,

    // Identifier
    ident,
    reserved_ident,

    // Keywords (order must match keywords_map entries)
    keyword_alias,
    keyword_break,
    keyword_case,
    keyword_const,
    keyword_const_assert,
    keyword_continue,
    keyword_continuing,
    keyword_default,
    keyword_diagnostic,
    keyword_discard,
    keyword_else,
    keyword_enable,
    keyword_fn,
    keyword_for,
    keyword_if,
    keyword_let,
    keyword_loop,
    keyword_override,
    keyword_requires,
    keyword_return,
    keyword_struct,
    keyword_switch,
    keyword_var,
    keyword_while,

    // Single-char operators
    plus,
    minus,
    star,
    slash,
    percent,
    amp,
    pipe,
    caret,
    tilde,
    bang,
    lt,
    gt,
    eq,
    dot,
    at,

    // Multi-char operators
    plus_plus,
    minus_minus,
    amp_amp,
    pipe_pipe,
    lt_lt,
    gt_gt,
    lt_eq,
    gt_eq,
    eq_eq,
    bang_eq,
    arrow,
    plus_eq,
    minus_eq,
    star_eq,
    slash_eq,
    percent_eq,
    amp_eq,
    pipe_eq,
    caret_eq,
    lt_lt_eq,
    gt_gt_eq,

    // Delimiters
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    l_bracket,
    r_bracket,
    semicolon,
    colon,
    comma,
    underscore,

    // Template delimiters (context-sensitive, reserved for future use)
    template_args_start,
    template_args_end,

    // Trivia — only emitted by `tokenizeAll`. The default `tokenize` entry
    // point skips over trivia (existing parser behavior). `.end` covers the
    // full run of contiguous whitespace / the full comment extent.
    whitespace,
    line_comment,
    block_comment,

    /// True when `self` is a trivia tag (whitespace or comment).
    pub fn isTrivia(self: Tag) bool {
        return switch (self) {
            .whitespace, .line_comment, .block_comment => true,
            else => false,
        };
    }

    pub fn symbol(self: Tag) []const u8 {
        return symbols_table[@intFromEnum(self)];
    }

    const symbols_table = init_symbols_table();

    fn init_symbols_table() [std.meta.fields(Tag).len][]const u8 {
        var result: [std.meta.fields(Tag).len][]const u8 = undefined;
        for (std.meta.fields(Tag)) |field| {
            result[field.value] = field.name;
        }
        // Override with readable symbols
        result[@intFromEnum(Tag.plus)] = "+";
        result[@intFromEnum(Tag.minus)] = "-";
        result[@intFromEnum(Tag.star)] = "*";
        result[@intFromEnum(Tag.slash)] = "/";
        result[@intFromEnum(Tag.percent)] = "%";
        result[@intFromEnum(Tag.amp)] = "&";
        result[@intFromEnum(Tag.pipe)] = "|";
        result[@intFromEnum(Tag.caret)] = "^";
        result[@intFromEnum(Tag.tilde)] = "~";
        result[@intFromEnum(Tag.bang)] = "!";
        result[@intFromEnum(Tag.lt)] = "<";
        result[@intFromEnum(Tag.gt)] = ">";
        result[@intFromEnum(Tag.eq)] = "=";
        result[@intFromEnum(Tag.dot)] = ".";
        result[@intFromEnum(Tag.at)] = "@";
        result[@intFromEnum(Tag.plus_plus)] = "++";
        result[@intFromEnum(Tag.minus_minus)] = "--";
        result[@intFromEnum(Tag.amp_amp)] = "&&";
        result[@intFromEnum(Tag.pipe_pipe)] = "||";
        result[@intFromEnum(Tag.lt_lt)] = "<<";
        result[@intFromEnum(Tag.gt_gt)] = ">>";
        result[@intFromEnum(Tag.lt_eq)] = "<=";
        result[@intFromEnum(Tag.gt_eq)] = ">=";
        result[@intFromEnum(Tag.eq_eq)] = "==";
        result[@intFromEnum(Tag.bang_eq)] = "!=";
        result[@intFromEnum(Tag.arrow)] = "->";
        result[@intFromEnum(Tag.plus_eq)] = "+=";
        result[@intFromEnum(Tag.minus_eq)] = "-=";
        result[@intFromEnum(Tag.star_eq)] = "*=";
        result[@intFromEnum(Tag.slash_eq)] = "/=";
        result[@intFromEnum(Tag.percent_eq)] = "%=";
        result[@intFromEnum(Tag.amp_eq)] = "&=";
        result[@intFromEnum(Tag.pipe_eq)] = "|=";
        result[@intFromEnum(Tag.caret_eq)] = "^=";
        result[@intFromEnum(Tag.lt_lt_eq)] = "<<=";
        result[@intFromEnum(Tag.gt_gt_eq)] = ">>=";
        result[@intFromEnum(Tag.l_paren)] = "(";
        result[@intFromEnum(Tag.r_paren)] = ")";
        result[@intFromEnum(Tag.l_brace)] = "{";
        result[@intFromEnum(Tag.r_brace)] = "}";
        result[@intFromEnum(Tag.l_bracket)] = "[";
        result[@intFromEnum(Tag.r_bracket)] = "]";
        result[@intFromEnum(Tag.semicolon)] = ";";
        result[@intFromEnum(Tag.colon)] = ":";
        result[@intFromEnum(Tag.comma)] = ",";
        result[@intFromEnum(Tag.underscore)] = "_";
        // Keywords
        result[@intFromEnum(Tag.keyword_alias)] = "alias";
        result[@intFromEnum(Tag.keyword_break)] = "break";
        result[@intFromEnum(Tag.keyword_case)] = "case";
        result[@intFromEnum(Tag.keyword_const)] = "const";
        result[@intFromEnum(Tag.keyword_const_assert)] = "const_assert";
        result[@intFromEnum(Tag.keyword_continue)] = "continue";
        result[@intFromEnum(Tag.keyword_continuing)] = "continuing";
        result[@intFromEnum(Tag.keyword_default)] = "default";
        result[@intFromEnum(Tag.keyword_diagnostic)] = "diagnostic";
        result[@intFromEnum(Tag.keyword_discard)] = "discard";
        result[@intFromEnum(Tag.keyword_else)] = "else";
        result[@intFromEnum(Tag.keyword_enable)] = "enable";
        result[@intFromEnum(Tag.keyword_fn)] = "fn";
        result[@intFromEnum(Tag.keyword_for)] = "for";
        result[@intFromEnum(Tag.keyword_if)] = "if";
        result[@intFromEnum(Tag.keyword_let)] = "let";
        result[@intFromEnum(Tag.keyword_loop)] = "loop";
        result[@intFromEnum(Tag.keyword_override)] = "override";
        result[@intFromEnum(Tag.keyword_requires)] = "requires";
        result[@intFromEnum(Tag.keyword_return)] = "return";
        result[@intFromEnum(Tag.keyword_struct)] = "struct";
        result[@intFromEnum(Tag.keyword_switch)] = "switch";
        result[@intFromEnum(Tag.keyword_var)] = "var";
        result[@intFromEnum(Tag.keyword_while)] = "while";
        return result;
    }
};

// -------------------------------------------------------------------------
// Comptime lookup tables
// -------------------------------------------------------------------------

// Pre-computed ASCII character classification tables for the hot tokenization
// loop. 128 entries (ASCII range only); the `c < 128` guard in isIdentStart/
// isIdentContinue rejects non-ASCII bytes before indexing.
const ident_start_table: [128]bool = blk: {
    var table = [_]bool{false} ** 128;
    for ('a'..('z' + 1)) |c| {
        table[c] = true;
    }
    for ('A'..('Z' + 1)) |c| {
        table[c] = true;
    }
    table['_'] = true;
    break :blk table;
};

const ident_continue_table: [128]bool = blk: {
    var table = ident_start_table;
    for ('0'..('9' + 1)) |c| {
        table[c] = true;
    }
    break :blk table;
};

/// Returns true if `c` is a valid WGSL identifier start character (ASCII only).
pub fn isIdentStart(c: u8) bool {
    return c < 128 and ident_start_table[c];
}

/// Returns true if `c` can continue a WGSL identifier (ASCII only).
pub fn isIdentContinue(c: u8) bool {
    return c < 128 and ident_continue_table[c];
}

/// Returns true if `c` is an ASCII decimal digit.
pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Returns true if `c` is an ASCII hexadecimal digit.
pub fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

// -------------------------------------------------------------------------
// Keyword map (comptime StaticStringMap)
// -------------------------------------------------------------------------

pub const keywords_map = std.StaticStringMap(Tag).initComptime(.{
    .{ "alias", .keyword_alias },
    .{ "break", .keyword_break },
    .{ "case", .keyword_case },
    .{ "const", .keyword_const },
    .{ "const_assert", .keyword_const_assert },
    .{ "continue", .keyword_continue },
    .{ "continuing", .keyword_continuing },
    .{ "default", .keyword_default },
    .{ "diagnostic", .keyword_diagnostic },
    .{ "discard", .keyword_discard },
    .{ "else", .keyword_else },
    .{ "enable", .keyword_enable },
    .{ "false", .false_literal },
    .{ "fn", .keyword_fn },
    .{ "for", .keyword_for },
    .{ "if", .keyword_if },
    .{ "let", .keyword_let },
    .{ "loop", .keyword_loop },
    .{ "override", .keyword_override },
    .{ "requires", .keyword_requires },
    .{ "return", .keyword_return },
    .{ "struct", .keyword_struct },
    .{ "switch", .keyword_switch },
    .{ "true", .true_literal },
    .{ "var", .keyword_var },
    .{ "while", .keyword_while },
});

/// Words reserved by the WGSL spec for future use (WGSL §14.5). The renamer
/// must never generate these as minified names, and identifiers matching them
/// are tokenized as `reserved_ident` instead of `ident`.
pub const reserved_words = std.StaticStringMap(void).initComptime(.{
    .{ "NULL", {} },             .{ "Self", {} },             .{ "abstract", {} },
    .{ "active", {} },           .{ "alignas", {} },          .{ "alignof", {} },
    .{ "as", {} },               .{ "asm", {} },              .{ "asm_fragment", {} },
    .{ "async", {} },            .{ "attribute", {} },        .{ "auto", {} },
    .{ "await", {} },            .{ "become", {} },           .{ "cast", {} },
    .{ "catch", {} },            .{ "class", {} },            .{ "co_await", {} },
    .{ "co_return", {} },        .{ "co_yield", {} },         .{ "coherent", {} },
    .{ "column_major", {} },     .{ "common", {} },           .{ "compile", {} },
    .{ "compile_fragment", {} }, .{ "concept", {} },          .{ "const_cast", {} },
    .{ "consteval", {} },        .{ "constexpr", {} },        .{ "constinit", {} },
    .{ "crate", {} },            .{ "debugger", {} },         .{ "decltype", {} },
    .{ "delete", {} },           .{ "demote", {} },           .{ "demote_to_helper", {} },
    .{ "do", {} },               .{ "dynamic_cast", {} },     .{ "enum", {} },
    .{ "explicit", {} },         .{ "export", {} },           .{ "extends", {} },
    .{ "extern", {} },           .{ "external", {} },         .{ "fallthrough", {} },
    .{ "filter", {} },           .{ "final", {} },            .{ "finally", {} },
    .{ "friend", {} },           .{ "from", {} },             .{ "fxgroup", {} },
    .{ "get", {} },              .{ "goto", {} },             .{ "groupshared", {} },
    .{ "highp", {} },            .{ "impl", {} },             .{ "implements", {} },
    .{ "import", {} },           .{ "inline", {} },           .{ "instanceof", {} },
    .{ "interface", {} },        .{ "layout", {} },           .{ "lowp", {} },
    .{ "macro", {} },            .{ "macro_rules", {} },      .{ "match", {} },
    .{ "mediump", {} },          .{ "meta", {} },             .{ "mod", {} },
    .{ "module", {} },           .{ "move", {} },             .{ "mut", {} },
    .{ "mutable", {} },          .{ "namespace", {} },        .{ "new", {} },
    .{ "nil", {} },              .{ "noexcept", {} },         .{ "noinline", {} },
    .{ "nointerpolation", {} },  .{ "non_coherent", {} },     .{ "noncoherent", {} },
    .{ "noperspective", {} },    .{ "null", {} },             .{ "nullptr", {} },
    .{ "of", {} },               .{ "operator", {} },         .{ "package", {} },
    .{ "packoffset", {} },       .{ "partition", {} },        .{ "pass", {} },
    .{ "patch", {} },            .{ "pixelfragment", {} },    .{ "precise", {} },
    .{ "precision", {} },        .{ "premerge", {} },         .{ "priv", {} },
    .{ "protected", {} },        .{ "pub", {} },              .{ "public", {} },
    .{ "readonly", {} },         .{ "ref", {} },              .{ "regardless", {} },
    .{ "register", {} },         .{ "reinterpret_cast", {} }, .{ "require", {} },
    .{ "resource", {} },         .{ "restrict", {} },         .{ "self", {} },
    .{ "set", {} },              .{ "shared", {} },           .{ "sizeof", {} },
    .{ "smooth", {} },           .{ "snorm", {} },            .{ "static", {} },
    .{ "static_assert", {} },    .{ "static_cast", {} },      .{ "std", {} },
    .{ "subroutine", {} },       .{ "super", {} },            .{ "target", {} },
    .{ "template", {} },         .{ "this", {} },             .{ "thread_local", {} },
    .{ "throw", {} },            .{ "trait", {} },            .{ "try", {} },
    .{ "type", {} },             .{ "typedef", {} },          .{ "typeid", {} },
    .{ "typename", {} },         .{ "typeof", {} },           .{ "union", {} },
    .{ "unless", {} },           .{ "unorm", {} },            .{ "unsafe", {} },
    .{ "unsized", {} },          .{ "use", {} },              .{ "using", {} },
    .{ "varying", {} },          .{ "virtual", {} },          .{ "volatile", {} },
    .{ "wgsl", {} },             .{ "where", {} },            .{ "with", {} },
    .{ "writeonly", {} },        .{ "yield", {} },
});

// -------------------------------------------------------------------------
// Initialization
// -------------------------------------------------------------------------

/// Creates a new lexer for the given sentinel-terminated WGSL source.
pub fn init(source: [:0]const u8) Lexer {
    return .{
        .source = source,
        .pos = 0,
        .tokens = std.MultiArrayList(Token){},
    };
}

/// Tokenize the entire source, skipping trivia (whitespace / comments),
/// returning owned token storage. Classic Parser entry point: the sequence
/// contains only real tokens followed by an `.eof` sentinel, matching the
/// pre-trivia-era layout. Every token carries a valid `[start, end)` range.
pub fn tokenize(arena: std.mem.Allocator, source: [:0]const u8) !std.MultiArrayList(Token) {
    var lex = Lexer{
        .source = source,
        .pos = 0,
        .tokens = .empty,
    };

    // Pre-estimate capacity: ~1 token per 8 source bytes
    const estimated = @max(source.len / 8, 16);
    try lex.tokens.ensureTotalCapacity(arena, estimated);

    for (0..source.len + 1) |_| {
        const tok = lex.next();
        try lex.tokens.append(arena, .{ .tag = tok.tag, .start = tok.start, .end = tok.end });
        if (tok.tag == .eof or tok.tag == .@"error") break;
    } else unreachable;

    return lex.tokens;
}

/// Tokenize the entire source, emitting `.whitespace`, `.line_comment`, and
/// `.block_comment` trivia tokens alongside real tokens. The concatenation
/// of every token's source slice is byte-identical to `source[0..source.len]`
/// — this is the contract the CST builder relies on.
pub fn tokenizeAll(arena: std.mem.Allocator, source: [:0]const u8) !std.MultiArrayList(Token) {
    var lex = Lexer{
        .source = source,
        .pos = 0,
        .tokens = .empty,
    };

    // Trivia can double the token count; bias the estimate up.
    const estimated = @max(source.len / 4, 16);
    try lex.tokens.ensureTotalCapacity(arena, estimated);

    // An upper bound: every source byte can at worst produce a 1-byte trivia
    // token plus a 0-length boundary token, plus the trailing `.eof`.
    for (0..source.len * 2 + 2) |_| {
        const tok = lex.nextAny();
        try lex.tokens.append(arena, .{ .tag = tok.tag, .start = tok.start, .end = tok.end });
        if (tok.tag == .eof or tok.tag == .@"error") break;
    } else unreachable;

    return lex.tokens;
}

// -------------------------------------------------------------------------
// Core scanning — labeled switch state machine
// -------------------------------------------------------------------------

const TokenResult = struct { tag: Tag, start: u32, end: u32 };

const State = enum {
    start,
    // Comments
    line_comment,
    block_comment,
    // Identifiers
    identifier,
    // Numbers — decimal
    zero,
    int,
    int_dot,
    decimal_frac,
    decimal_exponent,
    decimal_exp_digits,
    // Numbers — hex
    hex,
    hex_frac,
    hex_exponent,
    hex_exp_digits,
    // Dot
    dot,
    // Multi-char operators
    saw_plus,
    saw_minus,
    saw_star,
    saw_slash,
    saw_percent,
    saw_amp,
    saw_pipe,
    saw_caret,
    saw_lt,
    saw_lt_lt,
    saw_gt,
    saw_gt_gt,
    saw_eq,
    saw_bang,
};

fn next(self: *Lexer) TokenResult {
    var start: u32 = self.pos;
    var kind: Tag = .eof;
    var block_depth: u32 = 0;
    const src = self.source;

    state: switch (State.start) {
        // =============================================================
        // Start — dispatch on current character
        // =============================================================
        .start => switch (src[self.pos]) {
            0 => {
                if (self.pos >= src.len) return .{ .tag = .eof, .start = self.pos, .end = self.pos };
                // Embedded null — treat as error
                kind = .@"error";
                self.pos += 1;
            },
            ' ', '\n', '\t', '\r' => {
                self.pos += 1;
                start = self.pos;
                continue :state .start;
            },
            '/' => continue :state .saw_slash,
            'a'...'z', 'A'...'Z', '_' => {
                kind = .ident;
                self.pos += 1;
                continue :state .identifier;
            },
            '0' => {
                kind = .int_literal;
                self.pos += 1;
                continue :state .zero;
            },
            '1'...'9' => {
                kind = .int_literal;
                self.pos += 1;
                continue :state .int;
            },
            '.' => continue :state .dot,
            // Multi-char operator starts
            '+' => continue :state .saw_plus,
            '-' => continue :state .saw_minus,
            '*' => continue :state .saw_star,
            '%' => continue :state .saw_percent,
            '&' => continue :state .saw_amp,
            '|' => continue :state .saw_pipe,
            '^' => continue :state .saw_caret,
            '<' => continue :state .saw_lt,
            '>' => continue :state .saw_gt,
            '=' => continue :state .saw_eq,
            '!' => continue :state .saw_bang,
            // Single-char tokens
            '~' => {
                kind = .tilde;
                self.pos += 1;
            },
            '@' => {
                kind = .at;
                self.pos += 1;
            },
            '(' => {
                kind = .l_paren;
                self.pos += 1;
            },
            ')' => {
                kind = .r_paren;
                self.pos += 1;
            },
            '{' => {
                kind = .l_brace;
                self.pos += 1;
            },
            '}' => {
                kind = .r_brace;
                self.pos += 1;
            },
            '[' => {
                kind = .l_bracket;
                self.pos += 1;
            },
            ']' => {
                kind = .r_bracket;
                self.pos += 1;
            },
            ';' => {
                kind = .semicolon;
                self.pos += 1;
            },
            ':' => {
                kind = .colon;
                self.pos += 1;
            },
            ',' => {
                kind = .comma;
                self.pos += 1;
            },
            else => {
                kind = .@"error";
                self.pos += 1;
            },
        },

        // =============================================================
        // Comments
        // =============================================================
        .line_comment => switch (src[self.pos]) {
            0 => {
                // EOF during line comment — return to start (produces eof on next call)
                start = self.pos;
                continue :state .start;
            },
            '\n' => {
                self.pos += 1;
                start = self.pos;
                continue :state .start;
            },
            else => {
                self.pos += 1;
                continue :state .line_comment;
            },
        },
        .block_comment => switch (src[self.pos]) {
            0 => {
                if (self.pos >= src.len) {
                    // Unterminated block comment — match old behavior: return eof
                    return .{ .tag = .eof, .start = self.pos, .end = self.pos };
                }
                // Embedded null in comment
                self.pos += 1;
                continue :state .block_comment;
            },
            '/' => {
                if (src[self.pos + 1] == '*') {
                    block_depth += 1;
                    self.pos += 2;
                } else {
                    self.pos += 1;
                }
                continue :state .block_comment;
            },
            '*' => {
                if (src[self.pos + 1] == '/') {
                    block_depth -= 1;
                    self.pos += 2;
                    if (block_depth == 0) {
                        start = self.pos;
                        continue :state .start;
                    }
                } else {
                    self.pos += 1;
                }
                continue :state .block_comment;
            },
            else => {
                self.pos += 1;
                continue :state .block_comment;
            },
        },

        // =============================================================
        // Identifiers
        // =============================================================
        .identifier => switch (src[self.pos]) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => {
                self.pos += 1;
                continue :state .identifier;
            },
            else => {
                const text = src[start..self.pos];
                if (keywords_map.get(text)) |kw_tag| {
                    kind = kw_tag;
                } else if (text.len == 1 and text[0] == '_') {
                    kind = .underscore;
                } else if (reserved_words.has(text)) {
                    kind = .reserved_ident;
                } else if (text.len >= 2 and text[0] == '_' and text[1] == '_') {
                    kind = .reserved_ident;
                }
                // else kind stays .ident (set in .start)
            },
        },

        // =============================================================
        // Numbers — leading zero
        // =============================================================
        .zero => switch (src[self.pos]) {
            'x', 'X' => {
                self.pos += 1;
                continue :state .hex;
            },
            '0'...'9' => {
                self.pos += 1;
                continue :state .int;
            },
            '.' => continue :state .int_dot,
            'e', 'E' => {
                kind = .float_literal;
                self.pos += 1;
                continue :state .decimal_exponent;
            },
            'i', 'u' => {
                self.pos += 1;
            },
            'f', 'h' => {
                kind = .float_literal;
                self.pos += 1;
            },
            else => {},
        },

        // =============================================================
        // Numbers — decimal digits
        // =============================================================
        .int => switch (src[self.pos]) {
            '0'...'9' => {
                self.pos += 1;
                continue :state .int;
            },
            '.' => continue :state .int_dot,
            'e', 'E' => {
                kind = .float_literal;
                self.pos += 1;
                continue :state .decimal_exponent;
            },
            'i', 'u' => {
                self.pos += 1;
            },
            'f', 'h' => {
                kind = .float_literal;
                self.pos += 1;
            },
            else => {},
        },

        // =============================================================
        // Numbers — saw '.' after decimal digits, disambiguate
        // =============================================================
        .int_dot => {
            const after_dot = src[self.pos + 1]; // safe: sentinel
            const next_is_digit = after_dot >= '0' and after_dot <= '9';
            const next_is_ident = isIdentStart(after_dot);
            const at_end = self.pos + 1 >= src.len;
            // Accept 1.f and 1.h — float suffix after decimal point with no fractional digits
            const next_is_float_suffix = (after_dot == 'f' or after_dot == 'h') and
                !isIdentContinue(src[self.pos + 2]); // safe: sentinel guarantees valid read

            if (next_is_digit or at_end or !next_is_ident or next_is_float_suffix) {
                kind = .float_literal;
                self.pos += 1; // consume the '.'
                if (next_is_float_suffix) {
                    self.pos += 1; // consume the suffix
                    // Check for exponent after suffix? No — 1.f is complete.
                    // But we still need to scan fractional digits if not a suffix.
                } else {
                    continue :state .decimal_frac;
                }
            }
            // else: don't consume '.', leave for next token as dot operator
            // kind stays .int_literal
        },

        // =============================================================
        // Numbers — fractional decimal digits after '.'
        // =============================================================
        .decimal_frac => switch (src[self.pos]) {
            '0'...'9' => {
                self.pos += 1;
                continue :state .decimal_frac;
            },
            'e', 'E' => {
                self.pos += 1;
                continue :state .decimal_exponent;
            },
            'f', 'h' => {
                self.pos += 1;
            },
            'i', 'u' => {
                self.pos += 1;
            },
            else => {},
        },

        // =============================================================
        // Numbers — saw 'e'/'E', check for optional sign
        // =============================================================
        .decimal_exponent => switch (src[self.pos]) {
            '+', '-' => {
                self.pos += 1;
                continue :state .decimal_exp_digits;
            },
            '0'...'9' => {
                self.pos += 1;
                continue :state .decimal_exp_digits;
            },
            else => {},
        },

        // =============================================================
        // Numbers — exponent digit run
        // =============================================================
        .decimal_exp_digits => switch (src[self.pos]) {
            '0'...'9' => {
                self.pos += 1;
                continue :state .decimal_exp_digits;
            },
            'f', 'h' => {
                self.pos += 1;
            },
            'i', 'u' => {
                self.pos += 1;
            },
            else => {},
        },

        // =============================================================
        // Numbers — hex digit run
        // =============================================================
        .hex => switch (src[self.pos]) {
            '0'...'9', 'a'...'f', 'A'...'F' => {
                self.pos += 1;
                continue :state .hex;
            },
            '.' => {
                kind = .float_literal;
                self.pos += 1;
                continue :state .hex_frac;
            },
            'p', 'P' => {
                kind = .float_literal;
                self.pos += 1;
                continue :state .hex_exponent;
            },
            'i', 'u' => {
                self.pos += 1;
            },
            else => {},
        },

        // =============================================================
        // Numbers — hex fractional digits after '.'
        // =============================================================
        .hex_frac => switch (src[self.pos]) {
            '0'...'9', 'a'...'f', 'A'...'F' => {
                self.pos += 1;
                continue :state .hex_frac;
            },
            'p', 'P' => {
                self.pos += 1;
                continue :state .hex_exponent;
            },
            'i', 'u' => {
                self.pos += 1;
            },
            else => {},
        },

        // =============================================================
        // Numbers — hex exponent, check for optional sign
        // =============================================================
        .hex_exponent => switch (src[self.pos]) {
            '+', '-' => {
                self.pos += 1;
                continue :state .hex_exp_digits;
            },
            '0'...'9' => {
                self.pos += 1;
                continue :state .hex_exp_digits;
            },
            else => {},
        },

        // =============================================================
        // Numbers — hex exponent digit run
        // =============================================================
        .hex_exp_digits => switch (src[self.pos]) {
            '0'...'9' => {
                self.pos += 1;
                continue :state .hex_exp_digits;
            },
            'f', 'h' => {
                self.pos += 1;
            },
            'i', 'u' => {
                self.pos += 1;
            },
            else => {},
        },

        // =============================================================
        // Dot — '.' as float start or operator
        // =============================================================
        .dot => {
            self.pos += 1;
            if (src[self.pos] >= '0' and src[self.pos] <= '9') {
                kind = .float_literal;
                self.pos += 1;
                continue :state .decimal_frac;
            }
            kind = .dot;
        },

        // =============================================================
        // Operators
        // =============================================================
        .saw_plus => {
            self.pos += 1;
            switch (src[self.pos]) {
                '+' => {
                    kind = .plus_plus;
                    self.pos += 1;
                },
                '=' => {
                    kind = .plus_eq;
                    self.pos += 1;
                },
                else => kind = .plus,
            }
        },
        .saw_minus => {
            self.pos += 1;
            switch (src[self.pos]) {
                '-' => {
                    kind = .minus_minus;
                    self.pos += 1;
                },
                '=' => {
                    kind = .minus_eq;
                    self.pos += 1;
                },
                '>' => {
                    kind = .arrow;
                    self.pos += 1;
                },
                else => kind = .minus,
            }
        },
        .saw_star => {
            self.pos += 1;
            switch (src[self.pos]) {
                '=' => {
                    kind = .star_eq;
                    self.pos += 1;
                },
                else => kind = .star,
            }
        },
        .saw_slash => {
            self.pos += 1;
            switch (src[self.pos]) {
                '/' => {
                    self.pos += 1;
                    continue :state .line_comment;
                },
                '*' => {
                    self.pos += 1;
                    block_depth = 1;
                    continue :state .block_comment;
                },
                '=' => {
                    kind = .slash_eq;
                    self.pos += 1;
                },
                else => kind = .slash,
            }
        },
        .saw_percent => {
            self.pos += 1;
            switch (src[self.pos]) {
                '=' => {
                    kind = .percent_eq;
                    self.pos += 1;
                },
                else => kind = .percent,
            }
        },
        .saw_amp => {
            self.pos += 1;
            switch (src[self.pos]) {
                '&' => {
                    kind = .amp_amp;
                    self.pos += 1;
                },
                '=' => {
                    kind = .amp_eq;
                    self.pos += 1;
                },
                else => kind = .amp,
            }
        },
        .saw_pipe => {
            self.pos += 1;
            switch (src[self.pos]) {
                '|' => {
                    kind = .pipe_pipe;
                    self.pos += 1;
                },
                '=' => {
                    kind = .pipe_eq;
                    self.pos += 1;
                },
                else => kind = .pipe,
            }
        },
        .saw_caret => {
            self.pos += 1;
            switch (src[self.pos]) {
                '=' => {
                    kind = .caret_eq;
                    self.pos += 1;
                },
                else => kind = .caret,
            }
        },
        .saw_lt => {
            self.pos += 1;
            switch (src[self.pos]) {
                '<' => continue :state .saw_lt_lt,
                '=' => {
                    kind = .lt_eq;
                    self.pos += 1;
                },
                else => kind = .lt,
            }
        },
        .saw_lt_lt => {
            self.pos += 1;
            switch (src[self.pos]) {
                '=' => {
                    kind = .lt_lt_eq;
                    self.pos += 1;
                },
                else => kind = .lt_lt,
            }
        },
        .saw_gt => {
            self.pos += 1;
            switch (src[self.pos]) {
                '>' => continue :state .saw_gt_gt,
                '=' => {
                    kind = .gt_eq;
                    self.pos += 1;
                },
                else => kind = .gt,
            }
        },
        .saw_gt_gt => {
            self.pos += 1;
            switch (src[self.pos]) {
                '=' => {
                    kind = .gt_gt_eq;
                    self.pos += 1;
                },
                else => kind = .gt_gt,
            }
        },
        .saw_eq => {
            self.pos += 1;
            switch (src[self.pos]) {
                '=' => {
                    kind = .eq_eq;
                    self.pos += 1;
                },
                else => kind = .eq,
            }
        },
        .saw_bang => {
            self.pos += 1;
            switch (src[self.pos]) {
                '=' => {
                    kind = .bang_eq;
                    self.pos += 1;
                },
                else => kind = .bang,
            }
        },
    }

    return .{ .tag = kind, .start = start, .end = self.pos };
}

// -------------------------------------------------------------------------
// Trivia-emitting scanner — used by `tokenizeAll` / the CST builder.
// -------------------------------------------------------------------------

/// Like `next()` but emits whitespace and comment trivia as first-class
/// tokens instead of skipping them. Guarantees: for any sequence of
/// successive calls, the concatenation of `source[tok.start..tok.end]` is
/// byte-identical to the source up to EOF. Each whitespace run collapses
/// into a single `.whitespace` token (greedy run of any of space / tab /
/// CR / LF). Comments follow the same one-token-per-comment rule as today,
/// including nested block comments which still form a single token.
fn nextAny(self: *Lexer) TokenResult {
    const src = self.source;
    const start: u32 = self.pos;

    if (self.pos >= src.len) {
        return .{ .tag = .eof, .start = start, .end = start };
    }

    const ch = src[self.pos];

    // Whitespace run.
    if (ch == ' ' or ch == '\n' or ch == '\t' or ch == '\r') {
        self.pos += 1;
        while (self.pos < src.len) {
            const c = src[self.pos];
            if (c != ' ' and c != '\n' and c != '\t' and c != '\r') break;
            self.pos += 1;
        }
        return .{ .tag = .whitespace, .start = start, .end = self.pos };
    }

    // Line / block comments.
    if (ch == '/' and self.pos + 1 < src.len) {
        const next_ch = src[self.pos + 1];
        if (next_ch == '/') {
            self.pos += 2;
            while (self.pos < src.len and src[self.pos] != '\n') self.pos += 1;
            return .{ .tag = .line_comment, .start = start, .end = self.pos };
        }
        if (next_ch == '*') {
            self.pos += 2;
            var depth: u32 = 1;
            while (self.pos < src.len and depth > 0) {
                const c = src[self.pos];
                if (c == '/' and self.pos + 1 < src.len and src[self.pos + 1] == '*') {
                    depth += 1;
                    self.pos += 2;
                } else if (c == '*' and self.pos + 1 < src.len and src[self.pos + 1] == '/') {
                    depth -= 1;
                    self.pos += 2;
                } else {
                    self.pos += 1;
                }
            }
            // Unterminated block comment: we return it as a `.block_comment`
            // token that runs to EOF. The lexer contract (trivia round-trip)
            // still holds; a higher layer can flag the missing terminator.
            return .{ .tag = .block_comment, .start = start, .end = self.pos };
        }
    }

    // Everything else: defer to the real token scanner. `next()` starts at
    // `self.pos` and won't encounter leading trivia (we already consumed it
    // above, and the cases that called `next()` previously did the same).
    return self.next();
}

// -------------------------------------------------------------------------
// Public helpers
// -------------------------------------------------------------------------

/// Return the source text for the token at `index`.
pub fn tokenText(self: *const Lexer, index: u32) []const u8 {
    const tags = self.tokens.items(.tag);
    const starts = self.tokens.items(.start);
    const start = starts[index];

    // End is the start of the next token, or the token's own scan end
    if (index + 1 < self.tokens.len) {
        // Walk backwards from next token start to skip whitespace/comments
        const next_start = starts[index + 1];
        // For a precise end, we re-scan from start
        return self.retokenizeEnd(start, tags[index], next_start);
    }
    return self.retokenizeEnd(start, tags[index], @intCast(self.source.len));
}

/// Re-scan to find the end of a token given its start position and tag.
fn retokenizeEnd(self: *const Lexer, start: u32, tag: Tag, bound: u32) []const u8 {
    _ = tag;
    var pos = start;
    const src = self.source;

    if (pos >= src.len) return "";

    const ch = src[pos];

    // Identifier/keyword
    if (isIdentStart(ch)) {
        pos += 1;
        while (pos < bound and pos < src.len and isIdentContinue(src[pos])) pos += 1;
        return src[start..pos];
    }

    // Number
    if (isDigit(ch) or (ch == '.' and pos + 1 < src.len and isDigit(src[pos + 1]))) {
        // Hex
        if (pos + 1 < src.len and src[pos] == '0' and (src[pos + 1] == 'x' or src[pos + 1] == 'X')) {
            pos += 2;
            while (pos < src.len and isHexDigit(src[pos])) pos += 1;
            if (pos < src.len and src[pos] == '.') {
                pos += 1;
                while (pos < src.len and isHexDigit(src[pos])) pos += 1;
            }
            if (pos < src.len and (src[pos] == 'p' or src[pos] == 'P')) {
                pos += 1;
                if (pos < src.len and (src[pos] == '+' or src[pos] == '-')) pos += 1;
                while (pos < src.len and isDigit(src[pos])) pos += 1;
            }
        } else {
            while (pos < src.len and isDigit(src[pos])) pos += 1;
            if (pos < src.len and src[pos] == '.') {
                const nid = pos + 1 < src.len and isDigit(src[pos + 1]);
                const nie = pos + 1 < src.len and isIdentStart(src[pos + 1]);
                const ae = pos + 1 >= src.len;
                const nfs = pos + 1 < src.len and
                    (src[pos + 1] == 'f' or src[pos + 1] == 'h') and
                    (pos + 2 >= src.len or !isIdentContinue(src[pos + 2]));
                if (nid or ae or !nie or nfs) {
                    pos += 1;
                    while (pos < src.len and isDigit(src[pos])) pos += 1;
                }
            }
            if (pos < src.len and (src[pos] == 'e' or src[pos] == 'E')) {
                pos += 1;
                if (pos < src.len and (src[pos] == '+' or src[pos] == '-')) pos += 1;
                while (pos < src.len and isDigit(src[pos])) pos += 1;
            }
        }
        // Type suffix
        if (pos < src.len and (src[pos] == 'i' or src[pos] == 'u' or src[pos] == 'f' or src[pos] == 'h')) {
            pos += 1;
        }
        return src[start..pos];
    }

    // Operator - just return up to 3 chars matching the operator
    pos += 1;
    const nc: u8 = if (pos < src.len) src[pos] else 0;
    switch (ch) {
        '+' => if (nc == '+' or nc == '=') {
            pos += 1;
        },
        '-' => if (nc == '-' or nc == '=' or nc == '>') {
            pos += 1;
        },
        '*', '/', '%' => if (nc == '=') {
            pos += 1;
        },
        '&' => if (nc == '&' or nc == '=') {
            pos += 1;
        },
        '|' => if (nc == '|' or nc == '=') {
            pos += 1;
        },
        '^' => if (nc == '=') {
            pos += 1;
        },
        '<' => {
            if (nc == '<') {
                pos += 1;
                if (pos < src.len and src[pos] == '=') pos += 1;
            } else if (nc == '=') {
                pos += 1;
            }
        },
        '>' => {
            if (nc == '>') {
                pos += 1;
                if (pos < src.len and src[pos] == '=') pos += 1;
            } else if (nc == '=') {
                pos += 1;
            }
        },
        '=', '!' => if (nc == '=') {
            pos += 1;
        },
        else => {},
    }
    return src[start..pos];
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// Assert that `tokenizeAll(source)` produces tokens whose concatenated
/// source slices equal `source` byte-for-byte (the CST round-trip invariant).
fn expectTriviaRoundtrip(source: [:0]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try tokenizeAll(arena.allocator(), source);
    const tags = tokens.items(.tag);
    const starts = tokens.items(.start);
    const ends = tokens.items(.end);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    for (tags, 0..) |tag, i| {
        if (tag == .eof) break;
        const s = starts[i];
        const e = ends[i];
        try std.testing.expect(s <= e);
        try std.testing.expect(e <= source.len);
        try buf.appendSlice(std.testing.allocator, source[s..e]);
    }
    try std.testing.expectEqualStrings(source, buf.items);
    // Last entry must be a sentinel eof (or an error token — both terminate).
    try std.testing.expect(tags.len > 0);
    const last = tags[tags.len - 1];
    try std.testing.expect(last == .eof or last == .@"error");
}

test "lexer: tokenizeAll round-trip empty" {
    try expectTriviaRoundtrip("");
}

test "lexer: tokenizeAll round-trip line comment only" {
    try expectTriviaRoundtrip("// only a line comment");
}

test "lexer: tokenizeAll round-trip block comment only" {
    try expectTriviaRoundtrip("/* only block */");
}

test "lexer: tokenizeAll round-trip nested block comment" {
    try expectTriviaRoundtrip("/* /* nested */ still */");
}

test "lexer: tokenizeAll round-trip function no trivia" {
    try expectTriviaRoundtrip("fn f(){}");
}

test "lexer: tokenizeAll round-trip function with interior trivia" {
    try expectTriviaRoundtrip("fn f() { /* gap */ return 0; }");
}

test "lexer: tokenizeAll round-trip mixed whitespace + comments" {
    try expectTriviaRoundtrip("\t\t fn x(){\n  // indented\n}\n");
}

test "lexer: tokenizeAll round-trip CRLF" {
    try expectTriviaRoundtrip("const a = 1;\r\nconst b = 2;\r\n");
}

test "lexer: tokenizeAll round-trip UTF-8 BOM" {
    // BOM + code. The BOM bytes land inside an `.@"error"` token (since
    // 0xEF is not valid in the `.start` dispatch), but the round-trip
    // contract still holds because every byte up to the error point is
    // covered.
    const src: [:0]const u8 = "\xEF\xBB\xBFfn f(){}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try tokenizeAll(arena.allocator(), src);
    const tags = tokens.items(.tag);
    const starts = tokens.items(.start);
    const ends = tokens.items(.end);
    // Either we produce a continuous byte cover up to eof, or an error token
    // halts emission. Both are acceptable; assert no gap before the halt.
    var covered: usize = 0;
    for (tags, 0..) |tag, i| {
        if (tag == .eof or tag == .@"error") {
            try std.testing.expectEqual(covered, starts[i]);
            break;
        }
        try std.testing.expectEqual(@as(u32, @intCast(covered)), starts[i]);
        covered = ends[i];
    }
}

test "lexer: tokenizeAll round-trip multi-byte ident + emoji in comment" {
    try expectTriviaRoundtrip("fn x() { /* emoji: \xF0\x9F\x8E\x89 */ }");
}

test "lexer: tokenizeAll round-trip unterminated line comment" {
    try expectTriviaRoundtrip("// no newline");
}

test "lexer: tokenizeAll round-trip unterminated block comment" {
    // Spans to EOF as a single block_comment trivia token.
    const src: [:0]const u8 = "/* oops";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try tokenizeAll(arena.allocator(), src);
    const tags = tokens.items(.tag);
    try std.testing.expect(tags.len >= 1);
    try std.testing.expectEqual(Tag.block_comment, tags[0]);
    try expectTriviaRoundtrip(src);
}

test "lexer: tokenizeAll round-trip whitespace only" {
    try expectTriviaRoundtrip("   \n\n   ");
}

test "lexer: tokenizeAll round-trip comment adjacent to token" {
    try expectTriviaRoundtrip("fn/*x*/f(){}");
}

test "lexer: tokenizeAll emits trivia tags adjacent to real tokens" {
    const src: [:0]const u8 = "  fn /*mid*/ x() // trailing\n{}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try tokenizeAll(arena.allocator(), src);
    const tags = tokens.items(.tag);

    // Expected sequence: ws, fn, ws, block_comment, ws, ident, (, ), ws, line_comment, ws, {, }, eof
    try std.testing.expectEqual(Tag.whitespace, tags[0]);
    try std.testing.expectEqual(Tag.keyword_fn, tags[1]);
    try std.testing.expectEqual(Tag.whitespace, tags[2]);
    try std.testing.expectEqual(Tag.block_comment, tags[3]);
    try std.testing.expectEqual(Tag.whitespace, tags[4]);
    try std.testing.expectEqual(Tag.ident, tags[5]);
    try std.testing.expectEqual(Tag.l_paren, tags[6]);
    try std.testing.expectEqual(Tag.r_paren, tags[7]);
    try std.testing.expectEqual(Tag.whitespace, tags[8]);
    try std.testing.expectEqual(Tag.line_comment, tags[9]);
    try std.testing.expectEqual(Tag.whitespace, tags[10]);
    try std.testing.expectEqual(Tag.l_brace, tags[11]);
    try std.testing.expectEqual(Tag.r_brace, tags[12]);
    try std.testing.expectEqual(Tag.eof, tags[13]);
}

test "lexer: tokenize (skip_trivia) still yields no trivia tags" {
    const src: [:0]const u8 = "  fn /*m*/ x() // t\n{}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try tokenize(arena.allocator(), src);
    const tags = tokens.items(.tag);
    for (tags) |tag| {
        try std.testing.expect(!tag.isTrivia());
    }
}

test "lexer: tokenize populates end column for real tokens" {
    const src: [:0]const u8 = "fn main() {}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try tokenize(arena.allocator(), src);
    const tags = tokens.items(.tag);
    const starts = tokens.items(.start);
    const ends = tokens.items(.end);
    for (tags, 0..) |tag, i| {
        if (tag == .eof) {
            try std.testing.expectEqual(starts[i], ends[i]);
            continue;
        }
        try std.testing.expect(ends[i] > starts[i]);
        try std.testing.expect(ends[i] <= src.len);
    }
    // `fn` covers bytes 0..2 exactly.
    try std.testing.expectEqual(@as(u32, 0), starts[0]);
    try std.testing.expectEqual(@as(u32, 2), ends[0]);
    // `main` covers bytes 3..7.
    try std.testing.expectEqual(@as(u32, 3), starts[1]);
    try std.testing.expectEqual(@as(u32, 7), ends[1]);
}

test "lexer: tokenize simple" {
    const source: [:0]const u8 = "fn main() {}";
    var tokens = try tokenize(std.testing.allocator, source);
    defer tokens.deinit(std.testing.allocator);

    const tags = tokens.items(.tag);
    try std.testing.expectEqual(Tag.keyword_fn, tags[0]);
    try std.testing.expectEqual(Tag.ident, tags[1]);
    try std.testing.expectEqual(Tag.l_paren, tags[2]);
    try std.testing.expectEqual(Tag.r_paren, tags[3]);
    try std.testing.expectEqual(Tag.l_brace, tags[4]);
    try std.testing.expectEqual(Tag.r_brace, tags[5]);
    try std.testing.expectEqual(Tag.eof, tags[6]);
}

test "lexer: tokenize operators" {
    const source: [:0]const u8 = "++ -- && || << >> <= >= == != -> += -= *= /= %= &= |= ^= <<= >>=";
    var tokens = try tokenize(std.testing.allocator, source);
    defer tokens.deinit(std.testing.allocator);
    const tags = tokens.items(.tag);
    try std.testing.expectEqual(Tag.plus_plus, tags[0]);
    try std.testing.expectEqual(Tag.minus_minus, tags[1]);
    try std.testing.expectEqual(Tag.amp_amp, tags[2]);
    try std.testing.expectEqual(Tag.pipe_pipe, tags[3]);
    try std.testing.expectEqual(Tag.lt_lt, tags[4]);
    try std.testing.expectEqual(Tag.gt_gt, tags[5]);
    try std.testing.expectEqual(Tag.lt_eq, tags[6]);
    try std.testing.expectEqual(Tag.gt_eq, tags[7]);
    try std.testing.expectEqual(Tag.eq_eq, tags[8]);
    try std.testing.expectEqual(Tag.bang_eq, tags[9]);
    try std.testing.expectEqual(Tag.arrow, tags[10]);
}

test "lexer: tokenize nested block comment" {
    const source: [:0]const u8 = "/* outer /* inner */ still comment */ fn";
    var tokens = try tokenize(std.testing.allocator, source);
    defer tokens.deinit(std.testing.allocator);
    const tags = tokens.items(.tag);
    try std.testing.expectEqual(Tag.keyword_fn, tags[0]);
    try std.testing.expectEqual(Tag.eof, tags[1]);
}

test "lexer: tokenize keywords" {
    const source: [:0]const u8 = "const var let fn struct alias override return if else for while loop break continue discard switch case default";
    var tokens = try tokenize(std.testing.allocator, source);
    defer tokens.deinit(std.testing.allocator);
    const tags = tokens.items(.tag);
    try std.testing.expectEqual(Tag.keyword_const, tags[0]);
    try std.testing.expectEqual(Tag.keyword_var, tags[1]);
    try std.testing.expectEqual(Tag.keyword_let, tags[2]);
    try std.testing.expectEqual(Tag.keyword_fn, tags[3]);
}

test "lexer: fuzz no crash" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) !void {
            @disableInstrumentation();
            var buf: [256]u8 = undefined;
            const len = smith.slice(buf[0 .. buf.len - 1]);
            buf[len] = 0;
            const source: [:0]const u8 = buf[0..len :0];
            var tokens = tokenize(std.testing.allocator, source) catch return;
            defer tokens.deinit(std.testing.allocator);
            // Verify all token starts are within source bounds
            for (tokens.items(.start)) |start| {
                try std.testing.expect(start <= source.len);
            }
            // Last token must be eof or error
            const tags = tokens.items(.tag);
            if (tags.len > 0) {
                const last = tags[tags.len - 1];
                try std.testing.expect(last == .eof or last == .@"error" or last == .reserved_ident);
            }
        }
    }.testOne, .{
        .corpus = &.{
            "fn main() {}",
            "/* nested /* comment */ */",
            "var<storage, read_write> x: f32 = 1.0;",
            "++--&&||<<>>",
        },
    });
}

test "lexer: tokenize numbers" {
    const source: [:0]const u8 = "42 3.14 0xFF 1e10 0.5f 1u 2i";
    var tokens = try tokenize(std.testing.allocator, source);
    defer tokens.deinit(std.testing.allocator);
    const tags = tokens.items(.tag);
    try std.testing.expectEqual(Tag.int_literal, tags[0]);
    try std.testing.expectEqual(Tag.float_literal, tags[1]);
    try std.testing.expectEqual(Tag.int_literal, tags[2]); // 0xFF
    try std.testing.expectEqual(Tag.float_literal, tags[3]); // 1e10
    try std.testing.expectEqual(Tag.float_literal, tags[4]); // 0.5f
    try std.testing.expectEqual(Tag.int_literal, tags[5]); // 1u
    try std.testing.expectEqual(Tag.int_literal, tags[6]); // 2i
}

// =========================================================================
// Lexer unit tests
// =========================================================================

/// Tokenize `input`, assert the first token has the given tag, free memory.
fn expectToken(input: [:0]const u8, expected: Tag) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try tokenize(arena.allocator(), input);
    const tags = tokens.items(.tag);
    try std.testing.expect(tags.len > 0);
    try std.testing.expectEqual(expected, tags[0]);
}

/// Tokenize `input`, assert the first token has the given tag AND the given
/// source text, free memory.
fn expectTokenValue(input: [:0]const u8, expected_tag: Tag, expected_value: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try tokenize(arena.allocator(), input);
    const tags = tokens.items(.tag);
    const starts = tokens.items(.start);
    try std.testing.expect(tags.len > 0);
    try std.testing.expectEqual(expected_tag, tags[0]);
    // Token text runs from starts[0] up to (but not including) the start of
    // the next token.  The next token is always present because tokenize()
    // appends at least an eof sentinel.
    const tok_start = starts[0];
    const raw_end: u32 = if (tags.len > 1) starts[1] else @as(u32, @intCast(input.len));
    // Strip trailing whitespace that belongs to the gap between tokens.
    var tok_end = raw_end;
    while (tok_end > tok_start and
        (input[tok_end - 1] == ' ' or
            input[tok_end - 1] == '\n' or
            input[tok_end - 1] == '\t' or
            input[tok_end - 1] == '\r'))
    {
        tok_end -= 1;
    }
    const actual = input[tok_start..tok_end];
    try std.testing.expectEqualStrings(expected_value, actual);
}

/// Tokenize `input` and assert that the full sequence of tags (including the
/// trailing eof) matches `expected`.
fn expectTokenSequence(input: [:0]const u8, expected: []const Tag) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try tokenize(arena.allocator(), input);
    const tags = tokens.items(.tag);
    try std.testing.expectEqual(expected.len, tags.len);
    for (expected, 0..) |exp, i| {
        try std.testing.expectEqual(exp, tags[i]);
    }
}

/// Tokenize `input` and assert that the first token is an error.
fn expectError(input: [:0]const u8) !void {
    try expectToken(input, .@"error");
}

// -------------------------------------------------------------------------
// Keyword tests
// -------------------------------------------------------------------------

test "lexer: keywords" {
    try expectToken("alias", .keyword_alias);
    try expectToken("break", .keyword_break);
    try expectToken("case", .keyword_case);
    try expectToken("const", .keyword_const);
    try expectToken("const_assert", .keyword_const_assert);
    try expectToken("continue", .keyword_continue);
    try expectToken("continuing", .keyword_continuing);
    try expectToken("default", .keyword_default);
    try expectToken("diagnostic", .keyword_diagnostic);
    try expectToken("discard", .keyword_discard);
    try expectToken("else", .keyword_else);
    try expectToken("enable", .keyword_enable);
    try expectToken("fn", .keyword_fn);
    try expectToken("for", .keyword_for);
    try expectToken("if", .keyword_if);
    try expectToken("let", .keyword_let);
    try expectToken("loop", .keyword_loop);
    try expectToken("override", .keyword_override);
    try expectToken("requires", .keyword_requires);
    try expectToken("return", .keyword_return);
    try expectToken("struct", .keyword_struct);
    try expectToken("switch", .keyword_switch);
    try expectToken("var", .keyword_var);
    try expectToken("while", .keyword_while);
}

// -------------------------------------------------------------------------
// Boolean literal tests
// -------------------------------------------------------------------------

test "lexer: boolean literals" {
    try expectToken("true", .true_literal);
    try expectToken("false", .false_literal);
}

// -------------------------------------------------------------------------
// Identifier tests
// -------------------------------------------------------------------------

test "lexer: identifiers" {
    try expectTokenValue("foo", .ident, "foo");
    try expectTokenValue("_bar", .ident, "_bar");
    try expectTokenValue("camelCase", .ident, "camelCase");
    try expectTokenValue("snake_case", .ident, "snake_case");
    try expectTokenValue("UPPER_CASE", .ident, "UPPER_CASE");
    try expectTokenValue("a1", .ident, "a1");
    try expectTokenValue("vec3f", .ident, "vec3f");
    try expectTokenValue("mat4x4f", .ident, "mat4x4f");
    try expectTokenValue("i32", .ident, "i32");
    try expectTokenValue("Position", .ident, "Position");
}

test "lexer: single underscore is underscore token" {
    try expectToken("_", .underscore);
}

test "lexer: double underscore prefix is reserved_ident" {
    try expectToken("__reserved", .reserved_ident);
    try expectToken("__foo", .reserved_ident);
}

test "lexer: reserved words produce reserved_ident" {
    // Sample of WGSL reserved words (see reserved_words map)
    try expectToken("NULL", .reserved_ident);
    try expectToken("Self", .reserved_ident);
    try expectToken("abstract", .reserved_ident);
    try expectToken("async", .reserved_ident);
    try expectToken("await", .reserved_ident);
    try expectToken("class", .reserved_ident);
    try expectToken("enum", .reserved_ident);
    try expectToken("import", .reserved_ident);
    try expectToken("interface", .reserved_ident);
    try expectToken("module", .reserved_ident);
    try expectToken("namespace", .reserved_ident);
    try expectToken("new", .reserved_ident);
    try expectToken("null", .reserved_ident);
    try expectToken("public", .reserved_ident);
    try expectToken("static", .reserved_ident);
    try expectToken("super", .reserved_ident);
    try expectToken("this", .reserved_ident);
    try expectToken("throw", .reserved_ident);
    try expectToken("try", .reserved_ident);
    try expectToken("typeof", .reserved_ident);
    try expectToken("yield", .reserved_ident);
}

// -------------------------------------------------------------------------
// Decimal integer literal tests
// -------------------------------------------------------------------------

test "lexer: decimal integers" {
    try expectTokenValue("0", .int_literal, "0");
    try expectTokenValue("1", .int_literal, "1");
    try expectTokenValue("42", .int_literal, "42");
    try expectTokenValue("123456789", .int_literal, "123456789");
    try expectTokenValue("0i", .int_literal, "0i");
    try expectTokenValue("42i", .int_literal, "42i");
    try expectTokenValue("0u", .int_literal, "0u");
    try expectTokenValue("42u", .int_literal, "42u");
}

test "lexer: leading zeros in integers" {
    try expectTokenValue("00", .int_literal, "00");
    try expectTokenValue("007", .int_literal, "007");
}

// -------------------------------------------------------------------------
// Hex integer literal tests
// -------------------------------------------------------------------------

test "lexer: hex integers" {
    try expectTokenValue("0x0", .int_literal, "0x0");
    try expectTokenValue("0x1", .int_literal, "0x1");
    try expectTokenValue("0xABCDEF", .int_literal, "0xABCDEF");
    try expectTokenValue("0xabcdef", .int_literal, "0xabcdef");
    try expectTokenValue("0X1234", .int_literal, "0X1234");
    try expectTokenValue("0xFFi", .int_literal, "0xFFi");
    try expectTokenValue("0xFFu", .int_literal, "0xFFu");
    try expectTokenValue("0x0", .int_literal, "0x0");
    try expectTokenValue("0X0", .int_literal, "0X0");
}

// -------------------------------------------------------------------------
// Decimal float literal tests
// -------------------------------------------------------------------------

test "lexer: decimal floats" {
    try expectTokenValue("0.0", .float_literal, "0.0");
    try expectTokenValue("1.0", .float_literal, "1.0");
    try expectTokenValue("3.14159", .float_literal, "3.14159");
    try expectTokenValue(".5", .float_literal, ".5");
    try expectTokenValue("0.", .float_literal, "0.");
    try expectTokenValue("1e10", .float_literal, "1e10");
    try expectTokenValue("1E10", .float_literal, "1E10");
    try expectTokenValue("1e+10", .float_literal, "1e+10");
    try expectTokenValue("1e-10", .float_literal, "1e-10");
    try expectTokenValue("1.5e10", .float_literal, "1.5e10");
    try expectTokenValue("0.5f", .float_literal, "0.5f");
    try expectTokenValue("0.5h", .float_literal, "0.5h");
    try expectTokenValue("1.0f", .float_literal, "1.0f");
    try expectTokenValue("1f", .float_literal, "1f");
    try expectTokenValue("1e0", .float_literal, "1e0");
    try expectTokenValue("1E0", .float_literal, "1E0");
}

// -------------------------------------------------------------------------
// Hex float literal tests
// -------------------------------------------------------------------------

test "lexer: hex floats" {
    try expectTokenValue("0x1p0", .float_literal, "0x1p0");
    try expectTokenValue("0x1.0p0", .float_literal, "0x1.0p0");
    try expectTokenValue("0x1P10", .float_literal, "0x1P10");
    try expectTokenValue("0x1.ABCp+10", .float_literal, "0x1.ABCp+10");
    try expectTokenValue("0x1.0p-10", .float_literal, "0x1.0p-10");
    try expectTokenValue("0x1p0f", .float_literal, "0x1p0f");
    try expectTokenValue("0x1p0h", .float_literal, "0x1p0h");
}

// -------------------------------------------------------------------------
// Single-character operator tests
// -------------------------------------------------------------------------

test "lexer: single-char operators" {
    try expectToken("+", .plus);
    try expectToken("-", .minus);
    try expectToken("*", .star);
    try expectToken("/", .slash);
    try expectToken("%", .percent);
    try expectToken("&", .amp);
    try expectToken("|", .pipe);
    try expectToken("^", .caret);
    try expectToken("~", .tilde);
    try expectToken("!", .bang);
    try expectToken("<", .lt);
    try expectToken(">", .gt);
    try expectToken("=", .eq);
    try expectToken(".", .dot);
    try expectToken("@", .at);
}

test "lexer: single-char operators at end of input" {
    // Operators with no following character should still be correctly identified
    try expectToken("+", .plus);
    try expectToken("-", .minus);
    try expectToken("*", .star);
    try expectToken("/", .slash);
    try expectToken("%", .percent);
    try expectToken("&", .amp);
    try expectToken("|", .pipe);
    try expectToken("^", .caret);
    try expectToken("<", .lt);
    try expectToken(">", .gt);
    try expectToken("=", .eq);
    try expectToken("!", .bang);
}

// -------------------------------------------------------------------------
// Multi-character operator tests
// -------------------------------------------------------------------------

test "lexer: multi-char operators" {
    try expectToken("++", .plus_plus);
    try expectToken("--", .minus_minus);
    try expectToken("&&", .amp_amp);
    try expectToken("||", .pipe_pipe);
    try expectToken("<<", .lt_lt);
    try expectToken(">>", .gt_gt);
    try expectToken("<=", .lt_eq);
    try expectToken(">=", .gt_eq);
    try expectToken("==", .eq_eq);
    try expectToken("!=", .bang_eq);
    try expectToken("->", .arrow);
}

// -------------------------------------------------------------------------
// Assignment operator tests
// -------------------------------------------------------------------------

test "lexer: assignment operators" {
    try expectToken("+=", .plus_eq);
    try expectToken("-=", .minus_eq);
    try expectToken("*=", .star_eq);
    try expectToken("/=", .slash_eq);
    try expectToken("%=", .percent_eq);
    try expectToken("&=", .amp_eq);
    try expectToken("|=", .pipe_eq);
    try expectToken("^=", .caret_eq);
    try expectToken("<<=", .lt_lt_eq);
    try expectToken(">>=", .gt_gt_eq);
}

// -------------------------------------------------------------------------
// Delimiter tests
// -------------------------------------------------------------------------

test "lexer: delimiters" {
    try expectToken("(", .l_paren);
    try expectToken(")", .r_paren);
    try expectToken("{", .l_brace);
    try expectToken("}", .r_brace);
    try expectToken("[", .l_bracket);
    try expectToken("]", .r_bracket);
    try expectToken(";", .semicolon);
    try expectToken(":", .colon);
    try expectToken(",", .comma);
}

// -------------------------------------------------------------------------
// Comment tests
// -------------------------------------------------------------------------

test "lexer: line comment skipped" {
    // The token after a line comment is what we see first
    try expectToken("// comment\nfoo", .ident);
    try expectTokenValue("// comment\nbar", .ident, "bar");
}

test "lexer: line comment at end of file produces eof" {
    try expectTokenSequence("foo // comment", &.{ .ident, .eof });
}

test "lexer: block comment skipped" {
    try expectToken("/* comment */ foo", .ident);
    try expectTokenValue("/* comment */ bar", .ident, "bar");
}

test "lexer: multi-line block comment skipped" {
    try expectTokenValue("/* line1\nline2\nline3 */ baz", .ident, "baz");
}

test "lexer: nested block comments" {
    try expectTokenValue("/* outer /* inner */ still outer */ foo", .ident, "foo");
    try expectTokenValue("/* a /* b /* c */ b */ a */ x", .ident, "x");
}

// -------------------------------------------------------------------------
// Whitespace tests
// -------------------------------------------------------------------------

test "lexer: leading whitespace skipped" {
    try expectTokenValue("  \t\n\r  foo", .ident, "foo");
    try expectTokenValue("\n\n\nbar", .ident, "bar");
}

// -------------------------------------------------------------------------
// Edge cases
// -------------------------------------------------------------------------

test "lexer: empty input produces eof" {
    try expectTokenSequence("", &.{.eof});
}

test "lexer: whitespace-only input produces eof" {
    try expectTokenSequence("   \t\n\r\n   ", &.{.eof});
}

test "lexer: comment-only input produces eof" {
    try expectTokenSequence("// just a comment", &.{.eof});
}

test "lexer: unknown characters produce errors" {
    try expectError("$");
    try expectError("#");
    try expectError("`");
    try expectError("\\");
    try expectError("\"");
    try expectError("'");
    try expectError("?");
}

// -------------------------------------------------------------------------
// Token sequence tests (full shader snippets)
// -------------------------------------------------------------------------

test "lexer: function returning vec4f" {
    const input: [:0]const u8 = "fn main() -> vec4f { return vec4f(1.0); }";
    try expectTokenSequence(input, &.{
        .keyword_fn,
        .ident, // main
        .l_paren,
        .r_paren,
        .arrow,
        .ident, // vec4f
        .l_brace,
        .keyword_return,
        .ident, // vec4f
        .l_paren,
        .float_literal, // 1.0
        .r_paren,
        .semicolon,
        .r_brace,
        .eof,
    });
}

test "lexer: struct declaration" {
    const input: [:0]const u8 =
        \\struct VertexOutput {
        \\    @builtin(position) pos: vec4f,
        \\    @location(0) color: vec3f,
        \\}
    ;
    try expectTokenSequence(input, &.{
        .keyword_struct,
        .ident, // VertexOutput
        .l_brace,
        .at,
        .ident, // builtin
        .l_paren,
        .ident, // position
        .r_paren,
        .ident, // pos
        .colon,
        .ident, // vec4f
        .comma,
        .at,
        .ident, // location
        .l_paren,
        .int_literal, // 0
        .r_paren,
        .ident, // color
        .colon,
        .ident, // vec3f
        .comma,
        .r_brace,
        .eof,
    });
}

test "lexer: var declaration with group and binding" {
    const input: [:0]const u8 = "@group(0) @binding(1) var<uniform> uniforms: Uniforms;";
    try expectTokenSequence(input, &.{
        .at,
        .ident, // group
        .l_paren,
        .int_literal, // 0
        .r_paren,
        .at,
        .ident, // binding
        .l_paren,
        .int_literal, // 1
        .r_paren,
        .keyword_var,
        .lt,
        .ident, // uniform
        .gt,
        .ident, // uniforms
        .colon,
        .ident, // Uniforms
        .semicolon,
        .eof,
    });
}

test "lexer: compute shader header" {
    const input: [:0]const u8 =
        \\@compute @workgroup_size(64, 1, 1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
    ;
    try expectTokenSequence(input, &.{
        .at,
        .ident, // compute
        .at,
        .ident, // workgroup_size
        .l_paren,
        .int_literal, // 64
        .comma,
        .int_literal, // 1
        .comma,
        .int_literal, // 1
        .r_paren,
        .keyword_fn,
        .ident, // main
        .l_paren,
        .at,
        .ident, // builtin
        .l_paren,
        .ident, // global_invocation_id
        .r_paren,
        .ident, // id
        .colon,
        .ident, // vec3u
        .r_paren,
        .l_brace,
        .eof,
    });
}

test "lexer: let declaration" {
    const input: [:0]const u8 = "let x = 1;";
    try expectTokenSequence(input, &.{
        .keyword_let,
        .ident, // x
        .eq,
        .int_literal, // 1
        .semicolon,
        .eof,
    });
}

test "lexer: member access chain" {
    const input: [:0]const u8 = "a.b.c.d";
    try expectTokenSequence(input, &.{
        .ident, // a
        .dot,
        .ident, // b
        .dot,
        .ident, // c
        .dot,
        .ident, // d
        .eof,
    });
}

test "lexer: swizzle access" {
    const input: [:0]const u8 = "pos.xyz";
    try expectTokenSequence(input, &.{
        .ident, // pos
        .dot,
        .ident, // xyz
        .eof,
    });
}

test "lexer: number then member access is int dot ident" {
    // "v.x" — identifier, dot, identifier (not a float)
    const input: [:0]const u8 = "v.x";
    try expectTokenSequence(input, &.{
        .ident,
        .dot,
        .ident,
        .eof,
    });
}

test "lexer: double underscore prefix produces reserved_ident and continues" {
    const input: [:0]const u8 = "__invalid";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try tokenize(arena.allocator(), input);
    const tags = tokens.items(.tag);
    try std.testing.expect(tags.len >= 2);
    try std.testing.expectEqual(Tag.reserved_ident, tags[0]);
    try std.testing.expectEqual(Tag.eof, tags[1]);
}

// -------------------------------------------------------------------------
// Tag.symbol() helper test
// -------------------------------------------------------------------------

test "lexer: Tag.symbol returns readable text" {
    try std.testing.expectEqualStrings("+", Tag.plus.symbol());
    try std.testing.expectEqualStrings("-", Tag.minus.symbol());
    try std.testing.expectEqualStrings("*", Tag.star.symbol());
    try std.testing.expectEqualStrings("/", Tag.slash.symbol());
    try std.testing.expectEqualStrings("%", Tag.percent.symbol());
    try std.testing.expectEqualStrings("&", Tag.amp.symbol());
    try std.testing.expectEqualStrings("|", Tag.pipe.symbol());
    try std.testing.expectEqualStrings("^", Tag.caret.symbol());
    try std.testing.expectEqualStrings("~", Tag.tilde.symbol());
    try std.testing.expectEqualStrings("!", Tag.bang.symbol());
    try std.testing.expectEqualStrings("<", Tag.lt.symbol());
    try std.testing.expectEqualStrings(">", Tag.gt.symbol());
    try std.testing.expectEqualStrings("=", Tag.eq.symbol());
    try std.testing.expectEqualStrings(".", Tag.dot.symbol());
    try std.testing.expectEqualStrings("@", Tag.at.symbol());
    try std.testing.expectEqualStrings("++", Tag.plus_plus.symbol());
    try std.testing.expectEqualStrings("--", Tag.minus_minus.symbol());
    try std.testing.expectEqualStrings("&&", Tag.amp_amp.symbol());
    try std.testing.expectEqualStrings("||", Tag.pipe_pipe.symbol());
    try std.testing.expectEqualStrings("<<", Tag.lt_lt.symbol());
    try std.testing.expectEqualStrings(">>", Tag.gt_gt.symbol());
    try std.testing.expectEqualStrings("<=", Tag.lt_eq.symbol());
    try std.testing.expectEqualStrings(">=", Tag.gt_eq.symbol());
    try std.testing.expectEqualStrings("==", Tag.eq_eq.symbol());
    try std.testing.expectEqualStrings("!=", Tag.bang_eq.symbol());
    try std.testing.expectEqualStrings("->", Tag.arrow.symbol());
    try std.testing.expectEqualStrings("+=", Tag.plus_eq.symbol());
    try std.testing.expectEqualStrings("-=", Tag.minus_eq.symbol());
    try std.testing.expectEqualStrings("*=", Tag.star_eq.symbol());
    try std.testing.expectEqualStrings("/=", Tag.slash_eq.symbol());
    try std.testing.expectEqualStrings("%=", Tag.percent_eq.symbol());
    try std.testing.expectEqualStrings("&=", Tag.amp_eq.symbol());
    try std.testing.expectEqualStrings("|=", Tag.pipe_eq.symbol());
    try std.testing.expectEqualStrings("^=", Tag.caret_eq.symbol());
    try std.testing.expectEqualStrings("<<=", Tag.lt_lt_eq.symbol());
    try std.testing.expectEqualStrings(">>=", Tag.gt_gt_eq.symbol());
    try std.testing.expectEqualStrings("(", Tag.l_paren.symbol());
    try std.testing.expectEqualStrings(")", Tag.r_paren.symbol());
    try std.testing.expectEqualStrings("{", Tag.l_brace.symbol());
    try std.testing.expectEqualStrings("}", Tag.r_brace.symbol());
    try std.testing.expectEqualStrings("[", Tag.l_bracket.symbol());
    try std.testing.expectEqualStrings("]", Tag.r_bracket.symbol());
    try std.testing.expectEqualStrings(";", Tag.semicolon.symbol());
    try std.testing.expectEqualStrings(":", Tag.colon.symbol());
    try std.testing.expectEqualStrings(",", Tag.comma.symbol());
    try std.testing.expectEqualStrings("_", Tag.underscore.symbol());
}

// -------------------------------------------------------------------------
// isIdentStart / isIdentContinue / isDigit / isHexDigit helper tests
// -------------------------------------------------------------------------

// -------------------------------------------------------------------------
// Float suffix after decimal point (1.f, 1.h)
// -------------------------------------------------------------------------

test "lexer: float suffix after decimal point" {
    try expectTokenValue("1.f", .float_literal, "1.f");
    try expectTokenValue("0.f", .float_literal, "0.f");
    try expectTokenValue("1.h", .float_literal, "1.h");
    try expectTokenValue("0.h", .float_literal, "0.h");
    try expectTokenValue("123.f", .float_literal, "123.f");
    try expectTokenValue("42.h", .float_literal, "42.h");
}

test "lexer: float suffix does not capture multi-char ident" {
    // 1.foo should be int(1), dot, ident(foo) — NOT a float
    try expectTokenSequence("1.foo", &.{ .int_literal, .dot, .ident, .eof });
    // 1.fi should be int(1), dot, ident(fi)
    try expectTokenSequence("1.fi", &.{ .int_literal, .dot, .ident, .eof });
    // 1.float should be int(1), dot, ident(float)
    try expectTokenSequence("1.float", &.{ .int_literal, .dot, .ident, .eof });
}

test "lexer: float suffix in expressions" {
    try expectTokenSequence("abs(1.f)", &.{ .ident, .l_paren, .float_literal, .r_paren, .eof });
    try expectTokenSequence("vec4<f32>(1.f)", &.{ .ident, .lt, .ident, .gt, .l_paren, .float_literal, .r_paren, .eof });
}

test "lexer: isIdentStart accepts letters and underscore" {
    try std.testing.expect(isIdentStart('a'));
    try std.testing.expect(isIdentStart('z'));
    try std.testing.expect(isIdentStart('A'));
    try std.testing.expect(isIdentStart('Z'));
    try std.testing.expect(isIdentStart('_'));
}

test "lexer: isIdentStart rejects digits and operators" {
    try std.testing.expect(!isIdentStart('0'));
    try std.testing.expect(!isIdentStart('9'));
    try std.testing.expect(!isIdentStart('+'));
    try std.testing.expect(!isIdentStart('-'));
    try std.testing.expect(!isIdentStart(' '));
    try std.testing.expect(!isIdentStart('@'));
    try std.testing.expect(!isIdentStart(0x80)); // non-ASCII
}

test "lexer: isIdentContinue accepts letters, digits, and underscore" {
    try std.testing.expect(isIdentContinue('a'));
    try std.testing.expect(isIdentContinue('z'));
    try std.testing.expect(isIdentContinue('A'));
    try std.testing.expect(isIdentContinue('Z'));
    try std.testing.expect(isIdentContinue('0'));
    try std.testing.expect(isIdentContinue('9'));
    try std.testing.expect(isIdentContinue('_'));
}

test "lexer: isIdentContinue rejects operators and non-ASCII" {
    try std.testing.expect(!isIdentContinue('+'));
    try std.testing.expect(!isIdentContinue('-'));
    try std.testing.expect(!isIdentContinue(' '));
    try std.testing.expect(!isIdentContinue('@'));
    try std.testing.expect(!isIdentContinue('.'));
    try std.testing.expect(!isIdentContinue(0x80)); // non-ASCII
}

test "lexer: isDigit" {
    for ('0'..('9' + 1)) |c| {
        try std.testing.expect(isDigit(@intCast(c)));
    }
    try std.testing.expect(!isDigit('a'));
    try std.testing.expect(!isDigit(' '));
    try std.testing.expect(!isDigit('/'));
}

test "lexer: isHexDigit" {
    for ('0'..('9' + 1)) |c| {
        try std.testing.expect(isHexDigit(@intCast(c)));
    }
    for ('a'..('f' + 1)) |c| {
        try std.testing.expect(isHexDigit(@intCast(c)));
    }
    for ('A'..('F' + 1)) |c| {
        try std.testing.expect(isHexDigit(@intCast(c)));
    }
    try std.testing.expect(!isHexDigit('g'));
    try std.testing.expect(!isHexDigit('G'));
    try std.testing.expect(!isHexDigit(' '));
    try std.testing.expect(!isHexDigit('x'));
}

// -------------------------------------------------------------------------
// State machine edge-case tests
// -------------------------------------------------------------------------

test "lexer: sentinel boundary — input ending mid-hex-prefix" {
    try expectTokenSequence("0x", &.{ .int_literal, .eof });
}

test "lexer: sentinel boundary — input ending after decimal dot" {
    try expectTokenSequence("1.", &.{ .float_literal, .eof });
}

test "lexer: sentinel boundary — unterminated block comment" {
    try expectTokenSequence("/*", &.{.eof});
}

test "lexer: sentinel boundary — unterminated nested block comment" {
    try expectTokenSequence("/* /* */", &.{.eof});
}

test "lexer: operator disambiguation at EOF — single lt" {
    try expectTokenSequence("<", &.{ .lt, .eof });
}

test "lexer: operator disambiguation at EOF — single gt" {
    try expectTokenSequence(">", &.{ .gt, .eof });
}

test "lexer: operator disambiguation at EOF — single eq" {
    try expectTokenSequence("=", &.{ .eq, .eof });
}

test "lexer: operator disambiguation at EOF — single bang" {
    try expectTokenSequence("!", &.{ .bang, .eof });
}

test "lexer: operator disambiguation at EOF — single slash" {
    try expectTokenSequence("/", &.{ .slash, .eof });
}

test "lexer: number-dot-ident is int dot ident" {
    try expectTokenSequence("1.xyz", &.{ .int_literal, .dot, .ident, .eof });
}

test "lexer: number-dot-float-suffix 1.f is float" {
    try expectTokenSequence("1.f", &.{ .float_literal, .eof });
}

test "lexer: number-dot-float-suffix 1.h is float" {
    try expectTokenSequence("1.h", &.{ .float_literal, .eof });
}

test "lexer: number-dot-ident-like 1.foo is int dot ident" {
    try expectTokenSequence("1.foo", &.{ .int_literal, .dot, .ident, .eof });
}

test "lexer: deeply nested block comments" {
    try expectTokenSequence("/* /* /* deep */ */ */ fn", &.{ .keyword_fn, .eof });
}

test "lexer: empty block comment" {
    try expectTokenSequence("/**/fn", &.{ .keyword_fn, .eof });
}

test "lexer: three-char operator at EOF — left shift assign" {
    try expectTokenSequence("<<=", &.{ .lt_lt_eq, .eof });
}

test "lexer: three-char operator at EOF — right shift assign" {
    try expectTokenSequence(">>=", &.{ .gt_gt_eq, .eof });
}

test "lexer: slash disambiguation — div vs divassign vs comments" {
    try expectTokenSequence("/ /= // comment\nfn /* block */ +", &.{
        .slash,
        .slash_eq,
        .keyword_fn,
        .plus,
        .eof,
    });
}

test "lexer: hex float with exponent" {
    try expectTokenSequence("0x1.5p+3", &.{ .float_literal, .eof });
}

test "lexer: hex float with no fractional digits" {
    try expectTokenSequence("0x1.p2", &.{ .float_literal, .eof });
}

test "lexer: decimal float with exponent and sign" {
    try expectTokenSequence("1.5e-10", &.{ .float_literal, .eof });
}

test "lexer: zero is int literal" {
    try expectTokenSequence("0", &.{ .int_literal, .eof });
}

test "lexer: zero with suffix" {
    try expectTokenSequence("0u", &.{ .int_literal, .eof });
    try expectTokenSequence("0i", &.{ .int_literal, .eof });
    try expectTokenSequence("0f", &.{ .float_literal, .eof });
    try expectTokenSequence("0h", &.{ .float_literal, .eof });
}

test "lexer: leading dot float" {
    try expectTokenSequence(".5", &.{ .float_literal, .eof });
    try expectTokenSequence(".123", &.{ .float_literal, .eof });
}

test "lexer: dot not followed by digit is dot operator" {
    try expectTokenSequence(".x", &.{ .dot, .ident, .eof });
}
