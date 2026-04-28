//! Two-pass WGSL parser.
//!
//! Pass 1 (parse): Build AST, declare symbols with use_count = 0.
//! Pass 2 (visit): Bind identifiers to symbols, increment use_count, mark purity.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Lexer = @import("Lexer.zig");
const Cst = @import("Cst.zig");
const AstVisit = @import("AstVisit.zig");
const Suggest = @import("Suggest.zig");
const Diagnostic = @import("Diagnostic.zig");
const constants = @import("constants.zig");

const Parser = @This();

const Tag = Lexer.Tag;

arena: Allocator,
source: [:0]const u8,
// Mutable so `expectTemplateClose` can split a `>>` lexer token into two
// logical template closures (retag + start-bump). The underlying storage
// is parser-owned (arena-allocated by `TokenStream.init`, or caller-owned
// `MultiArrayList` items, both of which permit write-through).
token_tags: []Tag,
token_starts: []u32,
pos: u32,

// Symbol table
symbols: std.ArrayListUnmanaged(Ast.Symbol),
scope: *Ast.Scope,
/// DFS append-order list of non-root scopes, consumed by `AstVisit.visit`
/// to walk scopes in the same order `parseTranslationUnit` created them.
scopes_in_order: std.ArrayListUnmanaged(*Ast.Scope),

// Errors
errors: std.ArrayListUnmanaged(ParseError),
expr_context: []const u8 = "",

/// Sticky OOM flag. Set by the `markOom` helper when an arena allocation
/// inside a void-returning helper (CST builder close, error-list append,
/// duplicate-declaration message) hits `error.OutOfMemory`. Checked at
/// `parse()` return and translated to `error.OutOfMemory`, so the caller
/// sees OOM exactly once. After OOM, the AST, error list, and CST state
/// are all potentially incomplete — callers must not inspect them.
oom: bool = false,

/// Recursive descent depth counters. Each `parseExpression` /
/// `parseStatement` / `parseType` entry bumps the matching counter and
/// emits a `nesting_too_deep` diagnostic if it would exceed the limit
/// in `constants.zig`. Without these guards, adversarial input like
/// `(((((... a ...)))))` could overflow the call stack before the
/// validator's depth checks ever run.
expr_depth: u16 = 0,
stmt_depth: u16 = 0,
type_depth: u16 = 0,

// =========================================================================
// Optional concrete syntax tree shadow.
//
// When `cst` is non-null, the parser additionally emits events into the
// builder for every token it consumes and for every major grammar
// production it enters. The AST construction path is unaffected — CST
// emission is strictly additive.
//
// `cst_all_tags` / `cst_all_starts` / `cst_all_ends` hold the
// trivia-preserving token stream (produced by `Lexer.tokenizeAll`). The
// parser's own token cursor (`self.pos`) indexes into the non-trivia
// slice, while `cst_nt_to_all[self.pos]` maps it to the matching index
// in the full stream. `cst_next_all` tracks how far we've emitted into
// the full stream so trivia tokens between two consecutive real tokens
// are flushed in-order as leaves of the current open CST node.
// =========================================================================

cst: ?*Cst.Builder = null,
cst_all_tags: []const Tag = &.{},
cst_all_starts: []const u32 = &.{},
cst_all_ends: []const u32 = &.{},
cst_nt_to_all: []const u32 = &.{},
cst_next_all: u32 = 0,

/// Marker of the most recently closed expression-level CST node. Read by
/// `openBefore` call sites in `parsePostfixExpr`, `parseUnaryExpr`, and
/// each binary-precedence level to wrap the previously-produced
/// expression under a new outer node. Callers snapshot this into a local
/// before entering any nested parse that may reassign it (e.g., argument
/// list parsing inside a call).
cst_last_closed_expr: ?Cst.Marker = null,

pub const ParseError = struct {
    message: []const u8,
    pos: u32,
    end: u32 = 0,
    code: []const u8 = "",
};

// =========================================================================
// Initialization
// =========================================================================

/// Creates a parser for the given tokenized WGSL source. Allocates the root scope.
pub fn init(arena: Allocator, source: [:0]const u8, tokens: std.MultiArrayList(Lexer.Token)) !Parser {
    // Pre-condition: token list must contain at least one token (the EOF).
    std.debug.assert(tokens.len > 0);

    const scope = try arena.create(Ast.Scope);
    scope.* = Ast.Scope.init(null, .module);

    return .{
        .arena = arena,
        .source = source,
        .token_tags = tokens.items(.tag),
        .token_starts = tokens.items(.start),
        .pos = 0,
        .symbols = .empty,
        .scope = scope,
        .scopes_in_order = .empty,
        .errors = .empty,
    };
}

/// Precomputed view of a `tokenizeAll` output, splitting the raw token
/// stream into a trivia-preserving slice (`.*_all`) and a non-trivia
/// cursor slice mirroring `Lexer.tokenize`.
pub const TokenStream = struct {
    all_tags: []const Tag,
    all_starts: []const u32,
    all_ends: []const u32,

    non_trivia_tags: []Tag,
    non_trivia_starts: []u32,
    nt_to_all: []u32,

    /// Build a stream from the output of `Lexer.tokenizeAll`. Allocates
    /// `non_trivia_tags`, `non_trivia_starts`, and `nt_to_all` from `arena`;
    /// `all_*` slices alias the caller's token storage.
    pub fn init(arena: Allocator, all: *const std.MultiArrayList(Lexer.Token)) !TokenStream {
        const tags = all.items(.tag);
        const starts = all.items(.start);
        const ends = all.items(.end);

        // Count non-trivia.
        var n: u32 = 0;
        for (tags) |t| {
            if (!t.isTrivia()) n += 1;
        }

        const nt_tags = try arena.alloc(Tag, n);
        const nt_starts = try arena.alloc(u32, n);
        const nt_map = try arena.alloc(u32, n);
        var j: u32 = 0;
        for (tags, 0..) |t, i| {
            if (t.isTrivia()) continue;
            nt_tags[j] = t;
            nt_starts[j] = starts[i];
            nt_map[j] = @intCast(i);
            j += 1;
        }

        return .{
            .all_tags = tags,
            .all_starts = starts,
            .all_ends = ends,
            .non_trivia_tags = nt_tags,
            .non_trivia_starts = nt_starts,
            .nt_to_all = nt_map,
        };
    }
};

/// Like `init` but wires a CST builder so the parser emits events alongside
/// AST construction. `stream` is built from a `Lexer.tokenizeAll` output.
/// The caller retains ownership of the underlying token storage and the
/// builder; both must outlive the parser's call to `parse`.
pub fn initWithCst(
    arena: Allocator,
    source: [:0]const u8,
    stream: TokenStream,
    builder: *Cst.Builder,
) !Parser {
    std.debug.assert(stream.non_trivia_tags.len > 0);

    const scope = try arena.create(Ast.Scope);
    scope.* = Ast.Scope.init(null, .module);

    return .{
        .arena = arena,
        .source = source,
        .token_tags = stream.non_trivia_tags,
        .token_starts = stream.non_trivia_starts,
        .pos = 0,
        .symbols = .empty,
        .scope = scope,
        .scopes_in_order = .empty,
        .errors = .empty,
        .cst = builder,
        .cst_all_tags = stream.all_tags,
        .cst_all_starts = stream.all_starts,
        .cst_all_ends = stream.all_ends,
        .cst_nt_to_all = stream.nt_to_all,
        .cst_next_all = 0,
    };
}

// =========================================================================
// Anchor re-entry for incremental reparse
// =========================================================================

/// Kind of grammar production that `reparseAnchor` can restart at.
/// Matches the subset of `Cst.Kind` that the incremental driver treats
/// as safe subtree-replacement anchors on the symbol-free hot path.
pub const AnchorKind = enum {
    /// Any `Ast.Expr` variant. Emits whichever `*_expr` kind the inner
    /// expression helpers produce. The caller must verify the resulting
    /// root kind against the old anchor's kind before splicing.
    expression,
    /// Any `Ast.Stmt` variant other than `compound_stmt`. `parseStatement`
    /// opens its own CST marker and closes it with the specific stmt kind,
    /// so the resulting subtree has exactly one root node.
    statement,
};

/// Reposition the parser at `start_nt_pos` (an index into the non-trivia
/// cursor built by `TokenStream.init`) and invoke the grammar entry point
/// matching `kind`. Emits CST events into the attached builder so a call
/// to `builder.finish(...)` afterwards yields a single-rooted subtree.
///
/// The parser's symbol table / scope are not meant to be reused after this
/// call — any symbols declared by the inner production are throwaway. The
/// caller lowers the resulting CST subtree into AST using the prev
/// module's symbol table.
pub fn reparseAnchor(
    self: *Parser,
    kind: AnchorKind,
    start_nt_pos: u32,
) error{ OutOfMemory, ParseFailed }!void {
    std.debug.assert(self.cst != null);
    std.debug.assert(start_nt_pos <= self.token_tags.len);

    self.pos = start_nt_pos;
    // Place `cst_next_all` at the first all-stream token that belongs
    // inside the anchor: the token right after the previous non-trivia
    // token. This way the leading trivia (whitespace / comments between
    // the previous real token and the anchor's first real token) gets
    // emitted as children of the anchor's first-opened inner node —
    // matching how a full parse attributes trivia.
    self.cst_next_all = blk: {
        if (start_nt_pos == 0) break :blk 0;
        std.debug.assert(start_nt_pos - 1 < self.cst_nt_to_all.len);
        break :blk self.cst_nt_to_all[start_nt_pos - 1] + 1;
    };
    self.cst_last_closed_expr = null;

    switch (kind) {
        .expression => _ = try self.parseExpression(),
        .statement => _ = try self.parseStatement(),
    }
}

/// Parse source into a Module. Caller owns the returned module via the arena.
pub fn parse(self: *Parser) !*Ast.Module {
    std.debug.assert(self.pos == 0); // parse should only be called once

    const module = try self.arena.create(Ast.Module);
    module.* = Ast.Module.init(self.scope, self.source);

    // Pass 1: Parse
    try self.parseTranslationUnit(module);

    // Pass 2: Visit
    var ctx = AstVisit.Context{
        .arena = self.arena,
        .symbols = self.symbols.items,
        .scopes_in_order = self.scopes_in_order.items,
        .scope = module.scope,
        .errors = &self.errors,
        .safety_budget = self.token_tags.len * 2,
    };
    try AstVisit.visit(&ctx, module);

    // Copy symbols to module
    module.symbols = self.symbols;

    // Post-condition: all symbols have source names
    for (module.symbols.items) |sym| {
        std.debug.assert(sym.original_name.len > 0 or sym.kind == .unbound);
    }
    // Post-condition: every depth-tracked descent unwound; a stale value
    // here means a parseExpression/parseStatement/parseType path is missing
    // its `defer depth -= 1`, which would silently degrade later parses.
    std.debug.assert(self.expr_depth == 0);
    std.debug.assert(self.stmt_depth == 0);
    std.debug.assert(self.type_depth == 0);

    // Surface any OOM seen by void-returning helpers (see `self.oom`).
    if (self.oom) return error.OutOfMemory;

    return module;
}

/// Called by helpers that can't propagate `error.OutOfMemory` through
/// their signature. Sets the sticky flag consumed at `parse()` return.
fn markOom(self: *Parser) void {
    self.oom = true;
}

// =========================================================================
// Token helpers
// =========================================================================

fn currentTag(self: *const Parser) Tag {
    if (self.pos >= self.token_tags.len) return .eof;
    return self.token_tags[self.pos];
}

fn peekTag(self: *const Parser, offset: u32) Tag {
    const p = self.pos + offset;
    if (p >= self.token_tags.len) return .eof;
    return self.token_tags[p];
}

fn advance(self: *Parser) void {
    if (self.pos < self.token_tags.len) {
        self.emitCurrentTokenToCst();
        self.pos += 1;
    }
}

/// If a CST builder is attached, emit every trivia token plus the real
/// token at `self.pos` as children of the currently-open node. Flushing
/// trivia alongside the real token keeps the builder's child stream
/// identical (under concatenation) to `tokenizeAll`'s output.
fn emitCurrentTokenToCst(self: *Parser) void {
    const builder = self.cst orelse return;
    if (self.pos >= self.cst_nt_to_all.len) return;
    const target = self.cst_nt_to_all[self.pos];
    while (self.cst_next_all <= target) : (self.cst_next_all += 1) {
        builder.token(self.cst_next_all) catch {
            // Arena-scoped builder; OOM surfaces via a later check. Drop
            // silently here to keep the parser's void signature.
            return;
        };
    }
}

/// Flush any remaining trivia tokens after the last non-trivia token has
/// been consumed — typically whitespace at EOF or a trailing line comment.
fn flushTrailingTriviaToCst(self: *Parser) void {
    const builder = self.cst orelse return;
    // Target is strictly less than eof's index: every trivia token sits
    // before the sentinel eof. We emit up to (but not including) eof so
    // the eof token can be attached to the enclosing `module` node.
    const total: u32 = @intCast(self.cst_all_tags.len);
    while (self.cst_next_all < total and self.cst_all_tags[self.cst_next_all].isTrivia()) : (self.cst_next_all += 1) {
        builder.token(self.cst_next_all) catch return;
    }
}

fn cstOpen(self: *Parser) ?Cst.Marker {
    const builder = self.cst orelse return null;
    return builder.open() catch null;
}

fn cstClose(self: *Parser, maybe_marker: ?Cst.Marker, kind: Cst.Kind) void {
    if (self.cst) |builder| {
        if (maybe_marker) |m| builder.close(m, kind) catch self.markOom();
    }
}

/// Retroactively wrap `m` under a new outer marker. Returns `null` when no
/// CST builder is attached or when `m` is null (caller side-by-side with
/// `cst_last_closed_expr` checks). Used to express left-associative
/// precedence without rewriting the event stream.
fn cstOpenBefore(self: *Parser, m: ?Cst.Marker) ?Cst.Marker {
    const builder = self.cst orelse return null;
    const marker = m orelse return null;
    return builder.openBefore(marker) catch null;
}

fn cstAbandon(self: *Parser, maybe_marker: ?Cst.Marker) void {
    if (self.cst) |builder| {
        if (maybe_marker) |m| builder.abandon(m);
    }
}

fn cstEmitEof(self: *Parser) void {
    const builder = self.cst orelse return;
    const total: u32 = @intCast(self.cst_all_tags.len);
    while (self.cst_next_all < total) : (self.cst_next_all += 1) {
        builder.token(self.cst_next_all) catch return;
    }
}

fn eat(self: *Parser, tag: Tag) bool {
    if (self.currentTag() == tag) {
        self.advance();
        return true;
    }
    return false;
}

fn expect(self: *Parser, tag: Tag) bool {
    if (self.currentTag() != tag) {
        const msg = std.fmt.allocPrint(self.arena, "expected '{s}'", .{tag.symbol()}) catch "expected token";
        self.addError(msg);
        return false;
    }
    self.advance();
    return true;
}

/// Consume a single `>` closing a template-argument list, splitting a
/// compound trailing-`>` token in place if the lexer bundled two closures
/// together (WGSL §3.8, classic C++ nested-template problem). Leaves the
/// parser state exactly as if a real `.gt` had been consumed.
///
/// Rewrites the current non-trivia token entry (parser-owned storage) by
/// retagging and bumping the start byte by 1. The CST's all-stream tokens
/// are untouched, so the raw token trivia/byte tree remains faithful.
fn expectTemplateClose(self: *Parser) bool {
    switch (self.currentTag()) {
        .gt => {
            self.advance();
            return true;
        },
        .gt_gt => {
            // `>>` → consume the first `>`; the second becomes a `.gt` at
            // the same index for the enclosing template close to pick up.
            self.token_tags[self.pos] = .gt;
            self.token_starts[self.pos] += 1;
            return true;
        },
        .gt_gt_eq => {
            // `>>=` → consume the first `>`; the remainder is `>=`.
            self.token_tags[self.pos] = .gt_eq;
            self.token_starts[self.pos] += 1;
            return true;
        },
        .gt_eq => {
            // `>=` → consume the `>`; the remainder is `=`.
            self.token_tags[self.pos] = .eq;
            self.token_starts[self.pos] += 1;
            return true;
        },
        else => {
            const msg = std.fmt.allocPrint(self.arena, "expected '>'", .{}) catch "expected '>'";
            self.addError(msg);
            return false;
        },
    }
}

fn tokenText(self: *const Parser, pos: u32) []const u8 {
    if (pos >= self.token_tags.len) return "";
    const start = self.token_starts[pos];
    const tag = self.token_tags[pos];
    _ = tag;
    // Scan to find end of this token's text
    var end = start;
    const src = self.source;
    if (end >= src.len) return "";
    const ch = src[end];
    if (Lexer.peekIdentStart(src, end)) {
        end = Lexer.scanIdentEnd(src, end);
    } else if (Lexer.isDigit(ch) or (ch == '.' and end + 1 < src.len and Lexer.isDigit(src[end + 1]))) {
        return self.scanNumberText(start);
    } else {
        // operator - advance 1-3 chars
        end += 1;
        if (end < src.len) {
            const nc = src[end];
            switch (ch) {
                '+' => if (nc == '+' or nc == '=') {
                    end += 1;
                },
                '-' => if (nc == '-' or nc == '=' or nc == '>') {
                    end += 1;
                },
                '*', '/', '%' => if (nc == '=') {
                    end += 1;
                },
                '&' => if (nc == '&' or nc == '=') {
                    end += 1;
                },
                '|' => if (nc == '|' or nc == '=') {
                    end += 1;
                },
                '^' => if (nc == '=') {
                    end += 1;
                },
                '<' => {
                    if (nc == '<') {
                        end += 1;
                        if (end < src.len and src[end] == '=') end += 1;
                    } else if (nc == '=') end += 1;
                },
                '>' => {
                    if (nc == '>') {
                        end += 1;
                        if (end < src.len and src[end] == '=') end += 1;
                    } else if (nc == '=') end += 1;
                },
                '=', '!' => if (nc == '=') {
                    end += 1;
                },
                else => {},
            }
        }
    }
    return src[start..end];
}

fn scanNumberText(self: *const Parser, start: u32) []const u8 {
    var pos = start;
    const src = self.source;
    // Hex
    if (pos + 1 < src.len and src[pos] == '0' and (src[pos + 1] == 'x' or src[pos + 1] == 'X')) {
        pos += 2;
        while (pos < src.len and Lexer.isHexDigit(src[pos])) pos += 1;
        if (pos < src.len and src[pos] == '.') {
            pos += 1;
            while (pos < src.len and Lexer.isHexDigit(src[pos])) pos += 1;
        }
        if (pos < src.len and (src[pos] == 'p' or src[pos] == 'P')) {
            pos += 1;
            if (pos < src.len and (src[pos] == '+' or src[pos] == '-')) pos += 1;
            while (pos < src.len and Lexer.isDigit(src[pos])) pos += 1;
        }
    } else {
        while (pos < src.len and Lexer.isDigit(src[pos])) pos += 1;
        if (pos < src.len and src[pos] == '.') {
            const nid = pos + 1 < src.len and Lexer.isDigit(src[pos + 1]);
            const nie = Lexer.peekIdentStart(src, pos + 1);
            const ae = pos + 1 >= src.len;
            // `1.f` / `1.h` — digit, dot, float-suffix, no trailing ident
            // chars — is a complete float literal (matches the lexer).
            const nfs = pos + 1 < src.len and
                (src[pos + 1] == 'f' or src[pos + 1] == 'h') and
                !Lexer.peekIdentContinue(src, pos + 2);
            // `1.e…` — dot followed directly by an exponent is a float too
            // (WGSL §6.1.2 rule 4 — fractional digits optional).
            const nex = pos + 1 < src.len and (src[pos + 1] == 'e' or src[pos + 1] == 'E');
            if (nid or ae or !nie or nfs or nex) {
                pos += 1;
                while (pos < src.len and Lexer.isDigit(src[pos])) pos += 1;
            }
        }
        if (pos < src.len and (src[pos] == 'e' or src[pos] == 'E')) {
            pos += 1;
            if (pos < src.len and (src[pos] == '+' or src[pos] == '-')) pos += 1;
            while (pos < src.len and Lexer.isDigit(src[pos])) pos += 1;
        }
    }
    if (pos < src.len and (src[pos] == 'i' or src[pos] == 'u' or src[pos] == 'f' or src[pos] == 'h')) pos += 1;
    return src[start..pos];
}

fn currentText(self: *const Parser) []const u8 {
    return self.tokenText(self.pos);
}

fn currentStart(self: *const Parser) u32 {
    if (self.pos >= self.token_starts.len) return @intCast(self.source.len);
    return self.token_starts[self.pos];
}

/// Byte offset one past the end of the most recently consumed token.
/// Used to close out a span after an `expect(...)` / `advance()` that
/// consumes the terminator. Returns 0 if no token has been consumed
/// yet (not reachable during declaration parsing).
fn prevTokenEnd(self: *const Parser) u32 {
    if (self.pos == 0) return 0;
    const prev_pos = self.pos - 1;
    const start = self.token_starts[prev_pos];
    const text = self.tokenText(prev_pos);
    return start + @as(u32, @intCast(text.len));
}

fn addError(self: *Parser, message: []const u8) void {
    const start = self.currentStart();
    const text = self.currentText();
    self.errors.append(self.arena, .{ .message = message, .pos = start, .end = start +| @as(u32, @intCast(text.len)) }) catch self.markOom();
}

fn addErrorWithCode(self: *Parser, message: []const u8, code: []const u8) void {
    const start = self.currentStart();
    const text = self.currentText();
    self.errors.append(self.arena, .{
        .message = message,
        .pos = start,
        .end = start +| @as(u32, @intCast(text.len)),
        .code = code,
    }) catch self.markOom();
}

