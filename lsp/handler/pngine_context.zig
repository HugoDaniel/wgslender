//! Request contexts and declaration identity for pngine shader projects
//! (pngine-shaders phase 04, Task 1).
//!
//! A feature request arrives in **author coordinates**: a document URI and an
//! LSP position inside that file. An assembled root's analysis speaks in
//! **assembled coordinates**. This module is the one place that converts
//! between them, and it never hands an assembled offset to a caller as if it
//! were an author position.
//!
//! `contextsAt` resolves a document URI through the Store's reverse
//! membership index and returns one `RequestContext` per containing root.
//! Each context carries the root's borrowed `RootAnalysis`, the author part
//! the requested file occupies in that root, and the assembled offset the
//! analysis must be queried at. The request URI itself is never rewritten:
//! callers keep the client's spelling, while identity comes from `OriginKey`.
//!
//! ## Validity rules
//!
//! A position yields a context only when it names a real authored byte:
//!
//! - a body or hoisted-directive byte maps to an assembled offset and back
//!   to the same `(origin, offset)`;
//! - a first-occurrence blanked directive maps through its hoisted twin
//!   (the copy the compiler sees);
//! - a duplicate blanked directive, an offset past the author EOF, and a
//!   synthetic part terminator have no semantic byte and yield no context.
//!
//! No mapping result is ever clamped to a neighbouring part. The reverse
//! check runs on every context, so a Store/Assembled mismatch degrades to
//! "no context" instead of a silent cross-file answer.
//!
//! ## URIs and inline parts
//!
//! A `:file` part has a file URI; a `:code` part does not. Before the
//! virtual-document layer exists, `originUri` returns `null` for inline
//! parts rather than inventing a path, and a part-addressed context carries
//! no request URI. `Location` results must omit such origins; the codec
//! never fabricates a URI.
//!
//! ## Standalone documents
//!
//! A document that is not a project member gets exactly one identity
//! context: `analysis == null`, `origin == null`, and
//! `assembled_offset == author_offset`. Feature handlers can use that to
//! recognise the legacy single-document path while still sharing one
//! request-shape vocabulary with composed documents. The author text comes
//! from the Handler's open documents; a URI that is neither a member nor
//! open has no text to decode and yields no context.
//!
//! ## Lifetime
//!
//! `RootAnalysis.assembled` is borrowed from the Store and is valid only
//! while the Store keeps that unit. A context stores the pointer
//! `Handler.analyzeRoot` returned in the same call; consumers must read it
//! before any Store mutation and must not retain it across requests. The
//! context slice itself is owned by the caller and freed with
//! `freeContexts`.

const std = @import("std");
const wgslender = @import("wgslender");
const build_options = @import("build_options");
const pngine_path = @import("pngine_path");
const Handler = @import("../Handler.zig");
const PngineAnalysis = @import("pngine_analysis.zig");

const pngine_support = build_options.pngine_support;
const Pngine = if (pngine_support) wgslender.Pngine else void;
const Allocator = std.mem.Allocator;

/// A root's stable identity. In project-free graphs `pngine_analysis` lowers
/// this to an opaque integer so every signature still compiles.
pub const RootId = PngineAnalysis.RootId;
/// The root's validator result plus the borrowed assembly that produced it.
pub const RootAnalysis = PngineAnalysis.RootAnalysis;

/// A part identity. In project-free graphs there is no part, but the type
/// must still name something for the shared shape.
pub const OriginKey = if (pngine_support) Pngine.OriginKey else UnsupportedOriginKey;
const UnsupportedOriginKey = struct { program: u32 = 0, index: u32 = 0 };

/// One assembled range mapped back to an author part.
pub const OriginRange = if (pngine_support) Pngine.OriginRange else UnsupportedOriginRange;
const UnsupportedOriginRange = struct {
    origin: UnsupportedOriginKey = .{},
    range: UnsupportedByteRange = .{},
};

/// A half-open author-local byte range.
pub const ByteRange = if (pngine_support) Pngine.Mapping.ByteRange else UnsupportedByteRange;
const UnsupportedByteRange = struct { start: u32 = 0, end: u32 = 0 };

