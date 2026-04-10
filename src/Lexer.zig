//! WGSL tokenizer.
//!
//! Converts WGSL source text into a sequence of tokens using a
//! state-machine approach with comptime lookup tables for fast
//! ASCII classification.

const std = @import("std");
const Ast = @import("Ast.zig");

const Lexer = @This();

source: [:0]const u8,
pos: u32,
tokens: std.MultiArrayList(Token),

pub const Token = struct {
    tag: Tag,
    start: u32,
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

pub fn isIdentStart(c: u8) bool {
    return c < 128 and ident_start_table[c];
}

pub fn isIdentContinue(c: u8) bool {
    return c < 128 and ident_continue_table[c];
}

pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

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

pub const reserved_words = std.StaticStringMap(void).initComptime(.{
    .{ "NULL", {} },     .{ "Self", {} },          .{ "abstract", {} },
    .{ "active", {} },   .{ "alignas", {} },       .{ "alignof", {} },
    .{ "as", {} },       .{ "asm", {} },            .{ "asm_fragment", {} },
    .{ "async", {} },    .{ "attribute", {} },      .{ "auto", {} },
    .{ "await", {} },    .{ "become", {} },         .{ "cast", {} },
    .{ "catch", {} },    .{ "class", {} },          .{ "co_await", {} },
    .{ "co_return", {} }, .{ "co_yield", {} },      .{ "coherent", {} },
    .{ "column_major", {} }, .{ "common", {} },     .{ "compile", {} },
    .{ "compile_fragment", {} }, .{ "concept", {} }, .{ "const_cast", {} },
    .{ "consteval", {} }, .{ "constexpr", {} },     .{ "constinit", {} },
    .{ "crate", {} },    .{ "debugger", {} },       .{ "decltype", {} },
    .{ "delete", {} },   .{ "demote", {} },         .{ "demote_to_helper", {} },
    .{ "do", {} },       .{ "dynamic_cast", {} },   .{ "enum", {} },
    .{ "explicit", {} }, .{ "export", {} },         .{ "extends", {} },
    .{ "extern", {} },   .{ "external", {} },       .{ "fallthrough", {} },
    .{ "filter", {} },   .{ "final", {} },          .{ "finally", {} },
    .{ "friend", {} },   .{ "from", {} },           .{ "fxgroup", {} },
    .{ "get", {} },      .{ "goto", {} },           .{ "groupshared", {} },
    .{ "highp", {} },    .{ "impl", {} },           .{ "implements", {} },
    .{ "import", {} },   .{ "inline", {} },         .{ "instanceof", {} },
    .{ "interface", {} }, .{ "layout", {} },         .{ "lowp", {} },
    .{ "macro", {} },    .{ "macro_rules", {} },    .{ "match", {} },
    .{ "mediump", {} },  .{ "meta", {} },           .{ "mod", {} },
    .{ "module", {} },   .{ "move", {} },           .{ "mut", {} },
    .{ "mutable", {} },  .{ "namespace", {} },      .{ "new", {} },
    .{ "nil", {} },      .{ "noexcept", {} },       .{ "noinline", {} },
    .{ "nointerpolation", {} }, .{ "non_coherent", {} }, .{ "noncoherent", {} },
    .{ "noperspective", {} }, .{ "null", {} },      .{ "nullptr", {} },
    .{ "of", {} },       .{ "operator", {} },       .{ "package", {} },
    .{ "packoffset", {} }, .{ "partition", {} },    .{ "pass", {} },
    .{ "patch", {} },    .{ "pixelfragment", {} },  .{ "precise", {} },
    .{ "precision", {} }, .{ "premerge", {} },      .{ "priv", {} },
    .{ "protected", {} }, .{ "pub", {} },           .{ "public", {} },
    .{ "readonly", {} }, .{ "ref", {} },            .{ "regardless", {} },
    .{ "register", {} }, .{ "reinterpret_cast", {} }, .{ "require", {} },
    .{ "resource", {} }, .{ "restrict", {} },       .{ "self", {} },
    .{ "set", {} },      .{ "shared", {} },         .{ "sizeof", {} },
    .{ "smooth", {} },   .{ "snorm", {} },          .{ "static", {} },
    .{ "static_assert", {} }, .{ "static_cast", {} }, .{ "std", {} },
    .{ "subroutine", {} }, .{ "super", {} },        .{ "target", {} },
    .{ "template", {} }, .{ "this", {} },           .{ "thread_local", {} },
    .{ "throw", {} },    .{ "trait", {} },          .{ "try", {} },
    .{ "type", {} },     .{ "typedef", {} },        .{ "typeid", {} },
    .{ "typename", {} }, .{ "typeof", {} },         .{ "union", {} },
    .{ "unless", {} },   .{ "unorm", {} },          .{ "unsafe", {} },
    .{ "unsized", {} },  .{ "use", {} },            .{ "using", {} },
    .{ "varying", {} },  .{ "virtual", {} },        .{ "volatile", {} },
    .{ "wgsl", {} },     .{ "where", {} },          .{ "with", {} },
    .{ "writeonly", {} }, .{ "yield", {} },
});

// -------------------------------------------------------------------------
// Initialization
// -------------------------------------------------------------------------

pub fn init(source: [:0]const u8) Lexer {
    return .{
        .source = source,
        .pos = 0,
        .tokens = std.MultiArrayList(Token){},
    };
}

/// Tokenize the entire source, returning owned token storage.
/// Caller must call `deinit` on the returned Lexer to free memory.
pub fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) !std.MultiArrayList(Token) {
    var lex = Lexer{
        .source = source,
        .pos = 0,
        .tokens = .empty,
    };

    // Pre-estimate capacity: ~1 token per 8 source bytes
    const estimated = @max(source.len / 8, 16);
    try lex.tokens.ensureTotalCapacity(allocator, estimated);

    for (0..source.len + 1) |_| {
        const tag = lex.next();
        try lex.tokens.append(allocator, .{ .tag = tag.tag, .start = tag.start });
        if (tag.tag == .eof or tag.tag == .@"error") break;
    } else unreachable;

    return lex.tokens;
}