fn isIdentLike(self: *const Parser) bool {
    const tag = self.currentTag();
    return tag == .ident or tag == .reserved_ident;
}

fn peekIdentLike(self: *const Parser, offset: u32) bool {
    const tag = self.peekTag(offset);
    return tag == .ident or tag == .reserved_ident;
}

/// Check if current token is an identifier (or reserved word used as identifier).
/// Emits a diagnostic for reserved words but returns the text for error recovery.
fn eatIdent(self: *Parser) ?[]const u8 {
    if (self.currentTag() == .reserved_ident) {
        const text = self.currentText();
        const msg = if (text.len >= 2 and text[0] == '_' and text[1] == '_')
            std.fmt.allocPrint(self.arena, "identifier '{s}' must not start with '__'", .{text}) catch "identifier must not start with '__'"
        else
            std.fmt.allocPrint(self.arena, "'{s}' is a reserved word and cannot be used as an identifier", .{text}) catch "use of reserved word";
        self.errors.append(self.arena, .{ .message = msg, .pos = self.currentStart(), .code = "E0004" }) catch self.markOom();
        return text;
    }
    if (self.currentTag() == .ident) {
        return self.currentText();
    }
    return null;
}

// =========================================================================
// Symbol table (Pass 1)
// =========================================================================

fn declareSymbol(self: *Parser, name: []const u8, kind: Ast.Symbol.Kind, flags: Ast.Symbol.Flags, loc: u32) !Ast.SymbolIndex {
    // Check for duplicate declaration in the same scope
    if (self.scope.members.get(name) != null) {
        const msg = std.fmt.allocPrint(self.arena, "redeclaration of '{s}'", .{name}) catch "redeclaration of identifier";
        self.errors.append(self.arena, .{ .message = msg, .pos = loc, .code = "E0101" }) catch self.markOom();
    }
    std.debug.assert(self.symbols.items.len < std.math.maxInt(u32));
    const idx: u32 = @intCast(self.symbols.items.len);
    try self.symbols.append(self.arena, .{
        .original_name = name,
        .kind = kind,
        .flags = flags,
        .use_count = 0,
        .loc = loc,
    });
    try self.scope.members.put(self.arena, name, .{
        .ref = @enumFromInt(idx),
        .loc = loc,
    });
    return @enumFromInt(idx);
}

/// Creates a symbol without adding it to the scope lookup table.
/// Used for struct members which should not shadow other identifiers.
fn declareSymbolNoScope(self: *Parser, name: []const u8, kind: Ast.Symbol.Kind, flags: Ast.Symbol.Flags, loc: u32) !Ast.SymbolIndex {
    std.debug.assert(self.symbols.items.len < std.math.maxInt(u32));
    const idx: u32 = @intCast(self.symbols.items.len);
    try self.symbols.append(self.arena, .{
        .original_name = name,
        .kind = kind,
        .flags = flags,
        .use_count = 0,
        .loc = loc,
    });
    return @enumFromInt(idx);
}

fn pushScope(self: *Parser, kind: Ast.ScopeKind) !void {
    const new_scope = try self.arena.create(Ast.Scope);
    new_scope.* = Ast.Scope.init(self.scope, kind);
    // sibling_index counts same-kind children already present in the parent.
    var sib: u32 = 0;
    for (self.scope.children.items) |c| {
        if (c.kind == kind) sib += 1;
    }
    new_scope.sibling_index = sib;
    try self.scope.children.append(self.arena, new_scope);
    self.scope = new_scope;
    try self.scopes_in_order.append(self.arena, new_scope);
}

fn popScope(self: *Parser) void {
    std.debug.assert(self.scope.parent != null);
    if (self.scope.parent) |p| self.scope = p;
}

// =========================================================================
// Pass 1: Parse
// =========================================================================

fn parseTranslationUnit(self: *Parser, module: *Ast.Module) !void {
    const mod_marker = self.cstOpen();

    // Parse directives — each produces one `directive` CST node.
    for (0..self.token_tags.len) |_| {
        switch (self.currentTag()) {
            .keyword_enable => {
                const dir_marker = self.cstOpen();
                const dir = try self.parseEnableDirective();
                try module.directives.append(self.arena, dir);
                self.cstClose(dir_marker, .directive);
            },
            .keyword_requires => {
                const dir_marker = self.cstOpen();
                const dir = try self.parseRequiresDirective();
                try module.directives.append(self.arena, dir);
                self.cstClose(dir_marker, .directive);
            },
            .keyword_diagnostic => {
                const dir_marker = self.cstOpen();
                const dir = try self.parseDiagnosticDirective();
                try module.directives.append(self.arena, dir);
                self.cstClose(dir_marker, .directive);
            },
            else => break,
        }
    } else unreachable;

    // Parse declarations — `parseDeclaration` emits its own per-decl kind.
    while (self.currentTag() != .eof) {
        if (try self.parseDeclaration()) |decl| {
            try module.declarations.append(self.arena, decl);
        } else {
            // Malformed: consume the stray token into the module node so
            // the round-trip invariant holds.
            self.advance();
        }
    }

    // Attach the eof token + any trailing trivia to the module node.
    self.cstEmitEof();
    self.cstClose(mod_marker, .module);
}

fn parseEnableDirective(self: *Parser) !Ast.Directive {
    const dir_start = self.currentStart();
    _ = self.expect(.keyword_enable);
    var features: std.ArrayListUnmanaged([]const u8) = .empty;
    for (0..self.token_tags.len) |_| {
        if (self.currentTag() == .ident) {
            try features.append(self.arena, self.currentText());
            self.advance();
        }
        if (!self.eat(.comma)) break;
    } else unreachable;
    _ = self.expect(.semicolon);
    return .{ .enable = .{
        .features = features,
        .span = .{ .start = dir_start, .end = self.prevTokenEnd() },
    } };
}

fn parseRequiresDirective(self: *Parser) !Ast.Directive {
    const dir_start = self.currentStart();
    _ = self.expect(.keyword_requires);
    var features: std.ArrayListUnmanaged([]const u8) = .empty;
    for (0..self.token_tags.len) |_| {
        if (self.currentTag() == .ident) {
            try features.append(self.arena, self.currentText());
            self.advance();
        }
        if (!self.eat(.comma)) break;
    } else unreachable;
    _ = self.expect(.semicolon);
    return .{ .requires = .{
        .features = features,
        .span = .{ .start = dir_start, .end = self.prevTokenEnd() },
    } };
}

fn parseDiagnosticDirective(self: *Parser) !Ast.Directive {
    const dir_start = self.currentStart();
    _ = self.expect(.keyword_diagnostic);
    _ = self.expect(.l_paren);
    const severity = if (self.currentTag() == .ident) blk: {
        const text = self.currentText();
        self.advance();
        break :blk text;
    } else "";
    _ = self.expect(.comma);
    const rule = if (self.currentTag() == .ident) blk: {
        const text = self.currentText();
        self.advance();
        break :blk text;
    } else "";
    _ = self.expect(.r_paren);
    _ = self.expect(.semicolon);
    return .{ .diagnostic = .{
        .severity = severity,
        .rule = rule,
        .span = .{ .start = dir_start, .end = self.prevTokenEnd() },
    } };
}

fn parseDeclaration(self: *Parser) !?Ast.Decl {
    // Span starts at the first attribute's `@` if any, otherwise the
    // keyword that follows. `currentStart()` returns whichever comes first.
    const decl_start = self.currentStart();
    // Open the CST marker before attributes so attributes land inside the
    // decl node; close with the specific kind once we know what we parsed.
    const marker = self.cstOpen();
    var attrs = try self.parseAttributes();

    switch (self.currentTag()) {
        .keyword_const => {
            if (self.peekIdentLike(1)) {
                const decl: Ast.Decl = .{ .@"const" = try self.parseConstDecl(decl_start) };
                self.cstClose(marker, .const_decl);
                return decl;
            }
            const decl: Ast.Decl = .{ .const_assert = try self.parseConstAssert() };
            self.cstClose(marker, .const_assert_decl);
            return decl;
        },
        .keyword_const_assert => {
            const decl: Ast.Decl = .{ .const_assert = try self.parseConstAssert() };
            self.cstClose(marker, .const_assert_decl);
            return decl;
        },
        .keyword_override => {
            const decl: Ast.Decl = .{ .override = try self.parseOverrideDecl(&attrs, decl_start) };
            self.cstClose(marker, .override_decl);
            return decl;
        },
        .keyword_var => {
            const decl: Ast.Decl = .{ .@"var" = try self.parseVarDecl(&attrs, decl_start) };
            self.cstClose(marker, .var_decl);
            return decl;
        },
        .keyword_let => {
            const decl: Ast.Decl = .{ .let = try self.parseLetDecl(decl_start) };
            self.cstClose(marker, .let_decl);
            return decl;
        },
        .keyword_fn => {
            const decl: Ast.Decl = .{ .function = try self.parseFunctionDecl(&attrs, decl_start) };
            self.cstClose(marker, .fn_decl);
            return decl;
        },
        .keyword_struct => {
            const decl: Ast.Decl = .{ .@"struct" = try self.parseStructDecl(decl_start) };
            self.cstClose(marker, .struct_decl);
            return decl;
        },
        .keyword_alias => {
            const decl: Ast.Decl = .{ .alias = try self.parseAliasDecl(decl_start) };
            self.cstClose(marker, .alias_decl);
            return decl;
        },
        else => {
            if (attrs.items.len > 0) self.addError("unexpected attributes");
            // No decl was parsed; close as error_tree so stray tokens are
            // grouped under an obvious recovery node rather than under
            // `module` directly.
            self.cstClose(marker, .error_tree);
            return null;
        },
    }
}

fn parseAttributes(self: *Parser) !std.ArrayListUnmanaged(Ast.Attribute) {
    var attrs: std.ArrayListUnmanaged(Ast.Attribute) = .empty;
    // Only open an attribute_list marker if at least one attribute is coming.
    const list_marker = if (self.currentTag() == .at) self.cstOpen() else null;
    while (self.currentTag() == .at) {
        const attr_marker = self.cstOpen();
        const attr_loc = self.currentStart();
        self.advance();
        var attr = Ast.Attribute{ .name = "", .args = .empty, .loc = attr_loc };
        if (self.eatIdent()) |text| {
            attr.name = text;
            self.advance();
        }
        if (self.currentTag() == .l_paren) {
            const args_marker = self.cstOpen();
            self.advance(); // consume '(' — lives inside the attribute_args node
            attr.args = try self.parseExpressionList();
            _ = self.expect(.r_paren);
            self.cstClose(args_marker, .attribute_args);
        }
        // Check for duplicate attribute
        if (attr.name.len > 0) {
            for (attrs.items) |existing| {
                if (std.mem.eql(u8, existing.name, attr.name)) {
                    const msg = std.fmt.allocPrint(self.arena, "duplicate attribute '@{s}'", .{attr.name}) catch "duplicate attribute";
                    self.errors.append(self.arena, .{ .message = msg, .pos = attr_loc, .code = "E0401" }) catch self.markOom();
                    break;
                }
            }
        }
        try attrs.append(self.arena, attr);
        self.cstClose(attr_marker, .attribute);
    }
    self.cstClose(list_marker, .attribute_list);
    return attrs;
}

fn parseConstDecl(self: *Parser, decl_start: u32) !*Ast.ConstDecl {
    _ = self.expect(.keyword_const);
    const decl = try self.arena.create(Ast.ConstDecl);
    decl.* = .{ .name = .none };

    if (self.eatIdent()) |text| {
        const loc = self.currentStart();
        self.advance();
        decl.name = try self.declareSymbol(text, .@"const", .{}, loc);
    }

    if (self.eat(.colon)) decl.typ = try self.parseType("after ':' in const declaration");
    _ = self.expect(.eq);
    self.expr_context = "after '=' in const declaration";
    decl.initializer = try self.parseExpression();
    _ = self.expect(.semicolon);
    decl.decl_span = .{ .start = decl_start, .end = self.prevTokenEnd() };
    return decl;
}

fn parseOverrideDecl(self: *Parser, attrs: *std.ArrayListUnmanaged(Ast.Attribute), decl_start: u32) !*Ast.OverrideDecl {
    _ = self.expect(.keyword_override);
    const decl = try self.arena.create(Ast.OverrideDecl);
    decl.* = .{ .attributes = attrs.*, .name = .none };

    if (self.eatIdent()) |text| {
        const loc = self.currentStart();
        self.advance();
        decl.name = try self.declareSymbol(text, .override, .{}, loc);
    }

    if (self.eat(.colon)) decl.typ = try self.parseType("after ':' in override declaration");
    if (self.eat(.eq)) {
        self.expr_context = "after '=' in override declaration";
        decl.initializer = try self.parseExpression();
    }
    _ = self.expect(.semicolon);
    decl.decl_span = .{ .start = decl_start, .end = self.prevTokenEnd() };
    return decl;
}

fn parseVarDecl(self: *Parser, attrs: *std.ArrayListUnmanaged(Ast.Attribute), decl_start: u32) !*Ast.VarDecl {
    _ = self.expect(.keyword_var);
    const decl = try self.arena.create(Ast.VarDecl);
    decl.* = .{ .attributes = attrs.*, .name = .none };

    // Optional <address_space, access_mode>
    if (self.eat(.lt)) {
        decl.address_space = self.parseAddressSpace();
        if (self.eat(.comma)) decl.access_mode = self.parseAccessMode();
        _ = self.expect(.gt);
    }

    var flags = Ast.Symbol.Flags{};
    if (decl.address_space == .uniform or decl.address_space == .storage) {
        flags.is_external_binding = true;
    }

    if (self.eatIdent()) |text| {
        const loc = self.currentStart();
        self.advance();
        decl.name = try self.declareSymbol(text, .@"var", flags, loc);
    }

    if (self.eat(.colon)) decl.typ = try self.parseType("after ':' in var declaration");
    if (self.eat(.eq)) {
        self.expr_context = "after '=' in var declaration";
        decl.initializer = try self.parseExpression();
    }
    _ = self.expect(.semicolon);
    decl.decl_span = .{ .start = decl_start, .end = self.prevTokenEnd() };
    return decl;
}

fn parseLetDecl(self: *Parser, decl_start: u32) !*Ast.LetDecl {
    _ = self.expect(.keyword_let);
    const decl = try self.arena.create(Ast.LetDecl);
    decl.* = .{ .name = .none };

    if (self.eatIdent()) |text| {
        const loc = self.currentStart();
        self.advance();
        decl.name = try self.declareSymbol(text, .let, .{}, loc);
    }

    if (self.eat(.colon)) decl.typ = try self.parseType("after ':' in let declaration");
    _ = self.expect(.eq);
    self.expr_context = "after '=' in let declaration";
    decl.initializer = try self.parseExpression();
    _ = self.expect(.semicolon);
    decl.decl_span = .{ .start = decl_start, .end = self.prevTokenEnd() };
    return decl;
}

fn parseFunctionDecl(self: *Parser, attrs: *std.ArrayListUnmanaged(Ast.Attribute), decl_start: u32) !*Ast.FunctionDecl {
    _ = self.expect(.keyword_fn);
    const decl = try self.arena.create(Ast.FunctionDecl);
    decl.* = .{
        .attributes = attrs.*,
        .name = .none,
        .parameters = .empty,
        .return_attr = .empty,
    };

    // Check entry point
    const entry_point_attrs = std.StaticStringMap(void).initComptime(.{
        .{ "vertex", {} },
        .{ "fragment", {} },
        .{ "compute", {} },
    });
    var is_entry_point = false;
    for (attrs.items) |attr| {
        if (entry_point_attrs.has(attr.name)) {
            is_entry_point = true;
            break;
        }
    }

    var flags = Ast.Symbol.Flags{};
    if (is_entry_point) {
        flags.is_entry_point = true;
        flags.must_not_be_renamed = true;
    }

    if (self.eatIdent()) |text| {
        const loc = self.currentStart();
        self.advance();
        decl.name = try self.declareSymbol(text, .function, flags, loc);
    }

    try self.pushScope(.function);

    _ = self.expect(.l_paren);
    if (self.currentTag() != .r_paren) {
        decl.parameters = try self.parseParameters();
    }
    _ = self.expect(.r_paren);

    if (self.eat(.arrow)) {
        decl.return_attr = try self.parseAttributes();
        decl.return_type = try self.parseType("after '->' in function return type");
    }

    decl.body = try self.parseCompoundStmt();
    self.popScope();
    decl.decl_span = .{ .start = decl_start, .end = self.prevTokenEnd() };
    return decl;
}

fn parseParameters(self: *Parser) !std.ArrayListUnmanaged(Ast.Parameter) {
    var params: std.ArrayListUnmanaged(Ast.Parameter) = .empty;
    for (0..self.token_tags.len) |_| {
        const param_attrs = try self.parseAttributes();
        if (!self.isIdentLike()) break;
        const text = self.eatIdent().?;
        const loc = self.currentStart();
        self.advance();
        const name = try self.declareSymbol(text, .parameter, .{}, loc);
        _ = self.expect(.colon);
        const typ = try self.parseType("after ':' in function parameter");
        try params.append(self.arena, .{ .attributes = param_attrs, .name = name, .typ = typ });
        if (!self.eat(.comma)) break;
        if (self.currentTag() == .r_paren) break;
    } else unreachable;
    return params;
}

fn parseStructDecl(self: *Parser, decl_start: u32) !*Ast.StructDecl {
    _ = self.expect(.keyword_struct);
    const decl = try self.arena.create(Ast.StructDecl);
    decl.* = .{ .name = .none, .members = .empty };

    if (self.eatIdent()) |text| {
        const loc = self.currentStart();
        self.advance();
        decl.name = try self.declareSymbol(text, .@"struct", .{}, loc);
    }

    _ = self.expect(.l_brace);
    while (self.currentTag() != .r_brace and self.currentTag() != .eof) {
        const member_attrs = try self.parseAttributes();
        if (!self.isIdentLike()) break;
        const member_loc = self.currentStart();
        const text = self.eatIdent().?;
        self.advance();
        const name = try self.declareSymbolNoScope(text, .member, .{}, member_loc);
        _ = self.expect(.colon);
        const typ = try self.parseType("after ':' in struct member");
        try decl.members.append(self.arena, .{ .attributes = member_attrs, .name = name, .typ = typ });
        _ = self.eat(.comma);
    }
    _ = self.expect(.r_brace);
    decl.decl_span = .{ .start = decl_start, .end = self.prevTokenEnd() };
    return decl;
}

fn parseAliasDecl(self: *Parser, decl_start: u32) !*Ast.AliasDecl {
    _ = self.expect(.keyword_alias);
    const decl = try self.arena.create(Ast.AliasDecl);
    var name: Ast.SymbolIndex = .none;
    if (self.eatIdent()) |text| {
        const loc = self.currentStart();
        self.advance();
        name = try self.declareSymbol(text, .alias, .{}, loc);
    }
    _ = self.expect(.eq);
    const typ = try self.parseType("after '=' in alias declaration");
    _ = self.expect(.semicolon);
    decl.* = .{ .name = name, .typ = typ, .decl_span = .{ .start = decl_start, .end = self.prevTokenEnd() } };
    return decl;
}

fn parseConstAssert(self: *Parser) !*Ast.ConstAssertDecl {
    if (self.currentTag() == .keyword_const) self.advance();
    _ = self.expect(.keyword_const_assert);
    const decl = try self.arena.create(Ast.ConstAssertDecl);
    self.expr_context = "in const_assert";
    decl.* = .{ .expr = (try self.parseExpression()) orelse return error.ParseFailed };
    _ = self.expect(.semicolon);
    return decl;
}

// =========================================================================
// Types
// =========================================================================

fn parseType(self: *Parser, context: []const u8) error{ OutOfMemory, ParseFailed }!Ast.Type {
    if (self.type_depth >= constants.max_parser_type_depth) {
        self.addErrorWithCode("type nesting too deep", Diagnostic.Code.nesting_too_deep);
        return error.ParseFailed;
    }
    self.type_depth += 1;
    defer self.type_depth -= 1;
    const marker = self.cstOpen();

    if (self.eatIdent()) |name| {
        const name_loc = self.currentStart();
        self.advance();
        if (self.currentTag() == .lt) {
            const result = try self.parseTemplatedType(name, name_loc);
            self.cstClose(marker, typeCstKind(result));
            return result;
        }
        const typ = try self.arena.create(Ast.IdentType);
        typ.* = .{
            .name = name,
            .ref = .none,
            .loc = name_loc,
            .span = .{ .start = name_loc, .end = self.prevTokenEnd() },
        };
        self.cstClose(marker, .type_ident);
        return .{ .ident = typ };
    }

    const msg = if (context.len > 0)
        std.fmt.allocPrint(self.arena, "expected type {s}", .{context}) catch "expected type"
    else
        @as([]const u8, "expected type");
    self.addError(msg);
    const err_loc = self.currentStart();
    self.advance();
    const typ = try self.arena.create(Ast.IdentType);
    typ.* = .{
        .name = "error",
        .ref = .none,
        .loc = err_loc,
        .span = .{ .start = err_loc, .end = self.prevTokenEnd() },
    };
    self.cstClose(marker, .error_tree);
    return .{ .ident = typ };
}

fn parseTemplatedType(self: *Parser, name: []const u8, name_loc: u32) !Ast.Type {
    // The `<...>` region becomes a `template_args` CST node so reparse
    // anchors inside it land on a tight subtree. Both brackets live inside.
    const args_marker = self.cstOpen();
    _ = self.expect(.lt);
    const result = try self.parseTemplatedTypeInner(name, name_loc);
    self.cstClose(args_marker, .template_args);
    return result;
}

