//! Diagnostic reporting for WGSL validation.
//!
//! Compatible with WebGPU Dawn Tint compiler error reporting: accurate source
//! locations, severity levels, and WGSL spec references. Provides a LineIndex
//! for efficient byte-offset to line/column conversion.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @This();

// =========================================================================
// Severity
// =========================================================================

/// Severity level of a diagnostic.
pub const Severity = enum(u8) {
    /// Error prevents shader compilation.
    @"error",
    /// Warning is a non-blocking issue.
    warning,
    /// Informational message.
    info,
    /// Additional context for another diagnostic.
    note,

    /// Sentinel used by DiagnosticFilter to mark a rule as disabled.
    disabled = 255,

    pub fn string(self: Severity) []const u8 {
        return switch (self) {
            .@"error" => "error",
            .warning => "warning",
            .info => "info",
            .note => "note",
            .disabled => "unknown",
        };
    }
};

// =========================================================================
// Position / Range
// =========================================================================

/// A position in source code.
pub const Position = struct {
    /// Byte offset (0-based).
    offset: u32 = 0,
    /// Line number (1-based).
    line: u32 = 0,
    /// Column number (1-based).
    column: u32 = 0,
};

/// A range in source code.
pub const Range = struct {
    start: Position = .{},
    end: Position = .{},
};

/// Additional location information for a diagnostic.
pub const RelatedInfo = struct {
    range: Range = .{},
    message: []const u8 = "",
};

/// A source-text rewrite attached to a diagnostic. Applied by the linter's
/// fixer and surfaced as an LSP CodeAction by the language server. The byte
/// offsets on `range.start.offset` / `range.end.offset` drive splicing; the
/// line/column positions drive LSP rendering.
pub const Fix = struct {
    range: Range = .{},
    text: []const u8 = "",
};

// =========================================================================
// Entry
// =========================================================================

/// A single diagnostic message.
pub const Entry = struct {
    severity: Severity = .@"error",
    /// Error code (e.g. "E0001", "type-mismatch").
    code: []const u8 = "",
    /// Human-readable message.
    message: []const u8 = "",
    /// Source location.
    range: Range = .{},
    /// Related locations.
    related: []const RelatedInfo = &.{},
    /// WGSL spec section reference (e.g. "6.4").
    spec_ref: []const u8 = "",
    /// Origin of the diagnostic ("" for validator, "wgslender-lint" for
    /// linter rules). Editors can style/filter on this; JSON consumers use
    /// it to separate spec-errors from advisory lint.
    source: []const u8 = "",
    /// Optional autofix. When set, the linter's Fixer can rewrite source and
    /// the LSP can publish a quickfix code action. Stored by pointer so
    /// `Entry` stays compact — fixes live on the same arena as the
    /// diagnostic list, so the pointer lifetime tracks the list.
    fix: ?*const Fix = null,

    /// Format as "line:col: severity: message".
    pub fn format(self: *const Entry, writer: anytype) !void {
        try writer.print("{d}:{d}: {s}: {s}", .{
            self.range.start.line,
            self.range.start.column,
            self.severity.string(),
            self.message,
        });
    }
};

// =========================================================================
// JSON Serialization
// =========================================================================

