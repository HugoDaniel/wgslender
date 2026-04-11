//! WGSL Language Server — shared handler logic.
//!
//! Transport-agnostic core used by both the native (stdio) and WASM
//! entry points. Manages open documents, runs wgslender validation,
//! and converts diagnostics to a simple LSP-compatible format.
//!
//! This module has NO dependency on lsp-kit so it compiles for WASM.

const std = @import("std");
const wgslender = @import("wgslender");

const WgslDiagnostic = wgslender.Diagnostic;

const Handler = @This();

gpa: std.mem.Allocator,
documents: std.StringHashMapUnmanaged(Document),

pub const Document = struct {
    source: []u8,
    version: i32,
    /// Cached analysis result. Invalidated on document change/close.
    analysis: ?*wgslender.Validator.AnalysisResult = null,
    /// Sentinel-terminated source used by the analysis. Must stay alive
    /// as long as the analysis result since the AST holds slices into it.
    analysis_source: ?[:0]u8 = null,
};

// =========================================================================
// LSP-compatible diagnostic (no lsp-kit dependency)
// =========================================================================

pub const Position = struct { line: u32, character: u32 };
pub const Range = struct { start: Position, end: Position };

pub const DiagnosticSeverity = enum(u32) {
    @"error" = 1,
    warning = 2,
    information = 3,
    hint = 4,
};

pub const LspRelatedInfo = struct {
    range: Range,
    message: []const u8,
};

pub const LspDiagnostic = struct {
    range: Range,
    severity: DiagnosticSeverity,
    message: []const u8,
    code: []const u8 = "",
    spec_url: []const u8 = "",
    related: []const LspRelatedInfo = &.{},
};

pub const LspTextEdit = struct {
    range: Range,
    new_text: []const u8,
};

pub const LspCodeAction = struct {
    title: []const u8,
    kind: []const u8, // "quickfix"
    is_preferred: bool = false,
    diagnostic: LspDiagnostic,
    edits: []const LspTextEdit,
};

/// Server capabilities as a JSON string (shared by native and WASM).
pub const capabilities_json =
    \\{"textDocumentSync":{"openClose":true,"change":1},"positionEncoding":"utf-16","codeActionProvider":{"codeActionKinds":["quickfix"]},"hoverProvider":true,"definitionProvider":true,"referencesProvider":true,"renameProvider":{"prepareProvider":true},"completionProvider":{"triggerCharacters":[".","@"]},"signatureHelpProvider":{"triggerCharacters":["(",","]},"documentSymbolProvider":true,"foldingRangeProvider":true}
;

/// Creates a handler with an empty document store.
pub fn init(gpa: std.mem.Allocator) Handler {
    return .{
        .gpa = gpa,
        .documents = .empty,
    };
}

/// Frees all tracked documents and their sources.
pub fn deinit(self: *Handler) void {
    var it = self.documents.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.analysis) |a| {
            a.deinit(self.gpa);
            self.gpa.destroy(a);
        }
        if (entry.value_ptr.analysis_source) |s| {
            self.gpa.free(s);
        }
        self.gpa.free(entry.key_ptr.*);
        self.gpa.free(entry.value_ptr.source);
    }
    self.documents.deinit(self.gpa);
}

fn invalidateAnalysis(self: *Handler, uri: []const u8) void {
    const doc = self.documents.getPtr(uri) orelse return;
    if (doc.analysis) |a| {
        a.deinit(self.gpa);
        self.gpa.destroy(a);
        doc.analysis = null;
    }
    if (doc.analysis_source) |s| {
        self.gpa.free(s);
        doc.analysis_source = null;
    }
}

// =========================================================================
// Document management
// =========================================================================

/// Registers a new document (or replaces an existing one) with the given source text.
pub fn openDocument(self: *Handler, uri: []const u8, text: []const u8, version: i32) !void {
    const new_source = try self.gpa.dupe(u8, text);
    errdefer self.gpa.free(new_source);

    const gop = try self.documents.getOrPut(self.gpa, uri);
    if (gop.found_existing) {
        self.gpa.free(gop.value_ptr.source);
    } else {
        gop.key_ptr.* = try self.gpa.dupe(u8, uri);
    }
    gop.value_ptr.* = .{ .source = new_source, .version = version };
}

/// Replaces the source text of an already-open document.
pub fn changeDocument(self: *Handler, uri: []const u8, text: []const u8) !void {
    self.invalidateAnalysis(uri);
    const doc = self.documents.getPtr(uri) orelse return;
    const new_source = try self.gpa.dupe(u8, text);
    self.gpa.free(doc.source);
    doc.source = new_source;
}

/// Removes a document and frees its source and URI.
pub fn closeDocument(self: *Handler, uri: []const u8) void {
    self.invalidateAnalysis(uri);
    const entry = self.documents.fetchRemove(uri) orelse return;
    self.gpa.free(entry.key);
    self.gpa.free(entry.value.source);
}

pub fn getDocumentSource(self: *const Handler, uri: []const u8) ?[]const u8 {
    const doc = self.documents.get(uri) orelse return null;
    return doc.source;
}

/// Returns cached analysis result for a document, running analysis if needed.
/// The returned pointer is owned by the Handler and valid until the document
/// is changed or closed.
pub fn analyzeDocument(self: *Handler, uri: []const u8) !*wgslender.Validator.AnalysisResult {
    const doc = self.documents.getPtr(uri) orelse return error.DocumentNotFound;
    if (doc.analysis) |a| return a;

    // The sentinel-terminated source must stay alive as long as the analysis
    // result, because the AST holds slices into it.
    const source_z = try self.gpa.dupeZ(u8, doc.source);
    errdefer self.gpa.free(source_z);

    const result = try self.gpa.create(wgslender.Validator.AnalysisResult);
    errdefer self.gpa.destroy(result);
    result.* = try wgslender.analyzeWithOptions(self.gpa, source_z, .{});
    doc.analysis = result;
    doc.analysis_source = source_z;
    return result;
}

// =========================================================================
// Diagnostics
// =========================================================================

/// Run wgslender validation and return LSP diagnostics.
/// Caller owns the returned slice — free with the same allocator.
pub fn validateDocument(self: *Handler, source: []const u8) ![]LspDiagnostic {
    const source_z = try self.gpa.dupeZ(u8, source);
    defer self.gpa.free(source_z);

    var result = try wgslender.validateWithOptions(self.gpa, source_z, .{});
    defer result.deinit(self.gpa);

    const entries = result.diagnostics.diagnostics.items;
    const diags = try self.gpa.alloc(LspDiagnostic, entries.len);

    for (entries, 0..) |entry, i| {
        diags[i] = convertDiagnostic(self.gpa, &entry);
    }

    return diags;
}

const wgsl_spec_base = "https://www.w3.org/TR/WGSL/#";

fn convertDiagnostic(gpa: std.mem.Allocator, entry: *const WgslDiagnostic.Entry) LspDiagnostic {
    var related: []const LspRelatedInfo = &.{};
    if (entry.related.len > 0) {
        if (gpa.alloc(LspRelatedInfo, entry.related.len)) |rel| {
            for (entry.related, 0..) |r, ri| {
                rel[ri] = .{
                    .range = .{
                        .start = .{
                            .line = if (r.range.start.line > 0) r.range.start.line - 1 else 0,
                            .character = if (r.range.start.column > 0) r.range.start.column - 1 else 0,
                        },
                        .end = .{
                            .line = if (r.range.end.line > 0) r.range.end.line - 1 else 0,
                            .character = if (r.range.end.column > 0) r.range.end.column - 1 else 0,
                        },
                    },
                    .message = gpa.dupe(u8, r.message) catch "",
                };
            }
            related = rel;
        } else |_| {}
    }
    return .{
        .range = .{
            .start = .{
                .line = if (entry.range.start.line > 0) entry.range.start.line - 1 else 0,
                .character = if (entry.range.start.column > 0) entry.range.start.column - 1 else 0,
            },
            .end = .{
                .line = if (entry.range.end.line > 0) entry.range.end.line - 1 else 0,
                .character = if (entry.range.end.column > 0) entry.range.end.column - 1 else 0,
            },
        },
        .severity = switch (entry.severity) {
            .@"error" => .@"error",
            .warning => .warning,
            .note => .information,
            else => .information,
        },
        .message = gpa.dupe(u8, entry.message) catch "",
        .code = entry.code,
        .spec_url = if (entry.code.len > 0 and entry.spec_ref.len > 0) blk: {
            const url = gpa.alloc(u8, wgsl_spec_base.len + entry.spec_ref.len) catch break :blk "";
            @memcpy(url[0..wgsl_spec_base.len], wgsl_spec_base);
            @memcpy(url[wgsl_spec_base.len..], entry.spec_ref);
            break :blk url;
        } else "",
        .related = related,
    };
}

// =========================================================================
// Code Actions
// =========================================================================

/// Extract the suggestion from a "did you mean 'X'?" diagnostic message.
/// Returns the suggested name, or null if the message doesn't contain one.
pub fn extractDidYouMean(message: []const u8) ?[]const u8 {
    const needle = "; did you mean '";
    const idx = std.mem.indexOf(u8, message, needle) orelse return null;
    const start = idx + needle.len;
    const end = std.mem.indexOfPos(u8, message, start, "'") orelse return null;
    if (start >= end) return null;
    return message[start..end];
}

/// Extract the location number from a "duplicate input/output @location(N)" message.
/// Returns the numeric value N, or null if the message doesn't match.
pub fn extractDuplicateLocation(message: []const u8) ?i64 {
    // Look for "duplicate input @location(" or "duplicate output @location("
    const patterns = [_][]const u8{ "duplicate input @location(", "duplicate output @location(" };
    for (patterns) |pattern| {
        if (std.mem.indexOf(u8, message, pattern)) |idx| {
            const start = idx + pattern.len;
            const end = std.mem.indexOfPos(u8, message, start, ")") orelse continue;
            if (start >= end) continue;
            return std.fmt.parseInt(i64, message[start..end], 10) catch continue;
        }
    }
    return null;
}