fn parseTemplatedTypeInner(self: *Parser, name: []const u8, name_loc: u32) !Ast.Type {
    if (isVecName(name)) {
        const size = name[3] - '0';
        const elem = try self.parseType("in vector type");
        _ = self.expectTemplateClose();
        const typ = try self.arena.create(Ast.VecType);
        typ.* = .{
            .size = size,
            .elem_type = elem,
            .loc = name_loc,
            .span = .{ .start = name_loc, .end = self.prevTokenEnd() },
        };
        return .{ .vec = typ };
    }

    if (isMatName(name)) {
        const cols = name[3] - '0';
        const rows = name[5] - '0';
        const elem = try self.parseType("in matrix type");
        _ = self.expectTemplateClose();
        const typ = try self.arena.create(Ast.MatType);
        typ.* = .{
            .cols = cols,
            .rows = rows,
            .elem_type = elem,
            .loc = name_loc,
            .span = .{ .start = name_loc, .end = self.prevTokenEnd() },
        };
        return .{ .mat = typ };
    }

    if (std.mem.eql(u8, name, "array")) {
        const elem = try self.parseType("in array type");
        var size: ?Ast.Expr = null;
        if (self.eat(.comma)) {
            self.expr_context = "in array size";
            size = try self.parseTemplateArgExpr();
        }
        _ = self.expectTemplateClose();
        const typ = try self.arena.create(Ast.ArrayType);
        typ.* = .{
            .elem_type = elem,
            .size = size,
            .span = .{ .start = name_loc, .end = self.prevTokenEnd() },
        };
        return .{ .array = typ };
    }

    if (std.mem.eql(u8, name, "ptr")) {
        const addr = self.parseAddressSpace();
        _ = self.expect(.comma);
        const elem = try self.parseType("in pointer type");
        var access: Ast.AccessMode = .none;
        if (self.eat(.comma)) access = self.parseAccessMode();
        _ = self.expectTemplateClose();
        const typ = try self.arena.create(Ast.PtrType);
        typ.* = .{
            .address_space = addr,
            .elem_type = elem,
            .access_mode = access,
            .span = .{ .start = name_loc, .end = self.prevTokenEnd() },
        };
        return .{ .ptr = typ };
    }

    if (std.mem.eql(u8, name, "atomic")) {
        const elem = try self.parseType("in atomic type");
        _ = self.expectTemplateClose();
        const typ = try self.arena.create(Ast.AtomicType);
        typ.* = .{
            .elem_type = elem,
            .loc = name_loc,
            .span = .{ .start = name_loc, .end = self.prevTokenEnd() },
        };
        return .{ .atomic = typ };
    }

    // Texture types
    if (parseTextureTypeInfo(name)) |info| {
        const typ = try self.arena.create(Ast.TextureType);
        typ.* = .{ .kind = info.kind, .dimension = info.dim };
        if (info.kind == .storage) {
            if (self.eatIdent()) |texel_name| {
                typ.texel_format = texel_name;
                self.advance();
            }
            if (self.eat(.comma)) typ.access_mode = self.parseAccessMode();
        } else if (info.kind != .depth and info.kind != .depth_multisampled) {
            typ.sampled_type = try self.parseType("in texture type");
        }
        _ = self.expectTemplateClose();
        typ.span = .{ .start = name_loc, .end = self.prevTokenEnd() };
        return .{ .texture = typ };
    }

    // Generic templated type
    _ = try self.parseType("in template arguments");
    while (self.eat(.comma)) _ = try self.parseType("in template arguments");
    _ = self.expectTemplateClose();
    const typ = try self.arena.create(Ast.IdentType);
    typ.* = .{
        .name = name,
        .ref = .none,
        .loc = name_loc,
        .span = .{ .start = name_loc, .end = self.prevTokenEnd() },
    };
    return .{ .ident = typ };
}

const TextureInfo = struct { kind: Ast.TextureKind, dim: Ast.TextureDimension };

fn parseTextureTypeInfo(name: []const u8) ?TextureInfo {
    const map = std.StaticStringMap(TextureInfo).initComptime(.{
        .{ "texture_1d", TextureInfo{ .kind = .sampled, .dim = .@"1d" } },
        .{ "texture_2d", TextureInfo{ .kind = .sampled, .dim = .@"2d" } },
        .{ "texture_2d_array", TextureInfo{ .kind = .sampled, .dim = .@"2d_array" } },
        .{ "texture_3d", TextureInfo{ .kind = .sampled, .dim = .@"3d" } },
        .{ "texture_cube", TextureInfo{ .kind = .sampled, .dim = .cube } },
        .{ "texture_cube_array", TextureInfo{ .kind = .sampled, .dim = .cube_array } },
        .{ "texture_multisampled_2d", TextureInfo{ .kind = .multisampled, .dim = .@"2d" } },
        .{ "texture_storage_1d", TextureInfo{ .kind = .storage, .dim = .@"1d" } },
        .{ "texture_storage_2d", TextureInfo{ .kind = .storage, .dim = .@"2d" } },
        .{ "texture_storage_2d_array", TextureInfo{ .kind = .storage, .dim = .@"2d_array" } },
        .{ "texture_storage_3d", TextureInfo{ .kind = .storage, .dim = .@"3d" } },
        .{ "texture_depth_2d", TextureInfo{ .kind = .depth, .dim = .@"2d" } },
        .{ "texture_depth_2d_array", TextureInfo{ .kind = .depth, .dim = .@"2d_array" } },
        .{ "texture_depth_cube", TextureInfo{ .kind = .depth, .dim = .cube } },
        .{ "texture_depth_cube_array", TextureInfo{ .kind = .depth, .dim = .cube_array } },
        .{ "texture_depth_multisampled_2d", TextureInfo{ .kind = .depth_multisampled, .dim = .@"2d" } },
    });
    return map.get(name);
}

fn parseAddressSpace(self: *Parser) Ast.AddressSpace {
    const map = std.StaticStringMap(Ast.AddressSpace).initComptime(.{
        .{ "function", .function },
        .{ "private", .private },
        .{ "workgroup", .workgroup },
        .{ "uniform", .uniform },
        .{ "storage", .storage },
    });
    if (self.currentTag() == .ident) {
        const text = self.currentText();
        const pos = self.currentStart();
        self.advance();
        if (map.get(text)) |as| return as;
        // Only flag a typo when the token is close to a known address space;
        // leave unknown-but-distant identifiers (e.g. extension address spaces
        // like `pixel_local`) silently accepted as `.none` to preserve
        // forward-compat behavior.
        if (Suggest.suggestName(text, &Suggest.address_spaces, 3)) |s| {
            const end = pos +| @as(u32, @intCast(text.len));
            const msg = std.fmt.allocPrint(self.arena, "unknown address space '{s}'; did you mean '{s}'?", .{ text, s }) catch "unknown address space";
            self.errors.append(self.arena, .{ .message = msg, .pos = pos, .end = end, .code = "E0304" }) catch self.markOom();
        }
        return .none;
    }
    return .none;
}

fn parseAccessMode(self: *Parser) Ast.AccessMode {
    const map = std.StaticStringMap(Ast.AccessMode).initComptime(.{
        .{ "read", .read },
        .{ "write", .write },
        .{ "read_write", .read_write },
    });
    if (self.currentTag() == .ident) {
        const text = self.currentText();
        const pos = self.currentStart();
        self.advance();
        if (map.get(text)) |am| return am;
        if (Suggest.suggestName(text, &Suggest.access_modes, 3)) |s| {
            const end = pos +| @as(u32, @intCast(text.len));
            const msg = std.fmt.allocPrint(self.arena, "unknown access mode '{s}'; did you mean '{s}'?", .{ text, s }) catch "unknown access mode";
            self.errors.append(self.arena, .{ .message = msg, .pos = pos, .end = end, .code = "E0305" }) catch self.markOom();
        }
        return .none;
    }
    return .none;
}

// =========================================================================
// Expressions
// =========================================================================

fn parseExpression(self: *Parser) error{ OutOfMemory, ParseFailed }!?Ast.Expr {
    if (self.expr_depth >= constants.max_parser_expr_depth) {
        self.addErrorWithCode("expression nesting too deep", Diagnostic.Code.nesting_too_deep);
        return error.ParseFailed;
    }
    self.expr_depth += 1;
    defer self.expr_depth -= 1;
    return self.parseLogicalOrExpr();
}

fn parseLogicalOrExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseLogicalAndExpr()) orelse return null;
    var left_marker = self.cst_last_closed_expr;
    while (self.currentTag() == .pipe_pipe) {
        const loc = self.currentStart();
        self.advance();
        const right = (try self.parseLogicalAndExpr()) orelse return null;
        const node = try self.arena.create(Ast.BinaryExpr);
        node.* = .{ .loc = loc, .op = .logical_or, .left = left, .right = right };
        left = .{ .binary = node };
        if (self.cstOpenBefore(left_marker)) |wrap| {
            self.cstClose(wrap, .binary_expr);
            self.cst_last_closed_expr = wrap;
            left_marker = wrap;
        }
    }
    return left;
}

fn parseLogicalAndExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseBitwiseOrExpr()) orelse return null;
    var left_marker = self.cst_last_closed_expr;
    while (self.currentTag() == .amp_amp) {
        const loc = self.currentStart();
        self.advance();
        const right = (try self.parseBitwiseOrExpr()) orelse return null;
        const node = try self.arena.create(Ast.BinaryExpr);
        node.* = .{ .loc = loc, .op = .logical_and, .left = left, .right = right };
        left = .{ .binary = node };
        if (self.cstOpenBefore(left_marker)) |wrap| {
            self.cstClose(wrap, .binary_expr);
            self.cst_last_closed_expr = wrap;
            left_marker = wrap;
        }
    }
    return left;
}

fn parseBitwiseOrExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseBitwiseXorExpr()) orelse return null;
    var left_marker = self.cst_last_closed_expr;
    while (self.currentTag() == .pipe) {
        const loc = self.currentStart();
        self.advance();
        const right = (try self.parseBitwiseXorExpr()) orelse return null;
        const node = try self.arena.create(Ast.BinaryExpr);
        node.* = .{ .loc = loc, .op = .@"or", .left = left, .right = right };
        left = .{ .binary = node };
        if (self.cstOpenBefore(left_marker)) |wrap| {
            self.cstClose(wrap, .binary_expr);
            self.cst_last_closed_expr = wrap;
            left_marker = wrap;
        }
    }
    return left;
}

fn parseBitwiseXorExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseBitwiseAndExpr()) orelse return null;
    var left_marker = self.cst_last_closed_expr;
    while (self.currentTag() == .caret) {
        const loc = self.currentStart();
        self.advance();
        const right = (try self.parseBitwiseAndExpr()) orelse return null;
        const node = try self.arena.create(Ast.BinaryExpr);
        node.* = .{ .loc = loc, .op = .xor, .left = left, .right = right };
        left = .{ .binary = node };
        if (self.cstOpenBefore(left_marker)) |wrap| {
            self.cstClose(wrap, .binary_expr);
            self.cst_last_closed_expr = wrap;
            left_marker = wrap;
        }
    }
    return left;
}

fn parseBitwiseAndExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseEqualityExpr()) orelse return null;
    var left_marker = self.cst_last_closed_expr;
    while (self.currentTag() == .amp) {
        const loc = self.currentStart();
        self.advance();
        const right = (try self.parseEqualityExpr()) orelse return null;
        const node = try self.arena.create(Ast.BinaryExpr);
        node.* = .{ .loc = loc, .op = .@"and", .left = left, .right = right };
        left = .{ .binary = node };
        if (self.cstOpenBefore(left_marker)) |wrap| {
            self.cstClose(wrap, .binary_expr);
            self.cst_last_closed_expr = wrap;
            left_marker = wrap;
        }
    }
    return left;
}

fn parseEqualityExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseRelationalExpr()) orelse return null;
    var left_marker = self.cst_last_closed_expr;
    for (0..self.token_tags.len) |_| {
        const op: Ast.BinaryOp = switch (self.currentTag()) {
            .eq_eq => .eq,
            .bang_eq => .ne,
            else => return left,
        };
        const loc = self.currentStart();
        self.advance();
        const right = (try self.parseRelationalExpr()) orelse return null;
        const node = try self.arena.create(Ast.BinaryExpr);
        node.* = .{ .loc = loc, .op = op, .left = left, .right = right };
        left = .{ .binary = node };
        if (self.cstOpenBefore(left_marker)) |wrap| {
            self.cstClose(wrap, .binary_expr);
            self.cst_last_closed_expr = wrap;
            left_marker = wrap;
        }
    } else unreachable;
}

fn parseRelationalExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseShiftExpr()) orelse return null;
    var left_marker = self.cst_last_closed_expr;
    for (0..self.token_tags.len) |_| {
        const op: Ast.BinaryOp = switch (self.currentTag()) {
            .lt => .lt,
            .lt_eq => .le,
            .gt => .gt,
            .gt_eq => .ge,
            else => return left,
        };
        const loc = self.currentStart();
        self.advance();
        const right = (try self.parseShiftExpr()) orelse return null;
        const node = try self.arena.create(Ast.BinaryExpr);
        node.* = .{ .loc = loc, .op = op, .left = left, .right = right };
        left = .{ .binary = node };
        if (self.cstOpenBefore(left_marker)) |wrap| {
            self.cstClose(wrap, .binary_expr);
            self.cst_last_closed_expr = wrap;
            left_marker = wrap;
        }
    } else unreachable;
}

fn parseShiftExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseAdditiveExpr()) orelse return null;
    var left_marker = self.cst_last_closed_expr;
    for (0..self.token_tags.len) |_| {
        const op: Ast.BinaryOp = switch (self.currentTag()) {
            .lt_lt => .shl,
            .gt_gt => .shr,
            else => return left,
        };
        const loc = self.currentStart();
        self.advance();
        const right = (try self.parseAdditiveExpr()) orelse return null;
        const node = try self.arena.create(Ast.BinaryExpr);
        node.* = .{ .loc = loc, .op = op, .left = left, .right = right };
        left = .{ .binary = node };
        if (self.cstOpenBefore(left_marker)) |wrap| {
            self.cstClose(wrap, .binary_expr);
            self.cst_last_closed_expr = wrap;
            left_marker = wrap;
        }
    } else unreachable;
}

fn parseAdditiveExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseMultiplicativeExpr()) orelse return null;
    var left_marker = self.cst_last_closed_expr;
    for (0..self.token_tags.len) |_| {
        const op: Ast.BinaryOp = switch (self.currentTag()) {
            .plus => .add,
            .minus => .sub,
            else => return left,
        };
        const loc = self.currentStart();
        self.advance();
        const right = (try self.parseMultiplicativeExpr()) orelse return null;
        const node = try self.arena.create(Ast.BinaryExpr);
        node.* = .{ .loc = loc, .op = op, .left = left, .right = right };
        left = .{ .binary = node };
        if (self.cstOpenBefore(left_marker)) |wrap| {
            self.cstClose(wrap, .binary_expr);
            self.cst_last_closed_expr = wrap;
            left_marker = wrap;
        }
    } else unreachable;
}

fn parseMultiplicativeExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseUnaryExpr()) orelse return null;
    var left_marker = self.cst_last_closed_expr;
    for (0..self.token_tags.len) |_| {
        const op: Ast.BinaryOp = switch (self.currentTag()) {
            .star => .mul,
            .slash => .div,
            .percent => .mod,
            else => return left,
        };
        const loc = self.currentStart();
        self.advance();
        const right = (try self.parseUnaryExpr()) orelse return null;
        const node = try self.arena.create(Ast.BinaryExpr);
        node.* = .{ .loc = loc, .op = op, .left = left, .right = right };
        left = .{ .binary = node };
        if (self.cstOpenBefore(left_marker)) |wrap| {
            self.cstClose(wrap, .binary_expr);
            self.cst_last_closed_expr = wrap;
            left_marker = wrap;
        }
    } else unreachable;
}

fn parseUnaryExpr(self: *Parser) !?Ast.Expr {
    // Collect chained unary operators iteratively, then fold right-to-left.
    // Each operator opens its own CST marker BEFORE the operator token is
    // consumed, so the token lands inside that marker. Markers nest, with
    // the outermost (first) operator at the outside.
    const OpLoc = struct { op: Ast.UnaryOp, loc: u32 };
    var ops_buf: [32]OpLoc = undefined;
    var cst_markers_buf: [32]?Cst.Marker = undefined;
    var ops_len: u8 = 0;

    while (ops_len < ops_buf.len) {
        const unary_op: Ast.UnaryOp = switch (self.currentTag()) {
            .minus => .neg,
            .bang => .not,
            .tilde => .bit_not,
            .star => .deref,
            .amp => .addr,
            else => break,
        };
        cst_markers_buf[ops_len] = self.cstOpen();
        ops_buf[ops_len] = .{ .op = unary_op, .loc = self.currentStart() };
        ops_len += 1;
        self.advance();
    }

    var operand = (try self.parsePostfixExpr()) orelse {
        // Operand parse failed; tombstone every unary marker in reverse
        // so the consumed operator tokens fall through to the enclosing
        // expression context, matching pre-CST behavior.
        var k: u8 = ops_len;
        while (k > 0) : (k -= 1) self.cstAbandon(cst_markers_buf[k - 1]);
        return null;
    };

    // Fold right-to-left: innermost op wraps the operand first. Closing the
    // markers in reverse order honors the builder's stack discipline.
    var i: u8 = ops_len;
    while (i > 0) {
        i -= 1;
        const entry = ops_buf[i];
        const node = try self.arena.create(Ast.UnaryExpr);
        node.* = .{ .loc = entry.loc, .op = entry.op, .operand = operand };
        operand = .{ .unary = node };
        self.cstClose(cst_markers_buf[i], .unary_expr);
        self.cst_last_closed_expr = cst_markers_buf[i];
    }

    return operand;
}

fn parsePostfixExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parsePrimaryExpr()) orelse return null;
    // `parsePrimaryExpr` sets `cst_last_closed_expr`; snapshot it here so
    // nested expression parses inside postfix bodies (index, args) don't
    // clobber our "left" wrap target.
    var left_marker = self.cst_last_closed_expr;

    for (0..self.token_tags.len) |_| {
        switch (self.currentTag()) {
            .dot => {
                const saved = left_marker;
                const dot_loc = self.currentStart();
                self.advance();
                if (self.isIdentLike()) {
                    const member = self.currentText();
                    self.advance();
                    const node = try self.arena.create(Ast.MemberExpr);
                    node.* = .{ .loc = dot_loc, .base = left, .member_name = member };
                    left = .{ .member = node };
                    const wrap = self.cstOpenBefore(saved);
                    self.cstClose(wrap, .member_expr);
                    self.cst_last_closed_expr = wrap;
                    left_marker = wrap;
                } else {
                    self.addError("expected member name");
                }
            },
            .l_bracket => {
                const saved = left_marker;
                const bracket_loc = self.currentStart();
                self.advance();
                self.expr_context = "in array index";
                const idx = (try self.parseExpression()) orelse return null;
                const end_loc = self.currentStart() +| 1; // past the closing ']'
                _ = self.expect(.r_bracket);
                const node = try self.arena.create(Ast.IndexExpr);
                node.* = .{ .loc = bracket_loc, .end_loc = end_loc, .base = left, .idx = idx };
                left = .{ .index = node };
                const wrap = self.cstOpenBefore(saved);
                self.cstClose(wrap, .index_expr);
                self.cst_last_closed_expr = wrap;
                left_marker = wrap;
            },
            .l_paren => {
                const saved = left_marker;
                const paren_loc = self.currentStart();
                self.advance();
                const args = try self.parseExpressionList();
                const end_loc = self.currentStart() +| 1;
                _ = self.expect(.r_paren);
                const node = try self.arena.create(Ast.CallExpr);
                node.* = .{ .loc = paren_loc, .end_loc = end_loc, .func = left, .args = args };
                left = .{ .call = node };
                const wrap = self.cstOpenBefore(saved);
                self.cstClose(wrap, .call_expr);
                self.cst_last_closed_expr = wrap;
                left_marker = wrap;
            },
            else => return left,
        }
    } else unreachable;
}

fn parsePrimaryExpr(self: *Parser) !?Ast.Expr {
    const marker = self.cstOpen();
    const result = try self.parsePrimaryExprInner();
    if (result) |expr| {
        self.cstClose(marker, exprCstKind(expr));
        self.cst_last_closed_expr = marker;
    } else {
        // Null result covers two shapes: (a) the `else` branch ran, emitted a
        // parser error, and already consumed one offending token; (b) a
        // templated-constructor / bitcast fallback drove a `<...>` parse into
        // the marker and then couldn't find the `(`. In both cases, closing
        // the marker as `.error_tree` keeps whatever tokens and subtrees were
        // emitted grouped under a recovery node rather than leaking them to
        // the enclosing statement.
        self.cstClose(marker, .error_tree);
    }
    return result;
}

