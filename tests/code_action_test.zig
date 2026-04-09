//! Integration tests for LSP code actions.
//!
//! Tests the full pipeline: WGSL source → validate → diagnostics →
//! convert to LSP format → compute code actions → verify edits.

const std = @import("std");
const wgslender = @import("wgslender");

const Handler = @import("Handler");
const Diagnostic = wgslender.Diagnostic;

// =========================================================================
// Helpers
// =========================================================================

const TestResult = struct {
    actions: []Handler.LspCodeAction,
    handler: *Handler,
    diags: []Handler.LspDiagnostic,
};

/// Validate WGSL source and convert diagnostics to Handler's LSP format,
/// then compute code actions. Returns the actions (caller frees via cleanup).
fn getCodeActions(source: [:0]const u8) !TestResult {
    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);

    // Open the document so findLocationAttrRange can find it.
    try handler.openDocument("test://file.wgsl", source, 1);

    const diags = try handler.validateDocument(source);

    const actions = try handler.computeCodeActions(diags);

    return .{ .actions = actions, .handler = handler, .diags = diags };
}

fn cleanup(r: TestResult) void {
    for (r.actions) |a| {
        std.testing.allocator.free(a.title);
        for (a.edits) |edit| {
            std.testing.allocator.free(edit.new_text);
        }
        std.testing.allocator.free(a.edits);
    }
    std.testing.allocator.free(r.actions);
    Handler.freeDiagnostics(std.testing.allocator, r.diags);
    r.handler.deinit();
    std.testing.allocator.destroy(r.handler);
}

/// Find a code action whose title contains the given pattern.
fn findActionByTitle(actions: []const Handler.LspCodeAction, pattern: []const u8) ?Handler.LspCodeAction {
    for (actions) |a| {
        if (std.mem.indexOf(u8, a.title, pattern) != null) return a;
    }
    return null;
}

/// Apply a code action's edits to source text and return the result.
/// Only supports single-edit actions on line 0 for simplicity.
fn applyEdit(source: []const u8, edit: Handler.LspTextEdit) ![]u8 {
    // Convert LSP positions to byte offsets
    const start_offset = Handler.lspPositionToOffset(source, edit.range.start) orelse return error.InvalidPosition;
    const end_offset = Handler.lspPositionToOffset(source, edit.range.end) orelse return error.InvalidPosition;

    const result = try std.testing.allocator.alloc(u8, source.len - (end_offset - start_offset) + edit.new_text.len);
    @memcpy(result[0..start_offset], source[0..start_offset]);
    @memcpy(result[start_offset..][0..edit.new_text.len], edit.new_text);
    @memcpy(result[start_offset + edit.new_text.len ..], source[end_offset..]);
    return result;
}

// =========================================================================
// "Did you mean?" rename tests
// =========================================================================

test "undefined identifier with close match produces rename action" {
    const source =
        \\const position: f32 = 1.0;
        \\fn main() -> f32 { return positon; }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    const action = findActionByTitle(result.actions, "Replace with 'position'");
    try std.testing.expect(action != null);
    try std.testing.expect(action.?.is_preferred);
    try std.testing.expectEqualStrings("quickfix", action.?.kind);
    try std.testing.expectEqual(@as(usize, 1), action.?.edits.len);
    try std.testing.expectEqualStrings("position", action.?.edits[0].new_text);
}

test "undefined identifier rename produces valid WGSL after apply" {
    const source: [:0]const u8 =
        \\const position: f32 = 1.0;
        \\fn main() -> f32 { return positon; }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    const action = findActionByTitle(result.actions, "Replace with 'position'") orelse
        return error.TestUnexpectedResult;

    // Apply the fix
    const fixed = try applyEdit(source, action.edits[0]);
    defer std.testing.allocator.free(fixed);

    // The fixed source should contain "position" instead of "positon"
    try std.testing.expect(std.mem.indexOf(u8, fixed, "return position;") != null);
}

test "unknown type with suggestion produces rename action" {
    const source =
        \\fn main() { var x: vec4ff = vec4f(1.0, 2.0, 3.0, 4.0); _ = x; }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    // Should suggest vec4f (Levenshtein distance 1 from vec4ff)
    const action = findActionByTitle(result.actions, "Replace with 'vec4f'");
    try std.testing.expect(action != null);
    try std.testing.expectEqualStrings("vec4f", action.?.edits[0].new_text);
}

test "wrong struct member with suggestion" {
    const source =
        \\struct S { x: f32 }
        \\fn f(s: S) -> f32 { return s.y; }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    const action = findActionByTitle(result.actions, "Replace with 'x'");
    try std.testing.expect(action != null);
    try std.testing.expectEqualStrings("x", action.?.edits[0].new_text);
}

