//! pngine project graph vocabulary (pngine-shaders phase 01).
//!
//! Task 3 owns the extraction half: one `Program` per parsed `.sjon`
//! document, its `Part`s in source order, root indices into that part list,
//! and the diagnostics that make a document invalid or a root unusable.
//! The store/discovery tasks extend this file with memberships and source
//! overlays; the ownership helpers below stay here so every task frees a
//! graph the same way.
//!
//! All strings are owned by the `Program` (or by the `Result` while an
//! invalid document has no program). Spans are byte offsets into the
//! document text that produced them; keeping them lets later phases point
//! related information at the exact form, name, file, code, import, or
//! requires element without re-parsing.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// A byte range in the SJON document. `end` is exclusive.
pub const Span = struct {
    start: u32,
    end: u32,
};

/// The three pngine forms that carry WGSL author text.
pub const PartKind = enum {
    /// A named fragment, assembled into the modules that import it.
    wgsl,
    /// A named module root.
    shader_module,
    /// A pass root; its `:code` is WGSL and its `:file` is a data-file list.
    pass,
};

/// A part whose text is a path relative to the document.
pub const FileSource = struct {
    /// The `:file` string exactly as written; resolution belongs to
    /// discovery/store, not extraction.
    path: []const u8,
    /// The `:file` value span.
    span: Span,
};

/// A part whose text is inline in the document.
pub const InlineSource = struct {
    /// The `:code` string exactly as decoded by SJON.
    code: []const u8,
    /// The `:code` value span.
    span: Span,
};

/// Where a part's WGSL text comes from. Exactly one arm is present.
pub const PartOrigin = union(enum) {
    file: FileSource,
    inline_code: InlineSource,
};

/// A name and the SJON span it came from.
///
/// `:imports` entries and `:requires` entries share this shape. A
/// `:requires` name is a WGSL identifier (a hole), not a cross-reference to
/// another pngine form; the two lists are deliberately separate fields on
/// `Part` even though their records are identical.
pub const NameRef = struct {
    name: []const u8,
    span: Span,
};

/// One `:imports` element, in written order.
pub const ImportRef = NameRef;

/// One `:requires` element, in written order.
pub const Requirement = NameRef;

/// One `(wgsl …)`, `(shader-module …)`, or `(pass …)` form.
pub const Part = struct {
    kind: PartKind,
    /// Unique within a valid program; imports resolve against the program's
    /// own fragment table, never a workspace-global name.
    name: []const u8,
    name_span: Span,
    form_span: Span,
    origin: PartOrigin,
    imports: []ImportRef = &.{},
    /// The span of the `:imports` key, when written.
    imports_span: ?Span = null,
    requires: []Requirement = &.{},
    /// The span of the `:requires` key, when written.
    requires_span: ?Span = null,

    pub fn isRoot(self: Part) bool {
        return self.kind != .wgsl;
    }

    pub fn inlineCode(self: Part) ?[]const u8 {
        return switch (self.origin) {
            .inline_code => |source| source.code,
            .file => null,
        };
    }
};

/// Why a document or form could not become a graph.
pub const DiagnosticCode = enum {
    /// Longer than the `sjon.parse` ceiling; refused before the assert.
    document_too_large,
    /// SJON returned a recovered tree with an error-severity diagnostic.
    sjon_syntax_error,
    /// The document uses `(import …)` composition; fail closed.
    unsupported_document_import,
    /// A known form key with no value, or an otherwise broken form.
    malformed_form,
    /// A `(wgsl …)`/`(shader-module …)`/`(pass …)` without `:name`.
    missing_name,
    /// `:name` exists but is not a symbol.
    invalid_name,
    /// Two parts in one program share a name; never last-wins.
    duplicate_part_name,
    /// A known key appears more than once on one form.
    duplicate_key,
    /// A fragment or shader module has neither `:code` nor `:file`.
    missing_source,
    /// A fragment or shader module has both source keys.
    both_code_and_file,
    /// A source key is not a string, or a `:file` path is empty.
    invalid_source,
    /// A pass has no `:code`; its `:file` is a data-file list, not WGSL.
    missing_pass_code,
    /// `:imports` is not a vector.
    invalid_imports,
    /// An `:imports` element is not a symbol.
    non_symbol_import,
    /// `:requires` is not a vector.
    invalid_requires,
    /// A `:requires` element is not a symbol.
    non_symbol_requires,
    /// An import names no fragment in this program; the root keeps the
    /// error while the rest of the program stays usable.
    unknown_import,
};