/// Compute code actions for the given diagnostics.
/// Caller owns the returned slice.
pub fn computeCodeActions(
    self: *Handler,
    diags: []const LspDiagnostic,
) ![]LspCodeAction {
    var actions: std.ArrayListUnmanaged(LspCodeAction) = .empty;

    for (diags) |diag| {
        // "Did you mean?" rename fix
        if (isDidYouMeanCode(diag.code)) {
            if (extractDidYouMean(diag.message)) |suggestion| {
                const title = std.fmt.allocPrint(self.gpa, "Replace with '{s}'", .{suggestion}) catch continue;
                const new_text = self.gpa.dupe(u8, suggestion) catch {
                    self.gpa.free(title);
                    continue;
                };
                const edit = self.gpa.alloc(LspTextEdit, 1) catch {
                    self.gpa.free(new_text);
                    self.gpa.free(title);
                    continue;
                };
                edit[0] = .{ .range = diag.range, .new_text = new_text };
                actions.append(self.gpa, .{
                    .title = title,
                    .kind = "quickfix",
                    .is_preferred = true,
                    .diagnostic = diag,
                    .edits = edit,
                }) catch {
                    self.gpa.free(edit);
                    self.gpa.free(new_text);
                    self.gpa.free(title);
                };
            }
        }

        // Duplicate @location(N) → increment to N+1
        if (std.mem.eql(u8, diag.code, "E0602")) {
            if (extractDuplicateLocation(diag.message)) |loc_val| {
                const new_val = loc_val + 1;
                const title = std.fmt.allocPrint(self.gpa, "Change to @location({d})", .{new_val}) catch continue;
                const new_text = std.fmt.allocPrint(self.gpa, "@location({d})", .{new_val}) catch {
                    self.gpa.free(title);
                    continue;
                };
                // Find @location(...) within the source at the diagnostic range
                const attr_range = self.findLocationAttrRange(diag.range) orelse {
                    self.gpa.free(new_text);
                    self.gpa.free(title);
                    continue;
                };
                const edit = self.gpa.alloc(LspTextEdit, 1) catch {
                    self.gpa.free(new_text);
                    self.gpa.free(title);
                    continue;
                };
                edit[0] = .{ .range = attr_range, .new_text = new_text };
                actions.append(self.gpa, .{
                    .title = title,
                    .kind = "quickfix",
                    .is_preferred = false,
                    .diagnostic = diag,
                    .edits = edit,
                }) catch {
                    self.gpa.free(edit);
                    self.gpa.free(new_text);
                    self.gpa.free(title);
                };
            }
        }
    }

    return actions.toOwnedSlice(self.gpa) catch &.{};
}

fn isDidYouMeanCode(code: []const u8) bool {
    // E0100 = undefined_symbol, E0200 = type_mismatch (unknown type),
    // E0204 = not_callable, E0206 = no_such_member, E0403 = invalid_builtin
    return std.mem.eql(u8, code, "E0100") or
        std.mem.eql(u8, code, "E0200") or
        std.mem.eql(u8, code, "E0204") or
        std.mem.eql(u8, code, "E0206") or
        std.mem.eql(u8, code, "E0403");
}

/// Search the document source near a diagnostic range to find the actual
/// @location(N) attribute range, so the edit replaces the whole annotation.
fn findLocationAttrRange(self: *Handler, diag_range: Range) ?Range {
    // We need the source to scan for @location(...) near the diagnostic.
    // Iterate all open documents to find one containing this range.
    // (Code actions are always for the current document, so we check all.)
    var it = self.documents.iterator();
    while (it.next()) |entry| {
        const source = entry.value_ptr.source;
        // Convert LSP 0-based line/col to byte offset in the source.
        if (lspPositionToOffset(source, diag_range.start)) |start_offset| {
            // Search backwards from the diagnostic start for @location(
            const search_start = if (start_offset > 30) start_offset - 30 else 0;
            const region = source[search_start..@min(source.len, start_offset + 50)];
            if (std.mem.indexOf(u8, region, "@location(")) |rel_idx| {
                const abs_start = search_start + rel_idx;
                // Find the closing )
                if (std.mem.indexOfPos(u8, source, abs_start, ")")) |close_paren| {
                    const abs_end = close_paren + 1; // include the )
                    // Convert back to LSP positions
                    var line_index = WgslDiagnostic.LineIndex.init(self.gpa, source) catch return null;
                    // LineIndex is 0-based; LSP is also 0-based
                    const s = line_index.byteOffsetToLineColumn(@intCast(abs_start));
                    const e = line_index.byteOffsetToLineColumn(@intCast(abs_end));
                    line_index.deinit(self.gpa);
                    return .{
                        .start = .{ .line = s.line, .character = s.col },
                        .end = .{ .line = e.line, .character = e.col },
                    };
                }
            }
        }
    }
    return null;
}

/// Convert an LSP 0-based line:character position to a byte offset in source.
/// Handles LF, CR, and CRLF line endings.
pub fn lspPositionToOffset(source: []const u8, pos: Position) ?usize {
    var line: u32 = 0;
    var i: usize = 0;
    while (line < pos.line and i < source.len) {
        if (source[i] == '\r') {
            line += 1;
            // Skip LF in CRLF pair
            if (i + 1 < source.len and source[i + 1] == '\n') {
                i += 1;
            }
        } else if (source[i] == '\n') {
            line += 1;
        }
        i += 1;
    }
    if (line != pos.line) return null;
    const offset = i + pos.character;
    if (offset > source.len) return null;
    return offset;
}

/// Convert a byte offset to an LSP 0-based Position.
/// Uses a simple linear scan (suitable for typical shader sizes).
pub fn offsetToLspPosition(source: []const u8, offset: u32) ?Position {
    if (offset > source.len) return null;
    var line: u32 = 0;
    var col: u32 = 0;
    var i: u32 = 0;
    while (i < offset) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            col = 0;
        } else if (source[i] == '\r') {
            line += 1;
            col = 0;
            if (i + 1 < offset and source[i + 1] == '\n') {
                i += 1; // skip LF in CRLF
            }
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .character = col };
}

/// Convert a byte offset range to an LSP Range.
pub fn offsetRangeToLspRange(source: []const u8, start: u32, end: u32) ?Range {
    const start_pos = offsetToLspPosition(source, start) orelse return null;
    const end_pos = offsetToLspPosition(source, end) orelse return null;
    return .{ .start = start_pos, .end = end_pos };
}

// =========================================================================
// AST Node-at-Position Lookup
// =========================================================================

const Ast = wgslender.Ast;

pub const NodeAtPosition = union(enum) {
    /// An identifier expression referencing a symbol.
    ident: struct { name: []const u8, ref: Ast.SymbolIndex, loc: u32 },
    /// A member access expression (e.g., `s.field`).
    member_access: struct { member: []const u8, loc: u32 },
    /// A declaration name (the identifier in fn/struct/var/const/let/alias).
    decl_name: struct { sym_idx: Ast.SymbolIndex, loc: u32 },
    /// A type reference (e.g., `f32`, `MyStruct` in a type annotation).
    type_ref: struct { name: []const u8, ref: Ast.SymbolIndex, loc: u32 },
    /// No identifiable node at this position.
    none,
};

/// Find the AST node at a given byte offset in the source.
/// Walks declarations, statements, and expressions to find the
/// most specific node covering the offset.
pub fn findNodeAtOffset(module: *const Ast.Module, offset: u32) NodeAtPosition {
    for (module.declarations.items) |decl| {
        const result = findInDecl(module, decl, offset);
        if (result != .none) return result;
    }
    return .none;
}

fn findInDecl(module: *const Ast.Module, decl: Ast.Decl, offset: u32) NodeAtPosition {
    switch (decl) {
        .function => |f| {
            if (checkDeclName(module, f.name, offset)) |r| return r;
            for (f.parameters.items) |param| {
                if (checkDeclName(module, param.name, offset)) |r| return r;
                if (findInType(param.typ, offset)) |r| return r;
            }
            if (f.return_type) |rt| {
                if (findInType(rt, offset)) |r| return r;
            }
            if (f.body) |body| {
                if (findInCompound(module, body, offset)) |r| return r;
            }
        },
        .@"struct" => |s| {
            if (checkDeclName(module, s.name, offset)) |r| return r;
            for (s.members.items) |m| {
                if (checkDeclName(module, m.name, offset)) |r| return r;
                if (findInType(m.typ, offset)) |r| return r;
            }
        },
        .@"const" => |c| {
            if (checkDeclName(module, c.name, offset)) |r| return r;
            if (c.typ) |t| {
                if (findInType(t, offset)) |r| return r;
            }
            if (c.initializer) |initializer| {
                if (findInExpr(initializer, offset)) |r| return r;
            }
        },
        .override => |o| {
            if (checkDeclName(module, o.name, offset)) |r| return r;
            if (o.typ) |t| {
                if (findInType(t, offset)) |r| return r;
            }
            if (o.initializer) |initializer| {
                if (findInExpr(initializer, offset)) |r| return r;
            }
        },
        .@"var" => |v| {
            if (checkDeclName(module, v.name, offset)) |r| return r;
            if (v.typ) |t| {
                if (findInType(t, offset)) |r| return r;
            }
            if (v.initializer) |initializer| {
                if (findInExpr(initializer, offset)) |r| return r;
            }
        },
        .let => |l| {
            if (checkDeclName(module, l.name, offset)) |r| return r;
            if (l.typ) |t| {
                if (findInType(t, offset)) |r| return r;
            }
            if (l.initializer) |initializer| {
                if (findInExpr(initializer, offset)) |r| return r;
            }
        },
        .alias => |a| {
            if (checkDeclName(module, a.name, offset)) |r| return r;
            if (findInType(a.typ, offset)) |r| return r;
        },
        .const_assert => |ca| {
            if (findInExpr(ca.expr, offset)) |r| return r;
        },
    }
    return .none;
}

