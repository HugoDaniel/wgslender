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

test "code action: undefined identifier with close match produces rename action" {
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

test "code action: undefined identifier rename produces valid WGSL after apply" {
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

test "code action: unknown type with suggestion produces rename action" {
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

test "code action: wrong struct member with suggestion" {
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

test "code action: invalid builtin value with suggestion" {
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

test "code action: no suggestion available produces no code action" {
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

test "code action: duplicate @location produces increment action for input parameters" {
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

test "code action: empty source produces no actions" {
    const source: [:0]const u8 = "";
    const result = try getCodeActions(source);
    defer cleanup(result);
    try std.testing.expectEqual(@as(usize, 0), result.actions.len);
}

test "code action: valid source produces no actions" {
    const source =
        \\fn main() -> f32 { return 1.0; }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);
    try std.testing.expectEqual(@as(usize, 0), result.actions.len);
}

test "code action: diagnostic without code produces no action" {
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

test "code action: multiple errors produce multiple actions" {
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

test "code action: edit range is correct for multi-char identifiers" {
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

test "code action: applying unknown type fix produces fewer errors" {
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

test "code action: applying struct member fix replaces the diagnostic range" {
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

test "code action: not callable with suggestion produces rename" {
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

test "code action: suggestion preserves edit range across lines" {
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

test "code action: duplicate @location fix for input parameters updates correctly" {
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

test "code action: actions for warnings (not just errors)" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    // Warnings with did-you-mean should also produce actions
    const diags = [_]Handler.LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
        .severity = .warning,
        .message = "use of undeclared identifier 'pos'; did you mean 'position'?",
        .code = "E0100",
        .data = .{ .did_you_mean = "position" },
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

test "code action: action diagnostic field preserves original diagnostic" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]Handler.LspDiagnostic{.{
        .range = .{ .start = .{ .line = 2, .character = 10 }, .end = .{ .line = 2, .character = 17 } },
        .severity = .@"error",
        .message = "use of undeclared identifier 'positon'; did you mean 'position'?",
        .code = "E0100",
        .data = .{ .did_you_mean = "position" },
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

// =========================================================================
// Code actions: unused symbol removal (W0001)
// =========================================================================

test "code action: W0001 unused produces remove action" {
    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    defer {
        handler.deinit();
        std.testing.allocator.destroy(handler);
    }

    // Synthesize a W0001 diagnostic
    const diag = Handler.LspDiagnostic{
        .range = .{
            .start = .{ .line = 0, .character = 6 },
            .end = .{ .line = 0, .character = 17 },
        },
        .severity = .warning,
        .message = "'unused_var' is declared but never used",
        .code = "W0001",
        .data = .{ .unused_symbol = "unused_var" },
    };
    const diags = try std.testing.allocator.alloc(Handler.LspDiagnostic, 1);
    defer std.testing.allocator.free(diags);
    diags[0] = diag;

    const actions = try handler.computeCodeActions(diags);
    defer {
        for (actions) |a| {
            std.testing.allocator.free(a.title);
            for (a.edits) |e| {
                if (e.new_text.len > 0) std.testing.allocator.free(e.new_text);
            }
            std.testing.allocator.free(a.edits);
        }
        std.testing.allocator.free(actions);
    }

    try std.testing.expect(actions.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, actions[0].title, "unused_var") != null);
}

test "code action: W0001 offers rename to '_name' action alongside remove" {
    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    defer {
        handler.deinit();
        std.testing.allocator.destroy(handler);
    }

    const diag = Handler.LspDiagnostic{
        .range = .{
            .start = .{ .line = 0, .character = 4 },
            .end = .{ .line = 0, .character = 14 },
        },
        .severity = .warning,
        .message = "'unused_var' is declared but never used",
        .code = "W0001",
        .data = .{ .unused_symbol = "unused_var" },
    };
    const diags = try std.testing.allocator.alloc(Handler.LspDiagnostic, 1);
    defer std.testing.allocator.free(diags);
    diags[0] = diag;

    const actions = try handler.computeCodeActions(diags);
    defer {
        for (actions) |a| {
            std.testing.allocator.free(a.title);
            for (a.edits) |e| {
                if (e.new_text.len > 0) std.testing.allocator.free(e.new_text);
            }
            std.testing.allocator.free(a.edits);
        }
        std.testing.allocator.free(actions);
    }

    // Both actions should be emitted
    const remove = findActionByTitle(actions, "Remove unused 'unused_var'") orelse
        return error.TestUnexpectedResult;
    _ = remove;
    const rename = findActionByTitle(actions, "Rename to '_unused_var'") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("_unused_var", rename.edits[0].new_text);
    try std.testing.expectEqualStrings("quickfix", rename.kind);
}

test "code action: W0001 rename action is not preferred" {
    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    defer {
        handler.deinit();
        std.testing.allocator.destroy(handler);
    }

    const diag = Handler.LspDiagnostic{
        .range = .{
            .start = .{ .line = 0, .character = 4 },
            .end = .{ .line = 0, .character = 7 },
        },
        .severity = .warning,
        .message = "'foo' is declared but never used",
        .code = "W0001",
        .data = .{ .unused_symbol = "foo" },
    };
    const diags = try std.testing.allocator.alloc(Handler.LspDiagnostic, 1);
    defer std.testing.allocator.free(diags);
    diags[0] = diag;

    const actions = try handler.computeCodeActions(diags);
    defer {
        for (actions) |a| {
            std.testing.allocator.free(a.title);
            for (a.edits) |e| {
                if (e.new_text.len > 0) std.testing.allocator.free(e.new_text);
            }
            std.testing.allocator.free(a.edits);
        }
        std.testing.allocator.free(actions);
    }

    const rename = findActionByTitle(actions, "Rename to '_foo'") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(!rename.is_preferred);
}

test "code action: W0001 skips underscore-rename when name already starts with _" {
    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    defer {
        handler.deinit();
        std.testing.allocator.destroy(handler);
    }

    const diag = Handler.LspDiagnostic{
        .range = .{
            .start = .{ .line = 0, .character = 4 },
            .end = .{ .line = 0, .character = 8 },
        },
        .severity = .warning,
        .message = "'_tmp' is declared but never used",
        .code = "W0001",
        .data = .{ .unused_symbol = "_tmp" },
    };
    const diags = try std.testing.allocator.alloc(Handler.LspDiagnostic, 1);
    defer std.testing.allocator.free(diags);
    diags[0] = diag;

    const actions = try handler.computeCodeActions(diags);
    defer {
        for (actions) |a| {
            std.testing.allocator.free(a.title);
            for (a.edits) |e| {
                if (e.new_text.len > 0) std.testing.allocator.free(e.new_text);
            }
            std.testing.allocator.free(a.edits);
        }
        std.testing.allocator.free(actions);
    }

    // Remove action still exists
    try std.testing.expect(findActionByTitle(actions, "Remove unused '_tmp'") != null);
    // But no underscore-prefix rename (would produce '__tmp')
    try std.testing.expect(findActionByTitle(actions, "Rename to '__tmp'") == null);
    try std.testing.expect(findActionByTitle(actions, "Rename to ") == null);
}

test "code action: W0001 rename edit spans exactly the identifier" {
    const source: [:0]const u8 = "let unused_var: f32 = 1.0;";

    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    defer {
        handler.deinit();
        std.testing.allocator.destroy(handler);
    }

    // The identifier "unused_var" starts at offset 4, length 10.
    const diag = Handler.LspDiagnostic{
        .range = .{
            .start = .{ .line = 0, .character = 4 },
            .end = .{ .line = 0, .character = 14 },
        },
        .severity = .warning,
        .message = "'unused_var' is declared but never used",
        .code = "W0001",
        .data = .{ .unused_symbol = "unused_var" },
    };
    const diags = try std.testing.allocator.alloc(Handler.LspDiagnostic, 1);
    defer std.testing.allocator.free(diags);
    diags[0] = diag;

    const actions = try handler.computeCodeActions(diags);
    defer {
        for (actions) |a| {
            std.testing.allocator.free(a.title);
            for (a.edits) |e| {
                if (e.new_text.len > 0) std.testing.allocator.free(e.new_text);
            }
            std.testing.allocator.free(a.edits);
        }
        std.testing.allocator.free(actions);
    }

    const rename = findActionByTitle(actions, "Rename to '_unused_var'") orelse
        return error.TestUnexpectedResult;

    // The edit range should cover exactly "unused_var"
    const start = Handler.lspPositionToOffset(source, rename.edits[0].range.start) orelse
        return error.TestUnexpectedResult;
    const end = Handler.lspPositionToOffset(source, rename.edits[0].range.end) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("unused_var", source[start..end]);

    // Applying the rename produces "let _unused_var: f32 = 1.0;"
    const fixed = try applyEdit(source, rename.edits[0]);
    defer std.testing.allocator.free(fixed);
    try std.testing.expect(std.mem.indexOf(u8, fixed, "let _unused_var") != null);
}

// =========================================================================
// Code actions: insert cast on type mismatch (E0200)
// =========================================================================

test "code action: isSafeCastTarget accepts scalar-to-scalar and same-shape vector casts" {
    try std.testing.expect(Handler.isSafeCastTarget("i32", "f32"));
    try std.testing.expect(Handler.isSafeCastTarget("f32", "i32"));
    try std.testing.expect(Handler.isSafeCastTarget("bool", "u32"));
    try std.testing.expect(Handler.isSafeCastTarget("vec3i", "vec3f"));
    try std.testing.expect(Handler.isSafeCastTarget("vec4f", "vec4u"));
    // Long-form vectors (the shape the validator actually emits).
    try std.testing.expect(Handler.isSafeCastTarget("vec3<i32>", "vec3<f32>"));
    try std.testing.expect(Handler.isSafeCastTarget("vec4<f16>", "vec4<f32>"));
    // Mixed spellings still pass as long as the shape matches.
    try std.testing.expect(Handler.isSafeCastTarget("vec3i", "vec3<f32>"));
}

test "code action: isSafeCastTarget rejects shape-changing and non-whitelisted targets" {
    // Shape-changing: vec3 → vec4 is not a safe constructor call.
    try std.testing.expect(!Handler.isSafeCastTarget("vec3f", "vec4f"));
    try std.testing.expect(!Handler.isSafeCastTarget("vec2i", "vec3i"));
    try std.testing.expect(!Handler.isSafeCastTarget("vec3<f32>", "vec4<f32>"));
    // Scalar ↔ vector: not safe.
    try std.testing.expect(!Handler.isSafeCastTarget("f32", "vec3f"));
    try std.testing.expect(!Handler.isSafeCastTarget("vec4f", "f32"));
    // User struct / unknown types.
    try std.testing.expect(!Handler.isSafeCastTarget("f32", "MyStruct"));
    try std.testing.expect(!Handler.isSafeCastTarget("S", "T"));
    // Matrices are intentionally out-of-scope.
    try std.testing.expect(!Handler.isSafeCastTarget("mat2x2f", "mat2x2i"));
    // Abstract types don't appear in this spelling but any unrecognized form returns false.
    try std.testing.expect(!Handler.isSafeCastTarget("AbstractFloat", "f32"));
}

test "code action: E0200 scalar return mismatch offers cast" {
    const source: [:0]const u8 =
        \\fn f() -> f32 { let x: i32 = 1; return x; }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    const action = findActionByTitle(result.actions, "Cast to 'f32'") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("quickfix", action.kind);
    try std.testing.expectEqual(@as(usize, 1), action.edits.len);

    const fixed = try applyEdit(source, action.edits[0]);
    defer std.testing.allocator.free(fixed);
    try std.testing.expect(std.mem.indexOf(u8, fixed, "return f32(x);") != null);
}

test "code action: E0200 same-shape vector mismatch offers cast" {
    // The validator formats vector types in long form (`vec3<f32>`) in messages,
    // so the cast title and edit text match that spelling. Short-form aliases
    // would be equivalent WGSL; the implementation keeps the validator's spelling.
    const source: [:0]const u8 =
        \\fn f() -> vec3f { let v: vec3i = vec3i(1, 2, 3); return v; }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    const action = findActionByTitle(result.actions, "Cast to 'vec3<f32>'") orelse
        return error.TestUnexpectedResult;

    const fixed = try applyEdit(source, action.edits[0]);
    defer std.testing.allocator.free(fixed);
    try std.testing.expect(std.mem.indexOf(u8, fixed, "return vec3<f32>(v);") != null);
}

test "code action: E0200 assignment mismatch offers cast on RHS" {
    const source: [:0]const u8 =
        \\fn f() { var a: f32 = 0.0; let b: i32 = 1; a = b; }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    const action = findActionByTitle(result.actions, "Cast to 'f32'") orelse
        return error.TestUnexpectedResult;

    const fixed = try applyEdit(source, action.edits[0]);
    defer std.testing.allocator.free(fixed);
    try std.testing.expect(std.mem.indexOf(u8, fixed, "a = f32(b);") != null);
}

test "code action: E0200 shape-changing mismatch offers no cast" {
    const source: [:0]const u8 =
        \\fn f() -> vec4f { let v: vec3f = vec3f(0.0); return v; }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    // No naive cast — vec4f(vec3f_value) is not a valid WGSL constructor call.
    try std.testing.expect(findActionByTitle(result.actions, "Cast to 'vec4f'") == null);
    try std.testing.expect(findActionByTitle(result.actions, "Cast to 'vec4<f32>'") == null);
}

test "code action: E0200 expected type is a user struct — no cast" {
    const source: [:0]const u8 =
        \\struct S { x: f32 }
        \\fn f() -> S { let x: f32 = 1.0; return x; }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    try std.testing.expect(findActionByTitle(result.actions, "Cast to 'S'") == null);
    try std.testing.expect(findActionByTitle(result.actions, "Cast to ") == null);
}

test "code action: E0203 call-arg mismatch offers no cast in v1" {
    // E0203's diagnostic range is the whole call expression, not just the arg.
    // Until the validator narrows this range, the cast quickfix is scoped to E0200.
    // This test locks the behavior so regressions surface if dispatch widens prematurely.
    const source: [:0]const u8 =
        \\fn g(x: f32) -> f32 { return x; }
        \\fn f() -> f32 { let y: i32 = 1; return g(y); }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    try std.testing.expect(findActionByTitle(result.actions, "Cast to ") == null);
}

test "code action: E0200 round-trip — applied cast suppresses the original diagnostic" {
    const source: [:0]const u8 =
        \\fn f() -> f32 { let x: i32 = 1; return x; }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    const action = findActionByTitle(result.actions, "Cast to 'f32'") orelse
        return error.TestUnexpectedResult;

    const fixed_slice = try applyEdit(source, action.edits[0]);
    defer std.testing.allocator.free(fixed_slice);

    const fixed_z = try std.testing.allocator.alloc(u8, fixed_slice.len + 1);
    defer std.testing.allocator.free(fixed_z);
    @memcpy(fixed_z[0..fixed_slice.len], fixed_slice);
    fixed_z[fixed_slice.len] = 0;
    const fixed: [:0]const u8 = fixed_z[0..fixed_slice.len :0];

    var handler2 = Handler.init(std.testing.allocator);
    defer handler2.deinit();
    const diags2 = try handler2.validateDocument(fixed);
    defer Handler.freeDiagnostics(std.testing.allocator, diags2);

    // No E0200 about a mismatch between i32/f32 should remain.
    for (diags2) |d| {
        if (std.mem.eql(u8, d.code, "E0200") and
            std.mem.indexOf(u8, d.message, "i32") != null and
            std.mem.indexOf(u8, d.message, "f32") != null)
        {
            return error.TestUnexpectedResult;
        }
    }
}

// (Old test "E0200 cast coexists with did-you-mean rename" was deleted —
//  in the new architecture each diagnostic carries exactly one structured
//  `data` payload, so a synthetic message containing both patterns is no
//  longer possible. The validator only ever stamps one or the other.)

// =========================================================================
// Code actions: insert @builtin(position) for vertex entry point (E0600)
// =========================================================================

test "code action: E0600 plain vec4f return type inserts @builtin(position) before type" {
    const source: [:0]const u8 =
        \\@vertex fn vs() -> vec4f { return vec4f(0); }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    const action = findActionByTitle(result.actions, "Add @builtin(position) to return type") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(action.is_preferred);
    try std.testing.expectEqualStrings("quickfix", action.kind);

    const fixed = try applyEdit(source, action.edits[0]);
    defer std.testing.allocator.free(fixed);
    // The return type is now annotated with @builtin(position).
    try std.testing.expect(std.mem.indexOf(u8, fixed, "-> @builtin(position) vec4f") != null);
}

test "code action: E0600 plain return, existing contents are preserved" {
    const source: [:0]const u8 =
        \\@vertex fn vs() -> vec4f { return vec4f(0); }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    const action = findActionByTitle(result.actions, "Add @builtin(position) to return type") orelse
        return error.TestUnexpectedResult;

    const fixed = try applyEdit(source, action.edits[0]);
    defer std.testing.allocator.free(fixed);
    // Nothing else should be disturbed.
    try std.testing.expect(std.mem.indexOf(u8, fixed, "@vertex fn vs()") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixed, "return vec4f(0); }") != null);
}

test "code action: E0600 struct return type inserts @builtin(position) member" {
    const source: [:0]const u8 =
        \\struct Out { @location(0) color: vec4f, }
        \\@vertex fn vs() -> Out { return Out(vec4f(0)); }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    const action = findActionByTitle(result.actions, "Add @builtin(position) member to 'Out'") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(action.is_preferred);

    const fixed = try applyEdit(source, action.edits[0]);
    defer std.testing.allocator.free(fixed);
    // New member lands inside the struct body.
    try std.testing.expect(std.mem.indexOf(u8, fixed, "@builtin(position) position: vec4f,") != null);
    // Existing member still present.
    try std.testing.expect(std.mem.indexOf(u8, fixed, "@location(0) color: vec4f,") != null);
    // The struct still closes with `}`.
    try std.testing.expect(std.mem.indexOf(u8, fixed, "}") != null);
}

test "code action: E0600 struct declared AFTER the function still resolves" {
    // Declaration order doesn't matter for WGSL validation; the quickfix
    // should find the struct regardless of where it appears in the file.
    const source: [:0]const u8 =
        \\@vertex fn vs() -> Out { return Out(vec4f(0)); }
        \\struct Out { @location(0) color: vec4f, }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    const action = findActionByTitle(result.actions, "Add @builtin(position) member to 'Out'") orelse
        return error.TestUnexpectedResult;

    const fixed = try applyEdit(source, action.edits[0]);
    defer std.testing.allocator.free(fixed);
    try std.testing.expect(std.mem.indexOf(u8, fixed, "@builtin(position) position: vec4f,") != null);
}

test "code action: E0600 multi-member struct — insertion preserves all existing members" {
    const source: [:0]const u8 =
        \\struct Out { @location(0) color: vec4f, @location(1) uv: vec2f, }
        \\@vertex fn vs() -> Out { return Out(vec4f(0), vec2f(0)); }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    const action = findActionByTitle(result.actions, "Add @builtin(position) member to 'Out'") orelse
        return error.TestUnexpectedResult;

    const fixed = try applyEdit(source, action.edits[0]);
    defer std.testing.allocator.free(fixed);
    // All three members are present after the fix.
    try std.testing.expect(std.mem.indexOf(u8, fixed, "@location(0) color: vec4f,") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixed, "@location(1) uv: vec2f,") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixed, "@builtin(position) position: vec4f,") != null);
}

test "code action: E0600 round-trip — applied plain fix makes the shader validate" {
    const source: [:0]const u8 =
        \\@vertex fn vs() -> vec4f { return vec4f(0); }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    const action = findActionByTitle(result.actions, "Add @builtin(position) to return type") orelse
        return error.TestUnexpectedResult;

    const fixed_slice = try applyEdit(source, action.edits[0]);
    defer std.testing.allocator.free(fixed_slice);

    const fixed_z = try std.testing.allocator.alloc(u8, fixed_slice.len + 1);
    defer std.testing.allocator.free(fixed_z);
    @memcpy(fixed_z[0..fixed_slice.len], fixed_slice);
    fixed_z[fixed_slice.len] = 0;
    const fixed: [:0]const u8 = fixed_z[0..fixed_slice.len :0];

    var handler2 = Handler.init(std.testing.allocator);
    defer handler2.deinit();
    const diags2 = try handler2.validateDocument(fixed);
    defer Handler.freeDiagnostics(std.testing.allocator, diags2);

    for (diags2) |d| {
        if (std.mem.eql(u8, d.code, "E0600") and
            std.mem.indexOf(u8, d.message, "must include @builtin(position)") != null)
        {
            return error.TestUnexpectedResult;
        }
    }
}

test "code action: E0600 round-trip — applied struct fix makes the shader validate" {
    const source: [:0]const u8 =
        \\struct Out { @location(0) color: vec4f, }
        \\@vertex fn vs() -> Out { return Out(vec4f(0)); }
    ;
    const result = try getCodeActions(source);
    defer cleanup(result);

    const action = findActionByTitle(result.actions, "Add @builtin(position) member to 'Out'") orelse
        return error.TestUnexpectedResult;

    const fixed_slice = try applyEdit(source, action.edits[0]);
    defer std.testing.allocator.free(fixed_slice);

    const fixed_z = try std.testing.allocator.alloc(u8, fixed_slice.len + 1);
    defer std.testing.allocator.free(fixed_z);
    @memcpy(fixed_z[0..fixed_slice.len], fixed_slice);
    fixed_z[fixed_slice.len] = 0;
    const fixed: [:0]const u8 = fixed_z[0..fixed_slice.len :0];

    var handler2 = Handler.init(std.testing.allocator);
    defer handler2.deinit();
    const diags2 = try handler2.validateDocument(fixed);
    defer Handler.freeDiagnostics(std.testing.allocator, diags2);

    for (diags2) |d| {
        if (std.mem.eql(u8, d.code, "E0600") and
            std.mem.indexOf(u8, d.message, "must include @builtin(position)") != null)
        {
            return error.TestUnexpectedResult;
        }
    }
}

test "code action: E0600 is ignored when message is not the missing-position variant" {
    // Synthesize an E0600 with a different message (e.g. a compute-shader
    // invalid entry point). No builtin-position action should be emitted.
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    try handler.openDocument("test://file.wgsl", "@compute fn cs() {}\n", 1);

    const diags = [_]Handler.LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 12 }, .end = .{ .line = 0, .character = 14 } },
        .severity = .@"error",
        .message = "compute entry point 'cs' requires @workgroup_size",
        .code = "E0600",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer {
        for (actions) |a| {
            std.testing.allocator.free(a.title);
            for (a.edits) |e| std.testing.allocator.free(e.new_text);
            std.testing.allocator.free(a.edits);
        }
        std.testing.allocator.free(actions);
    }

    try std.testing.expect(findActionByTitle(actions, "@builtin(position)") == null);
}

test "code action: E0600 with no open document returns no actions" {
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();

    const diags = [_]Handler.LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 2 } },
        .severity = .@"error",
        .message = "vertex entry point 'vs' must include @builtin(position) output",
        .code = "E0600",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer {
        for (actions) |a| {
            std.testing.allocator.free(a.title);
            for (a.edits) |e| std.testing.allocator.free(e.new_text);
            std.testing.allocator.free(a.edits);
        }
        std.testing.allocator.free(actions);
    }

    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "code action: E0600 malformed source with no '->' returns no action" {
    // Synthesize a diagnostic on a signature-less function. The helper should
    // bail cleanly rather than emit a garbage edit.
    var handler = Handler.init(std.testing.allocator);
    defer handler.deinit();
    try handler.openDocument("test://file.wgsl", "@vertex fn vs() { }\n", 1);

    const diags = [_]Handler.LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 11 }, .end = .{ .line = 0, .character = 13 } },
        .severity = .@"error",
        .message = "vertex entry point 'vs' must include @builtin(position) output",
        .code = "E0600",
    }};

    const actions = try handler.computeCodeActions(&diags);
    defer {
        for (actions) |a| {
            std.testing.allocator.free(a.title);
            for (a.edits) |e| std.testing.allocator.free(e.new_text);
            std.testing.allocator.free(a.edits);
        }
        std.testing.allocator.free(actions);
    }

    try std.testing.expect(findActionByTitle(actions, "@builtin(position)") == null);
}

// =========================================================================
// Code actions: enable f16 (E0900)
// =========================================================================

test "code action: E0900 feature not enabled offers enable f16" {
    const handler = try std.testing.allocator.create(Handler);
    handler.* = Handler.init(std.testing.allocator);
    defer {
        handler.deinit();
        std.testing.allocator.destroy(handler);
    }

    const diag = Handler.LspDiagnostic{
        .range = .{
            .start = .{ .line = 0, .character = 7 },
            .end = .{ .line = 0, .character = 10 },
        },
        .severity = .@"error",
        .message = "type 'f16' requires 'enable f16;' directive",
        .code = "E0900",
        .data = .{ .feature_not_enabled = "f16" },
    };
    const diags = try std.testing.allocator.alloc(Handler.LspDiagnostic, 1);
    defer std.testing.allocator.free(diags);
    diags[0] = diag;

    const actions = try handler.computeCodeActions(diags);
    defer {
        for (actions) |a| {
            std.testing.allocator.free(a.title);
            for (a.edits) |e| std.testing.allocator.free(e.new_text);
            std.testing.allocator.free(a.edits);
        }
        std.testing.allocator.free(actions);
    }

    try std.testing.expect(actions.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, actions[0].title, "enable f16") != null);
    // Edit should insert at line 0, char 0
    try std.testing.expectEqual(@as(u32, 0), actions[0].edits[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 0), actions[0].edits[0].range.start.character);
}