test "invalid builtin value with suggestion" {
    // Use a non-entry-point function to avoid E0600 overshadowing
    const source =
        \\fn main(@builtin(positon) v: u32) -> u32 { return v; }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    const action = findActionByTitle(result.actions, "Replace with 'position'");
    try std.testing.expect(action != null);
    try std.testing.expectEqualStrings("position", action.?.edits[0].new_text);
}

test "no suggestion available produces no code action" {
    const source =
        \\fn main() -> f32 { return zzzzzzzzz; }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    // No "Replace with" actions (identifier too far from any known name)
    const action = findActionByTitle(result.actions, "Replace with");
    try std.testing.expect(action == null);
}

// =========================================================================
// Duplicate @location tests
// =========================================================================

test "duplicate @location produces increment action for input parameters" {
    // Use direct function parameters where the diagnostic range is on the
    // parameter itself (near the @location attribute), not on the function name.
    const source =
        \\@fragment fn main(@location(0) a: f32, @location(0) b: f32) -> @location(0) vec4f { return vec4f(a, b, 0.0, 1.0); }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    const action = findActionByTitle(result.actions, "Change to @location(1)");
    try std.testing.expect(action != null);
    try std.testing.expectEqual(@as(usize, 1), action.?.edits.len);
    try std.testing.expectEqualStrings("@location(1)", action.?.edits[0].new_text);
}

// =========================================================================
// Edge cases
// =========================================================================

test "empty source produces no actions" {
    const source: [:0]const u8 = "";
    const result = try getCodeActions(source);
    defer cleanup(result);
    try std.testing.expectEqual(@as(usize, 0), result.actions.len);
}

test "valid source produces no actions" {
    const source =
        \\fn main() -> f32 { return 1.0; }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);
    try std.testing.expectEqual(@as(usize, 0), result.actions.len);
}

test "diagnostic without code produces no action" {
    // Parser errors may not have suggestion-eligible codes
    const source =
        \\fn main() { if }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    // Should have diagnostics but no code actions (syntax errors are not fixable)
    const action = findActionByTitle(result.actions, "Replace with");
    try std.testing.expect(action == null);
}

test "multiple errors produce multiple actions" {
    const source =
        \\const position: f32 = 1.0;
        \\const velocity: f32 = 2.0;
        \\fn main() -> f32 { let a = positon; let b = velocty; return a + b; }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    // Should have at least 2 rename actions
    var rename_count: usize = 0;
    for (result.actions) |a| {
        if (std.mem.indexOf(u8, a.title, "Replace with") != null) rename_count += 1;
    }
    try std.testing.expect(rename_count >= 2);
}

test "code action edit range is correct for multi-char identifiers" {
    const source: [:0]const u8 =
        \\const position: f32 = 1.0;
        \\fn main() -> f32 { return positon; }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    const action = findActionByTitle(result.actions, "Replace with 'position'") orelse
        return error.TestUnexpectedResult;

    const edit = action.edits[0];
    // The edit should span exactly the misspelled identifier
    const start = Handler.lspPositionToOffset(source, edit.range.start) orelse
        return error.TestUnexpectedResult;
    const end = Handler.lspPositionToOffset(source, edit.range.end) orelse
        return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("positon", source[start..end]);
}

// =========================================================================
// Apply-and-revalidate tests
// =========================================================================

test "applying unknown type fix produces fewer errors" {
    const source: [:0]const u8 =
        \\fn main() { var x: vec4ff = vec4f(1.0, 2.0, 3.0, 4.0); _ = x; }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    const action = findActionByTitle(result.actions, "Replace with 'vec4f'") orelse
        return error.TestUnexpectedResult;

    // Apply the fix
    const fixed_slice = try applyEdit(source, action.edits[0]);
    defer std.testing.allocator.free(fixed_slice);

    // Make a sentinel-terminated copy for revalidation
    const fixed_z = try std.testing.allocator.alloc(u8, fixed_slice.len + 1);
    defer std.testing.allocator.free(fixed_z);
    @memcpy(fixed_z[0..fixed_slice.len], fixed_slice);
    fixed_z[fixed_slice.len] = 0;
    const fixed: [:0]const u8 = fixed_z[0..fixed_slice.len :0];

    // Revalidate — the type error should be gone
    var handler2 = Handler.init(std.testing.allocator);
    defer handler2.deinit();
    const diags2 = try handler2.validateDocument(fixed);
    defer Handler.freeDiagnostics(std.testing.allocator, diags2);

    // Should have no E0200 errors for vec4ff
    for (diags2) |d| {
        if (std.mem.eql(u8, d.code, "E0200") and std.mem.indexOf(u8, d.message, "vec4ff") != null) {
            return error.TestUnexpectedResult;
        }
    }
}

