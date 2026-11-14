//! Cross-root reference, highlight, and rename collection for pngine
//! shader projects (pngine-shaders phase 04, Task 3).
//!
//! Every entry point starts from `pngine_context.contextsAt`: the request
//! position is author-local, and each containing root contributes one
//! context with a borrowed `RootAnalysis` and the assembled offset to
//! query. `NodeAtOffset` is always applied to that assembled offset — never
//! to the author offset — and every collected range is mapped back through
//! the *same* root's `Assembled` before it becomes an LSP range.
//!
//! ## Declaration identity
//!
//! A target is identified by `Handler.SymbolKey` (author part plus the
//! declaration name's author-local byte range), not by a root-local
//! `SymbolIndex`. Two roots that resolve the same author position to
//! different keys have genuinely divergent bindings:
//!
//! - references return both identities' references, deduplicated by
//!   `(origin, author range)` and then by `(URI, range)`. That is the
//!   visible ambiguity report; no root is silently preferred.
//! - `prepareRename` and `computeRename` return `null`. Merging edits for
//!   two unrelated declarations would rewrite a symbol the request never
//!   selected.
//!
//! A root that does not resolve the token at all (an unfilled `:requires`
//! hole, for example) contributes no identity but does not by itself make a
//! rename ambiguous; only two distinct resolved identities do.
//!
//! ## Inline `:code` origins
//!
//! An inline part has a stable virtual document URI minted from the program
//! path, part index and current content hash. Its references are reported on
//! that URI; the URI is read-only and any edit set that would have to write
//! inline text refuses the whole rename.
//!
//! ## Unsaved text
//!
//! Ranges are converted against the origin part's *current* text from
//! `Store.textForPart`, so an open sibling's edits target its buffer ranges,
//! not the provider's disk ranges.

const std = @import("std");
const wgslender = @import("wgslender");
const build_options = @import("build_options");

const Handler = @import("../Handler.zig");
const PngineContext = @import("pngine_context.zig");
const NodeAtOffset = @import("node_at_offset.zig");

const pngine_support = build_options.pngine_support;
const Pngine = if (pngine_support) wgslender.Pngine else void;

const Allocator = std.mem.Allocator;
const Ast = wgslender.Ast;
const Edits = wgslender.Edits;
const Position = Handler.Position;
const Range = Handler.Range;
const LspTextEdit = Handler.LspTextEdit;
const DocumentEdits = Handler.DocumentEdits;
const WorkspaceChanges = Handler.WorkspaceChanges;

/// One author-facing reference. `uri` is the part's file URI or, for inline
/// `:code` text, its read-only virtual document URI.
pub const ReferenceLocation = struct {
    uri: ?[]const u8,
    range: Range,
    is_write: bool,
};

/// Release a slice returned by `references`.
pub fn freeReferences(handler: *Handler, refs: []ReferenceLocation) void {
    for (refs) |ref| {
        if (ref.uri) |uri| handler.gpa.free(uri);
    }
    handler.gpa.free(refs);
}

/// Release a value returned by `rename`.
pub fn freeWorkspaceChanges(handler: *Handler, changes: WorkspaceChanges) void {
    for (changes.documents) |document| {
        handler.gpa.free(document.uri);
        handler.gpa.free(document.edits);
    }
    handler.gpa.free(changes.documents);
}

// =========================================================================
// Targets
// =========================================================================

const TargetKind = enum {
    /// A single-document request: no project identity, one local symbol.
    standalone,
    /// A composed request with a mapped declaration identity.
    project,
};

const Target = struct {
    context_index: usize,
    symbol: Ast.SymbolIndex,
    key: ?Handler.SymbolKey,
    kind: TargetKind,
    /// The reference/declaration token at the request position, in the
    /// assembled module. Mapped back through the context for prepareRename.
    token_start: u32,
    token_end: u32,
    module: *const Ast.Module,
};

const ResolvedNode = struct {
    symbol: Ast.SymbolIndex,
    token_start: u32,
    token_end: u32,
};