/// One identity context for a request in one root.
pub const RequestContext = struct {
    /// The URI the request arrived with, when it arrived through a URI.
    /// `null` for a part-addressed request (an inline `:code` part, or the
    /// future virtual-document decoder calling `contextsForPart`).
    request_uri: ?[]const u8 = null,
    /// The file URI of `origin`, when that part is file-backed. `null` for
    /// inline `:code` parts: no path may be invented.
    origin_uri: ?[]const u8 = null,
    /// Author-local byte offset of the requested position.
    author_offset: u32 = 0,
    /// The containing root; `null` for a standalone document.
    root: ?RootId = null,
    /// The root's analysis. `null` for a standalone document.
    analysis: ?*RootAnalysis = null,
    /// The requested document's part inside `root`; `null` for standalone.
    origin: ?OriginKey = null,
    /// The assembled offset the analysis must be queried at. For a
    /// standalone document this is the identity `author_offset`.
    assembled_offset: u32 = 0,

    /// True when this context reads an assembled unit.
    pub fn isComposed(self: *const RequestContext) bool {
        return self.analysis != null;
    }
};

/// Declaration identity across roots: the author part and the declaration
/// name's author-local byte range. Deliberately not a `SymbolIndex`: the
/// same source declaration has a different index in each root.
pub const SymbolKey = struct {
    origin: OriginKey,
    declaration_range: ByteRange,

    pub fn eql(a: SymbolKey, b: SymbolKey) bool {
        if (comptime pngine_support) {
            if (a.origin.program != b.origin.program) return false;
            if (a.origin.index != b.origin.index) return false;
        }
        return a.declaration_range.start == b.declaration_range.start and
            a.declaration_range.end == b.declaration_range.end;
    }
};

/// Resolve `position` in `uri` to one context per containing root.
///
/// A project member with no valid root (broken graph, missing source, a
/// position with no semantic byte) yields no context. A document with no
/// project membership yields one identity context. The returned slice is
/// owned by the caller; release it with `freeContexts`.
pub fn contextsAt(handler: *Handler, uri: []const u8, position: Handler.Position) ![]RequestContext {
    if (comptime pngine_support) {
        return contextsAtSupported(handler, uri, position);
    } else {
        // Graph families without project support still serve standalone
        // documents; the identity context keeps that path on the same shape
        // as the composed one.
        return standaloneContext(handler, uri, position);
    }
}

/// Resolve `position` in a known part without a URI. This is the entry point
/// for an inline `:code` part, which has an author origin and no file URI
/// yet. The returned contexts carry `request_uri == null`; file-backed
/// origins still expose `origin_uri == null` here because the caller did not
/// supply a spelling — use `originUri` for the part's URI.
pub fn contextsForPart(
    handler: *Handler,
    part: OriginKey,
    position: Handler.Position,
) ![]RequestContext {
    if (comptime pngine_support) {
        return contextsForPartSupported(handler, part, position);
    } else {
        return error.PngineUnsupported;
    }
}

/// Completion is a between-bytes request: the editor asks at the byte
/// position just after the text it is completing. A trailing `@` or `.` at
/// the end of a part therefore has no covered author byte, and the strict
/// `contextsAt` mapping (hover/definition) rightly refuses it. Completion
/// retries the previous author byte as the mapping anchor; callers decide
/// the trigger from the real author offset and text. Every root context is
/// still real — no offset is fabricated inside the assembly.
pub fn contextsForCompletion(
    handler: *Handler,
    uri: []const u8,
    position: Handler.Position,
) ![]RequestContext {
    const contexts = try contextsAt(handler, uri, position);
    if (contexts.len > 0) return contexts;
    if (comptime pngine_support) {
        if (position.character > 0) {
            return contextsAt(handler, uri, .{
                .line = position.line,
                .character = position.character - 1,
            });
        }
    }
    return contexts;
}

/// The part-addressed counterpart of `contextsForCompletion`: an inline
/// `:code` part has no URI, and a trailing trigger at its end anchors on
/// its last author byte.
pub fn contextsForPartCompletion(
    handler: *Handler,
    part: OriginKey,
    position: Handler.Position,
) ![]RequestContext {
    const contexts = try contextsForPart(handler, part, position);
    if (contexts.len > 0) return contexts;
    if (comptime pngine_support) {
        if (position.character > 0) {
            return contextsForPart(handler, part, .{
                .line = position.line,
                .character = position.character - 1,
            });
        }
    }
    return contexts;
}

/// Release a slice returned by `contextsAt`, `contextsForPart`,
/// `contextsForCompletion`, or `contextsForPartCompletion`.
pub fn freeContexts(handler: *Handler, contexts: []RequestContext) void {
    if (contexts.len > 0) handler.gpa.free(contexts);
}