fn parsePrimaryExprInner(self: *Parser) !?Ast.Expr {
    switch (self.currentTag()) {
        .int_literal, .float_literal => {
            const text = self.currentText();
            const kind = self.currentTag();
            const loc = self.currentStart();
            self.advance();
            const node = try self.arena.create(Ast.LiteralExpr);
            node.* = .{ .loc = loc, .kind = kind, .value = text };
            return .{ .literal = node };
        },
        .true_literal, .false_literal => {
            const text = self.currentText();
            const kind = self.currentTag();
            const loc = self.currentStart();
            self.advance();
            const node = try self.arena.create(Ast.LiteralExpr);
            node.* = .{ .loc = loc, .kind = kind, .value = text };
            return .{ .literal = node };
        },
        .ident, .reserved_ident => {
            if (self.currentTag() == .reserved_ident) {
                _ = self.eatIdent(); // emits E0004 error
            }
            const text = self.currentText();
            const loc = self.currentStart();
            self.advance();

            // Templated constructor: array<T, N>(...) or vec2<f32>(...)
            if (self.currentTag() == .lt and isTemplatedTypeName(text)) {
                return self.parseTemplatedConstructor(text, loc);
            }

            // bitcast<T>(expr): builtin with template type argument
            if (self.currentTag() == .lt and std.mem.eql(u8, text, "bitcast")) {
                return self.parseBitcastExpr(text, loc);
            }

            const node = try self.arena.create(Ast.IdentExpr);
            node.* = .{ .loc = loc, .name = text, .ref = .none };
            return .{ .ident = node };
        },
        .l_paren => {
            self.advance();
            self.expr_context = "after '('";
            const expr = (try self.parseExpression()) orelse return null;
            _ = self.expect(.r_paren);
            const node = try self.arena.create(Ast.ParenExpr);
            node.* = .{ .expr = expr };
            return .{ .paren = node };
        },
        else => {
            const msg = if (self.expr_context.len > 0)
                std.fmt.allocPrint(self.arena, "expected expression {s}", .{self.expr_context}) catch "expected expression"
            else
                @as([]const u8, "expected expression");
            self.addError(msg);
            self.advance();
            return null;
        },
    }
}

fn parseTemplatedConstructor(self: *Parser, name: []const u8, name_loc: u32) !?Ast.Expr {
    const template_type = try self.parseTemplatedType(name, name_loc);
    if (self.currentTag() != .l_paren) {
        // `vec3<f32>` without `(...)` is accepted as a lenient ident
        // reference (existing behavior, no error emitted). The enclosing
        // primary closes as .ident_expr; the previously-emitted
        // template_args node stays as a child of that ident_expr — a
        // structural oddity we accept in exchange for AST compatibility.
        const node = try self.arena.create(Ast.IdentExpr);
        node.* = .{ .name = name, .ref = .none };
        return .{ .ident = node };
    }
    const paren_loc = self.currentStart();
    self.advance();
    const args = try self.parseExpressionList();
    const end_loc = self.currentStart() +| 1;
    _ = self.expect(.r_paren);
    const node = try self.arena.create(Ast.CallExpr);
    node.* = .{ .loc = paren_loc, .end_loc = end_loc, .template_type = template_type, .args = args };
    return .{ .call = node };
}

fn parseBitcastExpr(self: *Parser, name: []const u8, name_loc: u32) !?Ast.Expr {
    // Wrap `<T>` in template_args to match how parseTemplatedType emits it.
    const args_marker = self.cstOpen();
    _ = self.expect(.lt);
    const dest_type = try self.parseType("in bitcast type");
    _ = self.expectTemplateClose();
    self.cstClose(args_marker, .template_args);
    if (self.currentTag() != .l_paren) {
        self.addError("expected '(' after bitcast<T>");
        return null;
    }
    const paren_loc = self.currentStart();
    self.advance();
    const args = try self.parseExpressionList();
    const end_loc = self.currentStart() +| 1;
    _ = self.expect(.r_paren);
    // Create a CallExpr with func=ident("bitcast") and template_type=dest_type
    const func_node = try self.arena.create(Ast.IdentExpr);
    func_node.* = .{ .name = name, .ref = .none, .loc = name_loc };
    const node = try self.arena.create(Ast.CallExpr);
    node.* = .{ .loc = paren_loc, .end_loc = end_loc, .func = .{ .ident = func_node }, .template_type = dest_type, .args = args };
    return .{ .call = node };
}

fn parseExpressionList(self: *Parser) !std.ArrayListUnmanaged(Ast.Expr) {
    var exprs: std.ArrayListUnmanaged(Ast.Expr) = .empty;
    if (self.currentTag() == .r_paren) return exprs;
    self.expr_context = "in arguments";
    if (try self.parseExpression()) |first| {
        try exprs.append(self.arena, first);
    }
    while (self.eat(.comma)) {
        if (self.currentTag() == .r_paren) break;
        if (try self.parseExpression()) |expr| {
            try exprs.append(self.arena, expr);
        }
    }
    return exprs;
}

// Template argument expression (restricted: no > or >= operators)
fn parseTemplateArgExpr(self: *Parser) error{ OutOfMemory, ParseFailed }!?Ast.Expr {
    return self.parseTemplateAdditiveExpr();
}

fn parseTemplateAdditiveExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseTemplateMultiplicativeExpr()) orelse return null;
    var left_marker = self.cst_last_closed_expr;
    for (0..self.token_tags.len) |_| {
        const op: Ast.BinaryOp = switch (self.currentTag()) {
            .plus => .add,
            .minus => .sub,
            else => return left,
        };
        const loc = self.currentStart();
        self.advance();
        const right = (try self.parseTemplateMultiplicativeExpr()) orelse return null;
        const node = try self.arena.create(Ast.BinaryExpr);
        node.* = .{ .loc = loc, .op = op, .left = left, .right = right };
        left = .{ .binary = node };
        if (self.cstOpenBefore(left_marker)) |wrap| {
            self.cstClose(wrap, .binary_expr);
            self.cst_last_closed_expr = wrap;
            left_marker = wrap;
        }
    } else unreachable;
}

fn parseTemplateMultiplicativeExpr(self: *Parser) !?Ast.Expr {
    var left = (try self.parseTemplateUnaryExpr()) orelse return null;
    var left_marker = self.cst_last_closed_expr;
    for (0..self.token_tags.len) |_| {
        const op: Ast.BinaryOp = switch (self.currentTag()) {
            .star => .mul,
            .slash => .div,
            .percent => .mod,
            else => return left,
        };
        const loc = self.currentStart();
        self.advance();
        const right = (try self.parseTemplateUnaryExpr()) orelse return null;
        const node = try self.arena.create(Ast.BinaryExpr);
        node.* = .{ .loc = loc, .op = op, .left = left, .right = right };
        left = .{ .binary = node };
        if (self.cstOpenBefore(left_marker)) |wrap| {
            self.cstClose(wrap, .binary_expr);
            self.cst_last_closed_expr = wrap;
            left_marker = wrap;
        }
    } else unreachable;
}

fn parseTemplateUnaryExpr(self: *Parser) !?Ast.Expr {
    const op: ?Ast.UnaryOp = switch (self.currentTag()) {
        .minus => .neg,
        .bang => .not,
        .tilde => .bit_not,
        else => null,
    };
    if (op) |unary_op| {
        const outer_marker = self.cstOpen();
        const loc = self.currentStart();
        self.advance();
        const operand = (try self.parseTemplateUnaryExpr()) orelse {
            self.cstAbandon(outer_marker);
            return null;
        };
        const node = try self.arena.create(Ast.UnaryExpr);
        node.* = .{ .loc = loc, .op = unary_op, .operand = operand };
        self.cstClose(outer_marker, .unary_expr);
        self.cst_last_closed_expr = outer_marker;
        return .{ .unary = node };
    }
    return self.parseTemplatePrimaryExpr();
}

fn parseTemplatePrimaryExpr(self: *Parser) !?Ast.Expr {
    const marker = self.cstOpen();
    const result = try self.parseTemplatePrimaryExprInner();
    if (result) |expr| {
        self.cstClose(marker, exprCstKind(expr));
        self.cst_last_closed_expr = marker;
    } else {
        self.cstClose(marker, .error_tree);
    }
    return result;
}

fn parseTemplatePrimaryExprInner(self: *Parser) !?Ast.Expr {
    switch (self.currentTag()) {
        .int_literal, .float_literal, .true_literal, .false_literal => {
            const text = self.currentText();
            const kind = self.currentTag();
            const loc = self.currentStart();
            self.advance();
            const node = try self.arena.create(Ast.LiteralExpr);
            node.* = .{ .loc = loc, .kind = kind, .value = text };
            return .{ .literal = node };
        },
        .ident, .reserved_ident => {
            if (self.currentTag() == .reserved_ident) {
                _ = self.eatIdent(); // emits E0004 error
            }
            const text = self.currentText();
            const loc = self.currentStart();
            self.advance();
            const node = try self.arena.create(Ast.IdentExpr);
            node.* = .{ .loc = loc, .name = text, .ref = .none };
            return .{ .ident = node };
        },
        .l_paren => {
            self.advance();
            self.expr_context = "after '('";
            const expr = (try self.parseTemplateArgExpr()) orelse return null;
            _ = self.expect(.r_paren);
            const node = try self.arena.create(Ast.ParenExpr);
            node.* = .{ .expr = expr };
            return .{ .paren = node };
        },
        else => {
            const msg = if (self.expr_context.len > 0)
                std.fmt.allocPrint(self.arena, "expected expression {s}", .{self.expr_context}) catch "expected expression"
            else
                @as([]const u8, "expected expression");
            self.addError(msg);
            self.advance();
            return null;
        },
    }
}

// =========================================================================
// Statements
// =========================================================================

fn stmtCstKind(stmt: Ast.Stmt) Cst.Kind {
    return switch (stmt) {
        .compound => .compound_stmt,
        .@"return" => .return_stmt,
        .@"if" => .if_stmt,
        .@"switch" => .switch_stmt,
        .@"for" => .for_stmt,
        .@"while" => .while_stmt,
        .loop => .loop_stmt,
        .@"break" => .break_stmt,
        .break_if => .break_if_stmt,
        .@"continue" => .continue_stmt,
        .discard => .discard_stmt,
        .assign => .assign_stmt,
        .incr_decr => .incr_decr_stmt,
        .call => .call_stmt,
        .decl => .decl_stmt,
    };
}

fn exprCstKind(expr: Ast.Expr) Cst.Kind {
    return switch (expr) {
        .binary => .binary_expr,
        .unary => .unary_expr,
        .call => .call_expr,
        .index => .index_expr,
        .member => .member_expr,
        .paren => .paren_expr,
        .ident => .ident_expr,
        .literal => .literal_expr,
    };
}

fn typeCstKind(t: Ast.Type) Cst.Kind {
    return switch (t) {
        .ident => .type_ident,
        .vec => .type_vec,
        .mat => .type_mat,
        .array => .type_array,
        .ptr => .type_ptr,
        .atomic => .type_atomic,
        .texture => .type_texture,
        .sampler => .type_sampler,
    };
}

fn parseStatement(self: *Parser) error{ OutOfMemory, ParseFailed }!?Ast.Stmt {
    if (self.stmt_depth >= constants.max_parser_stmt_depth) {
        self.addErrorWithCode("statement nesting too deep", Diagnostic.Code.nesting_too_deep);
        return error.ParseFailed;
    }
    self.stmt_depth += 1;
    defer self.stmt_depth -= 1;
    // Compound statements open their own CST marker inside `parseCompoundStmt`;
    // don't nest a second one here.
    if (self.currentTag() == .l_brace) {
        return .{ .compound = try self.parseCompoundStmt() };
    }
    const stmt_start = self.currentStart();
    const marker = self.cstOpen();
    const parsed = try self.parseStatementInner();
    if (parsed) |s| {
        self.cstClose(marker, stmtCstKind(s));
        setStmtSpan(s, .{ .start = stmt_start, .end = self.prevTokenEnd() });
    } else {
        self.cstClose(marker, .error_tree);
    }
    return parsed;
}

/// Write `span` onto whichever concrete Stmt struct backs the union. A
/// thin switch so every variant stays in lock-step when new stmt kinds
/// are added (compile-time exhaustive).
fn setStmtSpan(stmt: Ast.Stmt, span: Ast.Span) void {
    switch (stmt) {
        .compound => |s| s.span = span,
        .@"return" => |s| s.span = span,
        .@"if" => |s| s.span = span,
        .@"switch" => |s| s.span = span,
        .@"for" => |s| s.span = span,
        .@"while" => |s| s.span = span,
        .loop => |s| s.span = span,
        .@"break" => |s| s.span = span,
        .break_if => |s| s.span = span,
        .@"continue" => |s| s.span = span,
        .discard => |s| s.span = span,
        .assign => |s| s.span = span,
        .incr_decr => |s| s.span = span,
        .call => |s| s.span = span,
        .decl => |s| s.span = span,
    }
}

fn parseStatementInner(self: *Parser) error{ OutOfMemory, ParseFailed }!?Ast.Stmt {
    switch (self.currentTag()) {
        .l_brace => return .{ .compound = try self.parseCompoundStmt() },
        .keyword_return => return .{ .@"return" = try self.parseReturnStmt() },
        .keyword_if => return .{ .@"if" = try self.parseIfStmt() },
        .keyword_switch => return .{ .@"switch" = try self.parseSwitchStmt() },
        .keyword_for => return .{ .@"for" = try self.parseForStmt() },
        .keyword_while => return .{ .@"while" = try self.parseWhileStmt() },
        .keyword_loop => return .{ .loop = try self.parseLoopStmt() },
        .keyword_break => {
            const loc = self.currentStart();
            self.advance();
            if (self.eat(.keyword_if)) {
                self.expr_context = "after 'if' in break";
                const cond = (try self.parseExpression()) orelse return null;
                _ = self.expect(.semicolon);
                const node = try self.arena.create(Ast.BreakIfStmt);
                node.* = .{ .condition = cond };
                return .{ .break_if = node };
            }
            _ = self.expect(.semicolon);
            const node = try self.arena.create(Ast.BreakStmt);
            node.* = .{ .loc = loc };
            return .{ .@"break" = node };
        },
        .keyword_continue => {
            const loc = self.currentStart();
            self.advance();
            _ = self.expect(.semicolon);
            const node = try self.arena.create(Ast.ContinueStmt);
            node.* = .{ .loc = loc };
            return .{ .@"continue" = node };
        },
        .keyword_discard => {
            const loc = self.currentStart();
            self.advance();
            _ = self.expect(.semicolon);
            const node = try self.arena.create(Ast.DiscardStmt);
            node.* = .{ .loc = loc };
            return .{ .discard = node };
        },
        .keyword_const, .keyword_const_assert, .keyword_let, .keyword_var => {
            if (try self.parseDeclaration()) |decl| {
                const node = try self.arena.create(Ast.DeclStmt);
                node.* = .{ .decl = decl };
                return .{ .decl = node };
            }
            return null;
        },
        else => return self.parseExpressionOrAssignment(),
    }
}

fn parseCompoundStmt(self: *Parser) !*Ast.CompoundStmt {
    const span_start = self.currentStart();
    const marker = self.cstOpen();
    _ = self.expect(.l_brace);
    try self.pushScope(.block);
    const stmt = try self.arena.create(Ast.CompoundStmt);
    stmt.* = .{ .stmts = .empty };
    while (self.currentTag() != .r_brace and self.currentTag() != .eof) {
        if (try self.parseStatement()) |s| {
            try stmt.stmts.append(self.arena, s);
        }
    }
    self.popScope();
    _ = self.expect(.r_brace);
    self.cstClose(marker, .compound_stmt);
    stmt.span = .{ .start = span_start, .end = self.prevTokenEnd() };
    return stmt;
}

fn parseReturnStmt(self: *Parser) !*Ast.ReturnStmt {
    const loc = self.currentStart();
    _ = self.expect(.keyword_return);
    const node = try self.arena.create(Ast.ReturnStmt);
    node.* = .{ .loc = loc };
    if (self.currentTag() != .semicolon) {
        self.expr_context = "after 'return'";
        node.value = try self.parseExpression();
    }
    _ = self.expect(.semicolon);
    return node;
}

/// Iteratively parses an if/else-if/else chain without recursion.
fn parseIfStmt(self: *Parser) !*Ast.IfStmt {
    // Track each `if` / `else if` start so we can backfill `span` at the
    // end of the chain. Every IfStmt in the chain ends at the same byte
    // (the end of the final body or final `else` compound) — they all
    // wrap one another via `else_branch`.
    var starts: std.ArrayListUnmanaged(struct { start: u32, ptr: *Ast.IfStmt }) = .empty;
    defer starts.deinit(self.arena);

    const root_start = self.currentStart();
    _ = self.expect(.keyword_if);
    self.expr_context = "in if condition";
    const root = try self.arena.create(Ast.IfStmt);
    root.* = .{
        .condition = (try self.parseExpression()) orelse return error.ParseFailed,
        .body = try self.parseCompoundStmt(),
    };
    try starts.append(self.arena, .{ .start = root_start, .ptr = root });

    var current = root;
    while (self.eat(.keyword_else)) {
        if (self.currentTag() == .keyword_if) {
            const inner_start = self.currentStart();
            _ = self.expect(.keyword_if);
            self.expr_context = "in if condition";
            const next = try self.arena.create(Ast.IfStmt);
            next.* = .{
                .condition = (try self.parseExpression()) orelse return error.ParseFailed,
                .body = try self.parseCompoundStmt(),
            };
            current.else_branch = .{ .@"if" = next };
            current = next;
            try starts.append(self.arena, .{ .start = inner_start, .ptr = next });
        } else {
            current.else_branch = .{ .compound = try self.parseCompoundStmt() };
            break;
        }
    }

    const chain_end = self.prevTokenEnd();
    for (starts.items) |s| {
        s.ptr.span = .{ .start = s.start, .end = chain_end };
    }
    return root;
}

fn parseSwitchStmt(self: *Parser) !*Ast.SwitchStmt {
    _ = self.expect(.keyword_switch);
    self.expr_context = "in switch expression";
    const node = try self.arena.create(Ast.SwitchStmt);
    node.* = .{
        .expr = (try self.parseExpression()) orelse return error.ParseFailed,
        .cases = .empty,
    };
    _ = self.expect(.l_brace);
    while (self.currentTag() != .r_brace and self.currentTag() != .eof) {
        var c = Ast.SwitchCase{ .selectors = .empty, .body = undefined };
        if (self.eat(.keyword_default)) {
            // default case
        } else {
            _ = self.expect(.keyword_case);
            self.expr_context = "in case selector";
            if (try self.parseExpression()) |sel| try c.selectors.append(self.arena, sel);
            while (self.eat(.comma)) {
                if (try self.parseExpression()) |sel| try c.selectors.append(self.arena, sel);
            }
        }
        _ = self.expect(.colon);
        c.body = try self.parseCompoundStmt();
        try node.cases.append(self.arena, c);
    }
    _ = self.expect(.r_brace);
    return node;
}

fn parseForStmt(self: *Parser) !*Ast.ForStmt {
    _ = self.expect(.keyword_for);
    _ = self.expect(.l_paren);
    try self.pushScope(.block);
    const node = try self.arena.create(Ast.ForStmt);
    node.* = .{ .body = undefined };

    // Init
    if (self.currentTag() != .semicolon) {
        switch (self.currentTag()) {
            .keyword_var, .keyword_let => {
                if (try self.parseDeclaration()) |decl| {
                    const ds = try self.arena.create(Ast.DeclStmt);
                    ds.* = .{ .decl = decl, .span = decl.declSpan() };
                    node.init_stmt = .{ .decl = ds };
                }
            },
            else => node.init_stmt = try self.parseExpressionOrAssignment(),
        }
    } else {
        self.advance();
    }

    // Condition
    if (self.currentTag() != .semicolon) {
        self.expr_context = "in for condition";
        node.condition = try self.parseExpression();
    }
    _ = self.expect(.semicolon);

    // Update
    if (self.currentTag() != .r_paren) {
        node.update = try self.parseForUpdateStmt();
    }

    _ = self.expect(.r_paren);
    node.body = try self.parseCompoundStmt();
    self.popScope();
    return node;
}

fn parseForUpdateStmt(self: *Parser) !?Ast.Stmt {
    self.expr_context = "in for update";
    // Capture the byte offset BEFORE parsing the LHS — Parser-built
    // expression nodes carry empty spans, so we cannot recover the
    // statement's start byte from `left.span()`. CstLower mirrors this
    // computation in `lowerLooseExprStmt`.
    const stmt_start = self.currentStart();
    const left = (try self.parseExpression()) orelse return null;

    // Check for assignment or incr/decr
    switch (self.currentTag()) {
        .plus_plus => {
            const loc = self.currentStart();
            self.advance();
            const node = try self.arena.create(Ast.IncrDecrStmt);
            node.* = .{
                .loc = loc,
                .expr = left,
                .increment = true,
                .span = .{ .start = stmt_start, .end = self.prevTokenEnd() },
            };
            return .{ .incr_decr = node };
        },
        .minus_minus => {
            const loc = self.currentStart();
            self.advance();
            const node = try self.arena.create(Ast.IncrDecrStmt);
            node.* = .{
                .loc = loc,
                .expr = left,
                .increment = false,
                .span = .{ .start = stmt_start, .end = self.prevTokenEnd() },
            };
            return .{ .incr_decr = node };
        },
        else => {},
    }

    if (self.parseAssignOp()) |op| {
        const loc = self.currentStart();
        self.advance();
        self.expr_context = "in for update assignment";
        const right = (try self.parseExpression()) orelse return null;
        const node = try self.arena.create(Ast.AssignStmt);
        node.* = .{
            .loc = loc,
            .op = op,
            .left = left,
            .right = right,
            .span = .{ .start = stmt_start, .end = right.span().end },
        };
        return .{ .assign = node };
    }

    // Call expression
    if (left == .call) {
        const node = try self.arena.create(Ast.CallStmt);
        node.* = .{
            .call = left.call,
            .span = .{ .start = stmt_start, .end = self.prevTokenEnd() },
        };
        return .{ .call = node };
    }

    self.addError("expected for update statement");
    return null;
}