/// Serialize a single diagnostic entry as a JSON object (no surrounding braces array).
pub fn entryToJson(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, entry: *const Entry) Allocator.Error!void {
    try buf.appendSlice(allocator, "{\"severity\":\"");
    try buf.appendSlice(allocator, entry.severity.string());
    try buf.appendSlice(allocator, "\",\"message\":\"");
    try appendJsonEscaped(buf, allocator, entry.message);
    try buf.append(allocator, '"');

    if (entry.code.len > 0) {
        try buf.appendSlice(allocator, ",\"code\":\"");
        try appendJsonEscaped(buf, allocator, entry.code);
        try buf.append(allocator, '"');
    }

    try buf.appendSlice(allocator, ",\"line\":");
    try appendInt(buf, allocator, entry.range.start.line);
    try buf.appendSlice(allocator, ",\"column\":");
    try appendInt(buf, allocator, entry.range.start.column);

    if (entry.spec_ref.len > 0) {
        try buf.appendSlice(allocator, ",\"specRef\":\"");
        try appendJsonEscaped(buf, allocator, entry.spec_ref);
        try buf.append(allocator, '"');
    }

    if (entry.related.len > 0) {
        try buf.appendSlice(allocator, ",\"related\":[");
        for (entry.related, 0..) |rel, ri| {
            if (ri > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"line\":");
            try appendInt(buf, allocator, rel.range.start.line);
            try buf.appendSlice(allocator, ",\"column\":");
            try appendInt(buf, allocator, rel.range.start.column);
            try buf.appendSlice(allocator, ",\"message\":\"");
            try appendJsonEscaped(buf, allocator, rel.message);
            try buf.appendSlice(allocator, "\"}");
        }
        try buf.append(allocator, ']');
    }

    if (entry.source.len > 0) {
        try buf.appendSlice(allocator, ",\"source\":\"");
        try appendJsonEscaped(buf, allocator, entry.source);
        try buf.append(allocator, '"');
    }

    if (entry.fix) |f| {
        try buf.appendSlice(allocator, ",\"fix\":{\"range\":{\"startLine\":");
        try appendInt(buf, allocator, f.range.start.line);
        try buf.appendSlice(allocator, ",\"startColumn\":");
        try appendInt(buf, allocator, f.range.start.column);
        try buf.appendSlice(allocator, ",\"startOffset\":");
        try appendInt(buf, allocator, f.range.start.offset);
        try buf.appendSlice(allocator, ",\"endLine\":");
        try appendInt(buf, allocator, f.range.end.line);
        try buf.appendSlice(allocator, ",\"endColumn\":");
        try appendInt(buf, allocator, f.range.end.column);
        try buf.appendSlice(allocator, ",\"endOffset\":");
        try appendInt(buf, allocator, f.range.end.offset);
        try buf.appendSlice(allocator, "},\"text\":\"");
        try appendJsonEscaped(buf, allocator, f.text);
        try buf.appendSlice(allocator, "\"}");
    }

    try buf.append(allocator, '}');
}

pub fn appendJsonEscaped(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, s: []const u8) Allocator.Error!void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
}

pub fn appendInt(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, value: anytype) Allocator.Error!void {
    var tmp: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch return;
    try buf.appendSlice(allocator, s);
}

// =========================================================================
// LineIndex
// =========================================================================

/// Pre-computed line-start offsets for O(log n) byte-offset to line/column.
pub const LineIndex = struct {
    line_starts: std.ArrayListUnmanaged(u32),

    /// Build a line index by scanning `source` for newlines.
    pub fn init(allocator: Allocator, source: []const u8) Allocator.Error!LineIndex {
        var starts: std.ArrayListUnmanaged(u32) = .empty;
        try starts.append(allocator, 0);

        var i: usize = 0;
        while (i < source.len) : (i += 1) {
            const c = source[i];
            if (c == '\n') {
                const next: u32 = @intCast(i + 1);
                if (next < source.len) {
                    try starts.append(allocator, next);
                }
            } else if (c == '\r') {
                // CR+LF pair
                if (i + 1 < source.len and source[i + 1] == '\n') {
                    const next: u32 = @intCast(i + 2);
                    if (next < source.len) {
                        try starts.append(allocator, next);
                    }
                    i += 1; // skip LF
                } else {
                    const next: u32 = @intCast(i + 1);
                    if (next < source.len) {
                        try starts.append(allocator, next);
                    }
                }
            }
        }

        return .{ .line_starts = starts };
    }

    pub fn deinit(self: *LineIndex, allocator: Allocator) void {
        self.line_starts.deinit(allocator);
    }

    /// Number of lines in the source.
    pub fn lineCount(self: *const LineIndex) u32 {
        return @intCast(self.line_starts.items.len);
    }

    /// Convert byte offset to 0-based (line, col).
    pub fn byteOffsetToLineColumn(self: *const LineIndex, offset: u32) struct { line: u32, col: u32 } {
        const starts = self.line_starts.items;
        if (starts.len == 0) return .{ .line = 0, .col = 0 };

        // Binary search: find last start <= offset.
        var lo: usize = 0;
        var hi: usize = starts.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (starts[mid] > offset) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        // lo is first index where starts[lo] > offset, so line = lo - 1.
        const line: u32 = if (lo > 0) @intCast(lo - 1) else 0;
        const col: u32 = offset - starts[line];
        return .{ .line = line, .col = col };
    }
};

// =========================================================================
// DiagnosticList
// =========================================================================

/// Collects diagnostics during compilation.
diagnostics: std.ArrayListUnmanaged(Entry),
line_index: LineIndex,
source: []const u8,
has_errors: bool,
/// Added to all reported line numbers. Useful when validating a snippet
/// extracted from a larger file so that error positions match the
/// original file's line numbers. May be negative.
line_offset: i32 = 0,