/// The declaration identity of `symbol` in `context`'s assembled module.
///
/// The symbol's declaration name is mapped through the root's `Assembled`
/// back to author coordinates. A symbol with no module (standalone context),
/// a retired tombstone, a builtin, or a declaration whose name does not map
/// to one contiguous author range returns `null`.
pub fn declarationKey(
    context: *const RequestContext,
    symbol: wgslender.Ast.SymbolIndex,
) ?SymbolKey {
    if (comptime pngine_support) {
        const analysis = context.analysis orelse return null;
        if (!symbol.isValid()) return null;
        const module = analysis.result.module orelse return null;
        const index = symbol.index();
        if (index >= module.symbols.items.len) return null;

        const sym = module.symbols.items[index];
        if (sym.flags.is_retired or sym.flags.is_builtin) return null;

        const start: u32 = sym.loc;
        const end: u32 = start + @as(u32, @intCast(sym.original_name.len));
        const mapped = analysis.assembled.toOrigin(.{ .start = start, .end = end }) orelse return null;
        return .{ .origin = mapped.origin, .declaration_range = mapped.range };
    } else {
        return null;
    }
}

/// Text of one author part, borrowed from the Handler's open documents or
/// copied out of the Store. Release with `deinit`.
pub const AuthorText = struct {
    text: []u8,
    owned: bool,

    pub fn deinit(self: *AuthorText, gpa: Allocator) void {
        if (self.owned) gpa.free(self.text);
        self.* = undefined;
    }
};

/// The validator result a context's features must read. Composed contexts
/// borrow it from the root cache; a standalone context analyzes the open
/// document exactly as the pre-project path did.
pub fn analysisFor(
    handler: *Handler,
    context: *const RequestContext,
) anyerror!*wgslender.Validator.AnalysisResult {
    if (comptime pngine_support) {
        if (context.analysis) |root| return root.result;
    }
    const uri = context.request_uri orelse return error.NoRequestUri;
    return handler.analyzeDocument(uri);
}

/// The assembled text a composed context's analysis ran on, or `null` for a
/// standalone context. The slice is borrowed from the Store's unit.
pub fn assembledText(context: *const RequestContext) ?[]const u8 {
    if (comptime pngine_support) {
        const analysis = context.analysis orelse return null;
        return analysis.assembled.text;
    } else {
        return null;
    }
}

/// The request document's own text at `context`'s origin. A standalone
/// context borrows the open document; a composed context owns a Store copy.
pub fn authorText(handler: *Handler, context: *const RequestContext) anyerror!AuthorText {
    if (comptime pngine_support) {
        if (context.analysis != null) {
            const origin = context.origin orelse return error.NoAuthorOrigin;
            return originText(handler, origin);
        }
    }
    const uri = context.request_uri orelse return error.NoRequestUri;
    const doc = handler.documents.getPtr(uri) orelse return error.DocumentNotOpen;
    return .{ .text = doc.source, .owned = false };
}

/// The current author text of any file-backed or inline origin. The caller
/// owns the returned buffer.
pub fn originText(handler: *Handler, origin: OriginKey) anyerror!AuthorText {
    if (comptime pngine_support) {
        const store = handler.pngine_store orelse return error.PngineStoreUnbound;
        const text = try store.textForPart(origin);
        return .{ .text = text.text, .owned = true };
    } else {
        return error.PngineUnsupported;
    }
}

/// The author part and local range a composed context's assembled range maps
/// to, or `null` for a standalone context / a range no single author range
/// represents. Consumers that need any origin (references, rename) use this;
/// `toAuthorRange` additionally requires the request's own origin.
pub fn originRange(context: *const RequestContext, start: u32, end: u32) ?OriginRange {
    if (comptime pngine_support) {
        const analysis = context.analysis orelse return null;
        return analysis.assembled.toOrigin(.{ .start = start, .end = end });
    } else {
        std.mem.doNotOptimizeAway(context);
        std.mem.doNotOptimizeAway(start);
        std.mem.doNotOptimizeAway(end);
        return null;
    }
}

/// Map an assembled byte range back to `context`'s request origin.
///
/// Standalone offsets are already author offsets. A composed range is mapped
/// through the root's `Assembled`; a range that belongs to another part, or
/// that no single author range represents, returns `null` rather than an
/// assembled offset.
pub fn toAuthorRange(context: *const RequestContext, start: u32, end: u32) ?ByteRange {
    if (!context.isComposed()) return .{ .start = start, .end = end };
    if (comptime pngine_support) {
        const analysis = context.analysis orelse return null;
        const mapped = analysis.assembled.toOrigin(.{ .start = start, .end = end }) orelse return null;
        const origin = context.origin orelse return null;
        if (mapped.origin.program != origin.program or mapped.origin.index != origin.index) return null;
        return mapped.range;
    } else {
        return null;
    }
}