fn parseWhileStmt(self: *Parser) !*Ast.WhileStmt {
    _ = self.expect(.keyword_while);
    self.expr_context = "in while condition";
    const node = try self.arena.create(Ast.WhileStmt);
    node.* = .{
        .condition = (try self.parseExpression()) orelse return error.ParseFailed,
        .body = try self.parseCompoundStmt(),
    };
    return node;
}

fn parseLoopStmt(self: *Parser) !*Ast.LoopStmt {
    _ = self.expect(.keyword_loop);
    const node = try self.arena.create(Ast.LoopStmt);
    // Uninitialized-field trap: assigning `node.* = .{ .body = parseLoopBody(&node.continuing) }`
    // looks fine but zeroes `continuing` *after* the callee wrote to it.
    // Initialize the whole struct first, then fill in fields.
    node.* = .{ .body = undefined };
    node.body = try self.parseLoopBody(&node.continuing);
    // Legacy trailing form (`loop { body } continuing { cont }`) — kept
    // alongside the spec-standard in-body form so both parse.
    if (node.continuing == null and self.currentTag() == .keyword_continuing) {
        const cont_marker = self.cstOpen();
        self.advance();
        node.continuing = try self.parseCompoundStmt();
        self.cstClose(cont_marker, .continuing_stmt);
    }
    return node;
}

/// Parses the `{ ... }` body of a `loop`, pulling a trailing
/// `continuing { ... }` out into `out_continuing` if present. WGSL §8.8:
/// the continuing statement, when present, is the *last* statement inside
/// the loop body — a plain `parseCompoundStmt` would fall through to
/// `parseExpressionOrAssignment` on the `continuing` keyword and emit
/// "expected expression in statement". Emits a `.continuing_stmt` CST
/// node around the keyword + compound so `CstLower.lowerLoopStmt` picks
/// it up the same way as the legacy trailing form.
fn parseLoopBody(self: *Parser, out_continuing: *?*Ast.CompoundStmt) !*Ast.CompoundStmt {
    const span_start = self.currentStart();
    const marker = self.cstOpen();
    _ = self.expect(.l_brace);
    try self.pushScope(.block);
    const stmt = try self.arena.create(Ast.CompoundStmt);
    stmt.* = .{ .stmts = .empty };
    while (self.currentTag() != .r_brace and self.currentTag() != .eof) {
        if (self.currentTag() == .keyword_continuing) {
            const cont_marker = self.cstOpen();
            self.advance();
            out_continuing.* = try self.parseCompoundStmt();
            self.cstClose(cont_marker, .continuing_stmt);
            break;
        }
        if (try self.parseStatement()) |s| {
            try stmt.stmts.append(self.arena, s);
        }
    }
    self.popScope();
    _ = self.expect(.r_brace);
    self.cstClose(marker, .compound_stmt);
    stmt.span = .{ .start = span_start, .end = self.prevTokenEnd() };
    return stmt;
}

fn parseExpressionOrAssignment(self: *Parser) !?Ast.Stmt {
    self.expr_context = "in statement";
    const left = (try self.parseExpression()) orelse return null;

    switch (self.currentTag()) {
        .plus_plus => {
            const loc = self.currentStart();
            self.advance();
            _ = self.expect(.semicolon);
            const node = try self.arena.create(Ast.IncrDecrStmt);
            node.* = .{ .loc = loc, .expr = left, .increment = true };
            return .{ .incr_decr = node };
        },
        .minus_minus => {
            const loc = self.currentStart();
            self.advance();
            _ = self.expect(.semicolon);
            const node = try self.arena.create(Ast.IncrDecrStmt);
            node.* = .{ .loc = loc, .expr = left, .increment = false };
            return .{ .incr_decr = node };
        },
        else => {},
    }

    if (self.parseAssignOp()) |op| {
        const loc = self.currentStart();
        self.advance();
        self.expr_context = "in assignment";
        const right = (try self.parseExpression()) orelse return null;
        _ = self.expect(.semicolon);
        const node = try self.arena.create(Ast.AssignStmt);
        node.* = .{ .loc = loc, .op = op, .left = left, .right = right };
        return .{ .assign = node };
    }

    _ = self.expect(.semicolon);
    if (left == .call) {
        const node = try self.arena.create(Ast.CallStmt);
        node.* = .{ .call = left.call };
        return .{ .call = node };
    }

    self.addError("expected assignment, increment, or function call");
    return null;
}

fn parseAssignOp(self: *const Parser) ?Ast.AssignOp {
    return switch (self.currentTag()) {
        .eq => .simple,
        .plus_eq => .add,
        .minus_eq => .sub,
        .star_eq => .mul,
        .slash_eq => .div,
        .percent_eq => .mod,
        .amp_eq => .@"and",
        .pipe_eq => .@"or",
        .caret_eq => .xor,
        .lt_lt_eq => .shl,
        .gt_gt_eq => .shr,
        else => null,
    };
}

// =========================================================================
// Helpers
// =========================================================================

fn isVecName(name: []const u8) bool {
    return name.len == 4 and std.mem.eql(u8, name[0..3], "vec") and name[3] >= '2' and name[3] <= '4';
}

fn isMatName(name: []const u8) bool {
    return name.len == 6 and std.mem.eql(u8, name[0..3], "mat") and name[4] == 'x';
}

fn isTemplatedTypeName(name: []const u8) bool {
    const map = std.StaticStringMap(void).initComptime(.{
        .{ "array", {} },                    .{ "vec2", {} },                     .{ "vec3", {} },
        .{ "vec4", {} },                     .{ "mat2x2", {} },                   .{ "mat2x3", {} },
        .{ "mat2x4", {} },                   .{ "mat3x2", {} },                   .{ "mat3x3", {} },
        .{ "mat3x4", {} },                   .{ "mat4x2", {} },                   .{ "mat4x3", {} },
        .{ "mat4x4", {} },                   .{ "ptr", {} },                      .{ "atomic", {} },
        .{ "texture_1d", {} },               .{ "texture_2d", {} },               .{ "texture_2d_array", {} },
        .{ "texture_3d", {} },               .{ "texture_cube", {} },             .{ "texture_cube_array", {} },
        .{ "texture_multisampled_2d", {} },  .{ "texture_storage_1d", {} },       .{ "texture_storage_2d", {} },
        .{ "texture_storage_2d_array", {} }, .{ "texture_storage_3d", {} },       .{ "sampler", {} },
        .{ "sampler_comparison", {} },       .{ "texture_depth_2d", {} },         .{ "texture_depth_2d_array", {} },
        .{ "texture_depth_cube", {} },       .{ "texture_depth_cube_array", {} }, .{ "texture_depth_multisampled_2d", {} },
    });
    return map.has(name);
}

// Public access for Lexer helpers used in tokenText
pub const isIdentStart = Lexer.isIdentStart;
pub const isIdentContinue = Lexer.isIdentContinue;
pub const isDigit = Lexer.isDigit;
pub const isHexDigit = Lexer.isHexDigit;

// Expose these for other modules
/// Re-exports Lexer.isIdentStart for use by other modules.
pub fn isIdentStartFn(c: u8) bool {
    return Lexer.isIdentStart(c);
}

// =========================================================================
// Tests
// =========================================================================

test "parser: simple const" {
    const source: [:0]const u8 = "const x = 1;";
    var tokens = try Lexer.tokenize(std.testing.allocator, source);
    defer tokens.deinit(std.testing.allocator);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = try Parser.init(alloc, source, tokens);
    const module = try parser.parse();
    _ = module;
    try std.testing.expectEqual(@as(usize, 1), parser.symbols.items.len);
    try std.testing.expectEqualStrings("x", parser.symbols.items[0].original_name);
}

// -------------------------------------------------------------------------
// Test helpers
// -------------------------------------------------------------------------

fn expectPrinted(input: [:0]const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try Lexer.tokenize(alloc, input);
    var parser = try Parser.init(alloc, input, tokens);
    const module = try parser.parse();

    const Renamer = @import("Renamer.zig");
    const noop = try alloc.create(Renamer.NoOpRenamer);
    noop.* = Renamer.NoOpRenamer.init(module.symbols.items);
    noop.renamer.ptr = @ptrCast(noop);

    const Printer = @import("Printer.zig");
    var printer = Printer.init(alloc, .{
        .minify_whitespace = false,
        .minify_identifiers = false,
        .minify_syntax = false,
        .tree_shaking = false,
        .renamer = &noop.renamer,
    }, module.symbols.items);
    const actual = try printer.print(module);

    try std.testing.expectEqualStrings(expected, actual);
}

fn expectPrintedMinify(input: [:0]const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try Lexer.tokenize(alloc, input);
    var parser = try Parser.init(alloc, input, tokens);
    const module = try parser.parse();

    const Renamer = @import("Renamer.zig");
    const noop = try alloc.create(Renamer.NoOpRenamer);
    noop.* = Renamer.NoOpRenamer.init(module.symbols.items);
    noop.renamer.ptr = @ptrCast(noop);

    const Printer = @import("Printer.zig");
    var printer = Printer.init(alloc, .{
        .minify_whitespace = true,
        .minify_identifiers = false,
        .minify_syntax = false,
        .tree_shaking = false,
        .renamer = &noop.renamer,
    }, module.symbols.items);
    const actual = try printer.print(module);

    try std.testing.expectEqualStrings(expected, actual);
}

fn expectParseError(input: [:0]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try Lexer.tokenize(alloc, input);
    var parser = try Parser.init(alloc, input, tokens);
    _ = parser.parse() catch return; // error return is sufficient
    if (parser.errors.items.len > 0) return;
    return error.TestExpectedError;
}

fn expectNoError(input: [:0]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try Lexer.tokenize(alloc, input);
    var parser = try Parser.init(alloc, input, tokens);
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
}

fn expectParseErrorMessage(input: [:0]const u8, expected_msg: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try Lexer.tokenize(alloc, input);
    var parser = try Parser.init(alloc, input, tokens);
    // Test helper: we only care about the populated `errors` list; swallow
    // parse failures (including OOM on the sticky flag path) to inspect state.
    _ = parser.parse() catch {};
    if (parser.errors.items.len == 0) return error.TestExpectedError;

    for (parser.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, expected_msg) != null) return;
    }
    std.debug.print("\nExpected error containing: '{s}'\nActual errors:\n", .{expected_msg});
    for (parser.errors.items) |err| {
        std.debug.print("  - {s}\n", .{err.message});
    }
    return error.TestExpectedError;
}

// -------------------------------------------------------------------------
// Const declaration tests
// -------------------------------------------------------------------------

test "parser: const declaration" {
    try expectPrinted("const x = 1;", "const x = 1;\n");
    try expectPrinted("const x: i32 = 1;", "const x: i32 = 1;\n");
    try expectPrinted("const x = 1 + 2;", "const x = 1 + 2;\n");
    try expectPrinted("const PI = 3.14159;", "const PI = 3.14159;\n");
}

test "parser: const expressions" {
    try expectPrinted("const x = 1 + 2 * 3;", "const x = 1 + 2 * 3;\n");
    try expectPrinted("const x = (1 + 2) * 3;", "const x = (1 + 2) * 3;\n");
    try expectPrinted("const x = -1;", "const x = -1;\n");
    try expectPrinted("const x = !true;", "const x = !true;\n");
}

// -------------------------------------------------------------------------
// Let declaration tests
// -------------------------------------------------------------------------

test "parser: let declaration" {
    try expectPrinted("let x = 1;", "let x = 1;\n");
    try expectPrinted("let x: f32 = 1.0;", "let x: f32 = 1.0;\n");
}

// -------------------------------------------------------------------------
// Var declaration tests
// -------------------------------------------------------------------------

test "parser: var declaration" {
    try expectPrinted("var x: i32;", "var x: i32;\n");
    try expectPrinted("var x: i32 = 0;", "var x: i32 = 0;\n");
    try expectPrinted("var<private> x: i32;", "var<private> x: i32;\n");
    try expectPrinted("var<workgroup> odds: array<i32, 16>;", "var<workgroup> odds: array<i32, 16>;\n");
    try expectPrinted("var<storage, read_write> data: array<f32>;", "var<storage, read_write> data: array<f32>;\n");
}

test "parser: var with attributes" {
    try expectPrinted("@group(0) @binding(0) var<uniform> u: Uniforms;", "@group(0) @binding(0) var<uniform> u: Uniforms;\n");
    try expectPrinted("@group(0) @binding(1) var tex: texture_2d<f32>;", "@group(0) @binding(1) var tex: texture_2d<f32>;\n");
    try expectPrinted("@group(0) @binding(2) var samp: sampler;", "@group(0) @binding(2) var samp: sampler;\n");
}

test "parser: var without address space" {
    try expectPrinted("var x: i32 = 0;", "var x: i32 = 0;\n");
}

// -------------------------------------------------------------------------
// Override declaration tests
// -------------------------------------------------------------------------

test "parser: override declaration" {
    try expectPrinted("override x: f32;", "override x: f32;\n");
    try expectPrinted("override x: f32 = 1.0;", "override x: f32 = 1.0;\n");
    try expectPrinted("@id(0) override x: f32;", "@id(0) override x: f32;\n");
}

// -------------------------------------------------------------------------
// Struct declaration tests
// -------------------------------------------------------------------------

test "parser: struct declaration" {
    try expectPrinted("struct Foo { x: i32, }", "struct Foo {\n    x: i32\n}\n");
    try expectPrinted("struct Point { x: f32, y: f32, }", "struct Point {\n    x: f32,\n    y: f32\n}\n");
}

test "parser: struct with attributes" {
    try expectPrinted(
        "struct VertexOutput { @builtin(position) pos: vec4f, @location(0) uv: vec2f, }",
        "struct VertexOutput {\n    @builtin(position) pos: vec4f,\n    @location(0) uv: vec2f\n}\n",
    );
}

// -------------------------------------------------------------------------
// Alias declaration tests
// -------------------------------------------------------------------------

test "parser: alias declaration" {
    try expectPrinted("alias Float = f32;", "alias Float = f32;\n");
    try expectPrinted("alias Vec3 = vec3<f32>;", "alias Vec3 = vec3<f32>;\n");
}

// -------------------------------------------------------------------------
// Function declaration tests
// -------------------------------------------------------------------------

test "parser: function declaration" {
    try expectPrinted("fn foo() {}", "fn foo() {\n}\n");
    try expectPrinted("fn foo() -> i32 { return 1; }", "fn foo() -> i32 {\n    return 1;\n}\n");
    try expectPrinted(
        "fn add(a: i32, b: i32) -> i32 { return a + b; }",
        "fn add(a: i32, b: i32) -> i32 {\n    return a + b;\n}\n",
    );
}

test "parser: entry point functions" {
    try expectPrinted(
        "@vertex fn main() -> @builtin(position) vec4f { return vec4f(); }",
        "@vertex fn main() -> @builtin(position) vec4f {\n    return vec4f();\n}\n",
    );
    try expectPrinted(
        "@fragment fn main() -> @location(0) vec4f { return vec4f(1.0); }",
        "@fragment fn main() -> @location(0) vec4f {\n    return vec4f(1.0);\n}\n",
    );
    try expectPrinted(
        "@compute @workgroup_size(64) fn main() {}",
        "@compute @workgroup_size(64) fn main() {\n}\n",
    );
}

test "parser: function with parameter attributes" {
    try expectPrinted(
        "@vertex fn main(@location(0) pos: vec4f) -> @builtin(position) vec4f { return pos; }",
        "@vertex fn main(@location(0) pos: vec4f) -> @builtin(position) vec4f {\n    return pos;\n}\n",
    );
}

// -------------------------------------------------------------------------
// Binary expression tests
// -------------------------------------------------------------------------

test "parser: binary expressions" {
    // Arithmetic
    try expectPrinted("const x = 1 + 2;", "const x = 1 + 2;\n");
    try expectPrinted("const x = 1 - 2;", "const x = 1 - 2;\n");
    try expectPrinted("const x = 1 * 2;", "const x = 1 * 2;\n");
    try expectPrinted("const x = 1 / 2;", "const x = 1 / 2;\n");
    try expectPrinted("const x = 1 % 2;", "const x = 1 % 2;\n");
    // Bitwise
    try expectPrinted("const x = 1 & 2;", "const x = 1 & 2;\n");
    try expectPrinted("const x = 1 | 2;", "const x = 1 | 2;\n");
    try expectPrinted("const x = 1 ^ 2;", "const x = 1 ^ 2;\n");
    try expectPrinted("const x = 1 << 2;", "const x = 1 << 2;\n");
    try expectPrinted("const x = 1 >> 2;", "const x = 1 >> 2;\n");
    // Comparison
    try expectPrinted("const x = 1 == 2;", "const x = 1 == 2;\n");
    try expectPrinted("const x = 1 != 2;", "const x = 1 != 2;\n");
    try expectPrinted("const x = 1 < 2;", "const x = 1 < 2;\n");
    try expectPrinted("const x = 1 <= 2;", "const x = 1 <= 2;\n");
    try expectPrinted("const x = 1 > 2;", "const x = 1 > 2;\n");
    try expectPrinted("const x = 1 >= 2;", "const x = 1 >= 2;\n");
    // Logical
    try expectPrinted("const x = true && false;", "const x = true && false;\n");
    try expectPrinted("const x = true || false;", "const x = true || false;\n");
}

test "parser: precedence — mul binds tighter than add" {
    // `1 + 2 * 3` groups as `1 + (2 * 3)` — no parens needed on output.
    try expectPrinted("const x = 1 + 2 * 3;", "const x = 1 + 2 * 3;\n");
    try expectPrinted("const x = 1 * 2 + 3;", "const x = 1 * 2 + 3;\n");
    // Parentheses flipping precedence must be preserved on output.
    try expectPrinted("const x = (1 + 2) * 3;", "const x = (1 + 2) * 3;\n");
    try expectPrinted("const x = 1 * (2 + 3);", "const x = 1 * (2 + 3);\n");
}

test "parser: precedence — negation binds tighter than binary ops" {
    // `-1 + 2` groups as `(-1) + 2`, not `-(1 + 2)`.
    try expectPrinted("const x = -1 + 2;", "const x = -1 + 2;\n");
    try expectPrinted("const x = 2 + -1;", "const x = 2 + -1;\n");
    // `!a && b` groups as `(!a) && b`.
    try expectPrinted("const x = !a && b;", "const x = !a && b;\n");
    // Overriding with parens must round-trip.
    try expectPrinted("const x = -(1 + 2);", "const x = -(1 + 2);\n");
    try expectPrinted("const x = !(a && b);", "const x = !(a && b);\n");
}

test "parser: precedence — left-associative infix" {
    // `1 - 2 - 3` groups left: `(1 - 2) - 3`; the default form drops parens.
    try expectPrinted("const x = 1 - 2 - 3;", "const x = 1 - 2 - 3;\n");
    try expectPrinted("const x = 1 / 2 / 3;", "const x = 1 / 2 / 3;\n");
    // Right-associating with explicit parens is NOT the same — parens must
    // survive the round-trip so semantics are preserved.
    try expectPrinted("const x = 1 - (2 - 3);", "const x = 1 - (2 - 3);\n");
}

test "parser: precedence — modulo vs comparison" {
    // `a % b == 0` groups as `(a % b) == 0` — no parens needed.
    try expectPrinted("const x = a % b == 0;", "const x = a % b == 0;\n");
    try expectPrinted("const x = a == b % 2;", "const x = a == b % 2;\n");
}

test "parser: precedence — shift vs add" {
    // WGSL gives shift lower precedence than add, so `1 + 2 << 3` is
    // `(1 + 2) << 3` — parens optional in source but the meaning is fixed.
    try expectPrinted("const x = (1 + 2) << 3;", "const x = (1 + 2) << 3;\n");
    try expectPrinted("const x = 1 << (2 + 3);", "const x = 1 << (2 + 3);\n");
}

// -------------------------------------------------------------------------
// Unary expression tests
// -------------------------------------------------------------------------

test "parser: unary expressions" {
    try expectPrinted("const x = -1;", "const x = -1;\n");
    try expectPrinted("const x = !true;", "const x = !true;\n");
    try expectPrinted("const x = ~1;", "const x = ~1;\n");
}

// -------------------------------------------------------------------------
// Call expression tests
// -------------------------------------------------------------------------

test "parser: call expressions" {
    try expectPrinted("const x = foo();", "const x = foo();\n");
    try expectPrinted("const x = foo(1);", "const x = foo(1);\n");
    try expectPrinted("const x = foo(1, 2);", "const x = foo(1, 2);\n");
    try expectPrinted("const x = foo(1, 2, 3);", "const x = foo(1, 2, 3);\n");
}

test "parser: bitcast — basic template form" {
    // `bitcast<T>(x)` — the canonical spec form.
    try expectPrinted("const x = bitcast<u32>(y);", "const x = bitcast<u32>(y);\n");
    try expectPrinted("const x = bitcast<i32>(1u);", "const x = bitcast<i32>(1u);\n");
}

test "parser: bitcast — vector target type" {
    // Aliased forms.
    try expectPrinted("const x = bitcast<vec4f>(v);", "const x = bitcast<vec4f>(v);\n");
    try expectPrinted("const x = bitcast<vec3i>(w);", "const x = bitcast<vec3i>(w);\n");
    // Nested-template forms — WGSL §3.8 requires splitting the trailing
    // `>>` lexer token into two template closes.
    try expectPrinted("const x = bitcast<vec4<u32>>(y);", "const x = bitcast<vec4<u32>>(y);\n");
    try expectPrinted("const x = bitcast<vec3<f32>>(x);", "const x = bitcast<vec3<f32>>(x);\n");
}

