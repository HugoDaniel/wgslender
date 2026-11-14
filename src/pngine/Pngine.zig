//! pngine shader-project support — public exports (experimental).
//!
//! Compiled into the graph only where the build resolved the SJON
//! dependency: `src/root.zig` gates this file behind
//! `build_options.pngine_support`, which `build.zig` sets true only on
//! the native CLI/LSP/tests path. The `wasm`, `lib` and `lsp-wasm`
//! graphs carry `pngine_support=false`, see `void` from `root.Pngine`,
//! and never analyze this file — so the `@import("sjon")` below exists
//! in exactly one graph family.
//!
//! Phase 01, Task 1: this is the dependency proof-of-life only. Path
//! identity, strict SJON→graph extraction, discovery, overlays and
//! invalidation arrive in Tasks 2–6 of the phase-01 plan
//! (docs/plans/pngine-shaders/01-discovery-and-graph.md).

const std = @import("std");
const build_options = @import("build_options");
const sjon = @import("sjon");

/// Whether this graph compiled pngine project support in. Mirrors the
/// build option that gated the module — a graph that did not resolve
/// SJON exposes no `Pngine` namespace at all (it is `void` there), so
/// there is no runtime "maybe" mode to ask.
pub const enabled = build_options.pngine_support;

/// Graph vocabulary shared by extraction, discovery, and the store.
pub const Types = @import("Types.zig");
/// Strict SJON → graph extraction (Task 3).
pub const Extract = @import("Extract.zig");
/// Provider-only workspace/ancestor discovery (Task 4).
pub const Discovery = @import("Discovery.zig");
/// Project store, reverse membership, overlays, and invalidation (Tasks 4–5).
pub const Store = @import("Store.zig").Store;
/// Pure fragment assembly and its line/byte tables (phase 02, Tasks 1–3).
pub const Assemble = @import("Assemble.zig");
/// Bidirectional assembled↔author byte and line mapping (phase 02, Task 3).
pub const Mapping = @import("Mapping.zig");
/// An assembled module: author text, pngine-compatible rows, byte segments.
pub const Assembled = Assemble.Assembled;
/// One assembled byte range's author origin.
pub const OriginRange = Mapping.OriginRange;
/// One author-local byte offset's assembled location.
pub const OriginOffset = Mapping.OriginOffset;
/// A located assembled line.
pub const LocatedLine = Mapping.LocatedLine;
/// A half-open byte range in either domain; the field's owner says which.
pub const ByteRange = Mapping.ByteRange;
/// A contributing part's stable identity, used by the origin mapping.
pub const OriginKey = Assemble.OriginKey;
/// A root's stable identity: program slot plus source-order part index.
pub const RootId = Assemble.RootId;

/// True when any top-level form in the SJON document `source` has head
/// `head` (e.g. "wgsl", "shader-module", "pass").
///
/// Proof-of-life for the pinned dependency: it goes through `sjon.parse`
/// and the public `Ast.Tree` readers only. Graph semantics — spans,
/// memberships, the error-severity policy for recovered trees — are
/// Task 3's extraction, not this.
///
/// - Complexity: O(n) in source bytes for the parse; the walk adds one
///   comparison per top-level form.
/// - Memory: one arena owned by the tree, freed before returning.
pub fn hasFormHead(gpa: std.mem.Allocator, source: [:0]const u8, head: []const u8) std.mem.Allocator.Error!bool {
    var tree = try sjon.parse(gpa, source);
    defer tree.deinit();
    for (tree.root) |node| {
        if (tree.tagOf(node) != .form) continue;
        if (std.mem.eql(u8, tree.formHeader(node).head, head)) return true;
    }
    return false;
}