/// Map an author-local offset in `context`'s origin to the assembled offset
/// the root analysis must be queried at. A standalone context is already in
/// author coordinates, so the offset passes through unchanged. A composed
/// byte with no semantic copy (blanked duplicate, past EOF, synthetic
/// terminator) returns `null` rather than clamping into a neighbouring part.
pub fn assembledOffsetFor(context: *const RequestContext, author_offset: u32) ?u32 {
    if (!context.isComposed()) return author_offset;
    if (comptime pngine_support) {
        const analysis = context.analysis orelse return null;
        const origin = context.origin orelse return null;
        const assembled = analysis.assembled.offsetFromOrigin(.{
            .origin = origin,
            .offset = author_offset,
        }) orelse return null;
        if (!isAuthoredByte(analysis.assembled, origin, author_offset, assembled)) return null;
        return assembled;
    } else {
        return null;
    }
}

/// The human label of the root a context was resolved in, or `null` for a
/// standalone document. Used only when root results disagree.
pub fn contextLabel(context: *const RequestContext) ?[]const u8 {
    if (comptime pngine_support) {
        const analysis = context.analysis orelse return null;
        return analysis.assembled.root_name;
    } else {
        return null;
    }
}

/// The file URI of a file-backed origin, or `null` for an inline `:code`
/// part. The caller owns the returned string.
///
/// This is the identity spelling (`Path.pathToFileUri` of the part's
/// resolved source path), not the request's spelling. Callers that answer in
/// the requested document must keep the request URI for that origin.
pub fn originUri(
    handler: *Handler,
    allocator: Allocator,
    origin: OriginKey,
) !?[]u8 {
    if (comptime pngine_support) {
        const store = handler.pngine_store orelse return null;
        const part = store.part(origin) orelse return null;
        const file = switch (part.origin) {
            .file => |source| source,
            .inline_code => return null,
        };
        const program = store.program(origin.program) orelse return null;
        const path = try resolvePath(allocator, program.document_path, file.path);
        defer allocator.free(path);
        return pngine_path.pathToFileUri(allocator, path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
    } else {
        return null;
    }
}

// =========================================================================
// Supported (native project) implementation
// =========================================================================

fn contextsAtSupported(
    handler: *Handler,
    uri: []const u8,
    position: Handler.Position,
) ![]RequestContext {
    if (handler.pngine_store) |store| {
        var memberships = try store.membershipsFor(uri);
        defer memberships.deinit(handler.gpa);
        if (memberships.items.len > 0) {
            var contexts: std.ArrayList(RequestContext) = .empty;
            errdefer contexts.deinit(handler.gpa);

            for (memberships.items) |membership| {
                const origin: Pngine.OriginKey = .{
                    .program = membership.program,
                    .index = membership.part.index,
                };
                for (membership.containing_roots) |root_index| {
                    const root: Pngine.RootId = .{
                        .program = membership.program,
                        .index = root_index,
                    };
                    if (try contextForRoot(handler, store, root, origin, position, uri)) |context| {
                        try appendUnique(handler.gpa, &contexts, context);
                    }
                }
            }
            return contexts.toOwnedSlice(handler.gpa);
        }
    }
    return standaloneContext(handler, uri, position);
}

fn contextsForPartSupported(
    handler: *Handler,
    part: Pngine.OriginKey,
    position: Handler.Position,
) ![]RequestContext {
    const store = handler.pngine_store orelse return error.PngineStoreUnbound;
    const program = store.program(part.program) orelse return handler.gpa.alloc(RequestContext, 0);

    var contexts: std.ArrayList(RequestContext) = .empty;
    errdefer contexts.deinit(handler.gpa);

    for (program.roots) |root_index| {
        const root: Pngine.RootId = .{ .program = part.program, .index = root_index };
        if (!rootContainsPart(handler.gpa, program, root, part)) continue;
        if (try contextForRoot(handler, store, root, part, position, null)) |context| {
            try appendUnique(handler.gpa, &contexts, context);
        }
    }
    return contexts.toOwnedSlice(handler.gpa);
}

/// Build one context, or `null` when this root cannot honestly map the
/// position. Analysis failures other than OOM mean "no mapping in this
/// root": the caller keeps the other roots' contexts.
fn contextForRoot(
    handler: *Handler,
    store: *Pngine.Store,
    root: Pngine.RootId,
    origin: Pngine.OriginKey,
    position: Handler.Position,
    request_uri: ?[]const u8,
) !?RequestContext {
    const analysis = handler.analyzeRoot(root) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };

    var text = store.textForPart(origin) catch return null;
    defer text.deinit(handler.gpa);

    const author_offset_usize = Handler.lspPositionToOffset(text.text, position) orelse return null;
    if (author_offset_usize > std.math.maxInt(u32)) return null;
    const author_offset: u32 = @intCast(author_offset_usize);

    const assembled_offset = analysis.assembled.offsetFromOrigin(.{
        .origin = origin,
        .offset = author_offset,
    }) orelse return null;
    if (!isAuthoredByte(analysis.assembled, origin, author_offset, assembled_offset)) return null;

    return .{
        .request_uri = request_uri,
        .origin_uri = request_uri,
        .author_offset = author_offset,
        .root = root,
        .analysis = analysis,
        .origin = origin,
        .assembled_offset = assembled_offset,
    };
}