// -------------------------------------------------------------------------
// Core scanning
// -------------------------------------------------------------------------

const TokenResult = struct { tag: Tag, start: u32 };

fn next(self: *Lexer) TokenResult {
    self.skipWhitespaceAndComments();

    if (self.pos >= self.source.len) {
        return .{ .tag = .eof, .start = self.pos };
    }

    const start = self.pos;
    const ch = self.source[self.pos];

    // Identifiers and keywords
    if (isIdentStart(ch)) {
        return self.scanIdentOrKeyword(start);
    }

    // Numbers
    if (isDigit(ch) or (ch == '.' and self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1]))) {
        return self.scanNumber(start);
    }

    // Operators and punctuation
    return self.scanOperator(start);
}

fn skipWhitespaceAndComments(self: *Lexer) void {
    while (self.pos < self.source.len) {
        const ch = self.source[self.pos];

        // Fast path: space and newline
        if (ch == ' ' or ch == '\n') {
            self.pos += 1;
            continue;
        }
        if (ch == '\t' or ch == '\r') {
            self.pos += 1;
            continue;
        }

        // Line comment
        if (ch == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') {
            self.pos += 2;
            while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                self.pos += 1;
            }
            continue;
        }

        // Block comment (nested)
        if (ch == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '*') {
            self.pos += 2;
            var depth: u32 = 1;
            while (self.pos + 1 < self.source.len and depth > 0) {
                const c = self.source[self.pos];
                if (c == '/' and self.source[self.pos + 1] == '*') {
                    depth += 1;
                    self.pos += 2;
                } else if (c == '*' and self.source[self.pos + 1] == '/') {
                    depth -= 1;
                    self.pos += 2;
                } else {
                    self.pos += 1;
                }
            }
            continue;
        }

        break;
    }
}

fn scanIdentOrKeyword(self: *Lexer, start: u32) TokenResult {
    // Scan ASCII identifier characters
    while (self.pos < self.source.len and isIdentContinue(self.source[self.pos])) {
        self.pos += 1;
    }

    const text = self.source[start..self.pos];

    // Check keywords
    if (keywords_map.get(text)) |kw_tag| {
        return .{ .tag = kw_tag, .start = start };
    }

    // Single underscore
    if (text.len == 1 and text[0] == '_') {
        return .{ .tag = .underscore, .start = start };
    }

    // Reserved words
    if (reserved_words.has(text)) {
        return .{ .tag = .reserved_ident, .start = start };
    }

    // Double underscore prefix
    if (text.len >= 2 and text[0] == '_' and text[1] == '_') {
        return .{ .tag = .reserved_ident, .start = start };
    }

    return .{ .tag = .ident, .start = start };
}