/// Create a new diagnostic list for the given source. Pre-allocates a
/// modest capacity for the diagnostic array so small-error-count
/// validator scenarios (e.g. `"fn { invalid }"` → 4 parse errors) don't
/// need to grow the list during the error-reporting hot path —
/// `Diagnostic.add` deliberately swallows OOM on append (best-effort
/// contract), which the exhaustive OOM tests flag as a swallowed
/// allocation every time a realloc fails. Eight slots covers typical
/// parse errors on invalid fragments without meaningfully bloating the
/// common, clean-shader case.
pub fn init(allocator: Allocator, source: []const u8) Allocator.Error!Diagnostic {
    var line_index = try LineIndex.init(allocator, source);
    errdefer line_index.deinit(allocator);

    var diags: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer diags.deinit(allocator);
    try diags.ensureTotalCapacity(allocator, 8);

    return .{
        .diagnostics = diags,
        .line_index = line_index,
        .source = source,
        .has_errors = false,
    };
}

pub fn deinit(self: *Diagnostic, allocator: Allocator) void {
    self.diagnostics.deinit(allocator);
    self.line_index.deinit(allocator);
}

// -------------------------------------------------------------------------
// Adding diagnostics
// -------------------------------------------------------------------------

/// Add a diagnostic entry.
pub fn add(self: *Diagnostic, allocator: Allocator, entry: Entry) void {
    var e = entry;
    if (e.spec_ref.len == 0 and e.code.len > 0) {
        e.spec_ref = specRefFor(e.code);
    }
    // Diagnostics are best-effort: silently drop if OOM rather than
    // propagating allocation failure through every parse/validate call site.
    self.diagnostics.append(allocator, e) catch {};
    if (e.severity == .@"error") {
        self.has_errors = true;
    }
}

/// Add an error at a single byte offset.
pub fn addError(self: *Diagnostic, allocator: Allocator, offset: u32, message: []const u8) void {
    self.addErrorRange(allocator, offset, offset + 1, message);
}

/// Add an error spanning a byte range.
pub fn addErrorRange(self: *Diagnostic, allocator: Allocator, start: u32, end: u32, message: []const u8) void {
    self.add(allocator, .{
        .severity = .@"error",
        .message = message,
        .range = self.makeRange(start, end),
    });
}

/// Add an error with an error code.
pub fn addErrorWithCode(self: *Diagnostic, allocator: Allocator, offset: u32, code: []const u8, message: []const u8) void {
    self.add(allocator, .{
        .severity = .@"error",
        .code = code,
        .message = message,
        .range = self.makeRange(offset, offset + 1),
    });
}

/// Add an error with an error code spanning a byte range.
pub fn addErrorWithCodeRange(self: *Diagnostic, allocator: Allocator, start: u32, end: u32, code: []const u8, message: []const u8) void {
    self.add(allocator, .{
        .severity = .@"error",
        .code = code,
        .message = message,
        .range = self.makeRange(start, end),
    });
}

/// Add a warning at a single byte offset.
pub fn addWarning(self: *Diagnostic, allocator: Allocator, offset: u32, message: []const u8) void {
    self.add(allocator, .{
        .severity = .warning,
        .message = message,
        .range = self.makeRange(offset, offset + 1),
    });
}

/// Add a warning spanning a byte range.
pub fn addWarningRange(self: *Diagnostic, allocator: Allocator, start: u32, end: u32, message: []const u8) void {
    self.add(allocator, .{
        .severity = .warning,
        .message = message,
        .range = self.makeRange(start, end),
    });
}

/// Add a note at a single byte offset.
pub fn addNote(self: *Diagnostic, allocator: Allocator, offset: u32, message: []const u8) void {
    self.add(allocator, .{
        .severity = .note,
        .message = message,
        .range = self.makeRange(offset, offset + 1),
    });
}

// -------------------------------------------------------------------------
// Position helpers
// -------------------------------------------------------------------------

/// Convert a byte offset to a 1-based Position.
/// The `line_offset` field is added to the line number.
pub fn makePosition(self: *const Diagnostic, offset: u32) Position {
    const lc = self.line_index.byteOffsetToLineColumn(offset);
    const base_line: i64 = @as(i64, lc.line) + 1 + self.line_offset;
    return .{
        .offset = offset,
        .line = if (base_line >= 1) @intCast(base_line) else 1,
        .column = lc.col + 1,
    };
}

/// Convert a byte range to a Range (1-based line/col).
pub fn makeRange(self: *const Diagnostic, start: u32, end: u32) Range {
    return .{
        .start = self.makePosition(start),
        .end = self.makePosition(end),
    };
}