fn nodeSymbol(node: NodeAtOffset.NodeAtPosition, module: *const Ast.Module) ?ResolvedNode {
    return switch (node) {
        .ident => |id| {
            if (!id.ref.isValid()) return null;
            return .{
                .symbol = id.ref,
                .token_start = id.loc,
                .token_end = id.loc + @as(u32, @intCast(id.name.len)),
            };
        },
        .decl_name => |dn| {
            if (!dn.sym_idx.isValid()) return null;
            if (dn.sym_idx.index() >= module.symbols.items.len) return null;
            const name = module.symbols.items[dn.sym_idx.index()].original_name;
            return .{
                .symbol = dn.sym_idx,
                .token_start = dn.loc,
                .token_end = dn.loc + @as(u32, @intCast(name.len)),
            };
        },
        .type_ref => |tr| {
            if (!tr.ref.isValid()) return null;
            return .{
                .symbol = tr.ref,
                .token_start = tr.loc,
                .token_end = tr.loc + @as(u32, @intCast(tr.name.len)),
            };
        },
        else => null,
    };
}

/// Resolve the request in every context. A builtin, retired, unmappable, or
/// unresolved token contributes nothing.
fn resolveTargets(handler: *Handler, contexts: []Handler.RequestContext) ![]Target {
    var targets: std.ArrayList(Target) = .empty;
    errdefer targets.deinit(handler.gpa);

    for (contexts, 0..) |*context, index| {
        const analysis = PngineContext.analysisFor(handler, context) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        const module = analysis.module orelse continue;
        const resolved = nodeSymbol(NodeAtOffset.find(module, context.assembled_offset), module) orelse
            continue;
        if (resolved.symbol.index() >= module.symbols.items.len) continue;
        const sym = module.symbols.items[resolved.symbol.index()];
        if (sym.flags.is_retired) continue;

        if (context.isComposed()) {
            if (sym.flags.is_builtin) continue;
            const key = Handler.declarationKey(context, resolved.symbol) orelse continue;
            try targets.append(handler.gpa, .{
                .context_index = index,
                .symbol = resolved.symbol,
                .key = key,
                .kind = .project,
                .token_start = resolved.token_start,
                .token_end = resolved.token_end,
                .module = module,
            });
        } else {
            try targets.append(handler.gpa, .{
                .context_index = index,
                .symbol = resolved.symbol,
                .key = null,
                .kind = .standalone,
                .token_start = resolved.token_start,
                .token_end = resolved.token_end,
                .module = module,
            });
        }
    }
    return targets.toOwnedSlice(handler.gpa);
}

/// True when every resolved target names the same declaration identity. A
/// single standalone target is trivially unambiguous.
fn sameIdentity(targets: []const Target) bool {
    var key: ?Handler.SymbolKey = null;
    for (targets) |target| {
        switch (target.kind) {
            .standalone => {
                if (targets.len != 1) return false;
            },
            .project => {
                const candidate = target.key orelse return false;
                if (key) |existing| {
                    if (!existing.eql(candidate)) return false;
                } else {
                    key = candidate;
                }
            },
        }
    }
    return true;
}

// =========================================================================
// Raw reference collection
// =========================================================================

const RawReference = struct {
    /// `null` for a standalone document; otherwise the author part the
    /// assembled range mapped to.
    origin: ?PngineContext.OriginKey,
    range: PngineContext.ByteRange,
    is_write: bool,
};

fn collectRawReferences(
    handler: *Handler,
    contexts: []Handler.RequestContext,
    targets: []const Target,
    include_declaration: bool,
) !std.ArrayList(RawReference) {
    var raws: std.ArrayList(RawReference) = .empty;
    errdefer raws.deinit(handler.gpa);

    for (targets) |target| {
        const context = &contexts[target.context_index];
        const analysis = PngineContext.analysisFor(handler, context) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        const module = analysis.module orelse continue;
        const refs = try Edits.findReferences(
            handler.gpa,
            module,
            target.symbol,
            include_declaration,
        );
        defer handler.gpa.free(refs);

        for (refs) |ref| {
            if (!context.isComposed()) {
                try appendRaw(handler.gpa, &raws, .{
                    .origin = null,
                    .range = .{ .start = ref.start, .end = ref.end },
                    .is_write = ref.is_write,
                });
                continue;
            }
            const origin_range = PngineContext.originRange(context, ref.start, ref.end) orelse
                continue;
            try appendRaw(handler.gpa, &raws, .{
                .origin = origin_range.origin,
                .range = origin_range.range,
                .is_write = ref.is_write,
            });
        }
    }
    return raws;
}

