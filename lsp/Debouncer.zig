//! Idle-debounce bookkeeping for the LSP native timer (Phase 7).
//!
//! Pure data structure: tracks "fire X at time Y" entries keyed by URI.
//! No threads, no IO — the native server's timer thread will own a
//! `Debouncer` and call `popDue` on every tick to learn which URIs to
//! refresh; the WASM transport relies on a JS-side debounce instead and
//! does not need this struct.
//!
//! Re-arming an already-pending URI replaces its deadline (the "settings
//! change resets debounce timer" semantic from master plan §10.1) — the
//! struct never accumulates duplicate entries for the same key.
//!
//! Time is parameterised: callers pass `now_ms` (typically
//! `std.time.milliTimestamp()`) into `popDue`. That keeps the struct
//! testable without sleeps.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Debouncer = @This();

gpa: Allocator,
/// Deadlines keyed by document URI. Both keys and values are owned —
/// keys are dup'd on `arm`, freed on `clear` / `popDue` / `deinit`. The
/// HashMap is small (at most one entry per open document), so a linear
/// scan in `popDue` is fine.
deadlines: std.StringHashMapUnmanaged(i64),

pub fn init(gpa: Allocator) Debouncer {
    return .{ .gpa = gpa, .deadlines = .empty };
}

pub fn deinit(self: *Debouncer) void {
    var it = self.deadlines.iterator();
    while (it.next()) |entry| self.gpa.free(entry.key_ptr.*);
    self.deadlines.deinit(self.gpa);
}

/// Schedule (or replace) the firing time for `uri`. The first arm dups
/// the URI into the debouncer's allocator; subsequent arms reuse the
/// existing key and only update the deadline value, so `arm` is cheap on
/// the hot didChange path.
pub fn arm(self: *Debouncer, uri: []const u8, deadline_ms: i64) Allocator.Error!void {
    const gop = try self.deadlines.getOrPut(self.gpa, uri);
    if (!gop.found_existing) {
        const key_dup = self.gpa.dupe(u8, uri) catch |err| {
            // Backing-out an half-applied getOrPut keeps the map honest.
            std.debug.assert(self.deadlines.remove(uri));
            return err;
        };
        gop.key_ptr.* = key_dup;
    }
    gop.value_ptr.* = deadline_ms;
}

/// Drop any pending entry for `uri`. No-op when none. Called from
/// `closeDocument` so a closed-doc deadline never fires.
pub fn clear(self: *Debouncer, uri: []const u8) void {
    const entry = self.deadlines.fetchRemove(uri) orelse return;
    self.gpa.free(entry.key);
}

/// Earliest deadline still pending, or `null` when the debouncer is
/// empty. The native timer thread uses this to bound its sleep time:
/// `sleep(min(tick_ms, nextDeadline - now))` so it doesn't oversleep
/// past a deadline.
pub fn nextDeadline(self: *const Debouncer) ?i64 {
    var it = self.deadlines.iterator();
    var best: ?i64 = null;
    while (it.next()) |entry| {
        const d = entry.value_ptr.*;
        if (best == null or d < best.?) best = d;
    }
    return best;
}

/// Pop and return one URI whose deadline is `<= now_ms`. Returns `null`
/// when nothing is due. The returned slice is owned by the caller — free
/// with `gpa` once done with it. Callers loop until they get `null` to
/// drain a tick.
///
/// The popped order is unspecified when multiple URIs are due
/// simultaneously, but every due entry is returned exactly once across
/// repeated calls within the same tick.
pub fn popDue(self: *Debouncer, now_ms: i64) ?[]u8 {
    var it = self.deadlines.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* <= now_ms) {
            const key = entry.key_ptr.*;
            std.debug.assert(self.deadlines.remove(key));
            return @constCast(key);
        }
    }
    return null;
}

// =========================================================================
// Tests
// =========================================================================

test "Debouncer: arm + popDue returns when deadline reached" {
    var d: Debouncer = .init(std.testing.allocator);
    defer d.deinit();

    try d.arm("file:///a.wgsl", 300);

    // Before deadline → nothing due.
    try std.testing.expect(d.popDue(0) == null);
    try std.testing.expect(d.popDue(299) == null);

    // At deadline → fires once.
    const fired = d.popDue(300) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(fired);
    try std.testing.expectEqualStrings("file:///a.wgsl", fired);

    // Subsequent pop is empty.
    try std.testing.expect(d.popDue(1000) == null);
}

test "Debouncer: re-arming pushes deadline forward" {
    var d: Debouncer = .init(std.testing.allocator);
    defer d.deinit();

    try d.arm("file:///a.wgsl", 300);
    try d.arm("file:///a.wgsl", 600); // settings-change-equivalent re-arm

    // The original 300ms deadline must have been replaced — `popDue(350)`
    // should NOT fire (would, if the struct kept duplicate entries).
    try std.testing.expect(d.popDue(350) == null);

    const fired = d.popDue(650) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(fired);
    try std.testing.expectEqualStrings("file:///a.wgsl", fired);
}

test "Debouncer: clear cancels pending entry" {
    var d: Debouncer = .init(std.testing.allocator);
    defer d.deinit();

    try d.arm("file:///a.wgsl", 300);
    d.clear("file:///a.wgsl");

    try std.testing.expect(d.popDue(1000) == null);
    try std.testing.expect(d.nextDeadline() == null);
}

test "Debouncer: nextDeadline reflects the earliest pending entry" {
    var d: Debouncer = .init(std.testing.allocator);
    defer d.deinit();

    try std.testing.expect(d.nextDeadline() == null);

    try d.arm("file:///a.wgsl", 800);
    try d.arm("file:///b.wgsl", 200);
    try d.arm("file:///c.wgsl", 500);

    try std.testing.expectEqual(@as(?i64, 200), d.nextDeadline());

    // After firing the earliest, the next-earliest takes over.
    const fired = d.popDue(250) orelse return error.TestUnexpectedResult;
    std.testing.allocator.free(fired);
    try std.testing.expectEqualStrings("file:///c.wgsl", (d.deadlines.getKey("file:///c.wgsl") orelse return error.TestUnexpectedResult));
    try std.testing.expectEqual(@as(?i64, 500), d.nextDeadline());
}

test "Debouncer: drains every due URI within a tick" {
    var d: Debouncer = .init(std.testing.allocator);
    defer d.deinit();

    try d.arm("file:///a.wgsl", 100);
    try d.arm("file:///b.wgsl", 200);
    try d.arm("file:///c.wgsl", 300);

    var seen: [3]bool = .{ false, false, false };
    var loops: u32 = 0;
    while (true) : (loops += 1) {
        const fired = d.popDue(500) orelse break;
        defer std.testing.allocator.free(fired);
        if (std.mem.eql(u8, fired, "file:///a.wgsl")) seen[0] = true;
        if (std.mem.eql(u8, fired, "file:///b.wgsl")) seen[1] = true;
        if (std.mem.eql(u8, fired, "file:///c.wgsl")) seen[2] = true;
        if (loops > 10) return error.TestRunaway;
    }
    try std.testing.expect(seen[0] and seen[1] and seen[2]);
}