// -------------------------------------------------------------------------
// Queries
// -------------------------------------------------------------------------

/// True if any error-level diagnostic was added.
pub fn hasErrors(self: *const Diagnostic) bool {
    return self.has_errors;
}

/// All collected diagnostics.
pub fn items(self: *const Diagnostic) []const Entry {
    return self.diagnostics.items;
}

/// Total number of diagnostics.
pub fn count(self: *const Diagnostic) u32 {
    return @intCast(self.diagnostics.items.len);
}

/// Number of error-level diagnostics.
pub fn errorCount(self: *const Diagnostic) u32 {
    var n: u32 = 0;
    for (self.diagnostics.items) |d| {
        if (d.severity == .@"error") n += 1;
    }
    return n;
}

/// Number of warning-level diagnostics.
pub fn warningCount(self: *const Diagnostic) u32 {
    var n: u32 = 0;
    for (self.diagnostics.items) |d| {
        if (d.severity == .warning) n += 1;
    }
    return n;
}

// -------------------------------------------------------------------------
// Filtering helpers
// -------------------------------------------------------------------------

/// Return only error-level diagnostics (caller owns returned slice).
pub fn errors(self: *const Diagnostic, allocator: Allocator) Allocator.Error![]const Entry {
    var result: std.ArrayListUnmanaged(Entry) = .empty;
    for (self.diagnostics.items) |d| {
        if (d.severity == .@"error") {
            try result.append(allocator, d);
        }
    }
    return result.items;
}

/// Return only warning-level diagnostics (caller owns returned slice).
pub fn warnings(self: *const Diagnostic, allocator: Allocator) Allocator.Error![]const Entry {
    var result: std.ArrayListUnmanaged(Entry) = .empty;
    for (self.diagnostics.items) |d| {
        if (d.severity == .warning) {
            try result.append(allocator, d);
        }
    }
    return result.items;
}

// -------------------------------------------------------------------------
// Formatting
// -------------------------------------------------------------------------

/// Format all diagnostics as a human-readable string.
pub fn format(self: *const Diagnostic, allocator: Allocator) Allocator.Error![]const u8 {
    if (self.diagnostics.items.len == 0) return "";

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const writer = buf.writer(allocator);
    for (self.diagnostics.items) |*d| {
        try self.formatDiagnostic(d, writer);
        try writer.writeByte('\n');
    }
    return buf.items;
}

/// Format a single diagnostic with source context.
pub fn formatDiagnostic(self: *const Diagnostic, d: *const Entry, writer: anytype) !void {
    // Main line: "line:col: severity: message"
    try writer.print("{d}:{d}: {s}: {s}\n", .{
        d.range.start.line,
        d.range.start.column,
        d.severity.string(),
        d.message,
    });

    // Spec reference
    if (d.spec_ref.len > 0) {
        try writer.print("  [WGSL spec section {s}]\n", .{d.spec_ref});
    }

    // Source context line
    const source_line = self.getSourceLine(d.range.start.line);
    if (source_line.len > 0) {
        try writer.print("    {s}\n", .{source_line});

        // Caret indicator
        const pad = d.range.start.column - 1 + 4;
        var i: u32 = 0;
        while (i < pad) : (i += 1) try writer.writeByte(' ');
        try writer.writeByte('^');

        if (d.range.end.line == d.range.start.line and d.range.end.column > d.range.start.column) {
            var j: u32 = 1;
            const tildes = d.range.end.column - d.range.start.column;
            while (j < tildes) : (j += 1) try writer.writeByte('~');
        }
        try writer.writeByte('\n');
    }

    // Related info
    for (d.related) |rel| {
        try writer.print("  {d}:{d}: note: {s}\n", .{
            rel.range.start.line,
            rel.range.start.column,
            rel.message,
        });
    }
}

/// Get source line at 1-based line number.
fn getSourceLine(self: *const Diagnostic, line_number: u32) []const u8 {
    if (line_number < 1) return "";

    const src = self.source;
    var current_line: u32 = 1;
    var line_start: usize = 0;

    // Walk to the requested line
    if (line_number > 1) {
        for (src, 0..) |c, idx| {
            if (c == '\n') {
                current_line += 1;
                if (current_line == line_number) {
                    line_start = idx + 1;
                    break;
                }
            }
        }
        if (current_line < line_number) return "";
    }

    // Find end of line
    var line_end: usize = line_start;
    while (line_end < src.len and src[line_end] != '\n' and src[line_end] != '\r') {
        line_end += 1;
    }

    return src[line_start..line_end];
}