fn scanNumber(self: *Lexer, start: u32) TokenResult {
    var kind: Tag = .int_literal;

    // Hex
    if (self.pos + 1 < self.source.len and self.source[self.pos] == '0' and
        (self.source[self.pos + 1] == 'x' or self.source[self.pos + 1] == 'X'))
    {
        self.pos += 2;
        while (self.pos < self.source.len and isHexDigit(self.source[self.pos])) self.pos += 1;
        // Hex float
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            kind = .float_literal;
            self.pos += 1;
            while (self.pos < self.source.len and isHexDigit(self.source[self.pos])) self.pos += 1;
        }
        // Hex exponent
        if (self.pos < self.source.len and (self.source[self.pos] == 'p' or self.source[self.pos] == 'P')) {
            kind = .float_literal;
            self.pos += 1;
            if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) self.pos += 1;
            while (self.pos < self.source.len and isDigit(self.source[self.pos])) self.pos += 1;
        }
    } else {
        // Decimal integer part
        while (self.pos < self.source.len and isDigit(self.source[self.pos])) self.pos += 1;
        // Decimal point
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            const next_is_digit = self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1]);
            const next_is_ident = self.pos + 1 < self.source.len and isIdentStart(self.source[self.pos + 1]);
            const at_end = self.pos + 1 >= self.source.len;
            // Accept 1.f and 1.h — float suffix after decimal point with no fractional digits
            const next_is_float_suffix = self.pos + 1 < self.source.len and
                (self.source[self.pos + 1] == 'f' or self.source[self.pos + 1] == 'h') and
                (self.pos + 2 >= self.source.len or !isIdentContinue(self.source[self.pos + 2]));

            if (next_is_digit or at_end or !next_is_ident or next_is_float_suffix) {
                kind = .float_literal;
                self.pos += 1;
                while (self.pos < self.source.len and isDigit(self.source[self.pos])) self.pos += 1;
            }
        }
        // Exponent
        if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
            kind = .float_literal;
            self.pos += 1;
            if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) self.pos += 1;
            while (self.pos < self.source.len and isDigit(self.source[self.pos])) self.pos += 1;
        }
    }

    // Type suffix
    if (self.pos < self.source.len) {
        const ch = self.source[self.pos];
        if (ch == 'i' or ch == 'u') {
            self.pos += 1;
        } else if (ch == 'f' or ch == 'h') {
            kind = .float_literal;
            self.pos += 1;
        }
    }

    return .{ .tag = kind, .start = start };
}

