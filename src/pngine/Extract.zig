//! Strict SJON → pngine graph extraction (pngine-shaders phase 01,
//! Task 3).
//!
//! The parser is SJON's public `sjon.parse` + `Ast.Tree` readers only. The
//! walk is deliberately non-recursive: only top-level forms are inspected,
//! and only `(wgsl …)`, `(shader-module …)`, and `(pass …)` heads become
//! parts. A recovered tree with an error-severity diagnostic never becomes a
//! typed graph, and an `(import …)` head fails the whole document closed
//! rather than assembling a partial graph.
//!
//! Every input is `dupeZ`'d before `sjon.parse` (its signature takes
//! `[:0]const u8` and asserts the 256 MiB `MAX_FILE_SIZE` ceiling). The
//! extractor checks the ceiling first and returns a located
//! `document_too_large` diagnostic; it never lets the assert fire. Tests can
//! lower the ceiling through `Options` to exercise that path cheaply.

const std = @import("std");
const sjon = @import("sjon");
const types = @import("Types.zig");

const Allocator = std.mem.Allocator;

/// Public re-export so tests and later phases need one import.
pub const Types = types;

/// The largest source `sjon.parse` accepts. `Binary.MAX_FILE_SIZE` is the
/// asserted ceiling (`SJON/src/BinaryFormat.zig`).
pub const max_document_bytes: usize = sjon.Binary.MAX_FILE_SIZE;

pub const Options = struct {
    /// Per-document ceiling. Defaults to SJON's own; clamped so a larger
    /// value can never reach the parser's assert.
    max_document_bytes: usize = max_document_bytes,
};

pub fn extract(
    gpa: Allocator,
    document_path: []const u8,
    source: []const u8,
) Allocator.Error!types.Result {
    return extractWithOptions(gpa, document_path, source, .{});
}