/// Remove duplicate diagnostics (same offset and message).
/// Preserves the first occurrence and the original order.
pub fn deduplicate(self: *Diagnostic) void {
    const entries = self.diagnostics.items;
    if (entries.len <= 1) return;

    // In-place stable dedup: walk forward, keeping entries whose
    // (start offset, message) pair hasn't been seen before.
    var write: usize = 0;
    for (0..entries.len) |read| {
        const entry = entries[read];
        const is_dup = blk: {
            for (entries[0..write]) |kept| {
                if (kept.range.start.offset == entry.range.start.offset and
                    std.mem.eql(u8, kept.message, entry.message))
                {
                    break :blk true;
                }
            }
            break :blk false;
        };
        if (!is_dup) {
            entries[write] = entry;
            write += 1;
        }
    }
    self.diagnostics.items.len = write;

    // Recompute has_errors from remaining entries.
    self.has_errors = false;
    for (self.diagnostics.items) |d| {
        if (d.severity == .@"error") {
            self.has_errors = true;
            break;
        }
    }
}

/// Remove all diagnostics.
pub fn clear(self: *Diagnostic) void {
    self.diagnostics.items.len = 0;
    self.has_errors = false;
}

// =========================================================================
// DiagnosticCode constants
// =========================================================================

pub const Code = struct {
    // Syntax errors (E00xx)
    pub const unexpected_token: []const u8 = "E0001";
    pub const unterminated_string: []const u8 = "E0002";
    pub const invalid_number: []const u8 = "E0003";
    pub const reserved_word: []const u8 = "E0004";

    // Symbol errors (E01xx)
    pub const undefined_symbol: []const u8 = "E0100";
    pub const duplicate_symbol: []const u8 = "E0101";
    pub const use_before_decl: []const u8 = "E0102";
    pub const recursive_function: []const u8 = "E0103";
    pub const recursive_type: []const u8 = "E0104";
    pub const reserved_identifier: []const u8 = "E0105";

    // Type errors (E02xx)
    pub const type_mismatch: []const u8 = "E0200";
    pub const invalid_operand: []const u8 = "E0201";
    pub const invalid_arg_count: []const u8 = "E0202";
    pub const invalid_arg_type: []const u8 = "E0203";
    pub const not_callable: []const u8 = "E0204";
    pub const not_indexable: []const u8 = "E0205";
    pub const no_such_member: []const u8 = "E0206";
    pub const invalid_return: []const u8 = "E0207";
    pub const missing_return: []const u8 = "E0208";
    pub const invalid_conversion: []const u8 = "E0209";
    pub const invalid_assignment: []const u8 = "E0210";
    pub const index_out_of_bounds: []const u8 = "E0211";
    pub const must_use_ignored: []const u8 = "E0212";
    pub const ambiguous_precedence: []const u8 = "E0213";
    pub const deref_requires_pointer: []const u8 = "E0214";
    pub const addr_of_requires_reference: []const u8 = "E0215";
    pub const addr_of_vector_component: []const u8 = "E0216";
    pub const addr_of_handle: []const u8 = "E0217";

    // Declaration errors (E03xx)
    pub const missing_initializer: []const u8 = "E0300";
    pub const invalid_initializer: []const u8 = "E0301";
    pub const invalid_const_expr: []const u8 = "E0302";
    pub const invalid_override: []const u8 = "E0303";
    pub const invalid_address_space: []const u8 = "E0304";
    pub const invalid_access_mode: []const u8 = "E0305";
    pub const duplicate_case_selector: []const u8 = "E0306";
    pub const missing_default_case: []const u8 = "E0307";
    pub const invalid_atomic_type: []const u8 = "E0308";
    pub const invalid_matrix_element: []const u8 = "E0309";
    pub const empty_struct: []const u8 = "E0310";
    pub const invalid_override_id: []const u8 = "E0311";
    pub const duplicate_override_id: []const u8 = "E0312";
    pub const invalid_array_count: []const u8 = "E0313";
    pub const invalid_float_literal: []const u8 = "E0314";
    pub const expression_not_const: []const u8 = "E0315";
    pub const division_by_zero: []const u8 = "E0316";
    pub const integer_overflow: []const u8 = "E0317";

    // Attribute errors (E04xx)
    pub const invalid_attribute: []const u8 = "E0400";
    pub const duplicate_attribute: []const u8 = "E0401";
    pub const missing_attribute: []const u8 = "E0402";
    pub const invalid_builtin: []const u8 = "E0403";
    pub const invalid_location: []const u8 = "E0404";
    pub const invalid_interpolation: []const u8 = "E0405";
    pub const missing_interpolation: []const u8 = "E0406";

    // Control flow errors (E05xx)
    pub const break_outside_loop: []const u8 = "E0500";
    pub const continue_outside_loop: []const u8 = "E0501";
    pub const discard_outside_fragment: []const u8 = "E0502";
    pub const unreachable_code: []const u8 = "E0503";
    pub const nesting_too_deep: []const u8 = "E0504";
    pub const infinite_loop: []const u8 = "E0505";
    pub const return_in_continuing: []const u8 = "E0506";

    // Entry point errors (E06xx)
    pub const invalid_entry_point: []const u8 = "E0600";
    pub const missing_entry_point: []const u8 = "E0601";
    pub const invalid_shader_io: []const u8 = "E0602";
    pub const entry_point_called: []const u8 = "E0603";

    // Uniformity errors (E07xx)
    pub const non_uniform_derivative: []const u8 = "E0700";
    pub const non_uniform_barrier: []const u8 = "E0701";
    pub const non_uniform_texture: []const u8 = "E0702";
    pub const non_uniform_subgroup: []const u8 = "E0703";

    // Memory errors (E08xx)
    pub const invalid_workgroup_var: []const u8 = "E0800";
    pub const invalid_storage_var: []const u8 = "E0801";
    pub const invalid_uniform_var: []const u8 = "E0802";
    pub const missing_binding: []const u8 = "E0803";
    pub const duplicate_binding: []const u8 = "E0804";
    pub const opaque_in_struct: []const u8 = "E0805";
    pub const runtime_array_not_last: []const u8 = "E0806";
    pub const const_assert_failed: []const u8 = "E0807";

    // Feature / directive errors (E09xx)
    pub const feature_not_enabled: []const u8 = "E0900";
    pub const unknown_feature: []const u8 = "E0901";
    pub const invalid_diagnostic_rule: []const u8 = "E0902";
    pub const invalid_diagnostic_severity: []const u8 = "E0903";

    // Warnings (W01xx)
    pub const shadowing: []const u8 = "W0100";
    pub const redundant_cast: []const u8 = "W0101";

    // Lint rules (W0001..W0003 are legacy LSP codes kept for back-compat,
    // W02xx is the new linter namespace for rules added after the refactor).
    pub const lint_no_unused_vars: []const u8 = "W0001";
    pub const lint_no_dead_code: []const u8 = "W0002";
    pub const lint_no_unused_binding: []const u8 = "W0003";
    pub const lint_naming_convention: []const u8 = "W0200";
    pub const lint_no_redundant_casts: []const u8 = "W0201";
    pub const lint_no_magic_numbers: []const u8 = "W0202";
    pub const lint_prefer_mix: []const u8 = "W0203";
    pub const lint_no_large_local_arrays: []const u8 = "W0204";
    pub const lint_prefer_workgroup_shared: []const u8 = "W0205";
    pub const lint_require_entry_point_attrs: []const u8 = "W0206";
    pub const lint_no_f16_without_extension: []const u8 = "W0207";
    pub const lint_consistent_binding_annotations: []const u8 = "W0208";
    pub const lint_unused_disable_directive: []const u8 = "W0209";
};