fn checkDeclName(module: *const Ast.Module, sym_idx: Ast.SymbolIndex, offset: u32) ?NodeAtPosition {
    if (!sym_idx.isValid()) return null;
    const sym = module.symbols.items[sym_idx.index()];
    if (offset >= sym.loc and offset < sym.loc + @as(u32, @intCast(sym.original_name.len))) {
        return .{ .decl_name = .{ .sym_idx = sym_idx, .loc = sym.loc } };
    }
    return null;
}

fn findInType(typ: Ast.Type, offset: u32) ?NodeAtPosition {
    switch (typ) {
        .ident => |t| {
            if (offset >= t.loc and offset < t.loc + @as(u32, @intCast(t.name.len))) {
                return .{ .type_ref = .{ .name = t.name, .ref = t.ref, .loc = t.loc } };
            }
        },
        .vec => |t| {
            if (t.elem_type) |et| return findInType(et, offset);
        },
        .mat => |t| {
            if (t.elem_type) |et| return findInType(et, offset);
        },
        .array => |t| {
            if (t.elem_type) |et| {
                if (findInType(et, offset)) |r| return r;
            }
            if (t.size) |sz| {
                // size is an Expr, not a Type
                return findInExpr(sz, offset);
            }
        },
        .ptr => |t| return findInType(t.elem_type, offset),
        .atomic => |t| return findInType(t.elem_type, offset),
        .sampler, .texture => {},
    }
    return null;
}

fn findInCompound(module: *const Ast.Module, compound: *const Ast.CompoundStmt, offset: u32) ?NodeAtPosition {
    for (compound.stmts.items) |stmt| {
        if (findInStmt(module, stmt, offset)) |r| return r;
    }
    return null;
}

fn findInStmt(module: *const Ast.Module, stmt: Ast.Stmt, offset: u32) ?NodeAtPosition {
    switch (stmt) {
        .compound => |c| return findInCompound(module, c, offset),
        .@"return" => |r| {
            if (r.value) |v| return findInExpr(v, offset);
        },
        .@"if" => |i| {
            if (findInExpr(i.condition, offset)) |r| return r;
            if (findInCompound(module, i.body, offset)) |r| return r;
            if (i.else_branch) |eb| return findInStmt(module, eb, offset);
        },
        .@"switch" => |s| {
            if (findInExpr(s.expr, offset)) |r| return r;
            for (s.cases.items) |case| {
                for (case.selectors.items) |sel| {
                    if (findInExpr(sel, offset)) |r| return r;
                }
                if (findInCompound(module, case.body, offset)) |r| return r;
            }
        },
        .@"for" => |f| {
            if (f.init_stmt) |init_s| {
                if (findInStmt(module, init_s, offset)) |r| return r;
            }
            if (f.condition) |cond| {
                if (findInExpr(cond, offset)) |r| return r;
            }
            if (f.update) |upd| {
                if (findInStmt(module, upd, offset)) |r| return r;
            }
            return findInCompound(module, f.body, offset);
        },
        .@"while" => |w| {
            if (findInExpr(w.condition, offset)) |r| return r;
            return findInCompound(module, w.body, offset);
        },
        .loop => |l| {
            if (findInCompound(module, l.body, offset)) |r| return r;
            if (l.continuing) |cont| return findInCompound(module, cont, offset);
        },
        .assign => |a| {
            if (findInExpr(a.left, offset)) |r| return r;
            return findInExpr(a.right, offset);
        },
        .incr_decr => |i| return findInExpr(i.expr, offset),
        .call => |c| return findInExpr(.{ .call = c.call }, offset),
        .decl => |d| return findInDecl(module, d.decl, offset),
        .@"break" => {},
        .@"continue" => {},
        .discard => {},
        .break_if => |b| return findInExpr(b.condition, offset),
    }
    return null;
}

fn findInExpr(expr: Ast.Expr, offset: u32) ?NodeAtPosition {
    switch (expr) {
        .ident => |e| {
            if (offset >= e.loc and offset < e.loc + @as(u32, @intCast(e.name.len))) {
                return .{ .ident = .{ .name = e.name, .ref = e.ref, .loc = e.loc } };
            }
        },
        .member => |e| {
            // e.loc is the dot position; member name starts at dot + 1
            const member_loc = e.loc + 1;
            if (offset >= member_loc and offset < member_loc + @as(u32, @intCast(e.member_name.len))) {
                return .{ .member_access = .{ .member = e.member_name, .loc = member_loc } };
            }
            return findInExpr(e.base, offset);
        },
        .call => |e| {
            if (e.func) |f| {
                if (findInExpr(f, offset)) |r| return r;
            }
            if (e.template_type) |tt| {
                if (findInType(tt, offset)) |r| return r;
            }
            for (e.args.items) |arg| {
                if (findInExpr(arg, offset)) |r| return r;
            }
        },
        .binary => |e| {
            if (findInExpr(e.left, offset)) |r| return r;
            return findInExpr(e.right, offset);
        },
        .unary => |e| return findInExpr(e.operand, offset),
        .index => |e| {
            if (findInExpr(e.base, offset)) |r| return r;
            return findInExpr(e.idx, offset);
        },
        .paren => |e| return findInExpr(e.expr, offset),
        .literal => {},
    }
    return null;
}

// =========================================================================
// LSP Feature: Hover
// =========================================================================

pub const HoverResult = struct {
    contents: []const u8,
    range: Range,
};

pub fn computeHover(self: *Handler, uri: []const u8, position: Position) !?HoverResult {
    const doc = self.documents.getPtr(uri) orelse return null;
    const source = doc.source;
    const offset: u32 = @intCast(lspPositionToOffset(source, position) orelse return null);
    const analysis = try self.analyzeDocument(uri);
    const module = analysis.module orelse return null;

    const node = findNodeAtOffset(module, offset);
    var buf: [512]u8 = undefined;
    switch (node) {
        .ident => |id| {
            if (!id.ref.isValid()) return null;
            const sym = module.symbols.items[id.ref.index()];
            const kind_str = @tagName(sym.kind);
            const type_str = if (analysis.symbol_types.get(id.ref.index())) |t| t.string() else "unknown";
            const len = (std.fmt.bufPrint(&buf, "({s}) {s}: {s}", .{ kind_str, id.name, type_str }) catch return null).len;
            const contents = try self.gpa.dupe(u8, buf[0..len]);
            return .{
                .contents = contents,
                .range = offsetRangeToLspRange(source, id.loc, id.loc + @as(u32, @intCast(id.name.len))) orelse return null,
            };
        },
        .decl_name => |dn| {
            if (!dn.sym_idx.isValid()) return null;
            const sym = module.symbols.items[dn.sym_idx.index()];
            const kind_str = @tagName(sym.kind);
            const type_str = if (analysis.symbol_types.get(dn.sym_idx.index())) |t| t.string() else "";
            const len = if (type_str.len > 0)
                (std.fmt.bufPrint(&buf, "({s}) {s}: {s}", .{ kind_str, sym.original_name, type_str }) catch return null).len
            else
                (std.fmt.bufPrint(&buf, "({s}) {s}", .{ kind_str, sym.original_name }) catch return null).len;
            const contents = try self.gpa.dupe(u8, buf[0..len]);
            return .{
                .contents = contents,
                .range = offsetRangeToLspRange(source, dn.loc, dn.loc + @as(u32, @intCast(sym.original_name.len))) orelse return null,
            };
        },
        .type_ref => |tr| {
            if (analysis.struct_types.get(tr.name)) |st| {
                // Show struct fields using bufPrint
                var pos_in_buf: usize = 0;
                const header = std.fmt.bufPrint(&buf, "struct {s} {{ ", .{tr.name}) catch return null;
                pos_in_buf = header.len;
                for (st.fields, 0..) |field, fi| {
                    if (fi > 0) {
                        const sep = std.fmt.bufPrint(buf[pos_in_buf..], ", ", .{}) catch return null;
                        pos_in_buf += sep.len;
                    }
                    const fld = std.fmt.bufPrint(buf[pos_in_buf..], "{s}: {s}", .{ field.name, field.typ.string() }) catch return null;
                    pos_in_buf += fld.len;
                }
                const tail = std.fmt.bufPrint(buf[pos_in_buf..], " }}", .{}) catch return null;
                pos_in_buf += tail.len;
                const contents = try self.gpa.dupe(u8, buf[0..pos_in_buf]);
                return .{
                    .contents = contents,
                    .range = offsetRangeToLspRange(source, tr.loc, tr.loc + @as(u32, @intCast(tr.name.len))) orelse return null,
                };
            }
            return null;
        },
        .member_access => |ma| {
            const contents = try self.gpa.dupe(u8, ma.member);
            return .{
                .contents = contents,
                .range = offsetRangeToLspRange(source, ma.loc, ma.loc + @as(u32, @intCast(ma.member.len))) orelse return null,
            };
        },
        .none => return null,
    }
}

// =========================================================================
// LSP Feature: Go-to-Definition
// =========================================================================

pub fn computeDefinition(self: *Handler, uri: []const u8, position: Position) !?Range {
    const doc = self.documents.getPtr(uri) orelse return null;
    const source = doc.source;
    const offset: u32 = @intCast(lspPositionToOffset(source, position) orelse return null);
    const analysis = try self.analyzeDocument(uri);
    const module = analysis.module orelse return null;

    const node = findNodeAtOffset(module, offset);
    switch (node) {
        .ident => |id| {
            if (!id.ref.isValid()) return null;
            const sym = module.symbols.items[id.ref.index()];
            return offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len)));
        },
        .type_ref => |tr| {
            if (!tr.ref.isValid()) return null;
            const sym = module.symbols.items[tr.ref.index()];
            return offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len)));
        },
        .decl_name => |dn| {
            if (!dn.sym_idx.isValid()) return null;
            const sym = module.symbols.items[dn.sym_idx.index()];
            return offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len)));
        },
        .member_access, .none => return null,
    }
}

// =========================================================================
// LSP Feature: Find All References
// =========================================================================

