//! Fuzzy "did you mean?" helpers shared by Parser and Validator.
//!
//! Levenshtein distance with early termination, plus a name-suggestion
//! function that picks the closest candidate under a distance bound.

const std = @import("std");

/// Levenshtein distance with early termination at `max`.
pub fn levenshteinBounded(a: []const u8, b: []const u8, max: usize) usize {
    if (a.len > max and b.len > max and
        (if (a.len > b.len) a.len - b.len else b.len - a.len) >= max)
        return max;
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    const width = b.len + 1;
    if (width > 128) return max;
    var row: [128]usize = undefined;
    for (0..width) |j| row[j] = j;
    for (a, 0..) |ca, i| {
        var prev = i;
        row[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            const ins = row[j + 1] + 1;
            const del = row[j] + 1;
            const sub = prev + cost;
            prev = row[j + 1];
            row[j + 1] = @min(ins, @min(del, sub));
        }
    }
    return row[b.len];
}

/// Find the closest name within Levenshtein distance `max_dist` (exclusive).
/// Returns null if no candidate is close enough.
pub fn suggestName(name: []const u8, candidates: []const []const u8, max_dist: usize) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: usize = max_dist;
    for (candidates) |candidate| {
        const d = levenshteinBounded(name, candidate, best_dist);
        if (d < best_dist) {
            best = candidate;
            best_dist = d;
        }
    }
    return best;
}

// -------------------------------------------------------------------------
// Canonical candidate lists for WGSL keyword-like identifiers
// -------------------------------------------------------------------------

pub const address_spaces = [_][]const u8{
    "function",
    "private",
    "workgroup",
    "uniform",
    "storage",
    "handle",
    "push_constant",
};

pub const access_modes = [_][]const u8{
    "read",
    "write",
    "read_write",
};