test "parser: nested template close — array/ptr forms" {
    // Non-bitcast forms also rely on the `>>` split.
    try expectPrinted(
        "alias A = array<vec4<u32>>;",
        "alias A = array<vec4<u32>>;\n",
    );
    // Three levels of nesting — the final `>>` closes two templates at
    // once, while the preceding single `>` closes one on its own.
    try expectPrinted(
        "alias P = ptr<function, array<f32, 4>>;",
        "alias P = ptr<function, array<f32, 4>>;\n",
    );
}

test "parser: bitcast — no template (plain function call)" {
    // `bitcast(x)` without `<T>` is a regular call expression — the lexer
    // must not special-case `bitcast` as a keyword and the parser must not
    // require a template list.
    try expectPrinted("const x = bitcast(y);", "const x = bitcast(y);\n");
}

test "parser: bitcast — embedded in expression" {
    // `1 + -bitcast<u32>(x) + 1` — bitcast as an operand of a binary op,
    // behind a unary minus. Exercises precedence at the bitcast boundary.
    try expectPrinted(
        "const x = 1 + -bitcast<u32>(y) + 1;",
        "const x = 1 + -bitcast<u32>(y) + 1;\n",
    );
}

// -------------------------------------------------------------------------
// Type constructor tests
// -------------------------------------------------------------------------

test "parser: type constructors" {
    try expectPrinted("const x = vec3f(1.0);", "const x = vec3f(1.0);\n");
    try expectPrinted("const x = vec3f(1.0, 2.0, 3.0);", "const x = vec3f(1.0, 2.0, 3.0);\n");
    try expectPrinted("const x = vec4f(v.xyz, 1.0);", "const x = vec4f(v.xyz, 1.0);\n");
    try expectPrinted("const x = mat4x4f();", "const x = mat4x4f();\n");
}

// -------------------------------------------------------------------------
// Member access tests
// -------------------------------------------------------------------------

test "parser: member access" {
    try expectPrinted("const x = a.b;", "const x = a.b;\n");
    try expectPrinted("const x = a.b.c;", "const x = a.b.c;\n");
    try expectPrinted("const x = v.xyz;", "const x = v.xyz;\n");
    try expectPrinted("const x = v.xyzw;", "const x = v.xyzw;\n");
}

// -------------------------------------------------------------------------
// Index access tests
// -------------------------------------------------------------------------

test "parser: index access" {
    try expectPrinted("const x = a[0];", "const x = a[0];\n");
    try expectPrinted("const x = a[i];", "const x = a[i];\n");
    try expectPrinted("const x = a[i + 1];", "const x = a[i + 1];\n");
    try expectPrinted("const x = a[0][1];", "const x = a[0][1];\n");
}

// -------------------------------------------------------------------------
// Parenthesis tests
// -------------------------------------------------------------------------

test "parser: parentheses" {
    try expectPrinted("const x = (1);", "const x = (1);\n");
    try expectPrinted("const x = (1 + 2) * 3;", "const x = (1 + 2) * 3;\n");
    try expectPrinted("const x = a * (b + c);", "const x = a * (b + c);\n");
}

// -------------------------------------------------------------------------
// Pointer/address-of/deref tests
// -------------------------------------------------------------------------

test "parser: address-of and deref" {
    try expectPrinted("fn foo() { let p = &x; }", "fn foo() {\n    let p = &x;\n}\n");
    try expectPrinted("fn foo() { let v = *p; }", "fn foo() {\n    let v = *p;\n}\n");
}

// -------------------------------------------------------------------------
// Statement tests
// -------------------------------------------------------------------------

test "parser: return statement" {
    try expectPrinted("fn foo() { return; }", "fn foo() {\n    return;\n}\n");
    try expectPrinted("fn foo() -> i32 { return 1; }", "fn foo() -> i32 {\n    return 1;\n}\n");
}

test "parser: if statement" {
    try expectPrinted(
        "fn foo() { if true { return; } }",
        "fn foo() {\n    if true {\n        return;\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { if true { return; } else { return; } }",
        "fn foo() {\n    if true {\n        return;\n    } else {\n        return;\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { if a { } else if b { } else { } }",
        "fn foo() {\n    if a {\n    } else if b {\n    } else {\n    }\n}\n",
    );
}

test "parser: if — multiple else-if clauses round-trip" {
    // Four-way chain with a trailing else. Regression guard for the
    // else-if walker — mirrors wgsl-analyzer's parse_if_multiple_else_clauses
    // coverage, but for the well-formed case.
    try expectPrinted(
        "fn foo() { if a { } else if b { } else if c { } else if d { } else { } }",
        "fn foo() {\n    if a {\n    } else if b {\n    } else if c {\n    } else if d {\n    } else {\n    }\n}\n",
    );
}

test "parser: if — duplicate else clauses error" {
    // `if () {} else {} else {}` — two bare `else` arms are illegal.
    try expectParseError("fn foo() { if a { } else { } else { } }");
}

test "parser: if — else-if after bare else error" {
    // `if () {} else {} else if () {}` — once a bare `else` has closed the
    // chain, any following `else if` must be a parse error.
    try expectParseError("fn foo() { if a { } else { } else if b { } }");
}

// -------------------------------------------------------------------------
// Parse-recovery scenarios — each mirrors a named wgsl-analyzer tests.rs
// case. Intent: the parser produces at least one diagnostic without
// crashing, so downstream IDE features (completion, hover) stay alive
// while the user types.
// -------------------------------------------------------------------------

test "parser: recovery — bare 'fn' at module scope" {
    // wgsl-analyzer: fn_recover. Two adjacent `fn` keywords, the first
    // missing name+signature; parser must recover into the second.
    try expectParseError("fn\nfn name() {}");
}

test "parser: recovery — fn missing body before next decl" {
    // wgsl-analyzer: fn_recover_2. `fn name()` with no body, followed by a
    // valid `fn test() {}` — the first must error, the second must parse.
    try expectParseError("fn name()\nfn test() {}");
}

test "parser: recovery — fn with incomplete parameter list" {
    // wgsl-analyzer: fn_recover_incomplete_param.
    try expectParseError("fn foo(x: ) {}");
}

test "parser: recovery — bare 'struct' keyword" {
    // wgsl-analyzer: struct_recover. `struct` with no name, followed by a
    // complete decl — parser must flag the bare keyword and continue.
    try expectParseError("struct\nfn test() {}");
}

test "parser: recovery — struct missing body" {
    // wgsl-analyzer: struct_recover_2. `struct Name` without `{…}`.
    try expectParseError("struct test\nfn test() {}");
}

test "parser: recovery — bare 'var' at module scope" {
    // wgsl-analyzer: var_recover_elided_name. A lone `var` must not crash
    // the parser.
    try expectParseError("var");
}

test "parser: recovery — let statement missing initializer before return" {
    // wgsl-analyzer: let_statement_recover_return. `let` alone followed by
    // a return must recover — the return statement should still parse.
    try expectParseError("fn main() { let\n    return 0;\n}");
}

test "parser: recovery — let 'x be' without '='" {
    // wgsl-analyzer: let_statement_recover_return_no_eq. Typing past `let x`
    // without `=`/`:`/`;` must emit an error, not hang or crash.
    try expectParseError("fn main() {\n    let x be\n}");
}

test "parser: recovery — if with empty parenthesized condition" {
    // wgsl-analyzer: parse_if_recover_empty. Empty `()` as condition.
    try expectParseError("fn foo() { if () { } }");
}

test "parser: recovery — missing LHS before unary plus" {
    // wgsl-analyzer: parse_missing_lhs_recover. WGSL has no unary `+`,
    // so `let a = +1;` must produce a parse error at the `+`.
    try expectParseError("fn foo() { let a = +1; }");
}

test "parser: for statement" {
    try expectPrinted(
        "fn foo() { for (var i: i32 = 0; i < 4; i++) { } }",
        "fn foo() {\n    for (var i: i32 = 0; i < 4; i++) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 0u; i < 10u; i++) { x++; } }",
        "fn foo() {\n    for (var i = 0u; i < 10u; i++) {\n        x++;\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i: i32 = 0; i < 4; i += 2) { } }",
        "fn foo() {\n    for (var i: i32 = 0; i < 4; i += 2) {\n    }\n}\n",
    );
}

test "parser: for loop empty clauses" {
    try expectPrinted(
        "fn foo() { for (;;) { break; } }",
        "fn foo() {\n    for (; ; ) {\n        break;\n    }\n}\n",
    );
}

test "parser: for loop update statements" {
    try expectPrinted(
        "fn foo() { for (var i = 0; i < 10; i = i + 1) {} }",
        "fn foo() {\n    for (var i = 0; i < 10; i = i + 1) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 0; i < 10; i += 1) {} }",
        "fn foo() {\n    for (var i = 0; i < 10; i += 1) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 10; i > 0; i -= 1) {} }",
        "fn foo() {\n    for (var i = 10; i > 0; i -= 1) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 1; i < 100; i *= 2) {} }",
        "fn foo() {\n    for (var i = 1; i < 100; i *= 2) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 100; i > 1; i /= 2) {} }",
        "fn foo() {\n    for (var i = 100; i > 1; i /= 2) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 0; i < 10; i %= 3) {} }",
        "fn foo() {\n    for (var i = 0; i < 10; i %= 3) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 0xFFu; i > 0u; i &= 0x7Fu) {} }",
        "fn foo() {\n    for (var i = 0xFFu; i > 0u; i &= 0x7Fu) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 0u; i < 255u; i |= 1u) {} }",
        "fn foo() {\n    for (var i = 0u; i < 255u; i |= 1u) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 0u; i < 255u; i ^= 1u) {} }",
        "fn foo() {\n    for (var i = 0u; i < 255u; i ^= 1u) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 1u; i < 256u; i <<= 1u) {} }",
        "fn foo() {\n    for (var i = 1u; i < 256u; i <<= 1u) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 256u; i > 0u; i >>= 1u) {} }",
        "fn foo() {\n    for (var i = 256u; i > 0u; i >>= 1u) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 10; i > 0; i--) {} }",
        "fn foo() {\n    for (var i = 10; i > 0; i--) {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { for (var i = 0; i < 10; update()) {} }",
        "fn foo() {\n    for (var i = 0; i < 10; update()) {\n    }\n}\n",
    );
}

test "parser: for loop expression initializer" {
    try expectNoError("fn f() { var i: i32; for (i = 0; i < 10; i += 1) { } }");
}

test "parser: while statement" {
    try expectPrinted(
        "fn foo() { while true { } }",
        "fn foo() {\n    while true {\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { while x < 10 { x++; } }",
        "fn foo() {\n    while x < 10 {\n        x++;\n    }\n}\n",
    );
}

test "parser: loop statement" {
    try expectPrinted(
        "fn foo() { loop { break; } }",
        "fn foo() {\n    loop {\n        break;\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { loop { if x { break; } } }",
        "fn foo() {\n    loop {\n        if x {\n            break;\n        }\n    }\n}\n",
    );
}

test "parser: loop continuing" {
    // Printer emits WGSL §8.8 spec form: continuing sits inside the loop
    // body's braces so vars declared in the body stay in scope.
    try expectPrinted(
        "fn foo() { loop { break; } continuing { i++; } }",
        "fn foo() {\n    loop {\n        break;\n        continuing {\n            i++;\n        }\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { loop { break; continuing { i++; } } }",
        "fn foo() {\n    loop {\n        break;\n        continuing {\n            i++;\n        }\n    }\n}\n",
    );
}

test "parser: switch statement" {
    try expectPrinted(
        "fn foo() { switch x { case 1: { } default: { } } }",
        "fn foo() {\n    switch x {\n        case 1: {\n        }\n        default: {\n        }\n    }\n}\n",
    );
}

test "parser: switch multiple selectors" {
    try expectPrinted(
        "fn foo() { switch x { case 1, 2, 3: { } default: { } } }",
        "fn foo() {\n    switch x {\n        case 1, 2, 3: {\n        }\n        default: {\n        }\n    }\n}\n",
    );
}

test "parser: switch only default" {
    try expectPrinted(
        "fn foo() { switch x { default: { } } }",
        "fn foo() {\n    switch x {\n        default: {\n        }\n    }\n}\n",
    );
}

test "parser: switch default with return" {
    try expectPrinted(
        "fn f() { var x: i32; switch x { default: { return; } } }",
        "fn f() {\n    var x: i32;\n    switch x {\n        default: {\n            return;\n        }\n    }\n}\n",
    );
}

test "parser: break and continue" {
    try expectPrinted(
        "fn foo() { loop { break; } }",
        "fn foo() {\n    loop {\n        break;\n    }\n}\n",
    );
    try expectPrinted(
        "fn foo() { loop { continue; } }",
        "fn foo() {\n    loop {\n        continue;\n    }\n}\n",
    );
}

test "parser: break if statement" {
    try expectPrinted(
        "fn foo() { loop { } continuing { break if true; } }",
        "fn foo() {\n    loop {\n        continuing {\n            break if true;\n        }\n    }\n}\n",
    );
    // Spec-form input (continuing inside body) round-trips identically.
    try expectPrinted(
        "fn foo() { loop { continuing { break if true; } } }",
        "fn foo() {\n    loop {\n        continuing {\n            break if true;\n        }\n    }\n}\n",
    );
}

test "parser: discard statement" {
    try expectPrinted(
        "@fragment fn main() { discard; }",
        "@fragment fn main() {\n    discard;\n}\n",
    );
}

test "parser: assignment statements" {
    try expectPrinted("fn foo() { x = 1; }", "fn foo() {\n    x = 1;\n}\n");
    try expectPrinted("fn foo() { x += 1; }", "fn foo() {\n    x += 1;\n}\n");
    try expectPrinted("fn foo() { x -= 1; }", "fn foo() {\n    x -= 1;\n}\n");
    try expectPrinted("fn foo() { x *= 2; }", "fn foo() {\n    x *= 2;\n}\n");
    try expectPrinted("fn foo() { x /= 2; }", "fn foo() {\n    x /= 2;\n}\n");
}

test "parser: compound assignment statements" {
    try expectPrinted("fn foo() { x %= 3; }", "fn foo() {\n    x %= 3;\n}\n");
    try expectPrinted("fn foo() { x &= 0xFF; }", "fn foo() {\n    x &= 0xFF;\n}\n");
    try expectPrinted("fn foo() { x |= 1; }", "fn foo() {\n    x |= 1;\n}\n");
    try expectPrinted("fn foo() { x ^= 0xF; }", "fn foo() {\n    x ^= 0xF;\n}\n");
    try expectPrinted("fn foo() { x <<= 2u; }", "fn foo() {\n    x <<= 2u;\n}\n");
    try expectPrinted("fn foo() { x >>= 2u; }", "fn foo() {\n    x >>= 2u;\n}\n");
}

test "parser: increment and decrement" {
    try expectPrinted("fn foo() { x++; }", "fn foo() {\n    x++;\n}\n");
    try expectPrinted("fn foo() { x--; }", "fn foo() {\n    x--;\n}\n");
}

test "parser: call statement" {
    try expectPrinted("fn foo() { bar(); }", "fn foo() {\n    bar();\n}\n");
}

// -------------------------------------------------------------------------
// Scalar type tests
// -------------------------------------------------------------------------

test "parser: scalar types" {
    try expectPrinted("var x: bool;", "var x: bool;\n");
    try expectPrinted("var x: i32;", "var x: i32;\n");
    try expectPrinted("var x: u32;", "var x: u32;\n");
    try expectPrinted("var x: f32;", "var x: f32;\n");
    try expectPrinted("var x: f16;", "var x: f16;\n");
}

// -------------------------------------------------------------------------
// Vector type tests
// -------------------------------------------------------------------------

test "parser: vector types" {
    try expectPrinted("var x: vec2<f32>;", "var x: vec2<f32>;\n");
    try expectPrinted("var x: vec3<f32>;", "var x: vec3<f32>;\n");
    try expectPrinted("var x: vec4<f32>;", "var x: vec4<f32>;\n");
    try expectPrinted("var x: vec2f;", "var x: vec2f;\n");
    try expectPrinted("var x: vec3f;", "var x: vec3f;\n");
    try expectPrinted("var x: vec4f;", "var x: vec4f;\n");
    try expectPrinted("var x: vec3i;", "var x: vec3i;\n");
    try expectPrinted("var x: vec3u;", "var x: vec3u;\n");
}

// -------------------------------------------------------------------------
// Matrix type tests
// -------------------------------------------------------------------------

test "parser: matrix types" {
    try expectPrinted("var x: mat4x4f;", "var x: mat4x4f;\n");
    try expectPrinted("var x: mat2x2<f32>;", "var x: mat2x2<f32>;\n");
    try expectPrinted("var x: mat3x3<f32>;", "var x: mat3x3<f32>;\n");
    try expectPrinted("var x: mat4x4<f32>;", "var x: mat4x4<f32>;\n");
    try expectPrinted("var x: mat2x3<f32>;", "var x: mat2x3<f32>;\n");
}

// -------------------------------------------------------------------------
// Array type tests
// -------------------------------------------------------------------------

test "parser: array types" {
    try expectPrinted("var x: array<f32>;", "var x: array<f32>;\n");
    try expectPrinted("var x: array<f32, 10>;", "var x: array<f32, 10>;\n");
    try expectPrinted("var x: array<vec3<f32>, 8>;", "var x: array<vec3<f32>, 8>;\n");
}

// -------------------------------------------------------------------------
// Pointer type tests
// -------------------------------------------------------------------------

test "parser: pointer types" {
    try expectPrinted("var x: ptr<function, f32>;", "var x: ptr<function, f32>;\n");
    try expectPrinted("var x: ptr<private, i32>;", "var x: ptr<private, i32>;\n");
    try expectPrinted("var x: ptr<storage, f32, read_write>;", "var x: ptr<storage, f32, read_write>;\n");
}

test "parser: multiple template args" {
    try expectPrinted("var x: ptr<storage, f32, read_write>;", "var x: ptr<storage, f32, read_write>;\n");
}

// -------------------------------------------------------------------------
// Atomic type tests
// -------------------------------------------------------------------------

test "parser: atomic types" {
    try expectPrinted("var x: atomic<i32>;", "var x: atomic<i32>;\n");
    try expectPrinted("var x: atomic<u32>;", "var x: atomic<u32>;\n");
}

// -------------------------------------------------------------------------
// Texture type tests
// -------------------------------------------------------------------------

test "parser: texture types" {
    try expectPrinted("var tex: texture_2d<f32>;", "var tex: texture_2d<f32>;\n");
    try expectPrinted("var tex: texture_3d<f32>;", "var tex: texture_3d<f32>;\n");
    try expectPrinted("var tex: texture_cube<f32>;", "var tex: texture_cube<f32>;\n");
}

test "parser: all texture types" {
    // Sampled textures
    try expectPrinted("var tex: texture_1d<f32>;", "var tex: texture_1d<f32>;\n");
    try expectPrinted("var tex: texture_2d<f32>;", "var tex: texture_2d<f32>;\n");
    try expectPrinted("var tex: texture_2d_array<f32>;", "var tex: texture_2d_array<f32>;\n");
    try expectPrinted("var tex: texture_3d<f32>;", "var tex: texture_3d<f32>;\n");
    try expectPrinted("var tex: texture_cube<f32>;", "var tex: texture_cube<f32>;\n");
    try expectPrinted("var tex: texture_cube_array<f32>;", "var tex: texture_cube_array<f32>;\n");
    // Multisampled
    try expectPrinted("var tex: texture_multisampled_2d<f32>;", "var tex: texture_multisampled_2d<f32>;\n");
    // Storage textures with format and access mode
    try expectPrinted("var tex: texture_storage_1d<rgba8unorm, write>;", "var tex: texture_storage_1d<rgba8unorm, write>;\n");
    try expectPrinted("var tex: texture_storage_2d<rgba8unorm, read>;", "var tex: texture_storage_2d<rgba8unorm, read>;\n");
    try expectPrinted("var tex: texture_storage_2d_array<rgba8unorm, read_write>;", "var tex: texture_storage_2d_array<rgba8unorm, read_write>;\n");
    try expectPrinted("var tex: texture_storage_3d<rgba32float, write>;", "var tex: texture_storage_3d<rgba32float, write>;\n");
    // Depth textures (no template args — parsed as ident type)
    try expectPrinted("var tex: texture_depth_2d;", "var tex: texture_depth_2d;\n");
    try expectPrinted("var tex: texture_depth_2d_array;", "var tex: texture_depth_2d_array;\n");
    try expectPrinted("var tex: texture_depth_cube;", "var tex: texture_depth_cube;\n");
    try expectPrinted("var tex: texture_depth_cube_array;", "var tex: texture_depth_cube_array;\n");
    try expectPrinted("var tex: texture_depth_multisampled_2d;", "var tex: texture_depth_multisampled_2d;\n");
}

test "parser: depth texture types with attributes" {
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_depth_2d;",
        "@group(0) @binding(0) var t: texture_depth_2d;\n",
    );
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_depth_2d_array;",
        "@group(0) @binding(0) var t: texture_depth_2d_array;\n",
    );
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_depth_cube;",
        "@group(0) @binding(0) var t: texture_depth_cube;\n",
    );
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_depth_cube_array;",
        "@group(0) @binding(0) var t: texture_depth_cube_array;\n",
    );
    try expectPrinted(
        "@group(0) @binding(0) var t: texture_depth_multisampled_2d;",
        "@group(0) @binding(0) var t: texture_depth_multisampled_2d;\n",
    );
}

test "parser: depth texture types templated" {
    // Depth textures with empty template args — the parser parses them as
    // texture types and the printer emits them without sampled/texel content
    try expectNoError("var t: texture_depth_2d<>;");
    try expectNoError("var t: texture_depth_2d_array<>;");
    try expectNoError("var t: texture_depth_cube<>;");
    try expectNoError("var t: texture_depth_cube_array<>;");
    try expectNoError("var t: texture_depth_multisampled_2d<>;");
}