/// Collect all byte offset locations of references to a given symbol.
fn collectReferences(gpa: std.mem.Allocator, module: *const Ast.Module, target: Ast.SymbolIndex, include_declaration: bool) ![]Range {
    const source = module.source;
    var locations: std.ArrayListUnmanaged(Range) = .empty;
    defer locations.deinit(gpa);

    // Include declaration location
    if (include_declaration and target.isValid()) {
        const sym = module.symbols.items[target.index()];
        if (offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len)))) |range| {
            try locations.append(gpa, range);
        }
    }

    // Walk all declarations collecting references
    for (module.declarations.items) |decl| {
        try collectRefsInDecl(gpa, module, decl, target, source, &locations);
    }

    return try gpa.dupe(Range, locations.items);
}

fn collectRefsInDecl(gpa: std.mem.Allocator, module: *const Ast.Module, decl: Ast.Decl, target: Ast.SymbolIndex, source: [:0]const u8, locations: *std.ArrayListUnmanaged(Range)) std.mem.Allocator.Error!void {
    switch (decl) {
        .function => |f| {
            for (f.parameters.items) |param| {
                try collectRefsInType(gpa, param.typ, target, source, locations);
            }
            if (f.return_type) |rt| try collectRefsInType(gpa, rt, target, source, locations);
            if (f.body) |body| try collectRefsInCompound(gpa, module, body, target, source, locations);
        },
        .@"struct" => |s| {
            for (s.members.items) |m| {
                try collectRefsInType(gpa, m.typ, target, source, locations);
            }
        },
        .@"const" => |c| {
            if (c.typ) |t| try collectRefsInType(gpa, t, target, source, locations);
            if (c.initializer) |e| try collectRefsInExpr(gpa, e, target, source, locations);
        },
        .override => |o| {
            if (o.typ) |t| try collectRefsInType(gpa, t, target, source, locations);
            if (o.initializer) |e| try collectRefsInExpr(gpa, e, target, source, locations);
        },
        .@"var" => |v| {
            if (v.typ) |t| try collectRefsInType(gpa, t, target, source, locations);
            if (v.initializer) |e| try collectRefsInExpr(gpa, e, target, source, locations);
        },
        .let => |l| {
            if (l.typ) |t| try collectRefsInType(gpa, t, target, source, locations);
            if (l.initializer) |e| try collectRefsInExpr(gpa, e, target, source, locations);
        },
        .alias => |a| try collectRefsInType(gpa, a.typ, target, source, locations),
        .const_assert => |ca| try collectRefsInExpr(gpa, ca.expr, target, source, locations),
    }
}

fn collectRefsInType(gpa: std.mem.Allocator, typ: Ast.Type, target: Ast.SymbolIndex, source: [:0]const u8, locations: *std.ArrayListUnmanaged(Range)) std.mem.Allocator.Error!void {
    switch (typ) {
        .ident => |t| {
            if (t.ref == target) {
                if (offsetRangeToLspRange(source, t.loc, t.loc + @as(u32, @intCast(t.name.len)))) |range| {
                    try locations.append(gpa, range);
                }
            }
        },
        .vec => |t| {
            if (t.elem_type) |et| try collectRefsInType(gpa, et, target, source, locations);
        },
        .mat => |t| {
            if (t.elem_type) |et| try collectRefsInType(gpa, et, target, source, locations);
        },
        .array => |t| {
            if (t.elem_type) |et| try collectRefsInType(gpa, et, target, source, locations);
            if (t.size) |sz| try collectRefsInExpr(gpa, sz, target, source, locations);
        },
        .ptr => |t| try collectRefsInType(gpa, t.elem_type, target, source, locations),
        .atomic => |t| try collectRefsInType(gpa, t.elem_type, target, source, locations),
        .sampler, .texture => {},
    }
}

fn collectRefsInCompound(gpa: std.mem.Allocator, module: *const Ast.Module, compound: *const Ast.CompoundStmt, target: Ast.SymbolIndex, source: [:0]const u8, locations: *std.ArrayListUnmanaged(Range)) std.mem.Allocator.Error!void {
    for (compound.stmts.items) |stmt| {
        try collectRefsInStmt(gpa, module, stmt, target, source, locations);
    }
}

fn collectRefsInStmt(gpa: std.mem.Allocator, module: *const Ast.Module, stmt: Ast.Stmt, target: Ast.SymbolIndex, source: [:0]const u8, locations: *std.ArrayListUnmanaged(Range)) std.mem.Allocator.Error!void {
    switch (stmt) {
        .compound => |c| try collectRefsInCompound(gpa, module, c, target, source, locations),
        .@"return" => |r| {
            if (r.value) |v| try collectRefsInExpr(gpa, v, target, source, locations);
        },
        .@"if" => |i| {
            try collectRefsInExpr(gpa, i.condition, target, source, locations);
            try collectRefsInCompound(gpa, module, i.body, target, source, locations);
            if (i.else_branch) |eb| try collectRefsInStmt(gpa, module, eb, target, source, locations);
        },
        .@"switch" => |s| {
            try collectRefsInExpr(gpa, s.expr, target, source, locations);
            for (s.cases.items) |case| {
                for (case.selectors.items) |sel| {
                    try collectRefsInExpr(gpa, sel, target, source, locations);
                }
                try collectRefsInCompound(gpa, module, case.body, target, source, locations);
            }
        },
        .@"for" => |f| {
            if (f.init_stmt) |init_s| try collectRefsInStmt(gpa, module, init_s, target, source, locations);
            if (f.condition) |cond| try collectRefsInExpr(gpa, cond, target, source, locations);
            if (f.update) |upd| try collectRefsInStmt(gpa, module, upd, target, source, locations);
            try collectRefsInCompound(gpa, module, f.body, target, source, locations);
        },
        .@"while" => |w| {
            try collectRefsInExpr(gpa, w.condition, target, source, locations);
            try collectRefsInCompound(gpa, module, w.body, target, source, locations);
        },
        .loop => |l| {
            try collectRefsInCompound(gpa, module, l.body, target, source, locations);
            if (l.continuing) |cont| try collectRefsInCompound(gpa, module, cont, target, source, locations);
        },
        .assign => |a| {
            try collectRefsInExpr(gpa, a.left, target, source, locations);
            try collectRefsInExpr(gpa, a.right, target, source, locations);
        },
        .incr_decr => |i| try collectRefsInExpr(gpa, i.expr, target, source, locations),
        .call => |c| try collectRefsInExpr(gpa, .{ .call = c.call }, target, source, locations),
        .decl => |d| try collectRefsInDecl(gpa, module, d.decl, target, source, locations),
        .@"break", .@"continue", .discard => {},
        .break_if => |b| try collectRefsInExpr(gpa, b.condition, target, source, locations),
    }
}

fn collectRefsInExpr(gpa: std.mem.Allocator, expr: Ast.Expr, target: Ast.SymbolIndex, source: [:0]const u8, locations: *std.ArrayListUnmanaged(Range)) std.mem.Allocator.Error!void {
    switch (expr) {
        .ident => |e| {
            if (e.ref == target) {
                if (offsetRangeToLspRange(source, e.loc, e.loc + @as(u32, @intCast(e.name.len)))) |range| {
                    try locations.append(gpa, range);
                }
            }
        },
        .member => |e| try collectRefsInExpr(gpa, e.base, target, source, locations),
        .call => |e| {
            if (e.func) |f| try collectRefsInExpr(gpa, f, target, source, locations);
            if (e.template_type) |tt| try collectRefsInType(gpa, tt, target, source, locations);
            for (e.args.items) |arg| try collectRefsInExpr(gpa, arg, target, source, locations);
        },
        .binary => |e| {
            try collectRefsInExpr(gpa, e.left, target, source, locations);
            try collectRefsInExpr(gpa, e.right, target, source, locations);
        },
        .unary => |e| try collectRefsInExpr(gpa, e.operand, target, source, locations),
        .index => |e| {
            try collectRefsInExpr(gpa, e.base, target, source, locations);
            try collectRefsInExpr(gpa, e.idx, target, source, locations);
        },
        .paren => |e| try collectRefsInExpr(gpa, e.expr, target, source, locations),
        .literal => {},
    }
}

pub fn computeReferences(self: *Handler, uri: []const u8, position: Position, include_declaration: bool) !?[]Range {
    const doc = self.documents.getPtr(uri) orelse return null;
    const source = doc.source;
    const offset: u32 = @intCast(lspPositionToOffset(source, position) orelse return null);
    const analysis = try self.analyzeDocument(uri);
    const module = analysis.module orelse return null;

    const node = findNodeAtOffset(module, offset);
    const target: Ast.SymbolIndex = switch (node) {
        .ident => |id| id.ref,
        .decl_name => |dn| dn.sym_idx,
        .type_ref => |tr| tr.ref,
        else => return null,
    };
    if (!target.isValid()) return null;
    return try collectReferences(self.gpa, module, target, include_declaration);
}

// =========================================================================
// LSP Feature: Rename Symbol
// =========================================================================

const Lexer = wgslender.Lexer;

pub fn prepareRename(self: *Handler, uri: []const u8, position: Position) !?Range {
    const doc = self.documents.getPtr(uri) orelse return null;
    const source = doc.source;
    const offset: u32 = @intCast(lspPositionToOffset(source, position) orelse return null);
    const analysis = try self.analyzeDocument(uri);
    const module = analysis.module orelse return null;

    const node = findNodeAtOffset(module, offset);
    switch (node) {
        .ident => |id| {
            if (!id.ref.isValid()) return null;
            const sym = module.symbols.items[id.ref.index()];
            if (sym.flags.is_builtin) return null;
            return offsetRangeToLspRange(source, id.loc, id.loc + @as(u32, @intCast(id.name.len)));
        },
        .decl_name => |dn| {
            if (!dn.sym_idx.isValid()) return null;
            const sym = module.symbols.items[dn.sym_idx.index()];
            if (sym.flags.is_builtin) return null;
            return offsetRangeToLspRange(source, dn.loc, dn.loc + @as(u32, @intCast(sym.original_name.len)));
        },
        .type_ref => |tr| {
            if (!tr.ref.isValid()) return null;
            const sym = module.symbols.items[tr.ref.index()];
            if (sym.flags.is_builtin) return null;
            return offsetRangeToLspRange(source, tr.loc, tr.loc + @as(u32, @intCast(tr.name.len)));
        },
        else => return null,
    }
}