/// A position is requestable only when it is a real authored byte that the
/// assembled unit represents as author bytes (body or hoisted copy). A
/// synthetic terminator, a blanked duplicate, a position past the origin's
/// text, or any reverse-mapping disagreement is refused.
fn isAuthoredByte(
    assembled: *const Pngine.Assembled,
    origin: Pngine.OriginKey,
    author_offset: u32,
    assembled_offset: u32,
) bool {
    const back = assembled.offsetToOrigin(assembled_offset) orelse return false;
    if (back.origin.program != origin.program or back.origin.index != origin.index) return false;
    if (back.offset != author_offset) return false;

    for (assembled.segments) |segment| {
        if (assembled_offset < segment.assembled.start or assembled_offset >= segment.assembled.end) continue;
        if (segment.origin.program != origin.program or segment.origin.index != origin.index) return false;
        return switch (segment.kind) {
            .body, .hoisted => author_offset >= segment.source.start and author_offset < segment.source.end,
            .blanked, .terminator => false,
        };
    }
    return false;
}

fn rootContainsPart(
    gpa: Allocator,
    program: *const Pngine.Types.Program,
    root: Pngine.RootId,
    part: Pngine.OriginKey,
) bool {
    if (part.program != root.program) return false;
    if (part.index == root.index) return true;

    const order = Pngine.Assemble.collectOrderWithLimits(gpa, program, root, .{}, null) catch |err| switch (err) {
        error.OutOfMemory => return false,
        else => return false,
    };
    defer if (order.len > 0) gpa.free(order);
    for (order) |index| {
        if (index == part.index) return true;
    }
    return false;
}

/// One identity context for a document that is not a project member.
fn standaloneContext(
    handler: *Handler,
    uri: []const u8,
    position: Handler.Position,
) ![]RequestContext {
    const doc = handler.documents.getPtr(uri) orelse return handler.gpa.alloc(RequestContext, 0);
    const offset = Handler.lspPositionToOffset(doc.source, position) orelse
        return handler.gpa.alloc(RequestContext, 0);
    if (offset > std.math.maxInt(u32)) return handler.gpa.alloc(RequestContext, 0);

    const contexts = try handler.gpa.alloc(RequestContext, 1);
    contexts[0] = .{
        .request_uri = uri,
        .origin_uri = uri,
        .author_offset = @intCast(offset),
        .assembled_offset = @intCast(offset),
    };
    return contexts;
}

fn appendUnique(
    gpa: Allocator,
    contexts: *std.ArrayList(RequestContext),
    context: RequestContext,
) !void {
    for (contexts.items) |existing| {
        if (existing.root == null or context.root == null) continue;
        if (existing.root.?.program != context.root.?.program) continue;
        if (existing.root.?.index != context.root.?.index) continue;
        if (existing.origin == null or context.origin == null) continue;
        if (existing.origin.?.program != context.origin.?.program) continue;
        if (existing.origin.?.index != context.origin.?.index) continue;
        return;
    }
    try contexts.append(gpa, context);
}

fn resolvePath(allocator: Allocator, document_path: []const u8, relative: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(relative)) {
        return pngine_path.normalizeLexical(allocator, relative);
    }
    const dir = std.fs.path.dirname(document_path) orelse ".";
    const joined = try std.fs.path.join(allocator, &.{ dir, relative });
    defer allocator.free(joined);
    return pngine_path.normalizeLexical(allocator, joined);
}