/// Extract one document's typed graph.
///
/// Returns `.ok` with a `Program` when the document is structurally
/// extractable. Root-scoped graph errors (an unknown import, for example)
/// live in `Program.diagnostics`; form-level and parser errors return
/// `.invalid` with no `Program`, and an `(import …)` document returns
/// `.unsupported_document_import` with no partial graph.
pub fn extractWithOptions(
    gpa: Allocator,
    document_path: []const u8,
    source: []const u8,
    options: Options,
) Allocator.Error!types.Result {
    const ceiling = @min(options.max_document_bytes, max_document_bytes);
    if (source.len > ceiling) {
        return singleDiagnostic(
            gpa,
            .invalid,
            .document_too_large,
            .{ .start = 0, .end = 0 },
            "SJON document is {d} bytes; the maximum is {d}",
            .{ source.len, ceiling },
        );
    }

    // `sjon.parse` borrows the sentinel-terminated source for the tree's
    // lifetime, spans included. Own that buffer for the walk.
    const terminated = try gpa.dupeZ(u8, source);
    defer gpa.free(terminated);

    var tree = try sjon.parse(gpa, terminated);
    defer tree.deinit();

    // A recovered tree is still a tree; it is not a graph. Refuse it
    // before any typed walk, following SJON's own configuration reader.
    if (tree.hasErrors()) {
        var diagnostics: std.ArrayList(types.Diagnostic) = .empty;
        errdefer {
            for (diagnostics.items) |diagnostic| gpa.free(diagnostic.message);
            diagnostics.deinit(gpa);
        }
        for (tree.diagnostics) |diagnostic| {
            if (diagnostic.severity != .err) continue;
            const message = try gpa.dupe(u8, diagnostic.message);
            errdefer gpa.free(message);
            try diagnostics.append(gpa, .{
                .code = .sjon_syntax_error,
                .message = message,
                .span = spanOf(diagnostic.span),
            });
        }
        return .{
            .status = .invalid,
            .diagnostics = try diagnostics.toOwnedSlice(gpa),
        };
    }

    // Fail closed before building anything: an `(import …)` document needs
    // SJON's composition semantics, which this phase does not implement.
    for (tree.root) |node| {
        if (tree.tagOf(node) != .form) continue;
        const header = tree.formHeader(node);
        if (std.mem.eql(u8, header.head, "import")) {
            return singleDiagnostic(
                gpa,
                .unsupported_document_import,
                .unsupported_document_import,
                spanOf(header.head_span),
                "`(import …)` documents are unsupported; no partial pngine graph was built",
                .{},
            );
        }
    }

    var parts: std.ArrayList(types.Part) = .empty;
    errdefer {
        types.deinitParts(gpa, parts.items);
        parts.deinit(gpa);
    }
    var diagnostics: std.ArrayList(types.Diagnostic) = .empty;
    errdefer {
        for (diagnostics.items) |diagnostic| gpa.free(diagnostic.message);
        diagnostics.deinit(gpa);
    }
    var had_error = false;

    for (tree.root) |node| {
        if (tree.tagOf(node) != .form) continue;
        const header = tree.formHeader(node);
        const kind: types.PartKind = if (std.mem.eql(u8, header.head, "wgsl"))
            .wgsl
        else if (std.mem.eql(u8, header.head, "shader-module"))
            .shader_module
        else if (std.mem.eql(u8, header.head, "pass"))
            .pass
        else
            continue;

        const part_index: u32 = @intCast(parts.items.len);
        const maybe_part = try parsePart(
            gpa,
            &tree,
            node,
            header,
            kind,
            part_index,
            &diagnostics,
            &had_error,
        );
        if (maybe_part) |part| {
            errdefer types.deinitPart(gpa, part);
            try parts.append(gpa, part);
        }
    }

    if (had_error) {
        const owned_diagnostics = try diagnostics.toOwnedSlice(gpa);
        types.deinitParts(gpa, parts.items);
        parts.deinit(gpa);
        return .{ .status = .invalid, .diagnostics = owned_diagnostics };
    }

    const owned_parts: []types.Part = if (parts.items.len == 0)
        &.{}
    else
        try parts.toOwnedSlice(gpa);
    errdefer {
        types.deinitParts(gpa, owned_parts);
        if (owned_parts.len > 0) gpa.free(owned_parts);
    }

    // Names are unique across every part kind in a valid program. A
    // duplicate is a program error at the second occurrence; no table is
    // built, so there is no last-wins answer to return.
    var seen: std.StringHashMapUnmanaged(u32) = .{};
    defer seen.deinit(gpa);
    for (owned_parts, 0..) |part, index| {
        const entry = try seen.getOrPut(gpa, part.name);
        if (entry.found_existing) {
            try addDiagnostic(
                gpa,
                &diagnostics,
                .duplicate_part_name,
                part.name_span,
                @intCast(index),
                "duplicate part name '{s}'",
                .{part.name},
            );
            had_error = true;
        } else {
            entry.value_ptr.* = @intCast(index);
        }
    }

    if (had_error) {
        const owned_diagnostics = try diagnostics.toOwnedSlice(gpa);
        types.deinitParts(gpa, owned_parts);
        if (owned_parts.len > 0) gpa.free(owned_parts);
        return .{ .status = .invalid, .diagnostics = owned_diagnostics };
    }

    var root_indices: std.ArrayList(u32) = .empty;
    errdefer root_indices.deinit(gpa);
    for (owned_parts, 0..) |part, index| {
        if (part.kind == .wgsl) continue;
        try root_indices.append(gpa, @intCast(index));
    }
    const roots: []u32 = if (root_indices.items.len == 0)
        &.{}
    else
        try root_indices.toOwnedSlice(gpa);
    errdefer if (roots.len > 0) gpa.free(roots);

    // Root-scoped graph errors stay on the program: D23's unknown import
    // must not make every other root unusable.
    var program_diagnostics: std.ArrayList(types.Diagnostic) = .empty;
    errdefer {
        for (program_diagnostics.items) |diagnostic| gpa.free(diagnostic.message);
        program_diagnostics.deinit(gpa);
    }
    for (owned_parts, 0..) |part, index| {
        for (part.imports) |import_ref| {
            if (findFragment(owned_parts, import_ref.name) != null) continue;
            try addDiagnostic(
                gpa,
                &program_diagnostics,
                .unknown_import,
                import_ref.span,
                @intCast(index),
                "`:imports` entry '{s}' names no `(wgsl …)` fragment in this program",
                .{import_ref.name},
            );
        }
    }
    const owned_program_diagnostics: []types.Diagnostic = if (program_diagnostics.items.len == 0)
        &.{}
    else
        try program_diagnostics.toOwnedSlice(gpa);
    errdefer types.deinitDiagnostics(gpa, owned_program_diagnostics);

    const owned_document_path = try gpa.dupe(u8, document_path);

    return .{
        .status = .ok,
        .program = .{
            .document_path = owned_document_path,
            .parts = owned_parts,
            .roots = roots,
            .diagnostics = owned_program_diagnostics,
        },
    };
}