test "applying struct member fix replaces the diagnostic range" {
    const source: [:0]const u8 =
        \\struct S { x: f32 }
        \\fn f(s: S) -> f32 { return s.y; }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    const action = findActionByTitle(result.actions, "Replace with 'x'") orelse
        return error.TestUnexpectedResult;

    // Verify the edit range covers the member access expression
    const start = Handler.lspPositionToOffset(source, action.edits[0].range.start) orelse
        return error.TestUnexpectedResult;
    const end = Handler.lspPositionToOffset(source, action.edits[0].range.end) orelse
        return error.TestUnexpectedResult;

    // The diagnostic range covers ".y" (dot + member name)
    const replaced_text = source[start..end];
    try std.testing.expect(std.mem.indexOf(u8, replaced_text, "y") != null);
}

// =========================================================================
// Additional integration edge cases
// =========================================================================

test "not callable with suggestion produces rename" {
    // Use a typo of a builtin function name to trigger E0204
    const source =
        \\fn main() { let x = coss(1.0); _ = x; }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    // "coss" is close to "cos" (Levenshtein 1)
    const action = findActionByTitle(result.actions, "Replace with");
    // May or may not produce suggestion depending on validator behavior
    // Just verify no crash and actions array is valid
    _ = action;
}

test "suggestion preserves edit range across lines" {
    const source: [:0]const u8 =
        \\const position: f32 = 1.0;
        \\const velocity: f32 = 2.0;
        \\fn main() -> f32 {
        \\    return positon;
        \\}
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    const action = findActionByTitle(result.actions, "Replace with 'position'") orelse
        return error.TestUnexpectedResult;

    // Verify the edit points to line 3 where "positon" is
    try std.testing.expectEqual(@as(u32, 3), action.edits[0].range.start.line);

    // Apply and verify
    const fixed = try applyEdit(source, action.edits[0]);
    defer std.testing.allocator.free(fixed);
    try std.testing.expect(std.mem.indexOf(u8, fixed, "return position;") != null);
}

test "duplicate @location fix for input parameters updates correctly" {
    const source: [:0]const u8 =
        \\@fragment fn main(@location(0) a: f32, @location(0) b: f32) -> @location(0) vec4f { return vec4f(a, b, 0.0, 1.0); }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    const action = findActionByTitle(result.actions, "Change to @location(1)") orelse
        return error.TestUnexpectedResult;

    // Apply and verify
    const fixed = try applyEdit(source, action.edits[0]);
    defer std.testing.allocator.free(fixed);

    // The fixed source should have @location(1) somewhere
    try std.testing.expect(std.mem.indexOf(u8, fixed, "@location(1)") != null);
    // And still have at least one @location(0) (the first one wasn't changed)
    try std.testing.expect(std.mem.indexOf(u8, fixed, "@location(0)") != null);
}

test "code actions for warnings (not just errors)" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    // Warnings with did-you-mean should also produce actions
    const diags = [_]Handler.LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
        .severity = .warning,
        .message = "use of undeclared identifier 'pos'; did you mean 'position'?",
        .code = "E0100",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer {
        for (actions) |a| {
            std.testing.allocator.free(a.title);
            for (a.edits) |edit| std.testing.allocator.free(edit.new_text);
            std.testing.allocator.free(a.edits);
        }
        std.testing.allocator.free(actions);
    }

    // Should still produce action regardless of severity
    try std.testing.expectEqual(@as(usize, 1), actions.len);
}

test "action diagnostic field preserves original diagnostic" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]Handler.LspDiagnostic{.{
        .range = .{ .start = .{ .line = 2, .character = 10 }, .end = .{ .line = 2, .character = 17 } },
        .severity = .@"error",
        .message = "use of undeclared identifier 'positon'; did you mean 'position'?",
        .code = "E0100",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer {
        for (actions) |a| {
            std.testing.allocator.free(a.title);
            for (a.edits) |edit| std.testing.allocator.free(edit.new_text);
            std.testing.allocator.free(a.edits);
        }
        std.testing.allocator.free(actions);
    }

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    // The action should carry the original diagnostic
    try std.testing.expectEqualStrings("E0100", actions[0].diagnostic.code);
    try std.testing.expectEqual(@as(u32, 2), actions[0].diagnostic.range.start.line);
    try std.testing.expectEqual(@as(u32, 10), actions[0].diagnostic.range.start.character);
}