pub fn isValidWgslIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    // WGSL reserved __ prefix
    if (name.len >= 2 and name[0] == '_' and name[1] == '_') return false;
    // Check it's not a keyword or reserved word
    if (Lexer.keywords_map.has(name)) return false;
    if (Lexer.reserved_words.has(name)) return false;
    // Basic identifier character check
    for (name, 0..) |c, i| {
        if (i == 0) {
            if (!std.ascii.isAlphabetic(c) and c != '_') return false;
        } else {
            if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
        }
    }
    return true;
}

pub fn computeRename(self: *Handler, uri: []const u8, position: Position, new_name: []const u8) !?[]LspTextEdit {
    if (!isValidWgslIdentifier(new_name)) return null;

    const refs = (try self.computeReferences(uri, position, true)) orelse return null;
    defer self.gpa.free(refs);

    if (refs.len == 0) return null;

    const edits = try self.gpa.alloc(LspTextEdit, refs.len);
    for (refs, 0..) |ref_range, i| {
        edits[i] = .{
            .range = ref_range,
            .new_text = new_name,
        };
    }
    return edits;
}

// =========================================================================
// LSP Feature: Completion
// =========================================================================

const Builtins = wgslender.Builtins;

pub const CompletionItem = struct {
    label: []const u8,
    kind: CompletionKind,
    detail: []const u8 = "",
};

pub const CompletionKind = enum(u8) {
    variable,
    function,
    struct_type,
    field,
    keyword,
    builtin,
    type_name,
    attribute,
};

const wgsl_type_names = [_][]const u8{
    "bool", "i32", "u32", "f32", "f16",
    "vec2", "vec3", "vec4",
    "vec2i", "vec3i", "vec4i",
    "vec2u", "vec3u", "vec4u",
    "vec2f", "vec3f", "vec4f",
    "vec2h", "vec3h", "vec4h",
    "mat2x2", "mat2x3", "mat2x4",
    "mat3x2", "mat3x3", "mat3x4",
    "mat4x2", "mat4x3", "mat4x4",
    "mat2x2f", "mat2x3f", "mat2x4f",
    "mat3x2f", "mat3x3f", "mat3x4f",
    "mat4x2f", "mat4x3f", "mat4x4f",
    "mat2x2h", "mat2x3h", "mat2x4h",
    "mat3x2h", "mat3x3h", "mat3x4h",
    "mat4x2h", "mat4x3h", "mat4x4h",
    "array",   "atomic",  "ptr",
    "sampler", "sampler_comparison",
    "texture_1d",          "texture_2d",          "texture_2d_array",
    "texture_3d",          "texture_cube",        "texture_cube_array",
    "texture_multisampled_2d",
    "texture_storage_1d",  "texture_storage_2d",  "texture_storage_2d_array",
    "texture_storage_3d",  "texture_depth_2d",    "texture_depth_2d_array",
    "texture_depth_cube",  "texture_depth_cube_array", "texture_depth_multisampled_2d",
};

const wgsl_attributes = [_][]const u8{
    "align",   "binding",   "builtin",     "compute",
    "const",   "diagnostic", "fragment",   "group",
    "id",      "interpolate", "invariant", "location",
    "must_use", "size",      "vertex",     "workgroup_size",
};

pub fn computeCompletion(self: *Handler, uri: []const u8, position: Position) ![]CompletionItem {
    const doc = self.documents.getPtr(uri) orelse return &.{};
    const source = doc.source;
    const offset: u32 = @intCast(lspPositionToOffset(source, position) orelse return &.{});

    // Check trigger context
    if (offset > 0 and source[offset - 1] == '@') {
        return self.attributeCompletion();
    }

    if (offset > 0 and source[offset - 1] == '.') {
        return self.memberCompletion(uri, source, offset);
    }

    return self.generalCompletion(uri);
}

fn attributeCompletion(self: *Handler) ![]CompletionItem {
    const items = try self.gpa.alloc(CompletionItem, wgsl_attributes.len);
    for (wgsl_attributes, 0..) |attr, i| {
        items[i] = .{ .label = attr, .kind = .attribute };
    }
    return items;
}

fn memberCompletion(self: *Handler, uri: []const u8, source: []const u8, dot_offset: u32) ![]CompletionItem {
    // Find the identifier before the dot
    var start = dot_offset - 1;
    if (start > 0 and source[start] == '.') start -= 1; // skip the dot
    while (start > 0 and (std.ascii.isAlphanumeric(source[start - 1]) or source[start - 1] == '_')) start -= 1;
    const base_name = source[start .. dot_offset - 1];
    if (base_name.len == 0) return &.{};

    // Try to resolve the base type via analysis
    const analysis = self.analyzeDocument(uri) catch return &.{};
    const module = analysis.module orelse return &.{};

    // Find the symbol for base_name and its type
    var base_type: ?wgslender.Types.Type = null;
    for (module.symbols.items, 0..) |sym, idx| {
        if (std.mem.eql(u8, sym.original_name, base_name)) {
            base_type = analysis.symbol_types.get(@intCast(idx));
            break;
        }
    }

    if (base_type) |bt| {
        switch (bt) {
            .@"struct" => |st| {
                const items = try self.gpa.alloc(CompletionItem, st.fields.len);
                for (st.fields, 0..) |field, i| {
                    items[i] = .{ .label = field.name, .kind = .field, .detail = field.typ.string() };
                }
                return items;
            },
            .vector => {
                // Vector swizzle components
                const swizzles = [_][]const u8{ "x", "y", "z", "w", "r", "g", "b", "a" };
                const items = try self.gpa.alloc(CompletionItem, swizzles.len);
                for (swizzles, 0..) |s, i| {
                    items[i] = .{ .label = s, .kind = .field };
                }
                return items;
            },
            else => {},
        }
    }

    return &.{};
}

fn generalCompletion(self: *Handler, uri: []const u8) ![]CompletionItem {
    var items: std.ArrayListUnmanaged(CompletionItem) = .empty;
    defer items.deinit(self.gpa);

    // Module-level symbols from analysis
    if (self.analyzeDocument(uri)) |analysis| {
        if (analysis.module) |module| {
            for (module.symbols.items, 0..) |sym, idx| {
                if (sym.original_name.len == 0) continue;
                const kind: CompletionKind = switch (sym.kind) {
                    .function => .function,
                    .@"struct" => .struct_type,
                    .parameter, .let, .@"var" => .variable,
                    .@"const", .override => .variable,
                    else => continue,
                };
                const detail = if (analysis.symbol_types.get(@intCast(idx))) |t| t.string() else "";
                try items.append(self.gpa, .{ .label = sym.original_name, .kind = kind, .detail = detail });
            }
        }
    } else |_| {}

    // Builtin functions
    for (Builtins.names()) |name| {
        try items.append(self.gpa, .{ .label = name, .kind = .builtin });
    }

    // Keywords
    for (Lexer.keywords_map.keys()) |kw| {
        try items.append(self.gpa, .{ .label = kw, .kind = .keyword });
    }

    // Built-in type names
    for (&wgsl_type_names) |tn| {
        try items.append(self.gpa, .{ .label = tn, .kind = .type_name });
    }

    return try self.gpa.dupe(CompletionItem, items.items);
}

// =========================================================================
// LSP Feature: Signature Help
// =========================================================================

pub const SignatureInfo = struct {
    label: []const u8,
    parameters: []const []const u8,
    active_parameter: u32,
};

pub fn computeSignatureHelp(self: *Handler, uri: []const u8, position: Position) !?SignatureInfo {
    const doc = self.documents.getPtr(uri) orelse return null;
    const source = doc.source;
    const offset: u32 = @intCast(lspPositionToOffset(source, position) orelse return null);

    // Scan backward to find enclosing '(' and the function name before it
    var paren_depth: i32 = 0;
    var comma_count: u32 = 0;
    var i: u32 = offset;
    while (i > 0) {
        i -= 1;
        const c = source[i];
        if (c == ')') {
            paren_depth += 1;
        } else if (c == '(') {
            if (paren_depth == 0) break; // found the enclosing '('
            paren_depth -= 1;
        } else if (c == ',' and paren_depth == 0) {
            comma_count += 1;
        }
    } else {
        return null; // no enclosing '('
    }

    // i now points to '('. Find the function name before it.
    if (i == 0) return null;
    var name_end = i;
    // Skip whitespace between name and '('
    while (name_end > 0 and source[name_end - 1] == ' ') name_end -= 1;
    if (name_end == 0) return null;
    var name_start = name_end;
    while (name_start > 0 and (std.ascii.isAlphanumeric(source[name_start - 1]) or source[name_start - 1] == '_')) name_start -= 1;
    const func_name = source[name_start..name_end];
    if (func_name.len == 0) return null;

    // Check if it's a builtin
    if (Builtins.lookup(func_name)) |builtin| {
        var buf: [256]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{s}({d}..{d} args)", .{ func_name, builtin.min_args, builtin.max_args }) catch return null;
        return .{
            .label = try self.gpa.dupe(u8, label),
            .parameters = &.{},
            .active_parameter = comma_count,
        };
    }

    // Check if it's a user-defined function
    const analysis = try self.analyzeDocument(uri);
    const module = analysis.module orelse return null;
    for (module.declarations.items) |decl| {
        switch (decl) {
            .function => |f| {
                if (!f.name.isValid()) continue;
                const sym = module.symbols.items[f.name.index()];
                if (!std.mem.eql(u8, sym.original_name, func_name)) continue;

                // Build signature label and parameter names
                var buf: [512]u8 = undefined;
                var pos_in_buf: usize = 0;
                const header = std.fmt.bufPrint(&buf, "fn {s}(", .{func_name}) catch return null;
                pos_in_buf = header.len;

                const param_names = try self.gpa.alloc([]const u8, f.parameters.items.len);
                for (f.parameters.items, 0..) |param, pi| {
                    if (pi > 0) {
                        const sep = std.fmt.bufPrint(buf[pos_in_buf..], ", ", .{}) catch return null;
                        pos_in_buf += sep.len;
                    }
                    const p_sym = module.symbols.items[param.name.index()];
                    const p_type = param.typ;
                    const p_str = switch (p_type) {
                        .ident => |t| t.name,
                        .vec => |t| t.shorthand,
                        .mat => |t| t.shorthand,
                        else => "?",
                    };
                    param_names[pi] = p_sym.original_name;
                    const fld = std.fmt.bufPrint(buf[pos_in_buf..], "{s}: {s}", .{ p_sym.original_name, p_str }) catch return null;
                    pos_in_buf += fld.len;
                }

                const tail_str = if (f.return_type) |rt| blk: {
                    const rt_str = switch (rt) {
                        .ident => |t| t.name,
                        .vec => |t| t.shorthand,
                        .mat => |t| t.shorthand,
                        else => "?",
                    };
                    break :blk std.fmt.bufPrint(buf[pos_in_buf..], ") -> {s}", .{rt_str}) catch return null;
                } else std.fmt.bufPrint(buf[pos_in_buf..], ")", .{}) catch return null;
                pos_in_buf += tail_str.len;

                return .{
                    .label = try self.gpa.dupe(u8, buf[0..pos_in_buf]),
                    .parameters = param_names,
                    .active_parameter = comma_count,
                };
            },
            else => {},
        }
    }

    return null;
}

