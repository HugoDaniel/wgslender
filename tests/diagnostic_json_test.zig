//! `Diagnostic.entryToJson` / `appendJsonEscaped` must emit valid JSON for
//! *every* byte a message can carry. JSON forbids raw control characters
//! (U+0000–U+001F) inside string literals, so those bytes must be escaped —
//! the shorthand forms (`\n`, `\r`, `\t`) where they exist, and the
//! `\u00XX` long form for the rest. A validator message that quotes a byte
//! of malformed source, or an LSP hover carrying an odd control byte, must
//! not produce a payload that fails to parse on the other end.
//!
//! The gate is `std.json.parseFromSlice` succeeding on the serialized
//! object — that is exactly what every JSON consumer (editors, `--format
//! json`, the npm wrapper) does.

const std = @import("std");
const wgslender = @import("wgslender");
const Diagnostic = wgslender.Diagnostic;

const Case = struct {
    name: []const u8,
    message: []const u8,
    /// Escape sequence that must appear in the raw serialized output.
    must_contain: []const u8,
    /// A sequence that must NOT appear — guards the shorthand-preferring
    /// cases against being over-escaped into their `\u00XX` long form.
    must_not_contain: ?[]const u8 = null,
};

const cases = [_]Case{
    .{ .name = "control 0x01", .message = "bad\x01char", .must_contain = "\\u0001" },
    .{ .name = "null 0x00", .message = "a\x00b", .must_contain = "\\u0000" },
    .{ .name = "unit separator 0x1f", .message = "x\x1fy", .must_contain = "\\u001f" },
    .{ .name = "escape 0x1b", .message = "\x1b[0m", .must_contain = "\\u001b" },
    // Bytes with an established shorthand keep it — don't regress to \u00XX.
    .{ .name = "newline keeps shorthand", .message = "a\nb", .must_contain = "\\n", .must_not_contain = "\\u000a" },
    .{ .name = "carriage return keeps shorthand", .message = "a\rb", .must_contain = "\\r", .must_not_contain = "\\u000d" },
    .{ .name = "tab keeps shorthand", .message = "a\tb", .must_contain = "\\t", .must_not_contain = "\\u0009" },
    // Structural bytes stay escaped as before.
    .{ .name = "quote", .message = "a\"b", .must_contain = "\\\"" },
    .{ .name = "backslash", .message = "a\\b", .must_contain = "\\\\" },
};

test "entryToJson: control bytes are escaped and the payload parses under std.json" {
    const gpa = std.testing.allocator;
    for (cases) |c| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        const entry = Diagnostic.Entry{ .message = c.message };
        try Diagnostic.entryToJson(&buf, gpa, &entry);

        // 1. The serialized object must be valid JSON. A raw control byte
        //    inside the "message" string makes std.json reject it — the RED.
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, buf.items, .{}) catch |err| {
            std.debug.print(
                "case '{s}': entryToJson output is not valid JSON ({s})\n  output: {s}\n",
                .{ c.name, @errorName(err), buf.items },
            );
            return err;
        };
        defer parsed.deinit();

        // 2. Round-trip fidelity: the decoded message equals the input bytes.
        const decoded = parsed.value.object.get("message").?.string;
        try std.testing.expectEqualStrings(c.message, decoded);

        // 3. The expected escape form is present ...
        if (std.mem.indexOf(u8, buf.items, c.must_contain) == null) {
            std.debug.print("case '{s}': missing {s} in output: {s}\n", .{ c.name, c.must_contain, buf.items });
            return error.MissingEscape;
        }
        // ... and shorthand cases are not over-escaped.
        if (c.must_not_contain) |bad| {
            if (std.mem.indexOf(u8, buf.items, bad) != null) {
                std.debug.print("case '{s}': over-escaped, found {s} in output: {s}\n", .{ c.name, bad, buf.items });
                return error.OverEscaped;
            }
        }
    }
}