/// Map a diagnostic code to a WGSL spec section slug.
/// Empty string if the code is unknown or does not belong to a known
/// category — callers may still set `spec_ref` explicitly on `Entry`.
pub fn specRefFor(code: []const u8) []const u8 {
    if (code.len < 5) return "";
    // Uniformity-analysis errors get a dedicated slug — the rule identifiers
    // in `rule_derivative_uniformity` / `rule_subgroup_uniformity` map to the
    // spec's "Uniformity" section and users search for it by that name.
    if (std.mem.startsWith(u8, code, "E07")) return "uniformity";
    if (std.mem.startsWith(u8, code, "E00")) return "shader-creation";
    if (std.mem.startsWith(u8, code, "E01")) return "module-scope-declarations";
    if (std.mem.startsWith(u8, code, "E02")) return "types";
    if (std.mem.startsWith(u8, code, "E03")) return "variable-and-value-declarations";
    if (std.mem.startsWith(u8, code, "E04")) return "attributes";
    if (std.mem.startsWith(u8, code, "E05")) return "statements";
    if (std.mem.startsWith(u8, code, "E06")) return "entry-points";
    if (std.mem.startsWith(u8, code, "E08")) return "memory-model";
    if (std.mem.startsWith(u8, code, "E09")) return "directives";
    if (std.mem.startsWith(u8, code, "W01")) return "module-scope-declarations";
    if (std.mem.startsWith(u8, code, "W02")) return "linting";
    if (std.mem.startsWith(u8, code, "W00")) return "linting";
    return "";
}