// =========================================================================
// LSP Feature: Document Symbols
// =========================================================================

pub const DocumentSymbolInfo = struct {
    name: []const u8,
    kind: SymbolKind,
    range: Range,
    selection_range: Range,
    children: []const DocumentSymbolInfo,
};

pub const SymbolKind = enum(u8) {
    function,
    struct_type,
    variable,
    constant,
    field,
    type_alias,
    override,
};

pub fn computeDocumentSymbols(self: *Handler, uri: []const u8) ![]DocumentSymbolInfo {
    const analysis = self.analyzeDocument(uri) catch return &.{};
    const module = analysis.module orelse return &.{};
    const source = module.source;

    var symbols: std.ArrayListUnmanaged(DocumentSymbolInfo) = .empty;
    defer symbols.deinit(self.gpa);

    for (module.declarations.items, 0..) |decl, di| {
        const name_ref = decl.nameRef();
        if (!name_ref.isValid()) continue;
        const sym = module.symbols.items[name_ref.index()];

        const kind: SymbolKind = switch (decl) {
            .function => .function,
            .@"struct" => .struct_type,
            .@"var" => .variable,
            .@"const" => .constant,
            .let => .constant,
            .override => .override,
            .alias => .type_alias,
            .const_assert => continue,
        };

        // Selection range = the name identifier
        const sel_range = offsetRangeToLspRange(source, sym.loc, sym.loc + @as(u32, @intCast(sym.original_name.len))) orelse continue;

        // Enclosing range: from this decl's name to next decl's name (or EOF)
        const range_end: u32 = if (di + 1 < module.declarations.items.len) blk: {
            const next_ref = module.declarations.items[di + 1].nameRef();
            if (next_ref.isValid()) break :blk module.symbols.items[next_ref.index()].loc;
            break :blk @as(u32, @intCast(source.len));
        } else @as(u32, @intCast(source.len));
        const range = offsetRangeToLspRange(source, sym.loc, range_end) orelse continue;

        // Children for structs
        var children: []const DocumentSymbolInfo = &.{};
        if (decl == .@"struct") {
            const st = decl.@"struct";
            var ch: std.ArrayListUnmanaged(DocumentSymbolInfo) = .empty;
            for (st.members.items) |member| {
                if (!member.name.isValid()) continue;
                const m_sym = module.symbols.items[member.name.index()];
                const m_sel = offsetRangeToLspRange(source, m_sym.loc, m_sym.loc + @as(u32, @intCast(m_sym.original_name.len))) orelse continue;
                ch.append(self.gpa, .{
                    .name = m_sym.original_name,
                    .kind = .field,
                    .range = m_sel,
                    .selection_range = m_sel,
                    .children = &.{},
                }) catch continue;
            }
            children = ch.toOwnedSlice(self.gpa) catch &.{};
        }

        try symbols.append(self.gpa, .{
            .name = sym.original_name,
            .kind = kind,
            .range = range,
            .selection_range = sel_range,
            .children = children,
        });
    }

    return try self.gpa.dupe(DocumentSymbolInfo, symbols.items);
}

// =========================================================================
// LSP Feature: Folding Ranges
// =========================================================================

pub const FoldingRangeInfo = struct {
    start_line: u32,
    end_line: u32,
    kind: enum { region, comment },
};

pub fn computeFoldingRanges(self: *Handler, uri: []const u8) ![]FoldingRangeInfo {
    const analysis = self.analyzeDocument(uri) catch return &.{};
    const module = analysis.module orelse return &.{};
    const source = module.source;

    var ranges: std.ArrayListUnmanaged(FoldingRangeInfo) = .empty;
    defer ranges.deinit(self.gpa);

    for (module.declarations.items) |decl| {
        switch (decl) {
            .function => |f| {
                if (f.body == null) continue;
                if (!f.name.isValid()) continue;
                const sym = module.symbols.items[f.name.index()];
                const start_pos = offsetToLspPosition(source, sym.loc) orelse continue;
                // Find closing brace by scanning source
                if (findClosingBrace(source, sym.loc)) |end_offset| {
                    const end_pos = offsetToLspPosition(source, end_offset) orelse continue;
                    if (end_pos.line > start_pos.line) {
                        try ranges.append(self.gpa, .{ .start_line = start_pos.line, .end_line = end_pos.line, .kind = .region });
                    }
                }
            },
            .@"struct" => |s| {
                if (!s.name.isValid()) continue;
                const sym = module.symbols.items[s.name.index()];
                const start_pos = offsetToLspPosition(source, sym.loc) orelse continue;
                if (findClosingBrace(source, sym.loc)) |end_offset| {
                    const end_pos = offsetToLspPosition(source, end_offset) orelse continue;
                    if (end_pos.line > start_pos.line) {
                        try ranges.append(self.gpa, .{ .start_line = start_pos.line, .end_line = end_pos.line, .kind = .region });
                    }
                }
            },
            else => {},
        }
    }

    return try self.gpa.dupe(FoldingRangeInfo, ranges.items);
}

fn findClosingBrace(source: []const u8, start: u32) ?u32 {
    var depth: i32 = 0;
    var i: u32 = start;
    while (i < source.len) : (i += 1) {
        if (source[i] == '{') {
            depth += 1;
        } else if (source[i] == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

// =========================================================================
// Tests
// =========================================================================

test "analyzeDocument caches result" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    try handler.openDocument("test://file.wgsl", "fn f() {}", 1);
    const a1 = try handler.analyzeDocument("test://file.wgsl");
    const a2 = try handler.analyzeDocument("test://file.wgsl");
    try std.testing.expect(a1 == a2); // same pointer
}

test "changeDocument invalidates analysis cache" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    try handler.openDocument("test://file.wgsl", "fn f() {}", 1);
    _ = try handler.analyzeDocument("test://file.wgsl");
    const doc1 = handler.documents.getPtr("test://file.wgsl").?;
    try std.testing.expect(doc1.analysis != null);
    try handler.changeDocument("test://file.wgsl", "fn g() {}");
    const doc2 = handler.documents.getPtr("test://file.wgsl").?;
    try std.testing.expect(doc2.analysis == null);
}

test "analyzeDocument after change re-analyzes" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    try handler.openDocument("test://file.wgsl", "fn f() {}", 1);
    const a1 = try handler.analyzeDocument("test://file.wgsl");
    try handler.changeDocument("test://file.wgsl", "fn g() {}");
    const a2 = try handler.analyzeDocument("test://file.wgsl");
    try std.testing.expect(a1 != a2); // different pointer after re-analysis
}

test "analyzeDocument returns semantic data" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    try handler.openDocument("test://file.wgsl", "struct S { x: f32, y: f32 }", 1);
    const analysis = try handler.analyzeDocument("test://file.wgsl");
    try std.testing.expect(analysis.module != null);
    const module = analysis.module.?;
    // Should have at least the struct declaration symbol
    try std.testing.expect(module.symbols.items.len > 0);
}

test "convertDiagnostic preserves code" {
    const entry = WgslDiagnostic.Entry{ .code = "E0200" };
    const result = convertDiagnostic(std.testing.allocator, &entry);
    try std.testing.expectEqualStrings("E0200", result.code);
}

test "convertDiagnostic builds spec_url from spec_ref" {
    const entry = WgslDiagnostic.Entry{ .code = "E0700", .spec_ref = "uniformity" };
    const result = convertDiagnostic(std.testing.allocator, &entry);
    defer std.testing.allocator.free(result.spec_url);
    try std.testing.expectEqualStrings("https://www.w3.org/TR/WGSL/#uniformity", result.spec_url);
}

test "convertDiagnostic omits code and spec_url when empty" {
    const entry = WgslDiagnostic.Entry{};
    const result = convertDiagnostic(std.testing.allocator, &entry);
    try std.testing.expectEqual(@as(usize, 0), result.code.len);
    try std.testing.expectEqual(@as(usize, 0), result.spec_url.len);
}

test "convertDiagnostic omits spec_url when code empty" {
    const entry = WgslDiagnostic.Entry{ .spec_ref = "uniformity" };
    const result = convertDiagnostic(std.testing.allocator, &entry);
    try std.testing.expectEqual(@as(usize, 0), result.spec_url.len);
}

/// Frees all allocations within a diagnostics slice (messages, related info, the slice itself).
pub fn freeDiagnostics(gpa: std.mem.Allocator, diags: []LspDiagnostic) void {
    for (diags) |d| {
        if (d.related.len > 0) {
            for (d.related) |r| {
                if (r.message.len > 0) gpa.free(r.message);
            }
            gpa.free(d.related);
        }
        if (d.message.len > 0) gpa.free(d.message);
        if (d.spec_url.len > 0) gpa.free(d.spec_url);
    }
    gpa.free(diags);
}

