//! Native pngine build-boundary test (pngine-shaders phase 01, Task 1).
//!
//! Compiled only into the native test graph — the one graph where the
//! build resolves the SJON dependency, so `pngine_support` is true. The
//! project-free graphs (`wasm`, `lib`, `lsp-wasm`, and every
//! `-Dlsp=false` build) carry `pngine_support=false`, never import SJON,
//! and prove it at compile time in `tests/pngine_project_free_check.zig`,
//! which `build.zig` attaches to the `wasm`, `lib` and `lsp-wasm` steps.

const std = @import("std");
const wgslender = @import("wgslender");
const sjon = @import("sjon");

/// Corpus-shaped fragment fixture — same form family as
/// `clock/program.sjon`'s `(wgsl :name sceneLib :file "scene_lib.wgsl")`.
const fixture = "(wgsl :name f :file \"a.wgsl\")";

test "pngine module compiled in on the native graph" {
    try std.testing.expect(wgslender.Pngine != void);
}

test "wgsl form head, name, and file readable through SJON's public AST readers" {
    const a = std.testing.allocator;
    var tree = try sjon.parse(a, fixture);
    defer tree.deinit();

    try std.testing.expect(!tree.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), tree.root.len);

    const form = tree.root[0];
    try std.testing.expectEqual(.form, tree.tagOf(form));

    // Form head through the public reader; the head span sits inside the
    // form span (`spanOf` is public too).
    const header = tree.formHeader(form);
    try std.testing.expectEqualStrings("wgsl", header.head);
    try std.testing.expect(header.namespace == null);
    const form_span = tree.spanOf(form);
    try std.testing.expect(form_span.start <= header.head_span.start);
    try std.testing.expect(header.head_span.end <= form_span.end);

    // `:name f` and `:file "a.wgsl"` arrive as kvpair children; their
    // values read through symbolText / stringText.
    try std.testing.expectEqual(@as(usize, 2), header.children.len);
    var saw_name = false;
    var saw_file = false;
    for (header.children) |child| {
        try std.testing.expectEqual(.kvpair, tree.tagOf(child));
        const kv = tree.kvpairHeader(child);
        if (std.mem.eql(u8, kv.key, "name")) {
            try std.testing.expectEqual(.symbol, tree.tagOf(kv.value));
            try std.testing.expectEqualStrings("f", tree.symbolText(kv.value));
            saw_name = true;
        } else if (std.mem.eql(u8, kv.key, "file")) {
            try std.testing.expectEqual(.string, tree.tagOf(kv.value));
            try std.testing.expectEqualStrings("a.wgsl", tree.stringText(kv.value));
            saw_file = true;
        } else {
            return error.UnexpectedFixtureKey;
        }
    }
    try std.testing.expect(saw_name);
    try std.testing.expect(saw_file);
}