fn appendRaw(gpa: Allocator, raws: *std.ArrayList(RawReference), raw: RawReference) !void {
    for (raws.items) |existing| {
        if (!std.meta.eql(existing.origin, raw.origin)) continue;
        if (existing.range.start != raw.range.start) continue;
        if (existing.range.end != raw.range.end) continue;
        return;
    }
    try raws.append(gpa, raw);
}

// =========================================================================
// Origin text and URI cache
// =========================================================================

const OriginState = struct {
    origin: ?PngineContext.OriginKey,
    text: PngineContext.AuthorText,
    mapper: Handler.PositionMapper,
    /// `null` for inline text, or a file URI. Valid after `uri_resolved`.
    uri: ?[]const u8 = null,
    uri_resolved: bool = false,

    fn deinit(self: *OriginState, gpa: Allocator) void {
        self.mapper.deinit(gpa);
        self.text.deinit(gpa);
        if (self.uri) |uri| gpa.free(uri);
    }
};

fn stateFor(
    handler: *Handler,
    contexts: []const Handler.RequestContext,
    cache: *std.ArrayList(OriginState),
    origin: ?PngineContext.OriginKey,
) !*OriginState {
    for (cache.items) |*entry| {
        if (std.meta.eql(entry.origin, origin)) return entry;
    }

    var text = if (origin) |part|
        try PngineContext.originText(handler, part)
    else
        try PngineContext.authorText(handler, &contexts[0]);
    errdefer text.deinit(handler.gpa);

    var mapper = try Handler.PositionMapper.init(handler.gpa, text.text);
    errdefer mapper.deinit(handler.gpa);

    try cache.append(handler.gpa, .{
        .origin = origin,
        .text = text,
        .mapper = mapper,
    });
    return &cache.items[cache.items.len - 1];
}

fn originEqual(a: PngineContext.OriginKey, b: PngineContext.OriginKey) bool {
    return a.program == b.program and a.index == b.index;
}

/// Resolve an origin's response URI once. The request document keeps the
/// client's own spelling; a sibling uses the part's canonical file URI; an
/// inline origin has none.
fn uriForState(
    handler: *Handler,
    contexts: []const Handler.RequestContext,
    state: *OriginState,
) !?[]const u8 {
    if (state.uri_resolved) return state.uri;

    var resolved: ?[]const u8 = null;
    if (state.origin) |origin| {
        const request_origin = contexts[0].origin;
        if (request_origin) |request| {
            if (originEqual(request, origin)) {
                if (contexts[0].request_uri) |request_uri| {
                    resolved = try handler.gpa.dupe(u8, request_uri);
                }
            }
        }
        if (resolved == null and (request_origin == null or !originEqual(request_origin.?, origin))) {
            resolved = try Handler.originUri(handler, handler.gpa, origin);
        }
    } else if (contexts[0].request_uri) |request_uri| {
        resolved = try handler.gpa.dupe(u8, request_uri);
    }

    state.uri = resolved;
    state.uri_resolved = true;
    return resolved;
}

/// True when an edit set may not write this origin: inline `:code` text is
/// read-only, and an origin whose part no longer exists cannot be addressed.
fn originCannotEdit(handler: *Handler, origin: PngineContext.OriginKey) bool {
    if (comptime pngine_support) {
        const store = handler.pngine_store orelse return true;
        const part = store.part(origin) orelse return true;
        return switch (part.origin) {
            .inline_code => true,
            .file => false,
        };
    } else {
        std.mem.doNotOptimizeAway(origin);
        return false;
    }
}

// =========================================================================
// References
// =========================================================================