/// Frees all allocations within a code actions slice (titles, edits, the slice itself).
pub fn freeCodeActions(gpa: std.mem.Allocator, actions: []LspCodeAction) void {
    for (actions) |a| {
        gpa.free(a.title);
        for (a.edits) |edit| {
            gpa.free(edit.new_text);
        }
        gpa.free(a.edits);
    }
    gpa.free(actions);
}

test "code round-trips through validateDocument" {
    // A type mismatch triggers a diagnostic with code "E0200".
    const source =
        \\const x: i32 = 1.5;
    ;
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = try handler.validateDocument(source);
    defer freeDiagnostics(std.testing.allocator, diags);

    // Find a diagnostic with a code
    for (diags) |d| {
        if (d.code.len > 0) {
            try std.testing.expect(std.mem.startsWith(u8, d.code, "E"));
            return;
        }
    }
    std.debug.print("\nExpected a diagnostic with a code, got {d} diagnostics:\n", .{diags.len});
    for (diags) |d| {
        std.debug.print("  [{s}] {s}\n", .{ d.code, d.message });
    }
    return error.TestUnexpectedResult;
}

test "spec_url round-trips through validateDocument" {
    // workgroupBarrier inside a branch on a non-uniform builtin triggers
    // a uniformity error with code (E0701) and spec_ref ("uniformity").
    const source =
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) global_invocation_id: vec3<u32>) {
        \\  if (global_invocation_id.x > 0) {
        \\    workgroupBarrier();
        \\  }
        \\}
    ;
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = try handler.validateDocument(source);
    defer freeDiagnostics(std.testing.allocator, diags);

    for (diags) |d| {
        if (d.spec_url.len > 0) {
            try std.testing.expectEqualStrings("https://www.w3.org/TR/WGSL/#uniformity", d.spec_url);
            try std.testing.expect(d.code.len > 0);
            return;
        }
    }
    std.debug.print("\nExpected a diagnostic with spec_url, got {d} diagnostics:\n", .{diags.len});
    for (diags) |d| {
        std.debug.print("  [{s}] {s}\n", .{ d.code, d.message });
    }
    return error.TestUnexpectedResult;
}

// =========================================================================
// Code Action Tests
// =========================================================================

test "extractDidYouMean: undefined identifier" {
    const result = extractDidYouMean("use of undeclared identifier 'pos'; did you mean 'position'?");
    try std.testing.expectEqualStrings("position", result.?);
}

test "extractDidYouMean: unknown type" {
    const result = extractDidYouMean("unknown type 'vec3'; did you mean 'vec3f'?");
    try std.testing.expectEqualStrings("vec3f", result.?);
}

test "extractDidYouMean: no such member" {
    const result = extractDidYouMean("struct 'Foo' has no member 'y'; did you mean 'x'?");
    try std.testing.expectEqualStrings("x", result.?);
}

test "extractDidYouMean: not callable" {
    const result = extractDidYouMean("'foo' is not a function or type constructor; did you mean 'foo2'?");
    try std.testing.expectEqualStrings("foo2", result.?);
}

test "extractDidYouMean: invalid builtin" {
    const result = extractDidYouMean("unknown @builtin value 'positon'; did you mean 'position'?");
    try std.testing.expectEqualStrings("position", result.?);
}

test "extractDidYouMean: no suggestion" {
    try std.testing.expect(extractDidYouMean("type mismatch: expected 'f32'") == null);
}

test "extractDidYouMean: empty message" {
    try std.testing.expect(extractDidYouMean("") == null);
}

test "extractDuplicateLocation: input" {
    try std.testing.expectEqual(@as(i64, 0), extractDuplicateLocation("duplicate input @location(0)").?);
}

test "extractDuplicateLocation: output" {
    try std.testing.expectEqual(@as(i64, 3), extractDuplicateLocation("duplicate output @location(3)").?);
}

test "extractDuplicateLocation: no match" {
    try std.testing.expect(extractDuplicateLocation("some other error") == null);
}

test "extractDuplicateLocation: empty" {
    try std.testing.expect(extractDuplicateLocation("") == null);
}

test "computeCodeActions: did-you-mean produces rename action" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 5 }, .end = .{ .line = 0, .character = 8 } },
        .severity = .@"error",
        .message = "use of undeclared identifier 'pos'; did you mean 'position'?",
        .code = "E0100",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Replace with 'position'", actions[0].title);
    try std.testing.expectEqualStrings("quickfix", actions[0].kind);
    try std.testing.expect(actions[0].is_preferred);
    try std.testing.expectEqual(@as(usize, 1), actions[0].edits.len);
    try std.testing.expectEqualStrings("position", actions[0].edits[0].new_text);
    // Edit range matches diagnostic range
    try std.testing.expectEqual(@as(u32, 5), actions[0].edits[0].range.start.character);
    try std.testing.expectEqual(@as(u32, 8), actions[0].edits[0].range.end.character);
}

test "computeCodeActions: no suggestion means no action" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
        .severity = .@"error",
        .message = "use of undeclared identifier 'zzzzz'",
        .code = "E0100",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "computeCodeActions: non-matching code produces no action" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
        .severity = .@"error",
        .message = "break statement must be inside loop",
        .code = "E0500",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "computeCodeActions: multiple diagnostics produce multiple actions" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{
        .{
            .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 4 } },
            .severity = .@"error",
            .message = "use of undeclared identifier 'pos'; did you mean 'position'?",
            .code = "E0100",
        },
        .{
            .range = .{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 1, .character = 4 } },
            .severity = .@"error",
            .message = "unknown type 'vec3'; did you mean 'vec3f'?",
            .code = "E0200",
        },
    };

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 2), actions.len);
    try std.testing.expectEqualStrings("Replace with 'position'", actions[0].title);
    try std.testing.expectEqualStrings("Replace with 'vec3f'", actions[1].title);
}

test "computeCodeActions: E0206 no_such_member with suggestion" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 10 }, .end = .{ .line = 0, .character = 11 } },
        .severity = .@"error",
        .message = "struct 'Foo' has no member 'y'; did you mean 'x'?",
        .code = "E0206",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Replace with 'x'", actions[0].title);
    try std.testing.expectEqualStrings("x", actions[0].edits[0].new_text);
}

test "computeCodeActions: E0403 invalid builtin with suggestion" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 10 }, .end = .{ .line = 0, .character = 17 } },
        .severity = .@"error",
        .message = "unknown @builtin value 'positon'; did you mean 'position'?",
        .code = "E0403",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Replace with 'position'", actions[0].title);
}

test "offsetToLspPosition: basic" {
    const source = "line1\nline2\nline3";
    // offset 0 → line 0, char 0
    const p0 = offsetToLspPosition(source, 0).?;
    try std.testing.expectEqual(@as(u32, 0), p0.line);
    try std.testing.expectEqual(@as(u32, 0), p0.character);
    // offset 6 → line 1, char 0 (first char of "line2")
    const p6 = offsetToLspPosition(source, 6).?;
    try std.testing.expectEqual(@as(u32, 1), p6.line);
    try std.testing.expectEqual(@as(u32, 0), p6.character);
    // offset 8 → line 1, char 2 (third char of "line2")
    const p8 = offsetToLspPosition(source, 8).?;
    try std.testing.expectEqual(@as(u32, 1), p8.line);
    try std.testing.expectEqual(@as(u32, 2), p8.character);
}

test "offsetToLspPosition: past end returns null" {
    const source = "abc";
    try std.testing.expect(offsetToLspPosition(source, 4) == null);
}

test "offsetToLspPosition: round-trip with lspPositionToOffset" {
    const source = "fn main() {\n  let x = 1;\n  return;\n}";
    // Test a few offsets
    for ([_]u32{ 0, 5, 12, 14, 25, 35 }) |offset| {
        if (offset > source.len) continue;
        const pos = offsetToLspPosition(source, offset) orelse continue;
        const back = lspPositionToOffset(source, pos) orelse continue;
        try std.testing.expectEqual(@as(usize, offset), back);
    }
}

test "offsetRangeToLspRange: basic" {
    const source = "fn main() {\n  let x = 1;\n}";
    const range = offsetRangeToLspRange(source, 3, 7).?;
    // "main" starts at offset 3 on line 0
    try std.testing.expectEqual(@as(u32, 0), range.start.line);
    try std.testing.expectEqual(@as(u32, 3), range.start.character);
    try std.testing.expectEqual(@as(u32, 0), range.end.line);
    try std.testing.expectEqual(@as(u32, 7), range.end.character);
}

test "lspPositionToOffset: basic" {
    const source = "line1\nline2\nline3";
    // Line 0, char 3 → offset 3
    try std.testing.expectEqual(@as(usize, 3), lspPositionToOffset(source, .{ .line = 0, .character = 3 }).?);
    // Line 1, char 0 → offset 6 (after "line1\n")
    try std.testing.expectEqual(@as(usize, 6), lspPositionToOffset(source, .{ .line = 1, .character = 0 }).?);
    // Line 2, char 2 → offset 14
    try std.testing.expectEqual(@as(usize, 14), lspPositionToOffset(source, .{ .line = 2, .character = 2 }).?);
}

test "lspPositionToOffset: past end" {
    const source = "ab";
    try std.testing.expect(lspPositionToOffset(source, .{ .line = 5, .character = 0 }) == null);
}

// =========================================================================
// Additional Edge Case Tests
// =========================================================================

test "lspPositionToOffset: CRLF line endings" {
    const source = "line1\r\nline2\r\nline3";
    // Line 0, char 3 → offset 3
    try std.testing.expectEqual(@as(usize, 3), lspPositionToOffset(source, .{ .line = 0, .character = 3 }).?);
    // Line 1, char 0 → offset 7 (after "line1\r\n")
    try std.testing.expectEqual(@as(usize, 7), lspPositionToOffset(source, .{ .line = 1, .character = 0 }).?);
    // Line 1, char 2 → offset 9
    try std.testing.expectEqual(@as(usize, 9), lspPositionToOffset(source, .{ .line = 1, .character = 2 }).?);
    // Line 2, char 0 → offset 14 (after "line1\r\nline2\r\n")
    try std.testing.expectEqual(@as(usize, 14), lspPositionToOffset(source, .{ .line = 2, .character = 0 }).?);
}