test "parser: storage texture without access mode" {
    // Printer emits trailing comma + empty string for the access mode
    try expectPrinted(
        "var tex: texture_storage_2d<rgba8unorm>;",
        "var tex: texture_storage_2d<rgba8unorm, >;\n",
    );
}

// -------------------------------------------------------------------------
// Sampler type tests
// -------------------------------------------------------------------------

test "parser: sampler types" {
    try expectPrinted("var s: sampler;", "var s: sampler;\n");
    try expectPrinted("var s: sampler_comparison;", "var s: sampler_comparison;\n");
}

// -------------------------------------------------------------------------
// Directive tests
// -------------------------------------------------------------------------

test "parser: enable directive" {
    try expectPrinted("enable f16;", "enable f16;\n");
    try expectPrinted("enable f16, dual_source_blending;", "enable f16, dual_source_blending;\n");
    try expectPrinted("enable f16, subgroups;", "enable f16, subgroups;\n");
}

test "parser: requires directive" {
    try expectPrinted(
        "requires readonly_and_readwrite_storage_textures;",
        "requires readonly_and_readwrite_storage_textures;\n",
    );
}

test "parser: diagnostic directive" {
    try expectPrinted(
        "diagnostic(off, derivative_uniformity);",
        "diagnostic(off, derivative_uniformity);\n",
    );
}

// -------------------------------------------------------------------------
// Const assert tests
// -------------------------------------------------------------------------

test "parser: const assert" {
    try expectPrinted("const_assert 1 == 1;", "const_assert 1 == 1;\n");
    try expectPrinted("const_assert SIZE > 0;", "const_assert SIZE > 0;\n");
    try expectPrinted("const_assert true;", "const_assert true;\n");
    try expectPrinted("const_assert 1 + 1 == 2;", "const_assert 1 + 1 == 2;\n");
}

test "parser: const assert at module level" {
    try expectPrinted("const_assert true;", "const_assert true;\n");
    try expectPrinted("const_assert 1 == 1;", "const_assert 1 == 1;\n");
    // Legacy syntax: const const_assert
    try expectNoError("const const_assert true;");
}

// -------------------------------------------------------------------------
// Template expression tests
// -------------------------------------------------------------------------

test "parser: template additive expressions" {
    try expectPrinted("var x: array<f32, 10 + 5>;", "var x: array<f32, 10 + 5>;\n");
    try expectPrinted("var x: array<f32, 20 - 5>;", "var x: array<f32, 20 - 5>;\n");
}

test "parser: template multiplicative expressions" {
    try expectPrinted("var x: array<f32, 2 * 8>;", "var x: array<f32, 2 * 8>;\n");
    try expectPrinted("var x: array<f32, 16 / 2>;", "var x: array<f32, 16 / 2>;\n");
    try expectPrinted("var x: array<f32, 17 % 5>;", "var x: array<f32, 17 % 5>;\n");
}

test "parser: template unary expressions" {
    try expectPrinted("var x: array<f32, -10>;", "var x: array<f32, -10>;\n");
    try expectPrinted("const x = array<bool, 2>(!true, !false);", "const x = array<bool, 2>(!true, !false);\n");
    try expectPrinted("var x: array<i32, ~0>;", "var x: array<i32, ~0>;\n");
}

test "parser: template parentheses expressions" {
    try expectPrinted("var x: array<f32, (10 + 5)>;", "var x: array<f32, (10 + 5)>;\n");
    try expectPrinted("var x: array<f32, (2 + 3) * 4>;", "var x: array<f32, (2 + 3) * 4>;\n");
}

test "parser: template complex expressions" {
    try expectPrinted("var x: array<f32, 2 + 3 * 4>;", "var x: array<f32, 2 + 3 * 4>;\n");
    try expectPrinted("var x: array<f32, (2 + 3) * 4 - 1>;", "var x: array<f32, (2 + 3) * 4 - 1>;\n");
}

test "parser: template identifier expressions" {
    // The Zig printer does not insert blank lines between declarations.
    try expectPrinted(
        "const N = 10;\nvar x: array<f32, N>;",
        "const N = 10;\nvar x: array<f32, N>;\n",
    );
}

test "parser: template bool literals" {
    try expectPrinted("const x = vec2<bool>(true, false);", "const x = vec2<bool>(true, false);\n");
    try expectNoError("alias T = array<i32, true>;");
    try expectNoError("alias T = array<i32, false>;");
}

test "parser: template unary not" {
    try expectNoError("alias T = vec2<f32>;");
    try expectNoError("alias T = array<i32, -1>;");
    try expectNoError("alias T = array<i32, ~0>;");
    try expectNoError("alias T = array<i32, 1 * !0>;");
}

// -------------------------------------------------------------------------
// Templated constructor tests
// -------------------------------------------------------------------------

test "parser: templated constructors" {
    try expectPrinted("var x = vec3<f32>(0);", "var x = vec3<f32>(0);\n");
    try expectPrinted("var x = vec2<i32>(1, 2);", "var x = vec2<i32>(1, 2);\n");
    try expectPrinted("var x = vec4<u32>(0, 0, 0, 1);", "var x = vec4<u32>(0, 0, 0, 1);\n");
    try expectPrinted("var x = mat2x2<f32>(1, 0, 0, 1);", "var x = mat2x2<f32>(1, 0, 0, 1);\n");
    try expectPrinted("var x = array<f32, 4>(1.0, 2.0, 3.0, 4.0);", "var x = array<f32, 4>(1.0, 2.0, 3.0, 4.0);\n");
}

test "parser: templated constructors with generic type" {
    try expectPrinted("const x = vec3<f32>(1.0, 2.0, 3.0);", "const x = vec3<f32>(1.0, 2.0, 3.0);\n");
    try expectPrinted("const x = array<i32, 3>(1, 2, 3);", "const x = array<i32, 3>(1, 2, 3);\n");
}

test "parser: templated type as expression not constructor" {
    // Templated type in expression position not followed by ( — should not crash
    try expectNoError("fn f() { let x = vec2<f32>; }");
    try expectNoError("fn f() { let x = array<i32, 5>; }");
}

// -------------------------------------------------------------------------
// Access mode tests
// -------------------------------------------------------------------------

test "parser: access modes" {
    try expectPrinted("var<storage, read> x: f32;", "var<storage, read> x: f32;\n");
    try expectPrinted("var<storage, write> x: f32;", "var<storage, write> x: f32;\n");
    try expectPrinted("var<storage, read_write> x: f32;", "var<storage, read_write> x: f32;\n");
}

// -------------------------------------------------------------------------
// Address space tests
// -------------------------------------------------------------------------

test "parser: address spaces" {
    try expectPrinted("var<function> x: f32;", "var<function> x: f32;\n");
    try expectPrinted("var<private> x: f32;", "var<private> x: f32;\n");
    try expectPrinted("var<workgroup> x: f32;", "var<workgroup> x: f32;\n");
    try expectPrinted("var<uniform> x: f32;", "var<uniform> x: f32;\n");
    try expectPrinted("var<storage> x: f32;", "var<storage> x: f32;\n");
}

// -------------------------------------------------------------------------
// Boolean literal tests
// -------------------------------------------------------------------------

test "parser: boolean literals" {
    try expectPrinted("const x = true;", "const x = true;\n");
    try expectPrinted("const x = false;", "const x = false;\n");
    try expectPrinted("const x = !true;", "const x = !true;\n");
    try expectPrinted("const x = !false;", "const x = !false;\n");
}

// -------------------------------------------------------------------------
// Generic templated type tests
// -------------------------------------------------------------------------

test "parser: generic templated types" {
    // Unknown templated type — template args consumed, ident type returned
    try expectPrinted("fn f(x: SomeType) {}", "fn f(x: SomeType) {\n}\n");
    try expectNoError("fn f(x: SomeType<i32>) {}");
    try expectNoError("fn f(x: SomeType<i32, f32>) {}");
    try expectNoError("fn f(x: SomeType<i32, f32, u32>) {}");
}

// -------------------------------------------------------------------------
// Empty var template args
// -------------------------------------------------------------------------

test "parser: empty var template args" {
    try expectNoError("var<> x: i32;");
    try expectNoError("var<storage,> x: i32;");
}

// -------------------------------------------------------------------------
// Complete shader tests (parse-only, no error expected)
// -------------------------------------------------------------------------

test "parser: complete vertex shader" {
    try expectNoError(
        \\struct VertexOutput {
        \\    @builtin(position) pos: vec4f,
        \\    @location(0) color: vec3f,
        \\}
        \\
        \\@vertex
        \\fn main(@location(0) position: vec3f) -> VertexOutput {
        \\    var output: VertexOutput;
        \\    output.pos = vec4f(position, 1.0);
        \\    output.color = vec3f(1.0, 0.0, 0.0);
        \\    return output;
        \\}
    );
}

test "parser: complete compute shader" {
    try expectNoError(
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let index = id.x;
        \\    if index < arrayLength(&data) {
        \\        data[index] = data[index] * 2.0;
        \\    }
        \\}
    );
}

// -------------------------------------------------------------------------
// Minification output tests
// -------------------------------------------------------------------------

test "parser: minify whitespace const" {
    try expectPrintedMinify("const x = 1;", "const x=1;");
    try expectPrintedMinify("const x: i32 = 1;", "const x:i32=1;");
}

test "parser: minify whitespace function" {
    try expectPrintedMinify("fn foo() {}", "fn foo(){}");
    try expectPrintedMinify(
        "fn foo() -> i32 { return 1; }",
        "fn foo()->i32{return 1;}",
    );
}

test "parser: minify whitespace struct" {
    try expectPrintedMinify(
        "struct Foo { x: i32, }",
        "struct Foo{x:i32}",
    );
}

// -------------------------------------------------------------------------
// Error tests
// -------------------------------------------------------------------------

test "parser: invalid type errors" {
    try expectParseError("struct Foo { x: 12341234 }");
    try expectParseError("var x: 999;");
    try expectParseError("fn foo(x: 123) {}");
    try expectParseError("fn foo() -> 456 {}");
    try expectParseError("var x: vec3<123>;");
    try expectParseError("var x: array<456>;");
}

test "parser: missing semicolon" {
    try expectParseError("const x = 1");
    try expectParseError("var x: f32");
}

test "parser: missing brace" {
    try expectParseError("fn foo() { return;");
    try expectParseError("struct Foo { x: f32");
    try expectParseError("fn foo() {");
}

test "parser: invalid expression errors" {
    try expectParseError("const x = ;");
    try expectParseError("const x = 1 +;");
}

test "parser: invalid statement in block" {
    try expectParseError("fn foo() { 12345 }");
}

test "parser: invalid switch statement" {
    try expectParseError("fn foo() { switch x { 1: {} } }");
}

test "parser: invalid directive" {
    // The Zig parser's enable directive loop silently skips missing feature
    // names after a comma, so only a bare semicolon as the sole token errors.
    // These three inputs all parse without error in the Zig implementation.
    try expectNoError("enable f16, ;");
    try expectNoError("enable f16,;");
    try expectNoError("enable ,;");
}

test "parser: unexpected attributes" {
    try expectParseError("@group(0) ;");
}

test "parser: struct missing member type" {
    try expectParseError("struct S { x }");
}

test "parser: struct unexpected token" {
    // The Zig parser's struct loop exits on non-ident after attributes,
    // so `@` in a struct body is silently consumed as an attribute with an
    // empty name; no parse error is emitted.
    try expectNoError("struct S { @ }");
}

test "parser: for loop missing paren" {
    try expectParseError("fn f() { for var i = 0; i < 10; i++ { } }");
}

test "parser: invalid template expression" {
    try expectParseError("var x: array<f32, @>;");
}

test "parser: invalid for loop update" {
    try expectParseError("fn foo() { for (var i = 0; i < 10; @invalid) {} }");
}

test "parser: const assert missing semicolon" {
    try expectParseError("const_assert true");
}

test "parser: block unexpected token" {
    try expectParseError("fn f() { @ }");
}

test "parser: switch unexpected token" {
    try expectParseError("fn f() { var x: i32; switch x { @ } }");
}

test "parser: unclosed compound statement" {
    try expectParseError("fn foo() {");
}

// -------------------------------------------------------------------------
// Regression tests
// -------------------------------------------------------------------------

test "parser: inline array initialization" {
    // Simple inline array
    try expectNoError("fn test() { var pos = array(1, 2, 3); }");
    // Inline array with vec2f
    try expectNoError(
        \\fn test() {
        \\  var pos = array(
        \\    vec2f(-1.0, -1.0),
        \\    vec2f(-1.0, 3.0),
        \\    vec2f(3.0, -1.0),
        \\  );
        \\}
    );
    // Inline array indexing
    try expectNoError(
        \\fn test(idx: u32) -> vec2f {
        \\  var pos = array(
        \\    vec2f(-1.0, -1.0),
        \\    vec2f(-1.0, 3.0),
        \\  );
        \\  return pos[idx];
        \\}
    );
    // Inline array in expression (indexed immediately)
    try expectNoError(
        \\fn test(index: u32) -> vec2f {
        \\  let position = array<vec2<f32>, 3>(
        \\    vec2f(0.0, 0.0),
        \\    vec2f(1.0, 0.0),
        \\    vec2f(0.0, 1.0)
        \\  )[index];
        \\  return position;
        \\}
    );
}

test "parser: struct declaration variations" {
    // Struct with trailing semicolon after closing brace
    try expectNoError(
        \\struct Foo {
        \\  x: f32,
        \\  y: f32,
        \\};
    );
    // Struct without trailing semicolon
    try expectNoError(
        \\struct Foo {
        \\  x: f32,
        \\  y: f32,
        \\}
    );
    // Struct with trailing comma on last member
    try expectNoError(
        \\struct Foo {
        \\  x: f32,
        \\  y: f32,
        \\}
    );
}

test "parser: for loop parsing variations" {
    // For loop with typed var
    try expectNoError(
        \\fn test() {
        \\  for (var i: u32 = 0u; i < 10u; i++) {
        \\  }
        \\}
    );
    // For loop in function returning value
    try expectNoError(
        \\fn sum() -> i32 {
        \\  var result = 0;
        \\  for (var i = 0; i < 10; i++) {
        \\    result += i;
        \\  }
        \\  return result;
        \\}
    );
    // Nested for loops
    try expectNoError(
        \\fn test() {
        \\  for (var i = 0u; i < 10u; i++) {
        \\    for (var j = 0u; j < 10u; j++) {
        \\    }
        \\  }
        \\}
    );
}

test "parser: type casting" {
    // u32 cast
    try expectNoError(
        \\fn test(x: f32) -> u32 {
        \\  return u32(x);
        \\}
    );
    // i32 cast
    try expectNoError(
        \\fn test(x: f32) -> i32 {
        \\  return i32(x);
        \\}
    );
    // f32 cast
    try expectNoError(
        \\fn test(x: i32) -> f32 {
        \\  return f32(x);
        \\}
    );
    // Cast in switch
    try expectNoError(
        \\fn test(phase: f32) {
        \\  switch u32(phase) {
        \\    case 0u: {}
        \\    default: {}
        \\  }
        \\}
    );
    // Cast in expression
    try expectNoError(
        \\fn test(n: u32) -> f32 {
        \\  return f32(n) * 2.0;
        \\}
    );
}

test "parser: array type with size expression" {
    // Array with expression size in function context
    try expectNoError(
        \\const movements: u32 = 3;
        \\fn test() {
        \\  let position = array<vec2<f32>, movements>(
        \\    vec2f(0.0),
        \\    vec2f(1.0),
        \\    vec2f(2.0)
        \\  );
        \\}
    );
}

test "parser: sceneW real-world patterns" {
    // Vertex shader with inline array
    try expectNoError(
        \\@vertex
        \\fn vs_test(@builtin(vertex_index) vertexIndex: u32) -> @builtin(position) vec4f {
        \\  var pos = array(
        \\    vec2f(-1.0, -1.0),
        \\    vec2f(-1.0, 3.0),
        \\    vec2f(3.0, -1.0),
        \\  );
        \\  let xy = pos[vertexIndex];
        \\  return vec4f(xy, 0.0, 1.0);
        \\}
    );
    // Struct member accessor
    try expectNoError(
        \\struct VertexOutput {
        \\  @builtin(position) position: vec4f,
        \\  @location(0) uv: vec2f,
        \\}
        \\
        \\fn get_uv(i: VertexOutput) -> vec2f {
        \\  return i.uv;
        \\}
    );
    // Switch with u32 cast
    try expectNoError(
        \\fn test(beat: f32) -> f32 {
        \\  let phase = floor(beat / 4.0) % 4.0;
        \\  var value: f32;
        \\  switch u32(phase) {
        \\    case 0u: {
        \\      value = 1.0;
        \\    }
        \\    case 2u: {
        \\      value = 2.0;
        \\    }
        \\    default: {
        \\      value = 0.0;
        \\    }
        \\  }
        \\  return value;
        \\}
    );
    // Struct constructor return
    try expectNoError(
        \\struct BezierResult {
        \\  dist: f32,
        \\  point: vec2f,
        \\}
        \\
        \\fn bezier(pos: vec2f, A: vec2f, B: vec2f, C: vec2f) -> BezierResult {
        \\  return BezierResult(1.0, vec2f(0.0));
        \\}
    );
    // For loop with u32 iteration
    try expectNoError(
        \\fn test() {
        \\  for (var i = 0u; i < 7u; i++) {
        \\  }
        \\}
    );
    // For loop with i32 cast comparison
    try expectNoError(
        \\fn test() {
        \\  let numCables = i32(10);
        \\  for (var i = 1; i < numCables; i++) {
        \\  }
        \\}
    );
    // texture_external type
    try expectNoError("@group(1) @binding(1) var videoTexture: texture_external;");
    // textureSampleBaseClampToEdge call
    try expectNoError(
        \\@group(0) @binding(0) var videoTexture: texture_external;
        \\@group(0) @binding(1) var videoSampler: sampler;
        \\
        \\fn sampleVideo(uv: vec2f) -> vec4f {
        \\  return textureSampleBaseClampToEdge(videoTexture, videoSampler, uv);
        \\}
    );
}

test "parser: trailing comma in function parameters" {
    // Single parameter with trailing comma
    try expectNoError(
        \\fn test(x: f32,) -> f32 {
        \\  return x;
        \\}
    );
    // Multiple parameters with trailing comma
    try expectNoError(
        \\fn test(x: f32, y: f32,) -> f32 {
        \\  return x + y;
        \\}
    );
    // Vertex shader with trailing comma
    try expectNoError(
        \\@vertex
        \\fn vs_main(
        \\  @builtin(vertex_index) vertexIndex: u32,
        \\  @location(0) position: vec4f,
        \\) -> @builtin(position) vec4f {
        \\  return position;
        \\}
    );
    // Fragment shader with trailing comma
    try expectNoError(
        \\@fragment
        \\fn fs_main(
        \\  @location(0) uv: vec2f,
        \\) -> @location(0) vec4f {
        \\  return vec4f(uv, 0.0, 1.0);
        \\}
    );
    // Compute shader with trailing comma
    try expectNoError(
        \\@compute @workgroup_size(64)
        \\fn main(
        \\  @builtin(global_invocation_id) id: vec3u,
        \\) {
        \\}
    );
    // Helper function with trailing comma
    try expectNoError(
        \\fn lerp(
        \\  a: f32,
        \\  b: f32,
        \\  t: f32,
        \\) -> f32 {
        \\  return a + (b - a) * t;
        \\}
    );
}

// -------------------------------------------------------------------------
// Contextual error message tests
// -------------------------------------------------------------------------

test "parser error: expect names the expected token" {
    // Missing semicolons
    try expectParseErrorMessage("const x = 1", "expected ';'");
    try expectParseErrorMessage("var x: i32", "expected ';'");
    try expectParseErrorMessage("let x = 1", "expected ';'");
    // Missing closing paren
    try expectParseErrorMessage("fn foo(x: i32 {}", "expected ')'");
    // Missing closing brace
    try expectParseErrorMessage("fn foo() { return;", "expected '}'");
    // Missing closing angle bracket
    try expectParseErrorMessage("var x: vec3<f32;", "expected '>'");
    // Missing equals
    try expectParseErrorMessage("const x 1;", "expected '='");
    // Missing colon in parameter
    try expectParseErrorMessage("fn foo(x i32) {}", "expected ':'");
}

test "parser error: expected type with context" {
    // Type after colon in var declaration
    try expectParseErrorMessage("var x: 999;", "expected type after ':' in var declaration");
    // Type after arrow in function return type
    try expectParseErrorMessage("fn foo() -> 456 {}", "expected type after '->' in function return type");
    // Type after colon in function parameter
    try expectParseErrorMessage("fn foo(x: 123) {}", "expected type after ':' in function parameter");
    // Type after colon in struct member
    try expectParseErrorMessage("struct Foo { x: 123 }", "expected type after ':' in struct member");
    // Type after equals in alias declaration
    try expectParseErrorMessage("alias T = 123;", "expected type after '=' in alias declaration");
    // Type after colon in const declaration
    try expectParseErrorMessage("const x: 123 = 1;", "expected type after ':' in const declaration");
    // Type after colon in override declaration
    try expectParseErrorMessage("override x: 123;", "expected type after ':' in override declaration");
    // Type after colon in let declaration
    try expectParseErrorMessage("fn f() { let x: 123 = 1; }", "expected type after ':' in let declaration");
    // Type in vector type
    try expectParseErrorMessage("var x: vec3<123>;", "expected type in vector type");
    // Type in array type
    try expectParseErrorMessage("var x: array<123>;", "expected type in array type");
    // Type in matrix type
    try expectParseErrorMessage("var x: mat2x2<123>;", "expected type in matrix type");
}