const Field = struct {
    value: sjon.Ast.NodeIndex,
    key_span: types.Span,
};

const NameList = struct {
    items: []types.NameRef = &.{},
    invalid: bool = false,
};

fn parsePart(
    gpa: Allocator,
    tree: *const sjon.Ast.Tree,
    node: sjon.Ast.NodeIndex,
    header: sjon.Ast.FormHeader,
    kind: types.PartKind,
    part_index: u32,
    diagnostics: *std.ArrayList(types.Diagnostic),
    had_error: *bool,
) Allocator.Error!?types.Part {
    const head = header.head;

    var name_field: ?Field = null;
    var code_field: ?Field = null;
    var file_field: ?Field = null;
    var imports_field: ?Field = null;
    var requires_field: ?Field = null;

    var part_invalid = false;
    var name: ?[]const u8 = null;
    var name_span = spanOf(header.head_span);
    var origin: ?types.PartOrigin = null;
    var imports: []types.ImportRef = &.{};
    var imports_span: ?types.Span = null;
    var requires: []types.Requirement = &.{};
    var requires_span: ?types.Span = null;

    var keep = false;
    defer if (!keep) {
        if (name) |value| gpa.free(value);
        if (origin) |value| deinitOrigin(gpa, value);
        types.deinitNameRefs(gpa, imports);
        types.deinitNameRefs(gpa, requires);
    };

    for (header.children) |child| {
        switch (tree.tagOf(child)) {
            .kvpair => {
                const pair = tree.kvpairHeader(child);
                const key = pair.key;

                // A pass's `:file` is a data-file list for WASM data
                // segments, not WGSL. Ignore it completely, including a
                // malformed value: extraction never reads it as source.
                if (kind == .pass and std.mem.eql(u8, key, "file")) continue;

                const slot: ?*?Field = if (std.mem.eql(u8, key, "name"))
                    &name_field
                else if (std.mem.eql(u8, key, "code"))
                    &code_field
                else if (std.mem.eql(u8, key, "file"))
                    &file_field
                else if (std.mem.eql(u8, key, "imports"))
                    &imports_field
                else if (std.mem.eql(u8, key, "requires"))
                    &requires_field
                else
                    null;
                const destination = slot orelse continue;

                if (destination.* != null) {
                    try addDiagnostic(
                        gpa,
                        diagnostics,
                        .duplicate_key,
                        spanOf(pair.key_span),
                        part_index,
                        "`:{s}` appears more than once on `({s} …)`",
                        .{ key, head },
                    );
                    part_invalid = true;
                    continue;
                }
                destination.* = .{
                    .value = pair.value,
                    .key_span = spanOf(pair.key_span),
                };
            },
            .keyword => {
                const key = tree.keywordText(child);
                if (kind == .pass and std.mem.eql(u8, key, "file")) continue;
                if (!isKnownKey(key)) continue;
                try addDiagnostic(
                    gpa,
                    diagnostics,
                    .malformed_form,
                    spanOf(tree.spanOf(child)),
                    part_index,
                    "`:{s}` has no value on `({s} …)`",
                    .{ key, head },
                );
                part_invalid = true;
            },
            // Positional children (a pass's `(constant …)`, or any other
            // nested data) are not part of this walk.
            else => {},
        }
    }

    if (name_field) |field| {
        name_span = spanOf(tree.spanOf(field.value));
        if (tree.tagOf(field.value) != .symbol) {
            try addDiagnostic(
                gpa,
                diagnostics,
                .invalid_name,
                name_span,
                part_index,
                "`({s} …)` has a non-symbol `:name`",
                .{head},
            );
            part_invalid = true;
        } else {
            const text = tree.symbolText(field.value);
            if (text.len == 0) {
                try addDiagnostic(
                    gpa,
                    diagnostics,
                    .invalid_name,
                    name_span,
                    part_index,
                    "`({s} …)` has an empty `:name`",
                    .{head},
                );
                part_invalid = true;
            } else {
                name = try gpa.dupe(u8, text);
            }
        }
    } else {
        try addDiagnostic(
            gpa,
            diagnostics,
            .missing_name,
            spanOf(header.head_span),
            part_index,
            "`({s} …)` is missing its required `:name`",
            .{head},
        );
        part_invalid = true;
    }

    switch (kind) {
        .wgsl, .shader_module => {
            if (code_field != null and file_field != null) {
                try addDiagnostic(
                    gpa,
                    diagnostics,
                    .both_code_and_file,
                    spanOf(tree.spanOf(file_field.?.value)),
                    part_index,
                    "`({s} …)` has both `:code` and `:file`; exactly one is required",
                    .{head},
                );
                part_invalid = true;
            } else if (code_field == null and file_field == null) {
                try addDiagnostic(
                    gpa,
                    diagnostics,
                    .missing_source,
                    spanOf(header.head_span),
                    part_index,
                    "`({s} …)` has neither `:code` nor `:file`; exactly one is required",
                    .{head},
                );
                part_invalid = true;
            } else if (code_field) |field| {
                if (tree.tagOf(field.value) != .string) {
                    try addDiagnostic(
                        gpa,
                        diagnostics,
                        .invalid_source,
                        spanOf(tree.spanOf(field.value)),
                        part_index,
                        "`({s} … :code …)` must be a string",
                        .{head},
                    );
                    part_invalid = true;
                } else {
                    origin = .{ .inline_code = .{
                        .code = try gpa.dupe(u8, tree.stringText(field.value)),
                        .span = spanOf(tree.spanOf(field.value)),
                    } };
                }
            } else if (file_field) |field| {
                if (tree.tagOf(field.value) != .string) {
                    try addDiagnostic(
                        gpa,
                        diagnostics,
                        .invalid_source,
                        spanOf(tree.spanOf(field.value)),
                        part_index,
                        "`({s} … :file …)` must be a string path",
                        .{head},
                    );
                    part_invalid = true;
                } else {
                    const path = tree.stringText(field.value);
                    if (path.len == 0) {
                        try addDiagnostic(
                            gpa,
                            diagnostics,
                            .invalid_source,
                            spanOf(tree.spanOf(field.value)),
                            part_index,
                            "`({s} … :file …)` has an empty path",
                            .{head},
                        );
                        part_invalid = true;
                    } else {
                        origin = .{ .file = .{
                            .path = try gpa.dupe(u8, path),
                            .span = spanOf(tree.spanOf(field.value)),
                        } };
                    }
                }
            }
        },
        .pass => {
            if (code_field) |field| {
                if (tree.tagOf(field.value) != .string) {
                    try addDiagnostic(
                        gpa,
                        diagnostics,
                        .invalid_source,
                        spanOf(tree.spanOf(field.value)),
                        part_index,
                        "`(pass … :code …)` must be a string",
                        .{},
                    );
                    part_invalid = true;
                } else {
                    origin = .{ .inline_code = .{
                        .code = try gpa.dupe(u8, tree.stringText(field.value)),
                        .span = spanOf(tree.spanOf(field.value)),
                    } };
                }
            } else {
                try addDiagnostic(
                    gpa,
                    diagnostics,
                    .missing_pass_code,
                    spanOf(header.head_span),
                    part_index,
                    "`(pass …)` is missing its required `:code`; `:file` is a data-file list, not WGSL",
                    .{},
                );
                part_invalid = true;
            }
        },
    }

    if (imports_field) |field| {
        imports_span = field.key_span;
        const parsed = try parseNameList(
            gpa,
            tree,
            field,
            .invalid_imports,
            .non_symbol_import,
            "imports",
            part_index,
            diagnostics,
        );
        imports = parsed.items;
        if (parsed.invalid) part_invalid = true;
    }

    if (requires_field) |field| {
        requires_span = field.key_span;
        const parsed = try parseNameList(
            gpa,
            tree,
            field,
            .invalid_requires,
            .non_symbol_requires,
            "requires",
            part_index,
            diagnostics,
        );
        requires = parsed.items;
        if (parsed.invalid) part_invalid = true;
    }

    if (name == null or origin == null) part_invalid = true;
    if (part_invalid) {
        had_error.* = true;
        return null;
    }

    keep = true;
    return .{
        .kind = kind,
        .name = name.?,
        .name_span = name_span,
        .form_span = spanOf(tree.spanOf(node)),
        .origin = origin.?,
        .imports = imports,
        .imports_span = imports_span,
        .requires = requires,
        .requires_span = requires_span,
    };
}