pub fn references(
    handler: *Handler,
    uri: []const u8,
    position: Position,
    include_declaration: bool,
) !?[]ReferenceLocation {
    const contexts = try Handler.contextsAt(handler, uri, position);
    defer Handler.freeContexts(handler, contexts);
    if (contexts.len == 0) return null;

    const targets = try resolveTargets(handler, contexts);
    defer handler.gpa.free(targets);
    if (targets.len == 0) return null;

    var raws = try collectRawReferences(handler, contexts, targets, include_declaration);
    defer raws.deinit(handler.gpa);

    var out: std.ArrayList(ReferenceLocation) = .empty;
    errdefer {
        for (out.items) |ref| {
            if (ref.uri) |ref_uri| handler.gpa.free(ref_uri);
        }
        out.deinit(handler.gpa);
    }

    var cache: std.ArrayList(OriginState) = .empty;
    defer {
        for (cache.items) |*state| state.deinit(handler.gpa);
        cache.deinit(handler.gpa);
    }

    for (raws.items) |raw| {
        const state = try stateFor(handler, contexts, &cache, raw.origin);
        const range = state.mapper.range(raw.range.start, raw.range.end) orelse continue;
        const uri_value = try uriForState(handler, contexts, state);
        const owned_uri = if (uri_value) |value| try handler.gpa.dupe(u8, value) else null;
        errdefer if (owned_uri) |value| handler.gpa.free(value);
        try appendReference(handler.gpa, &out, .{
            .uri = owned_uri,
            .range = range,
            .is_write = raw.is_write,
        });
    }

    return try out.toOwnedSlice(handler.gpa);
}

fn appendReference(
    gpa: Allocator,
    out: *std.ArrayList(ReferenceLocation),
    ref: ReferenceLocation,
) !void {
    for (out.items) |existing| {
        if (ref.uri != null and existing.uri != null) {
            if (!std.mem.eql(u8, existing.uri.?, ref.uri.?)) continue;
        } else if (ref.uri != null or existing.uri != null) {
            continue;
        } else {
            // Two inline references may share local offsets in different
            // parts. Raw collection already deduplicated `(origin, range)`,
            // so keep the second inline entry rather than merging origins.
            continue;
        }
        if (!std.meta.eql(existing.range, ref.range)) continue;
        // Same file location reached through another part/origin spelling:
        // report it once, keyed by `(URI, range)`.
        if (ref.uri) |owned| gpa.free(owned);
        return;
    }
    try out.append(gpa, ref);
}

// =========================================================================
// Document highlights
// =========================================================================

pub fn highlights(handler: *Handler, uri: []const u8, position: Position) !?[]Handler.DocumentHighlight {
    const contexts = try Handler.contextsAt(handler, uri, position);
    defer Handler.freeContexts(handler, contexts);
    if (contexts.len == 0) return null;

    const targets = try resolveTargets(handler, contexts);
    defer handler.gpa.free(targets);
    if (targets.len == 0) return null;

    var raws = try collectRawReferences(handler, contexts, targets, true);
    defer raws.deinit(handler.gpa);

    var text = try PngineContext.authorText(handler, &contexts[0]);
    defer text.deinit(handler.gpa);
    var mapper = try Handler.PositionMapper.init(handler.gpa, text.text);
    defer mapper.deinit(handler.gpa);

    var out: std.ArrayList(Handler.DocumentHighlight) = .empty;
    errdefer out.deinit(handler.gpa);

    for (raws.items) |raw| {
        if (contexts[0].isComposed()) {
            const origin = raw.origin orelse continue;
            const request_origin = contexts[0].origin orelse continue;
            if (!originEqual(origin, request_origin)) continue;
        }
        const range = mapper.range(raw.range.start, raw.range.end) orelse continue;
        const kind: Handler.HighlightKind = if (raw.is_write) .write else .read;
        var duplicate = false;
        for (out.items) |existing| {
            if (!std.meta.eql(existing.range, range)) continue;
            if (existing.kind != kind) continue;
            duplicate = true;
            break;
        }
        if (!duplicate) try out.append(handler.gpa, .{ .range = range, .kind = kind });
    }

    return try out.toOwnedSlice(handler.gpa);
}

// =========================================================================
// Prepare rename
// =========================================================================

pub fn prepareRename(handler: *Handler, uri: []const u8, position: Position) !?Range {
    const contexts = try Handler.contextsAt(handler, uri, position);
    defer Handler.freeContexts(handler, contexts);
    if (contexts.len == 0) return null;

    const targets = try resolveTargets(handler, contexts);
    defer handler.gpa.free(targets);
    if (targets.len == 0) return null;
    if (!sameIdentity(targets)) return null;

    // The edit set is not known here, but it always includes the declaration
    // and every bound reference. If any of those would write virtual inline
    // text, prepare must refuse just like rename.
    var raws = try collectRawReferences(handler, contexts, targets, true);
    defer raws.deinit(handler.gpa);
    for (raws.items) |raw| {
        const origin = raw.origin orelse continue;
        if (originCannotEdit(handler, origin)) return null;
    }

    const target = targets[0];
    const context = &contexts[target.context_index];
    var text = try PngineContext.authorText(handler, context);
    defer text.deinit(handler.gpa);

    if (context.isComposed()) {
        const author = PngineContext.toAuthorRange(
            context,
            target.token_start,
            target.token_end,
        ) orelse return null;
        return Handler.offsetRangeToLspRange(text.text, author.start, author.end);
    }
    return Handler.offsetRangeToLspRange(text.text, target.token_start, target.token_end);
}

