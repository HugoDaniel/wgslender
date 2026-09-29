//! Public Pipeline surface — exercises `Pass.custom`, the extension
//! point for downstream tooling that wants to insert work between
//! bundled passes.
//!
//! These tests also serve as documentation: they show how to attach a
//! user context, observe state populated by previous passes, and mutate
//! state in a way that is honored by later passes.

const std = @import("std");
const wgslender = @import("wgslender");
const Allocator = std.mem.Allocator;
const Ast = wgslender.Ast;
const Pipeline = wgslender.Pipeline;
const Minifier = wgslender.Minifier;
const RenamePolicy = wgslender.RenamePolicy;

// =========================================================================
// Test 1 — A custom pass sees the state populated by `mark_api_facing` and
// mutates `rename_policy` to pin extra symbols. The print pass downstream
// must honor the pinning.
// =========================================================================

const PinByNamePrefix = struct {
    prefix: []const u8,
    saw_populated_policy: bool = false,
    saw_populated_module: bool = false,
    saw_options_minify_identifiers: bool = false,
    pinned_count: u32 = 0,

    fn run(
        opaque_ctx: *anyopaque,
        state: *Pipeline.State,
        options: *const Minifier.Options,
    ) Allocator.Error!void {
        const self: *PinByNamePrefix = @ptrCast(@alignCast(opaque_ctx));
        self.saw_options_minify_identifiers = options.minify_identifiers;
        const module = state.module orelse return;
        const policy = state.rename_policy orelse return;
        self.saw_populated_module = true;
        self.saw_populated_policy = true;
        for (module.symbols.items, 0..) |sym, i| {
            if (sym.kind == .builtin) continue;
            if (!std.mem.startsWith(u8, sym.original_name, self.prefix)) continue;
            if (policy.reasons[i] != .none) continue;
            policy.reasons[i] = .keep_names;
            self.pinned_count += 1;
        }
    }
};

test "Pipeline.custom: pre-DCE marker pins extra symbols and print honors it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source: [:0]const u8 =
        \\fn keepme_one(x: f32) -> f32 { return x * 2.0; }
        \\fn keepme_two(y: f32) -> f32 { return y + 1.0; }
        \\fn other_helper(z: f32) -> f32 { return z; }
        \\@compute @workgroup_size(1) fn main() {
        \\    let a = keepme_one(1.0);
        \\    let b = keepme_two(2.0);
        \\    let c = other_helper(3.0);
        \\}
    ;

    var observer = PinByNamePrefix{ .prefix = "keepme_" };

    var state = Pipeline.State.init(a, source);
    try Pipeline.run(&state, &.{
        .tokenize,        .parse,                .mark_api_facing,
        .{ .custom = .{ .ctx = &observer, .run = PinByNamePrefix.run } },
        .dce,             .compute_usage,        .build_reserved_names,
        .init_source_map, .build_renamer,        .print,
        .finalize_source_map,
    }, .{
        .minify_identifiers = true,
        .minify_whitespace = true,
        .tree_shaking = false,
    });

    // The custom pass observed pre-populated state and read options.
    try std.testing.expect(observer.saw_populated_module);
    try std.testing.expect(observer.saw_populated_policy);
    try std.testing.expect(observer.saw_options_minify_identifiers);
    try std.testing.expectEqual(@as(u32, 2), observer.pinned_count);

    // The mutation was honored by the renamer/printer downstream:
    // pinned names survive, the unpinned helper is renamed away.
    const out = state.output orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, out, "keepme_one") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "keepme_two") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "other_helper") == null);
}

// =========================================================================
// Test 2 — A custom pass placed early (after parse, before
// mark_api_facing) sees the module but no policy yet. Demonstrates the
// non-strict pipeline contract: missing inputs do not error.
// =========================================================================

const PreMarkObserver = struct {
    saw_module: bool = false,
    saw_policy: bool = false,
    saw_renamer: bool = false,

    fn run(
        opaque_ctx: *anyopaque,
        state: *Pipeline.State,
        _: *const Minifier.Options,
    ) Allocator.Error!void {
        const self: *PreMarkObserver = @ptrCast(@alignCast(opaque_ctx));
        self.saw_module = state.module != null;
        self.saw_policy = state.rename_policy != null;
        self.saw_renamer = state.renamer != null;
    }
};

test "Pipeline.custom: ordering — early pass sees module but not later state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source: [:0]const u8 = "fn main() { let x = 1; }";

    var observer = PreMarkObserver{};

    var state = Pipeline.State.init(a, source);
    try Pipeline.run(&state, &.{
        .tokenize, .parse,
        .{ .custom = .{ .ctx = &observer, .run = PreMarkObserver.run } },
        .mark_api_facing, .dce, .compute_usage, .build_reserved_names,
        .build_renamer,   .print,
    }, .{});

    try std.testing.expect(observer.saw_module);
    try std.testing.expect(!observer.saw_policy);
    try std.testing.expect(!observer.saw_renamer);
}