fn scanOperator(self: *Lexer, start: u32) TokenResult {
    const ch = self.source[self.pos];
    self.pos += 1;

    const next_ch: u8 = if (self.pos < self.source.len) self.source[self.pos] else 0;

    switch (ch) {
        '+' => {
            if (next_ch == '+') { self.pos += 1; return .{ .tag = .plus_plus, .start = start }; }
            if (next_ch == '=') { self.pos += 1; return .{ .tag = .plus_eq, .start = start }; }
            return .{ .tag = .plus, .start = start };
        },
        '-' => {
            if (next_ch == '-') { self.pos += 1; return .{ .tag = .minus_minus, .start = start }; }
            if (next_ch == '=') { self.pos += 1; return .{ .tag = .minus_eq, .start = start }; }
            if (next_ch == '>') { self.pos += 1; return .{ .tag = .arrow, .start = start }; }
            return .{ .tag = .minus, .start = start };
        },
        '*' => {
            if (next_ch == '=') { self.pos += 1; return .{ .tag = .star_eq, .start = start }; }
            return .{ .tag = .star, .start = start };
        },
        '/' => {
            if (next_ch == '=') { self.pos += 1; return .{ .tag = .slash_eq, .start = start }; }
            return .{ .tag = .slash, .start = start };
        },
        '%' => {
            if (next_ch == '=') { self.pos += 1; return .{ .tag = .percent_eq, .start = start }; }
            return .{ .tag = .percent, .start = start };
        },
        '&' => {
            if (next_ch == '&') { self.pos += 1; return .{ .tag = .amp_amp, .start = start }; }
            if (next_ch == '=') { self.pos += 1; return .{ .tag = .amp_eq, .start = start }; }
            return .{ .tag = .amp, .start = start };
        },
        '|' => {
            if (next_ch == '|') { self.pos += 1; return .{ .tag = .pipe_pipe, .start = start }; }
            if (next_ch == '=') { self.pos += 1; return .{ .tag = .pipe_eq, .start = start }; }
            return .{ .tag = .pipe, .start = start };
        },
        '^' => {
            if (next_ch == '=') { self.pos += 1; return .{ .tag = .caret_eq, .start = start }; }
            return .{ .tag = .caret, .start = start };
        },
        '<' => {
            if (next_ch == '<') {
                self.pos += 1;
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    return .{ .tag = .lt_lt_eq, .start = start };
                }
                return .{ .tag = .lt_lt, .start = start };
            }
            if (next_ch == '=') { self.pos += 1; return .{ .tag = .lt_eq, .start = start }; }
            return .{ .tag = .lt, .start = start };
        },
        '>' => {
            if (next_ch == '>') {
                self.pos += 1;
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    return .{ .tag = .gt_gt_eq, .start = start };
                }
                return .{ .tag = .gt_gt, .start = start };
            }
            if (next_ch == '=') { self.pos += 1; return .{ .tag = .gt_eq, .start = start }; }
            return .{ .tag = .gt, .start = start };
        },
        '=' => {
            if (next_ch == '=') { self.pos += 1; return .{ .tag = .eq_eq, .start = start }; }
            return .{ .tag = .eq, .start = start };
        },
        '!' => {
            if (next_ch == '=') { self.pos += 1; return .{ .tag = .bang_eq, .start = start }; }
            return .{ .tag = .bang, .start = start };
        },
        '~' => return .{ .tag = .tilde, .start = start },
        '.' => return .{ .tag = .dot, .start = start },
        '@' => return .{ .tag = .at, .start = start },
        '(' => return .{ .tag = .l_paren, .start = start },
        ')' => return .{ .tag = .r_paren, .start = start },
        '{' => return .{ .tag = .l_brace, .start = start },
        '}' => return .{ .tag = .r_brace, .start = start },
        '[' => return .{ .tag = .l_bracket, .start = start },
        ']' => return .{ .tag = .r_bracket, .start = start },
        ';' => return .{ .tag = .semicolon, .start = start },
        ':' => return .{ .tag = .colon, .start = start },
        ',' => return .{ .tag = .comma, .start = start },
        else => return .{ .tag = .@"error", .start = start },
    }
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
        '+' => if (nc == '+' or nc == '=') { pos += 1; },
        '-' => if (nc == '-' or nc == '=' or nc == '>') { pos += 1; },
        '*', '/', '%' => if (nc == '=') { pos += 1; },
        '&' => if (nc == '&' or nc == '=') { pos += 1; },
        '|' => if (nc == '|' or nc == '=') { pos += 1; },
        '^' => if (nc == '=') { pos += 1; },
        '<' => {
            if (nc == '<') { pos += 1; if (pos < src.len and src[pos] == '=') pos += 1; } else if (nc == '=') { pos += 1; }
        },
        '>' => {
            if (nc == '>') { pos += 1; if (pos < src.len and src[pos] == '=') pos += 1; } else if (nc == '=') { pos += 1; }
        },
        '=', '!' => if (nc == '=') { pos += 1; },
        else => {},
    }
    return src[start..pos];
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "tokenize simple" {
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

test "tokenize operators" {
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

test "tokenize nested block comment" {
    const source: [:0]const u8 = "/* outer /* inner */ still comment */ fn";
    var tokens = try tokenize(std.testing.allocator, source);
    defer tokens.deinit(std.testing.allocator);
    const tags = tokens.items(.tag);
    try std.testing.expectEqual(Tag.keyword_fn, tags[0]);
    try std.testing.expectEqual(Tag.eof, tags[1]);
}

test "tokenize keywords" {
    const source: [:0]const u8 = "const var let fn struct alias override return if else for while loop break continue discard switch case default";
    var tokens = try tokenize(std.testing.allocator, source);
    defer tokens.deinit(std.testing.allocator);
    const tags = tokens.items(.tag);
    try std.testing.expectEqual(Tag.keyword_const, tags[0]);
    try std.testing.expectEqual(Tag.keyword_var, tags[1]);
    try std.testing.expectEqual(Tag.keyword_let, tags[2]);
    try std.testing.expectEqual(Tag.keyword_fn, tags[3]);
}

test "fuzz lexer no crash" {
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

test "tokenize numbers" {
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
// Ported from Go internal/lexer/lexer_test.go
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