// =========================================================================
// Rename
// =========================================================================

pub fn rename(
    handler: *Handler,
    uri: []const u8,
    position: Position,
    new_name: []const u8,
) !?WorkspaceChanges {
    if (!Edits.isValidWgslIdentifier(new_name)) return null;

    const contexts = try Handler.contextsAt(handler, uri, position);
    defer Handler.freeContexts(handler, contexts);
    if (contexts.len == 0) return null;

    const targets = try resolveTargets(handler, contexts);
    defer handler.gpa.free(targets);
    if (targets.len == 0) return null;
    if (!sameIdentity(targets)) return null;

    // A rename is one edit applied to every affected root. If any root would
    // gain a duplicate declaration with `new_name`, no root may receive the
    // edit set. Standalone documents keep their pre-project behavior.
    for (targets) |target| {
        if (target.kind != .project) continue;
        if (collidesWithDeclaration(target.module, target.symbol, new_name)) return null;
    }

    var raws = try collectRawReferences(handler, contexts, targets, true);
    defer raws.deinit(handler.gpa);

    for (raws.items) |raw| {
        const origin = raw.origin orelse continue;
        if (originCannotEdit(handler, origin)) return null;
    }

    return try buildWorkspaceChanges(handler, contexts, raws.items, new_name);
}

const PendingDocument = struct {
    uri: ?[]u8,
    edits: std.ArrayList(LspTextEdit) = .empty,

    fn deinit(self: *PendingDocument, gpa: Allocator) void {
        if (self.uri) |uri| gpa.free(uri);
        self.edits.deinit(gpa);
    }
};