/// A located graph error. `message` is owned by the enclosing `Program` or
/// `Result`. `part_index` is the source-order occurrence of the form that
/// carries the error, when the error is root/form-scoped.
pub const Diagnostic = struct {
    code: DiagnosticCode,
    message: []const u8,
    span: Span,
    part_index: ?u32 = null,
};

/// One valid (or root-error-carrying) document graph.
pub const Program = struct {
    /// Canonical document path; identity, not response spelling.
    document_path: []const u8,
    /// Every pngine part in source order.
    parts: []Part,
    /// Source-order part indices for `shader-module` and `pass` roots.
    roots: []u32,
    /// Program-level graph errors such as unknown imports. A document with a
    /// form-level/syntax error returns no `Program` at all.
    diagnostics: []Diagnostic,

    pub fn deinit(self: *Program, gpa: Allocator) void {
        gpa.free(self.document_path);
        deinitParts(gpa, self.parts);
        if (self.parts.len > 0) gpa.free(self.parts);
        if (self.roots.len > 0) gpa.free(self.roots);
        deinitDiagnostics(gpa, self.diagnostics);
        self.* = undefined;
    }

    /// Program-scoped fragment lookup. Returns the part index of the first
    /// (and, in a valid program, only) `wgsl` part with `name`.
    pub fn findFragment(self: *const Program, name: []const u8) ?u32 {
        for (self.parts, 0..) |part, index| {
            if (part.kind != .wgsl) continue;
            if (std.mem.eql(u8, part.name, name)) return @intCast(index);
        }
        return null;
    }
};

/// Document-level extraction outcome.
pub const Status = enum {
    /// A typed graph was built. `Result.program` is present; any
    /// `Program.diagnostics` are root-scoped graph errors.
    ok,
    /// Nothing was built. `Result.diagnostics` explains why.
    invalid,
    /// The document uses `(import …)`; no partial graph was built.
    unsupported_document_import,
};

/// Owned extraction result. Call `deinit` exactly once.
pub const Result = struct {
    status: Status,
    program: ?Program = null,
    diagnostics: []Diagnostic = &.{},

    pub fn deinit(self: *Result, gpa: Allocator) void {
        if (self.program) |*program| program.deinit(gpa);
        deinitDiagnostics(gpa, self.diagnostics);
        self.* = undefined;
    }

    pub fn hasDiagnostic(self: *const Result, code: DiagnosticCode) bool {
        for (self.diagnostics) |diagnostic| {
            if (diagnostic.code == code) return true;
        }
        return false;
    }
};

/// Free one part's owned names, path, code, and list slices.
pub fn deinitPart(gpa: Allocator, part: Part) void {
    gpa.free(part.name);
    switch (part.origin) {
        .file => |source| gpa.free(source.path),
        .inline_code => |source| gpa.free(source.code),
    }
    deinitNameRefs(gpa, part.imports);
    deinitNameRefs(gpa, part.requires);
}

/// Free every part in `parts` (the slice itself is not freed).
pub fn deinitParts(gpa: Allocator, parts: []Part) void {
    for (parts) |part| deinitPart(gpa, part);
}

/// Free a list of name/span records (the slice itself too).
pub fn deinitNameRefs(gpa: Allocator, refs: []NameRef) void {
    for (refs) |ref| gpa.free(ref.name);
    if (refs.len > 0) gpa.free(refs);
}

/// Free diagnostic messages and the owning slice.
pub fn deinitDiagnostics(gpa: Allocator, diagnostics: []Diagnostic) void {
    for (diagnostics) |diagnostic| gpa.free(diagnostic.message);
    if (diagnostics.len > 0) gpa.free(diagnostics);
}