// =========================================================================
// Standard diagnostic rules (from WGSL spec)
// =========================================================================

pub const rule_derivative_uniformity: []const u8 = "derivative_uniformity";
pub const rule_subgroup_uniformity: []const u8 = "subgroup_uniformity";

// =========================================================================
// DiagnosticFilter
// =========================================================================

/// Controls which diagnostics are reported; rules map names to severity
/// overrides.
pub const DiagnosticFilter = struct {
    rules: std.StringHashMapUnmanaged(Severity),

    pub fn init() DiagnosticFilter {
        return .{ .rules = .{} };
    }

    pub fn deinit(self: *DiagnosticFilter, allocator: Allocator) void {
        self.rules.deinit(allocator);
    }

    /// Set the severity for a diagnostic rule.
    pub fn setRule(self: *DiagnosticFilter, allocator: Allocator, rule: []const u8, severity: Severity) void {
        self.rules.put(allocator, rule, severity) catch {};
    }

    /// Disable a diagnostic rule.
    pub fn disableRule(self: *DiagnosticFilter, allocator: Allocator, rule: []const u8) void {
        self.rules.put(allocator, rule, .disabled) catch {};
    }

    /// True if the rule has been disabled.
    pub fn isDisabled(self: *const DiagnosticFilter, rule: []const u8) bool {
        if (self.rules.get(rule)) |sev| {
            return sev == .disabled;
        }
        return false;
    }

    /// Severity for a rule, falling back to `default_severity` when unset.
    /// Caller should check `isDisabled` first; a disabled rule returns the
    /// default (matching Go behaviour).
    pub fn getSeverity(self: *const DiagnosticFilter, rule: []const u8, default_severity: Severity) Severity {
        if (self.rules.get(rule)) |sev| {
            if (sev == .disabled) return default_severity;
            return sev;
        }
        return default_severity;
    }
};

// =========================================================================
// Tests
// =========================================================================

test "diagnostic: Severity.string" {
    try std.testing.expectEqualStrings("error", Severity.@"error".string());
    try std.testing.expectEqualStrings("warning", Severity.warning.string());
    try std.testing.expectEqualStrings("info", Severity.info.string());
    try std.testing.expectEqualStrings("note", Severity.note.string());
}

test "diagnostic: LineIndex basic" {
    const allocator = std.testing.allocator;
    var li = try LineIndex.init(allocator, "abc\ndef\nghi");
    defer li.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 3), li.lineCount());

    const p0 = li.byteOffsetToLineColumn(0);
    try std.testing.expectEqual(@as(u32, 0), p0.line);
    try std.testing.expectEqual(@as(u32, 0), p0.col);

    // 'd' is at byte 4
    const p4 = li.byteOffsetToLineColumn(4);
    try std.testing.expectEqual(@as(u32, 1), p4.line);
    try std.testing.expectEqual(@as(u32, 0), p4.col);

    // 'g' is at byte 8
    const p8 = li.byteOffsetToLineColumn(8);
    try std.testing.expectEqual(@as(u32, 2), p8.line);
    try std.testing.expectEqual(@as(u32, 0), p8.col);
}

test "diagnostic: DiagnosticList add and query" {
    const allocator = std.testing.allocator;
    var dl = try Diagnostic.init(allocator, "fn main() {}");
    defer dl.deinit(allocator);

    try std.testing.expect(!dl.hasErrors());

    dl.addError(allocator, 3, "unexpected token");
    try std.testing.expect(dl.hasErrors());
    try std.testing.expectEqual(@as(u32, 1), dl.count());
    try std.testing.expectEqual(@as(u32, 1), dl.errorCount());

    dl.addWarning(allocator, 0, "unused variable");
    try std.testing.expectEqual(@as(u32, 2), dl.count());
    try std.testing.expectEqual(@as(u32, 1), dl.errorCount());
}