fn parseNameList(
    gpa: Allocator,
    tree: *const sjon.Ast.Tree,
    field: Field,
    invalid_code: types.DiagnosticCode,
    non_symbol_code: types.DiagnosticCode,
    comptime label: []const u8,
    part_index: u32,
    diagnostics: *std.ArrayList(types.Diagnostic),
) Allocator.Error!NameList {
    if (tree.tagOf(field.value) != .vector) {
        try addDiagnostic(
            gpa,
            diagnostics,
            invalid_code,
            spanOf(tree.spanOf(field.value)),
            part_index,
            "`:{s}` must be a vector of symbols",
            .{label},
        );
        return .{ .invalid = true };
    }

    const elements = tree.vectorElements(field.value);
    if (elements.len == 0) return .{};

    var list: std.ArrayList(types.NameRef) = .empty;
    defer list.deinit(gpa);
    errdefer for (list.items) |item| gpa.free(item.name);

    var invalid = false;
    for (elements) |element| {
        if (tree.tagOf(element) != .symbol) {
            try addDiagnostic(
                gpa,
                diagnostics,
                non_symbol_code,
                spanOf(tree.spanOf(element)),
                part_index,
                "`:{s}` entry must be a symbol",
                .{label},
            );
            invalid = true;
            continue;
        }
        const name = try gpa.dupe(u8, tree.symbolText(element));
        errdefer gpa.free(name);
        try list.append(gpa, .{
            .name = name,
            .span = spanOf(tree.spanOf(element)),
        });
    }

    if (invalid) {
        for (list.items) |item| gpa.free(item.name);
        return .{ .invalid = true };
    }

    return .{ .items = try list.toOwnedSlice(gpa) };
}