// =========================================================================
// Test 3 — Two custom passes interleaved with bundled passes both run,
// and each sees the state mutations made by earlier passes.
// =========================================================================

const StageRecorder = struct {
    label: u8,
    log: *std.ArrayListUnmanaged(u8),
    arena: Allocator,
    seen_policy: bool = false,
    seen_renamer: bool = false,

    fn run(
        opaque_ctx: *anyopaque,
        state: *Pipeline.State,
        _: *const Minifier.Options,
    ) Allocator.Error!void {
        const self: *StageRecorder = @ptrCast(@alignCast(opaque_ctx));
        try self.log.append(self.arena, self.label);
        self.seen_policy = state.rename_policy != null;
        self.seen_renamer = state.renamer != null;
    }
};

test "Pipeline.custom: multiple custom passes run in order with cumulative state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source: [:0]const u8 = "fn main() { let x = 1; }";

    var log: std.ArrayListUnmanaged(u8) = .empty;
    var first = StageRecorder{ .label = 'A', .log = &log, .arena = a };
    var second = StageRecorder{ .label = 'B', .log = &log, .arena = a };

    var state = Pipeline.State.init(a, source);
    try Pipeline.run(&state, &.{
        .tokenize, .parse, .mark_api_facing,
        .{ .custom = .{ .ctx = &first, .run = StageRecorder.run } },
        .dce, .compute_usage, .build_reserved_names, .build_renamer,
        .{ .custom = .{ .ctx = &second, .run = StageRecorder.run } },
        .print,
    }, .{});

    try std.testing.expectEqualStrings("AB", log.items);
    // First custom pass sees policy (mark_api_facing ran) but not renamer.
    try std.testing.expect(first.seen_policy);
    try std.testing.expect(!first.seen_renamer);
    // Second custom pass sees both (build_renamer ran in between).
    try std.testing.expect(second.seen_policy);
    try std.testing.expect(second.seen_renamer);
}

// =========================================================================
// Test 4 — A custom pass installed without any module-producing passes
// before it observes the empty state and is a no-op (no panic, no error).
// Proves the non-strict contract: the pipeline does not enforce ordering.
// =========================================================================

const NullObserver = struct {
    invoked: bool = false,
    saw_anything: bool = false,

    fn run(
        opaque_ctx: *anyopaque,
        state: *Pipeline.State,
        _: *const Minifier.Options,
    ) Allocator.Error!void {
        const self: *NullObserver = @ptrCast(@alignCast(opaque_ctx));
        self.invoked = true;
        self.saw_anything = state.module != null or state.tokens != null or
            state.rename_policy != null or state.renamer != null;
    }
};

test "Pipeline.custom: empty state is observable, custom pass still runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var observer = NullObserver{};
    var state = Pipeline.State.init(a, "");
    try Pipeline.run(&state, &.{
        .{ .custom = .{ .ctx = &observer, .run = NullObserver.run } },
    }, .{});

    try std.testing.expect(observer.invoked);
    try std.testing.expect(!observer.saw_anything);
}

// =========================================================================
// Test 5 — A pipeline that asks for scope-local renaming but omits the
// `build_reserved_names` pass must still print. The reserved set is a pure
// function of the arena and `keep_names`, so the print pass derives it on
// demand and produces exactly the bytes of the canonical pass list.
// =========================================================================

test "Pipeline.custom: scope-local print derives reserved names when the pass is omitted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source: [:0]const u8 =
        \\fn sum_to(n: i32) -> i32 {
        \\    var acc = 0;
        \\    for (var i = 0; i < n; i = i + 1) {
        \\        acc = acc + i;
        \\    }
        \\    return acc;
        \\}
        \\@compute @workgroup_size(1) fn main() {
        \\    let s = sum_to(4);
        \\}
    ;

    const options: Minifier.Options = .{
        .minify_identifiers = true,
        .scope_local_rename = true,
    };

    // Same shader and options; only `.build_reserved_names` is missing.
    var without = Pipeline.State.init(a, source);
    try Pipeline.run(&without, &.{
        .tokenize, .parse, .mark_api_facing, .dce, .compute_usage,
        .build_renamer, .print,
    }, options);

    var with = Pipeline.State.init(a, source);
    try Pipeline.run(&with, &.{
        .tokenize, .parse, .mark_api_facing, .dce, .compute_usage,
        .build_reserved_names, .build_renamer, .print,
    }, options);

    const out_with = with.output orelse return error.TestUnexpectedResult;
    const out_without = without.output orelse return error.TestUnexpectedResult;
    try std.testing.expect(out_without.len > 0);
    try std.testing.expectEqualStrings(out_with, out_without);
}