test "diagnostic: DiagnosticList makePosition" {
    const allocator = std.testing.allocator;
    var dl = try Diagnostic.init(allocator, "line1\nline2\nline3");
    defer dl.deinit(allocator);

    // Byte 0 -> line 1, col 1
    const p0 = dl.makePosition(0);
    try std.testing.expectEqual(@as(u32, 1), p0.line);
    try std.testing.expectEqual(@as(u32, 1), p0.column);

    // Byte 6 -> line 2, col 1
    const p6 = dl.makePosition(6);
    try std.testing.expectEqual(@as(u32, 2), p6.line);
    try std.testing.expectEqual(@as(u32, 1), p6.column);
}

test "diagnostic: DiagnosticList clear" {
    const allocator = std.testing.allocator;
    var dl = try Diagnostic.init(allocator, "x");
    defer dl.deinit(allocator);

    dl.addError(allocator, 0, "err");
    try std.testing.expectEqual(@as(u32, 1), dl.count());
    try std.testing.expect(dl.hasErrors());

    dl.clear();
    try std.testing.expectEqual(@as(u32, 0), dl.count());
    try std.testing.expect(!dl.hasErrors());
}

test "diagnostic: deduplicate removes exact duplicates" {
    const allocator = std.testing.allocator;
    var dl = try Diagnostic.init(allocator, "fn main() {}");
    defer dl.deinit(allocator);

    dl.addError(allocator, 3, "unknown type 'Foo'");
    dl.addError(allocator, 3, "unknown type 'Foo'"); // duplicate
    dl.addError(allocator, 7, "unknown type 'Bar'");
    dl.addError(allocator, 3, "unknown type 'Foo'"); // duplicate
    dl.addError(allocator, 7, "unknown type 'Bar'"); // duplicate

    try std.testing.expectEqual(@as(u32, 5), dl.count());

    dl.deduplicate();

    try std.testing.expectEqual(@as(u32, 2), dl.count());
    try std.testing.expect(dl.hasErrors());
}

test "diagnostic: deduplicate preserves different messages at same offset" {
    const allocator = std.testing.allocator;
    var dl = try Diagnostic.init(allocator, "fn main() {}");
    defer dl.deinit(allocator);

    dl.addError(allocator, 3, "error A");
    dl.addError(allocator, 3, "error B"); // same offset, different message — keep

    dl.deduplicate();

    try std.testing.expectEqual(@as(u32, 2), dl.count());
}

test "diagnostic: deduplicate preserves same message at different offsets" {
    const allocator = std.testing.allocator;
    var dl = try Diagnostic.init(allocator, "fn main() {}");
    defer dl.deinit(allocator);

    dl.addError(allocator, 3, "unknown type 'Foo'");
    dl.addError(allocator, 7, "unknown type 'Foo'"); // same message, different offset — keep

    dl.deduplicate();

    try std.testing.expectEqual(@as(u32, 2), dl.count());
}

test "diagnostic: deduplicate recomputes has_errors" {
    const allocator = std.testing.allocator;
    var dl = try Diagnostic.init(allocator, "fn main() {}");
    defer dl.deinit(allocator);

    dl.addWarning(allocator, 0, "warning");
    dl.addWarning(allocator, 0, "warning"); // duplicate

    dl.deduplicate();

    try std.testing.expectEqual(@as(u32, 1), dl.count());
    try std.testing.expect(!dl.hasErrors()); // only warnings, no errors
}

test "diagnostic: DiagnosticFilter" {
    const allocator = std.testing.allocator;
    var filter = DiagnosticFilter.init();
    defer filter.deinit(allocator);

    // Default: not disabled, returns default severity
    try std.testing.expect(!filter.isDisabled("derivative_uniformity"));
    try std.testing.expectEqual(Severity.@"error", filter.getSeverity("derivative_uniformity", .@"error"));

    // Set a rule
    filter.setRule(allocator, "derivative_uniformity", .warning);
    try std.testing.expectEqual(Severity.warning, filter.getSeverity("derivative_uniformity", .@"error"));

    // Disable a rule
    filter.disableRule(allocator, "subgroup_uniformity");
    try std.testing.expect(filter.isDisabled("subgroup_uniformity"));
    // Disabled rule returns default when queried (caller should check isDisabled)
    try std.testing.expectEqual(Severity.@"error", filter.getSeverity("subgroup_uniformity", .@"error"));
}

test "entryToJson: propagates OOM" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const entry = Entry{ .severity = .@"error", .message = "test error" };
    const result = entryToJson(&buf, failing.allocator(), &entry);
    try std.testing.expect(result == error.OutOfMemory);
}

test "LineIndex.init: propagates OOM" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const result = LineIndex.init(failing.allocator(), "hello\nworld");
    try std.testing.expect(result == error.OutOfMemory);
}