fn isKnownKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "name") or
        std.mem.eql(u8, key, "code") or
        std.mem.eql(u8, key, "file") or
        std.mem.eql(u8, key, "imports") or
        std.mem.eql(u8, key, "requires");
}

fn findFragment(parts: []const types.Part, name: []const u8) ?u32 {
    for (parts, 0..) |part, index| {
        if (part.kind != .wgsl) continue;
        if (std.mem.eql(u8, part.name, name)) return @intCast(index);
    }
    return null;
}

fn addDiagnostic(
    gpa: Allocator,
    list: *std.ArrayList(types.Diagnostic),
    code: types.DiagnosticCode,
    span: types.Span,
    part_index: ?u32,
    comptime format: []const u8,
    args: anytype,
) Allocator.Error!void {
    const message = try std.fmt.allocPrint(gpa, format, args);
    errdefer gpa.free(message);
    try list.append(gpa, .{
        .code = code,
        .message = message,
        .span = span,
        .part_index = part_index,
    });
}

fn singleDiagnostic(
    gpa: Allocator,
    status: types.Status,
    code: types.DiagnosticCode,
    span: types.Span,
    comptime format: []const u8,
    args: anytype,
) Allocator.Error!types.Result {
    const diagnostics = try gpa.alloc(types.Diagnostic, 1);
    errdefer gpa.free(diagnostics);
    const message = try std.fmt.allocPrint(gpa, format, args);
    diagnostics[0] = .{
        .code = code,
        .message = message,
        .span = span,
    };
    return .{ .status = status, .diagnostics = diagnostics };
}

fn deinitOrigin(gpa: Allocator, origin: types.PartOrigin) void {
    switch (origin) {
        .file => |source| gpa.free(source.path),
        .inline_code => |source| gpa.free(source.code),
    }
}

fn spanOf(span: sjon.Ast.Span) types.Span {
    return .{ .start = span.start, .end = span.end };
}