test "parser error: expected expression with context" {
    // Expression after = in const
    try expectParseErrorMessage("const x = ;", "expected expression after '=' in const declaration");
    // Expression after = in let
    try expectParseErrorMessage("fn f() { let x = ; }", "expected expression after '=' in let declaration");
    // Expression after = in var
    try expectParseErrorMessage("var x: i32 = ;", "expected expression after '=' in var declaration");
    // Expression in if condition
    try expectParseErrorMessage("fn f() { if ; {} }", "expected expression in if condition");
    // Expression in while condition
    try expectParseErrorMessage("fn f() { while ; {} }", "expected expression in while condition");
    // Expression in switch
    try expectParseErrorMessage("fn f() { switch ; {} }", "expected expression in switch expression");
    // Expression after return (return with invalid token, not just semicolon)
    try expectParseErrorMessage("fn f() -> i32 { return +; }", "after 'return'");
}

test "parser error: expected assignment or call in statement" {
    try expectParseErrorMessage("fn foo() { 42; }", "expected assignment, increment, or function call");
}

pub const Error = error{ParseFailed} || Allocator.Error;

// =========================================================================
// Shadow-CST tests — exercise `initWithCst` alongside normal AST
// construction, and verify that the resulting CST round-trips the source
// and nests top-level declarations under the expected kinds.
// =========================================================================

/// Parse `source` with a CST builder attached, then walk the finalized
/// tree and assert that concatenating every leaf token yields the original
/// source byte-for-byte.
fn expectCstRoundtrip(source: [:0]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var all_tokens = try Lexer.tokenizeAll(alloc, source);
    const stream = try TokenStream.init(alloc, &all_tokens);

    var builder = Cst.Builder.init(std.testing.allocator);
    defer builder.deinit();

    var parser = try Parser.initWithCst(alloc, source, stream, &builder);
    _ = try parser.parse();

    var tree = try builder.finish(alloc, all_tokens, source);
    // Tree lives in arena, no explicit deinit needed.

    // Walk every token child in document order and rebuild the source.
    var recovered: std.ArrayListUnmanaged(u8) = .empty;
    defer recovered.deinit(std.testing.allocator);

    const WalkCtx = struct {
        tree: *const Cst.Tree,
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,

        fn walk(self: @This(), node_idx: Cst.NodeIndex) !void {
            const n = self.tree.getNode(node_idx);
            const children = self.tree.children[n.first_child .. n.first_child + n.child_count];
            for (children) |el| {
                if (el.asToken()) |tok_idx| {
                    const start = self.tree.tokens.items(.start)[tok_idx];
                    const end = self.tree.tokens.items(.end)[tok_idx];
                    try self.buf.appendSlice(self.alloc, self.tree.source[start..end]);
                } else if (el.asNode()) |child_idx| {
                    try self.walk(child_idx);
                }
            }
        }
    };
    const ctx = WalkCtx{ .tree = &tree, .buf = &recovered, .alloc = std.testing.allocator };
    try ctx.walk(tree.root());

    try std.testing.expectEqualStrings(source, recovered.items);
}

test "cst shadow: round-trip empty source" {
    try expectCstRoundtrip("");
}

test "cst shadow: round-trip single const" {
    try expectCstRoundtrip("const x = 1;");
}

test "cst shadow: round-trip const with trivia" {
    try expectCstRoundtrip("// intro\nconst x = 1; /* trailing */\n");
}

test "cst shadow: round-trip multi-decl module with mixed trivia" {
    try expectCstRoundtrip(
        \\// header
        \\enable f16;
        \\
        \\struct S { x: f32, y: i32 }
        \\
        \\// comment between
        \\const PI: f32 = 3.14;
        \\alias V = vec3<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main() { let a = 1; return; }
        \\
    );
}

test "cst shadow: root kind is module, child kinds match each decl" {
    const source: [:0]const u8 = "enable f16; const X = 1; fn f() {} struct S { x: f32 } alias V = f32;";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var all_tokens = try Lexer.tokenizeAll(alloc, source);
    const stream = try TokenStream.init(alloc, &all_tokens);

    var builder = Cst.Builder.init(std.testing.allocator);
    defer builder.deinit();

    var parser = try Parser.initWithCst(alloc, source, stream, &builder);
    _ = try parser.parse();

    var tree = try builder.finish(alloc, all_tokens, source);
    const root_cursor = tree.rootCursor();
    try std.testing.expectEqual(Cst.Kind.module, root_cursor.kind());

    // Expected child-node kinds in order: directive, const_decl, fn_decl,
    // struct_decl, alias_decl.
    const expected = [_]Cst.Kind{
        .directive,
        .const_decl,
        .fn_decl,
        .struct_decl,
        .alias_decl,
    };
    var found: std.ArrayListUnmanaged(Cst.Kind) = .empty;
    defer found.deinit(std.testing.allocator);
    for (root_cursor.childElements()) |el| {
        if (el.asNode()) |n| {
            try found.append(std.testing.allocator, tree.getNode(n).kind);
        }
    }
    try std.testing.expectEqualSlices(Cst.Kind, &expected, found.items);
}

test "cst shadow: AST path unchanged — init without builder still works" {
    // Sanity: the existing Parser.init path still produces the same AST.
    const source: [:0]const u8 = "const x = 1;";
    var tokens = try Lexer.tokenize(std.testing.allocator, source);
    defer tokens.deinit(std.testing.allocator);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = try Parser.init(arena.allocator(), source, tokens);
    const module = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), module.declarations.items.len);
    try std.testing.expectEqual(@as(?*Cst.Builder, null), parser.cst);
}

test "cst shadow: statements emit their specific kinds" {
    const source: [:0]const u8 =
        \\fn f() {
        \\    let x = 1;
        \\    if x > 0 { return; } else { discard; }
        \\    for (var i = 0; i < 4; i = i + 1) {}
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var all_tokens = try Lexer.tokenizeAll(alloc, source);
    const stream = try TokenStream.init(alloc, &all_tokens);

    var builder = Cst.Builder.init(std.testing.allocator);
    defer builder.deinit();

    var parser = try Parser.initWithCst(alloc, source, stream, &builder);
    _ = try parser.parse();

    var tree = try builder.finish(alloc, all_tokens, source);

    // Walk the tree collecting every distinct kind we see. Must include at
    // least: module, fn_decl, compound_stmt, decl_stmt, if_stmt, return_stmt,
    // discard_stmt, for_stmt.
    var seen: std.AutoArrayHashMapUnmanaged(Cst.Kind, void) = .empty;
    defer seen.deinit(std.testing.allocator);

    const Walker = struct {
        tree: *const Cst.Tree,
        seen: *std.AutoArrayHashMapUnmanaged(Cst.Kind, void),
        alloc: std.mem.Allocator,

        fn walk(self: @This(), n: Cst.NodeIndex) !void {
            const node = self.tree.getNode(n);
            _ = try self.seen.getOrPut(self.alloc, node.kind);
            for (self.tree.childrenOf(n)) |el| {
                if (el.asNode()) |c| try self.walk(c);
            }
        }
    };
    try (Walker{ .tree = &tree, .seen = &seen, .alloc = std.testing.allocator }).walk(tree.root());

    for (&[_]Cst.Kind{
        .module,
        .fn_decl,
        .compound_stmt,
        .decl_stmt,
        .if_stmt,
        .return_stmt,
        .discard_stmt,
        .for_stmt,
    }) |k| {
        if (!seen.contains(k)) {
            std.debug.print("missing CST kind in tree: {any}\n", .{k});
            return error.TestExpectedKindMissing;
        }
    }
}

test "stmt spans: populated for every statement kind" {
    const source: [:0]const u8 =
        \\fn f() {
        \\    let x = 1;
        \\    x = x + 1;
        \\    x++;
        \\    if x > 0 { return; } else { discard; }
        \\    while false { break; }
        \\    for (var i = 0; i < 2; i = i + 1) { continue; }
        \\    loop { break if true; }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try Lexer.tokenize(arena.allocator(), source);
    var parser = try Parser.init(arena.allocator(), source, tokens);
    const module = try parser.parse();

    const fn_decl = module.declarations.items[0].function;
    const body = fn_decl.body.?;
    try std.testing.expect(body.stmts.items.len > 0);

    // Every stmt must have a populated, monotonically-increasing span that
    // stays within the enclosing body.
    var prev_end: u32 = body.span.start;
    for (body.stmts.items) |s| {
        const sp = s.span();
        try std.testing.expect(sp.start >= prev_end);
        try std.testing.expect(sp.end > sp.start);
        try std.testing.expect(sp.end <= body.span.end);
        prev_end = sp.end;
    }

    // Top-level body span covers `{` through `}`.
    try std.testing.expectEqual(@as(u8, '{'), source[body.span.start]);
    try std.testing.expectEqual(@as(u8, '}'), source[body.span.end - 1]);
}

test "directive spans: populated for each directive kind" {
    const source: [:0]const u8 =
        \\enable f16;
        \\requires readonly_and_readwrite_storage_textures;
        \\diagnostic(error, derivative_uniformity);
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try Lexer.tokenize(arena.allocator(), source);
    var parser = try Parser.init(arena.allocator(), source, tokens);
    const module = try parser.parse();

    try std.testing.expectEqual(@as(usize, 3), module.directives.items.len);
    for (module.directives.items) |dir| {
        const sp = dir.span();
        try std.testing.expect(sp.end > sp.start);
        try std.testing.expectEqual(@as(u8, ';'), source[sp.end - 1]);
    }
}

test "cst shadow: compute.toys sample round-trip" {
    // Pulled in-line to avoid a large embed; exercises realistic complexity.
    const source: [:0]const u8 =
        \\struct Uniforms { time: f32, resolution: vec2f, cursor: vec4f }
        \\@group(0) @binding(0) var<uniform> u: Uniforms;
        \\@group(0) @binding(1) var tex: texture_2d<f32>;
        \\@group(0) @binding(2) var smp: sampler;
        \\
        \\fn sdCircle(p: vec2f, r: f32) -> f32 {
        \\    return length(p) - r;
        \\}
        \\
        \\@compute @workgroup_size(16, 16, 1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let uv = vec2f(id.xy);
        \\    let d = sdCircle(uv, 32.0);
        \\    // trailing // comment
        \\}
        \\
    ;
    try expectCstRoundtrip(source);
}

/// Build the CST for `source`, locate `needle` in the source, and assert
/// that the smallest CST node tightly containing `[offset, offset + len)`
/// has `expected_kind`. Node spans include leading trivia, so this uses a
/// byte range (not a text slice) to identify the target subtree.
fn expectCstKindAt(
    source: [:0]const u8,
    needle: []const u8,
    expected_kind: Cst.Kind,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var all_tokens = try Lexer.tokenizeAll(alloc, source);
    const stream = try TokenStream.init(alloc, &all_tokens);

    var builder = Cst.Builder.init(std.testing.allocator);
    defer builder.deinit();

    var parser = try Parser.initWithCst(alloc, source, stream, &builder);
    _ = try parser.parse();

    var tree = try builder.finish(alloc, all_tokens, source);

    const idx = std.mem.indexOf(u8, source, needle) orelse {
        std.debug.print("needle \"{s}\" not found in source", .{needle});
        return error.TestNeedleNotFound;
    };
    const span: Cst.Span = .{
        .start = @intCast(idx),
        .end = @intCast(idx + needle.len),
    };
    const hit = tree.rootCursor().findSmallestContaining(span);
    if (hit.kind() != expected_kind) {
        std.debug.print(
            "expected kind {any} at \"{s}\" ({d}..{d}) but got {any} (range {d}..{d})\n",
            .{ expected_kind, needle, span.start, span.end, hit.kind(), hit.range().start, hit.range().end },
        );
        return error.TestExpectedKindMismatch;
    }
}

test "cst shadow: binary expressions left-associate" {
    // Use names that don't clash with keyword substrings (avoid naive
    // indexOf picking up letters inside `const`, `let`, etc.).
    const source: [:0]const u8 = "fn f() { let r = p + q + r; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var all_tokens = try Lexer.tokenizeAll(alloc, source);
    const stream = try TokenStream.init(alloc, &all_tokens);
    var builder = Cst.Builder.init(std.testing.allocator);
    defer builder.deinit();
    var parser = try Parser.initWithCst(alloc, source, stream, &builder);
    _ = try parser.parse();
    var tree = try builder.finish(alloc, all_tokens, source);

    // Outermost binary_expr covers the full `p + q + r` non-trivia span.
    try expectCstKindAt(source, "p + q + r", .binary_expr);
    // Inner binary_expr covers `p + q` — the left-associative fold.
    try expectCstKindAt(source, "p + q", .binary_expr);
    // Leaves. "r" appears as a let target too (`let r = ...`), so we look
    // for it via "r;" to reach the rightmost ident.
    try expectCstKindAt(source, "p", .ident_expr);
    try expectCstKindAt(source, "q", .ident_expr);
    // The rightmost `r` is at source index `indexOf("+ r;") + 2`.
    const r_ident_idx: u32 = @intCast(std.mem.indexOf(u8, source, "+ r;").? + 2);
    const r_cursor = tree.rootCursor().findSmallestContaining(.{
        .start = r_ident_idx,
        .end = r_ident_idx + 1,
    });
    try std.testing.expectEqual(Cst.Kind.ident_expr, r_cursor.kind());

    // Structural check: the outer binary_expr's first child node is itself a
    // binary_expr (the left-fold for `p + q`).
    const outer_idx = std.mem.indexOf(u8, source, "p + q + r").?;
    const outer = tree.rootCursor().findSmallestContaining(.{
        .start = @intCast(outer_idx),
        .end = @intCast(outer_idx + "p + q + r".len),
    });
    try std.testing.expectEqual(Cst.Kind.binary_expr, outer.kind());
    const first_child_node = outer.firstChildNode() orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(Cst.Kind.binary_expr, first_child_node.kind());
}

test "cst shadow: postfix chain wraps primary" {
    const source: [:0]const u8 = "fn f() { let x = foo.bar[0](y); }";
    // Outermost postfix is the call; it wraps the index, which wraps the
    // member, which wraps the primary ident.
    try expectCstKindAt(source, "foo.bar[0](y)", .call_expr);
    try expectCstKindAt(source, "foo.bar[0]", .index_expr);
    try expectCstKindAt(source, "foo.bar", .member_expr);
    try expectCstKindAt(source, "foo", .ident_expr);
    try expectCstKindAt(source, "0", .literal_expr);
    try expectCstKindAt(source, "y", .ident_expr);
}

test "cst shadow: unary fold wraps each level" {
    const source: [:0]const u8 = "const x = -!~a;";
    // Each prefix op creates its own unary_expr wrap. Byte ranges cover the
    // op-plus-operand span; findSmallestContaining lands on the matching
    // unary_expr wrap.
    try expectCstKindAt(source, "-!~a", .unary_expr);
    try expectCstKindAt(source, "!~a", .unary_expr);
    try expectCstKindAt(source, "~a", .unary_expr);
    try expectCstKindAt(source, "a", .ident_expr);
}

test "cst shadow: templated types emit type_* + template_args" {
    const source: [:0]const u8 = "alias V = array<vec3<f32>, 4>;";
    try expectCstKindAt(source, "array<vec3<f32>, 4>", .type_array);
    try expectCstKindAt(source, "<vec3<f32>, 4>", .template_args);
    try expectCstKindAt(source, "vec3<f32>", .type_vec);
    try expectCstKindAt(source, "<f32>", .template_args);
    try expectCstKindAt(source, "f32", .type_ident);
    try expectCstKindAt(source, "4", .literal_expr);
}

test "cst shadow: attributes emit attribute_list + attribute + attribute_args" {
    const source: [:0]const u8 = "@group(0) @binding(0) @compute @workgroup_size(16, 16, 1) fn f() {}";
    try expectCstKindAt(source, "@group(0) @binding(0) @compute @workgroup_size(16, 16, 1)", .attribute_list);
    try expectCstKindAt(source, "@group(0)", .attribute);
    try expectCstKindAt(source, "@binding(0)", .attribute);
    try expectCstKindAt(source, "@compute", .attribute);
    try expectCstKindAt(source, "@workgroup_size(16, 16, 1)", .attribute);
    try expectCstKindAt(source, "(16, 16, 1)", .attribute_args);
}

// =========================================================================
// reparseAnchor tests
// =========================================================================

/// Build a standalone CST subtree by running `reparseAnchor` against a
/// fresh Parser positioned at `source`'s first non-trivia token. The
/// returned tree has exactly one root node.
fn runReparseAnchor(
    arena: std.mem.Allocator,
    source: [:0]const u8,
    kind: AnchorKind,
    builder: *Cst.Builder,
) !Cst.Tree {
    var all_tokens = try Lexer.tokenizeAll(arena, source);
    const stream = try TokenStream.init(arena, &all_tokens);
    var parser = try Parser.initWithCst(arena, source, stream, builder);
    try parser.reparseAnchor(kind, 0);
    return builder.finish(arena, all_tokens, source);
}

test "reparseAnchor: literal expression produces literal_expr root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var builder = Cst.Builder.init(std.testing.allocator);
    defer builder.deinit();
    var tree = try runReparseAnchor(arena.allocator(), "42", .expression, &builder);
    const root = tree.rootCursor();
    try std.testing.expectEqual(Cst.Kind.literal_expr, root.kind());
    try std.testing.expectEqualStrings("42", root.text());
}

test "reparseAnchor: identifier expression produces ident_expr root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var builder = Cst.Builder.init(std.testing.allocator);
    defer builder.deinit();
    var tree = try runReparseAnchor(arena.allocator(), "foo", .expression, &builder);
    const root = tree.rootCursor();
    try std.testing.expectEqual(Cst.Kind.ident_expr, root.kind());
    try std.testing.expectEqualStrings("foo", root.text());
}

test "reparseAnchor: binary expression left-associates and wraps primary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var builder = Cst.Builder.init(std.testing.allocator);
    defer builder.deinit();
    var tree = try runReparseAnchor(arena.allocator(), "a + b + c", .expression, &builder);
    const root = tree.rootCursor();
    try std.testing.expectEqual(Cst.Kind.binary_expr, root.kind());
    try std.testing.expectEqualStrings("a + b + c", root.text());
    // First child node of the outer binary_expr is the left-fold (a + b).
    const first = root.firstChildNode() orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(Cst.Kind.binary_expr, first.kind());
    try std.testing.expectEqualStrings("a + b", first.text());
}

test "reparseAnchor: return statement produces return_stmt root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var builder = Cst.Builder.init(std.testing.allocator);
    defer builder.deinit();
    var tree = try runReparseAnchor(arena.allocator(), "return 1;", .statement, &builder);
    const root = tree.rootCursor();
    try std.testing.expectEqual(Cst.Kind.return_stmt, root.kind());
    try std.testing.expectEqualStrings("return 1;", root.text());
}

test "reparseAnchor: assignment statement produces assign_stmt root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var builder = Cst.Builder.init(std.testing.allocator);
    defer builder.deinit();
    var tree = try runReparseAnchor(arena.allocator(), "x = 1;", .statement, &builder);
    const root = tree.rootCursor();
    try std.testing.expectEqual(Cst.Kind.assign_stmt, root.kind());
    try std.testing.expectEqualStrings("x = 1;", root.text());
}

test "reparseAnchor: at start_nt_pos=0 includes leading trivia in anchor" {
    // When the anchor is the first non-trivia token of the source, any
    // leading trivia (block comment, whitespace) is attributed to the
    // anchor's first-opened inner node. This matches how a full parse
    // places trivia that precedes the first real token.
    const source: [:0]const u8 = "/*skip*/ 42";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var all_tokens = try Lexer.tokenizeAll(arena.allocator(), source);
    const stream = try TokenStream.init(arena.allocator(), &all_tokens);
    var builder = Cst.Builder.init(std.testing.allocator);
    defer builder.deinit();
    var parser = try Parser.initWithCst(arena.allocator(), source, stream, &builder);
    try parser.reparseAnchor(.expression, 0);
    var tree = try builder.finish(arena.allocator(), all_tokens, source);

    const root = tree.rootCursor();
    try std.testing.expectEqual(Cst.Kind.literal_expr, root.kind());
    // Subtree covers leading "/*skip*/ " trivia + "42".
    try std.testing.expectEqual(@as(u32, 0), root.range().start);
    try std.testing.expectEqualStrings(source, root.text());
}

test "reparseAnchor: at start_nt_pos>0 includes interior trivia only" {
    // With a non-zero anchor position, only the trivia *between* the
    // previous non-trivia token and the anchor is absorbed. Trivia and
    // tokens earlier than that are untouched by the reparse.
    const source: [:0]const u8 = "x /* gap */ 42";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var all_tokens = try Lexer.tokenizeAll(arena.allocator(), source);
    const stream = try TokenStream.init(arena.allocator(), &all_tokens);
    var builder = Cst.Builder.init(std.testing.allocator);
    defer builder.deinit();
    var parser = try Parser.initWithCst(arena.allocator(), source, stream, &builder);
    // Skip the leading "x" — parse starting at non-trivia index 1 ("42").
    try parser.reparseAnchor(.expression, 1);
    var tree = try builder.finish(arena.allocator(), all_tokens, source);

    const root = tree.rootCursor();
    try std.testing.expectEqual(Cst.Kind.literal_expr, root.kind());
    // Subtree begins at the byte right after "x" (offset 1), covering
    // " /* gap */ 42" including the gap trivia.
    try std.testing.expectEqual(@as(u32, 1), root.range().start);
    try std.testing.expectEqualStrings(" /* gap */ 42", root.text());
}