fn buildWorkspaceChanges(
    handler: *Handler,
    contexts: []const Handler.RequestContext,
    raws: []const RawReference,
    new_name: []const u8,
) !WorkspaceChanges {
    var pending: std.ArrayList(PendingDocument) = .empty;
    defer {
        for (pending.items) |*document| document.deinit(handler.gpa);
        pending.deinit(handler.gpa);
    }

    var cache: std.ArrayList(OriginState) = .empty;
    defer {
        for (cache.items) |*state| state.deinit(handler.gpa);
        cache.deinit(handler.gpa);
    }

    for (raws) |raw| {
        const state = try stateFor(handler, contexts, &cache, raw.origin);
        const range = state.mapper.range(raw.range.start, raw.range.end) orelse continue;
        const resolved_uri = try uriForState(handler, contexts, state);
        const uri_value = resolved_uri orelse continue;

        var document: ?*PendingDocument = null;
        for (pending.items) |*candidate| {
            const candidate_uri = candidate.uri orelse continue;
            if (!std.mem.eql(u8, candidate_uri, uri_value)) continue;
            document = candidate;
            break;
        }
        if (document == null) {
            const owned_uri = try handler.gpa.dupe(u8, uri_value);
            errdefer handler.gpa.free(owned_uri);
            try pending.append(handler.gpa, .{ .uri = owned_uri });
            document = &pending.items[pending.items.len - 1];
        }

        const target_document = document.?;
        var duplicate = false;
        for (target_document.edits.items) |existing| {
            if (std.meta.eql(existing.range, range)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) {
            try target_document.edits.append(handler.gpa, .{
                .range = range,
                .new_text = new_name,
            });
        }
    }

    const documents = try handler.gpa.alloc(DocumentEdits, pending.items.len);
    errdefer handler.gpa.free(documents);
    var transferred: usize = 0;
    errdefer for (documents[0..transferred]) |document| {
        handler.gpa.free(document.uri);
        handler.gpa.free(document.edits);
    };

    for (pending.items, 0..) |*document, index| {
        const edits = try document.edits.toOwnedSlice(handler.gpa);
        documents[index] = .{
            .uri = document.uri.?,
            .edits = edits,
        };
        document.uri = null;
        transferred = index + 1;
    }

    return .{ .documents = documents };
}

// =========================================================================
// Collision safety
// =========================================================================

/// True when renaming `target` to `new_name` in this root would introduce a
/// duplicate declaration in the same WGSL scope.
fn collidesWithDeclaration(
    module: *const Ast.Module,
    target: Ast.SymbolIndex,
    new_name: []const u8,
) bool {
    if (!target.isValid()) return false;
    if (target.index() >= module.symbols.items.len) return false;
    const target_loc = module.symbols.items[target.index()].loc;

    switch (Edits.findOwningDecl(module, target, false)) {
        .decl => return moduleDeclarationCollides(module, target, new_name),
        .parameter, .local_decl => {
            for (module.declarations.items) |decl| {
                const function = switch (decl) {
                    .function => |f| f,
                    else => continue,
                };
                if (!spanContains(function.decl_span, target_loc)) continue;
                for (function.parameters.items) |parameter| {
                    if (parameter.name == target) continue;
                    if (symbolNamed(module, parameter.name, new_name)) return true;
                }
                if (function.body) |body| {
                    return compoundHasName(module, body, target, new_name);
                }
                return false;
            }
            return false;
        },
        .member => {
            for (module.declarations.items) |decl| {
                const struct_decl = switch (decl) {
                    .@"struct" => |s| s,
                    else => continue,
                };
                if (!spanContains(struct_decl.decl_span, target_loc)) continue;
                for (struct_decl.members.items) |member| {
                    if (member.name == target) continue;
                    if (symbolNamed(module, member.name, new_name)) return true;
                }
                return false;
            }
            return false;
        },
        .return_type, .none => return moduleDeclarationCollides(module, target, new_name),
    }
}

fn moduleDeclarationCollides(
    module: *const Ast.Module,
    target: Ast.SymbolIndex,
    new_name: []const u8,
) bool {
    for (module.declarations.items) |decl| {
        const name = decl.nameRef();
        if (name == target) continue;
        if (symbolNamed(module, name, new_name)) return true;
    }
    return false;
}

fn symbolNamed(module: *const Ast.Module, symbol: Ast.SymbolIndex, name: []const u8) bool {
    if (!symbol.isValid()) return false;
    if (symbol.index() >= module.symbols.items.len) return false;
    const sym = module.symbols.items[symbol.index()];
    if (sym.flags.is_retired) return false;
    return std.mem.eql(u8, sym.original_name, name);
}

fn spanContains(span: Ast.Span, offset: u32) bool {
    return !span.isEmpty() and offset >= span.start and offset < span.end;
}

fn compoundHasName(
    module: *const Ast.Module,
    compound: *const Ast.CompoundStmt,
    target: Ast.SymbolIndex,
    new_name: []const u8,
) bool {
    for (compound.stmts.items) |stmt| {
        if (stmtHasName(module, stmt, target, new_name)) return true;
    }
    return false;
}

fn stmtHasName(
    module: *const Ast.Module,
    stmt: Ast.Stmt,
    target: Ast.SymbolIndex,
    new_name: []const u8,
) bool {
    switch (stmt) {
        .decl => |decl| {
            const name = decl.decl.nameRef();
            return name != target and symbolNamed(module, name, new_name);
        },
        .compound => |compound| return compoundHasName(module, compound, target, new_name),
        .@"if" => |branch| {
            if (compoundHasName(module, branch.body, target, new_name)) return true;
            if (branch.else_branch) |else_branch| {
                return stmtHasName(module, else_branch, target, new_name);
            }
            return false;
        },
        .@"for" => |loop| {
            if (loop.init_stmt) |init_stmt| {
                if (stmtHasName(module, init_stmt, target, new_name)) return true;
            }
            return compoundHasName(module, loop.body, target, new_name);
        },
        .@"while" => |loop| return compoundHasName(module, loop.body, target, new_name),
        .loop => |loop| {
            if (compoundHasName(module, loop.body, target, new_name)) return true;
            if (loop.continuing) |continuing| {
                return compoundHasName(module, continuing, target, new_name);
            }
            return false;
        },
        .@"switch" => |switch_stmt| {
            for (switch_stmt.cases.items) |case| {
                if (compoundHasName(module, case.body, target, new_name)) return true;
            }
            return false;
        },
        else => return false,
    }
}