test "lspPositionToOffset: CR-only line endings" {
    const source = "line1\rline2\rline3";
    try std.testing.expectEqual(@as(usize, 6), lspPositionToOffset(source, .{ .line = 1, .character = 0 }).?);
    try std.testing.expectEqual(@as(usize, 12), lspPositionToOffset(source, .{ .line = 2, .character = 0 }).?);
}

test "lspPositionToOffset: empty source" {
    try std.testing.expectEqual(@as(usize, 0), lspPositionToOffset("", .{ .line = 0, .character = 0 }).?);
    try std.testing.expect(lspPositionToOffset("", .{ .line = 0, .character = 1 }) == null);
    try std.testing.expect(lspPositionToOffset("", .{ .line = 1, .character = 0 }) == null);
}

test "lspPositionToOffset: position at exact end" {
    const source = "abc";
    try std.testing.expectEqual(@as(usize, 3), lspPositionToOffset(source, .{ .line = 0, .character = 3 }).?);
    // One past end returns null
    try std.testing.expect(lspPositionToOffset(source, .{ .line = 0, .character = 4 }) == null);
}

test "lspPositionToOffset: character beyond line length" {
    const source = "short\nab";
    // character 100 on a 5-char line
    try std.testing.expect(lspPositionToOffset(source, .{ .line = 0, .character = 100 }) == null);
}

test "extractDidYouMean: suggestion with underscores" {
    const result = extractDidYouMean("use of undeclared identifier 'global_id'; did you mean 'global_invocation_id'?");
    try std.testing.expectEqualStrings("global_invocation_id", result.?);
}

test "extractDidYouMean: suggestion with numbers" {
    const result = extractDidYouMean("unknown type 'vec3f32'; did you mean 'vec3f'?");
    try std.testing.expectEqualStrings("vec3f", result.?);
}

test "extractDidYouMean: single-character suggestion" {
    const result = extractDidYouMean("struct 'S' has no member 'ab'; did you mean 'a'?");
    try std.testing.expectEqualStrings("a", result.?);
}

test "extractDidYouMean: message with quotes but no suggestion" {
    // Has single quotes but not the "did you mean" pattern
    try std.testing.expect(extractDidYouMean("cannot initialize 'x' with type 'f32'") == null);
}

test "extractDuplicateLocation: multi-digit numbers" {
    try std.testing.expectEqual(@as(i64, 10), extractDuplicateLocation("duplicate input @location(10)").?);
    try std.testing.expectEqual(@as(i64, 99), extractDuplicateLocation("duplicate output @location(99)").?);
    try std.testing.expectEqual(@as(i64, 255), extractDuplicateLocation("duplicate input @location(255)").?);
}

test "extractDuplicateLocation: non-numeric content" {
    // @location with non-numeric value should return null
    try std.testing.expect(extractDuplicateLocation("duplicate input @location(abc)") == null);
}

test "computeCodeActions: E0204 not_callable with suggestion" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 4 } },
        .severity = .@"error",
        .message = "'foo' is not a function or type constructor; did you mean 'f32'?",
        .code = "E0204",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Replace with 'f32'", actions[0].title);
    try std.testing.expectEqualStrings("f32", actions[0].edits[0].new_text);
}

test "computeCodeActions: empty diagnostic array" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{};
    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "computeCodeActions: diagnostic with empty code" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
        .severity = .@"error",
        .message = "some error; did you mean 'x'?",
        .code = "",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    // Empty code should not match any handler
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "computeCodeActions: diagnostic with empty message" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
        .severity = .@"error",
        .message = "",
        .code = "E0100",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    // Empty message means no suggestion extractable
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "computeCodeActions: zero-width diagnostic range" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 5 }, .end = .{ .line = 0, .character = 5 } },
        .severity = .@"error",
        .message = "use of undeclared identifier 'x'; did you mean 'y'?",
        .code = "E0100",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    // Still produces action even with zero-width range (insertion)
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("y", actions[0].edits[0].new_text);
    // Edit range matches the zero-width diagnostic range
    try std.testing.expectEqual(@as(u32, 5), actions[0].edits[0].range.start.character);
    try std.testing.expectEqual(@as(u32, 5), actions[0].edits[0].range.end.character);
}

test "computeCodeActions: E0602 duplicate location increment" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    // Register a source document so findLocationAttrRange can scan it
    try handler.openDocument("test://file.wgsl", "@location(0) a: f32, @location(0) b: f32", 1);

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 21 }, .end = .{ .line = 0, .character = 34 } },
        .severity = .@"error",
        .message = "duplicate input @location(0)",
        .code = "E0602",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Change to @location(1)", actions[0].title);
    try std.testing.expectEqualStrings("@location(1)", actions[0].edits[0].new_text);
}

test "computeCodeActions: E0602 with no open document" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    // No document opened — findLocationAttrRange should return null
    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 5 }, .end = .{ .line = 0, .character = 10 } },
        .severity = .@"error",
        .message = "duplicate input @location(0)",
        .code = "E0602",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    // No action because no document to scan
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "computeCodeActions: E0602 multi-digit location" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    try handler.openDocument("test://file.wgsl", "@location(10) a: f32, @location(10) b: f32", 1);

    const diags = [_]LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 22 }, .end = .{ .line = 0, .character = 36 } },
        .severity = .@"error",
        .message = "duplicate input @location(10)",
        .code = "E0602",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Change to @location(11)", actions[0].title);
    try std.testing.expectEqualStrings("@location(11)", actions[0].edits[0].new_text);
}

test "computeCodeActions: mixed diagnostics produce correct actions" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    try handler.openDocument("test://file.wgsl", "@location(0) a: f32, @location(0) b: f32", 1);

    const diags = [_]LspDiagnostic{
        .{
            .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 3 } },
            .severity = .@"error",
            .message = "use of undeclared identifier 'pos'; did you mean 'position'?",
            .code = "E0100",
        },
        .{
            .range = .{ .start = .{ .line = 0, .character = 21 }, .end = .{ .line = 0, .character = 34 } },
            .severity = .@"error",
            .message = "duplicate input @location(0)",
            .code = "E0602",
        },
        .{
            .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
            .severity = .@"error",
            .message = "break statement must be inside loop",
            .code = "E0500",
        },
    };

    const actions = try handler.computeCodeActions(&diags);
    defer freeCodeActions(std.testing.allocator, actions);

    // E0100 produces rename, E0602 produces location fix, E0500 produces nothing
    try std.testing.expectEqual(@as(usize, 2), actions.len);
    try std.testing.expectEqualStrings("Replace with 'position'", actions[0].title);
    try std.testing.expectEqualStrings("Change to @location(1)", actions[1].title);
}

test "isDidYouMeanCode: all supported codes" {
    try std.testing.expect(isDidYouMeanCode("E0100"));
    try std.testing.expect(isDidYouMeanCode("E0200"));
    try std.testing.expect(isDidYouMeanCode("E0204"));
    try std.testing.expect(isDidYouMeanCode("E0206"));
    try std.testing.expect(isDidYouMeanCode("E0403"));
}

test "isDidYouMeanCode: non-matching codes" {
    try std.testing.expect(!isDidYouMeanCode("E0500"));
    try std.testing.expect(!isDidYouMeanCode("E0602"));
    try std.testing.expect(!isDidYouMeanCode(""));
    try std.testing.expect(!isDidYouMeanCode("E0101"));
}

test "convertDiagnostic OOM on message dupe yields empty message" {
    // FailingAllocator that fails on the first allocation (the message dupe).
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const alloc = failing.allocator();

    const entry = WgslDiagnostic.Entry{ .message = "some error" };
    const result = convertDiagnostic(alloc, &entry);

    // OOM fallback: message should be empty, not a dangling borrowed slice.
    try std.testing.expectEqual(@as(usize, 0), result.message.len);

    // freeDiagnostics must not crash — the empty message is skipped by the len > 0 guard.
    const diags = try std.testing.allocator.alloc(LspDiagnostic, 1);
    diags[0] = result;
    freeDiagnostics(std.testing.allocator, diags);
}

test "convertDiagnostic OOM on related message dupe yields empty message" {
    // Allocator that succeeds for the related[] alloc but fails on the string dupe.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const alloc = failing.allocator();

    const related = [_]WgslDiagnostic.RelatedInfo{
        .{ .message = "related note" },
    };
    const entry = WgslDiagnostic.Entry{
        .message = "main error",
        .related = &related,
    };
    const result = convertDiagnostic(alloc, &entry);

    // The related array was allocated (alloc #0), but the dupe (#1) failed.
    if (result.related.len > 0) {
        try std.testing.expectEqual(@as(usize, 0), result.related[0].message.len);
    }

    // Clean up: freeDiagnostics must handle this without crashing.
    const diags = try std.testing.allocator.alloc(LspDiagnostic, 1);
    diags[0] = result;
    freeDiagnostics(std.testing.allocator, diags);
}

test "convertDiagnostic with message and related round-trips through freeDiagnostics" {
    const related = [_]WgslDiagnostic.RelatedInfo{
        .{ .message = "see declaration here" },
        .{ .message = "first used here" },
    };
    const entry = WgslDiagnostic.Entry{
        .message = "duplicate definition",
        .code = "E0100",
        .related = &related,
    };
    const result = convertDiagnostic(std.testing.allocator, &entry);

    // Verify all strings were duped (owned, not borrowed).
    try std.testing.expectEqualStrings("duplicate definition", result.message);
    try std.testing.expectEqual(@as(usize, 2), result.related.len);
    try std.testing.expectEqualStrings("see declaration here", result.related[0].message);
    try std.testing.expectEqualStrings("first used here", result.related[1].message);

    // freeDiagnostics must free all owned memory without leaking.
    // std.testing.allocator detects leaks.
    const diags = try std.testing.allocator.alloc(LspDiagnostic, 1);
    diags[0] = result;
    freeDiagnostics(std.testing.allocator, diags);
}
