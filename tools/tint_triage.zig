//! Tint-oracle triage worklist/report tool.
//!
//! Re-walks `tests/testdata/tint/`, validates each WGSL shader, and reports
//! how our diagnostics line up with Tint's own verdict (via `tint_oracle`,
//! reading each shader's sibling `.expected.wgsl`). The golden test
//! (`tests/inference_corpus_pinning_test.zig`) *pins* these counts; this tool
//! is the human view: which shaders to open, plus a machine-readable dump.
//!
//! Usage — `zig build tint-triage -- <args>`:
//!   (no args)                            per-code fp/tp/unk summary table
//!   --code E0802 [--bucket fp|tp|unk] [--max-per-code N]
//!                                        worklist: path<TAB>line:col<TAB>message
//!   --tsv <path>                         per-shader TSV report -> <path>
//!
//! Exit is always 0 — the *gate* is the golden test; this only reports.

const std = @import("std");
const wgslender = @import("wgslender");
const tint_oracle = @import("tint_oracle");
const Verdict = tint_oracle.Verdict;
const Bucket = tint_oracle.Bucket;
const File = std.Io.File;

const corpus_dir = "tests/testdata/tint";

const usage =
    \\tint-triage — Tint-oracle conformance triage (reports only; exit 0)
    \\
    \\Usage: zig build tint-triage -- [options]
    \\  (no options)              per-code fp/tp/unk summary table
    \\  --code <CODE>             worklist for shaders emitting <CODE>
    \\  --bucket fp|tp|unk        restrict the worklist to a verdict bucket
    \\  --max-per-code <N>        cap the worklist at N rows
    \\  --tsv <path>              write a per-shader TSV report to <path>
    \\  -h, --help                show this help
    \\
;

const Args = struct {
    code: ?[]const u8 = null,
    bucket: ?Bucket = null,
    max_per_code: ?usize = null,
    tsv: ?[]const u8 = null,
    help: bool = false,
};

/// Parse the tool's argv (program name already stripped). Returns null on any
/// malformed flag so `main` can print usage and exit 0.
fn parseArgs(argv: []const []const u8) ?Args {
    var a: Args = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            a.help = true;
        } else if (std.mem.eql(u8, arg, "--code")) {
            i += 1;
            if (i >= argv.len) return null;
            a.code = argv[i];
        } else if (std.mem.eql(u8, arg, "--bucket")) {
            i += 1;
            if (i >= argv.len) return null;
            a.bucket = tint_oracle.bucketFromStr(argv[i]) orelse return null;
        } else if (std.mem.eql(u8, arg, "--max-per-code")) {
            i += 1;
            if (i >= argv.len) return null;
            a.max_per_code = std.fmt.parseInt(usize, argv[i], 10) catch return null;
        } else if (std.mem.eql(u8, arg, "--tsv")) {
            i += 1;
            if (i >= argv.len) return null;
            a.tsv = argv[i];
        } else {
            return null;
        }
    }
    return a;
}

/// Escape a TSV field: tab/newline/CR/backslash become two-char escapes so a
/// record stays on one line with a stable column count.
fn escapeTsv(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    for (s) |c| switch (c) {
        '\t' => try out.appendSlice(alloc, "\\t"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        else => try out.append(alloc, c),
    };
    return out.toOwnedSlice(alloc);
}

fn verdictName(v: Verdict) []const u8 {
    return switch (v) {
        .accepts => "accepts",
        .rejects => "rejects",
        .unknown => "unknown",
    };
}

fn makeSentinel(alloc: std.mem.Allocator, bytes: []const u8) ![:0]const u8 {
    const buf = try alloc.alloc(u8, bytes.len + 1);
    @memcpy(buf[0..bytes.len], bytes);
    buf[bytes.len] = 0;
    return buf[0..bytes.len :0];
}

/// Copy `p` with backslashes normalized to `/` (stable output on Windows).
fn normalize(alloc: std.mem.Allocator, p: []const u8) ![]u8 {
    const buf = try alloc.dupe(u8, p);
    for (buf) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return buf;
}

const Counts = struct {
    count: u32 = 0,
    fp: u32 = 0,
    tp: u32 = 0,
    unk: u32 = 0,
    fn bump(self: *Counts, b: Bucket) void {
        self.count += 1;
        switch (b) {
            .fp => self.fp += 1,
            .tp => self.tp += 1,
            .unk => self.unk += 1,
        }
    }
};

const CodeRow = struct { code: []const u8, c: Counts };
fn lessByCode(_: void, a: CodeRow, b: CodeRow) bool {
    return std.mem.lessThan(u8, a.code, b.code);
}

const WorkRow = struct { path: []const u8, line: u32, col: u32, message: []const u8 };

const Mode = union(enum) { summary, worklist: Args, tsv: []const u8 };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = arg_it.skip(); // program name
    while (arg_it.next()) |a| try argv.append(arena, a);

    const args = parseArgs(argv.items) orelse {
        try File.stderr().writeStreamingAll(io, usage);
        return;
    };
    if (args.help) {
        try File.stdout().writeStreamingAll(io, usage);
        return;
    }

    var dir = std.Io.Dir.cwd().openDir(io, corpus_dir, .{ .iterate = true }) catch {
        try File.stderr().writeStreamingAll(io, "tint-triage: corpus not found at " ++ corpus_dir ++
            " — run scripts/fetch-tint-testdata.sh\n");
        return;
    };
    defer dir.close(io);

    const mode: Mode = if (args.tsv) |p|
        .{ .tsv = p }
    else if (args.code != null)
        .{ .worklist = args }
    else
        .summary;
    try triage(arena, io, &dir, mode);
}

fn triage(arena: std.mem.Allocator, io: std.Io, dir: *std.Io.Dir, mode: Mode) !void {
    var codes: std.StringHashMapUnmanaged(Counts) = .{}; // summary
    var work: std.ArrayListUnmanaged(WorkRow) = .empty; // worklist
    var tsv: std.ArrayListUnmanaged(u8) = .empty; // tsv report
    switch (mode) {
        .tsv => try tsv.appendSlice(arena, "path\tverdict\toutcome\tdistinct_codes\tfirst_error_code\tfirst_error_message\n"),
        else => {},
    }

    // Heavy per-shader allocations get their own freeing arena so a 9k-shader
    // walk stays bounded; retained rows/counts live on the process arena.
    var sh_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer sh_arena.deinit();

    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".wgsl")) continue;
        if (std.mem.indexOf(u8, entry.path, ".expected.") != null) continue;

        _ = sh_arena.reset(.retain_capacity);
        const salloc = sh_arena.allocator();

        const bytes = entry.dir.readFileAlloc(io, entry.basename, salloc, .unlimited) catch continue;
        if (tint_oracle.containsUnsupported(bytes)) continue;

        const verdict = tint_oracle.verdictForEntry(io, entry.dir, entry.basename, salloc);
        const bucket = tint_oracle.bucketOf(verdict);

        const source = makeSentinel(salloc, bytes) catch continue;
        var result = wgslender.validateWithOptions(salloc, source, .{}) catch continue;
        defer result.deinit(salloc);
        const diags = result.diagnostics.items();

        switch (mode) {
            .summary => {
                var seen: std.StringHashMapUnmanaged(void) = .{};
                for (diags) |d| {
                    if (d.code.len == 0) continue;
                    if ((seen.getOrPut(salloc, d.code) catch continue).found_existing) continue;
                    const gop = codes.getOrPut(arena, d.code) catch continue;
                    if (!gop.found_existing) {
                        gop.key_ptr.* = arena.dupe(u8, d.code) catch continue;
                        gop.value_ptr.* = .{};
                    }
                    gop.value_ptr.bump(bucket);
                }
            },
            .worklist => |a| {
                if (a.bucket == null or a.bucket.? == bucket) {
                    for (diags) |d| {
                        if (!std.mem.eql(u8, d.code, a.code.?)) continue;
                        try work.append(arena, .{
                            .path = try normalize(arena, entry.path),
                            .line = d.range.start.line,
                            .col = d.range.start.column,
                            .message = try arena.dupe(u8, d.message),
                        });
                        break; // first hit of that code in this shader
                    }
                }
            },
            .tsv => {
                var seen: std.StringHashMapUnmanaged(void) = .{};
                var joined: std.ArrayListUnmanaged(u8) = .empty;
                var first = true;
                for (diags) |d| {
                    if (d.code.len == 0) continue;
                    if ((seen.getOrPut(salloc, d.code) catch continue).found_existing) continue;
                    if (!first) try joined.append(salloc, ',');
                    try joined.appendSlice(salloc, d.code);
                    first = false;
                }
                var fe_code: []const u8 = "";
                var fe_msg: []const u8 = "";
                for (diags) |d| {
                    if (d.severity == .@"error" and d.code.len > 0) {
                        fe_code = d.code;
                        fe_msg = d.message;
                        break;
                    }
                }
                const outcome: []const u8 = if (result.valid)
                    "accept"
                else if (fe_code.len == 0)
                    "reject"
                else
                    try std.fmt.allocPrint(salloc, "reject:{s}", .{fe_code});
                const row = try std.fmt.allocPrint(arena, "{s}\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{
                    try normalize(salloc, entry.path),
                    verdictName(verdict),
                    outcome,
                    joined.items,
                    fe_code,
                    try escapeTsv(salloc, fe_msg),
                });
                try tsv.appendSlice(arena, row);
            },
        }
    }

    switch (mode) {
        .summary => try emitSummary(arena, io, &codes),
        .worklist => |a| try emitWorklist(arena, io, work.items, a.max_per_code),
        .tsv => |p| {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = tsv.items });
            const msg = try std.fmt.allocPrint(arena, "tint-triage: wrote {s} ({d} bytes)\n", .{ p, tsv.items.len });
            try File.stdout().writeStreamingAll(io, msg);
        },
    }
}

fn emitSummary(arena: std.mem.Allocator, io: std.Io, codes: *std.StringHashMapUnmanaged(Counts)) !void {
    var rows: std.ArrayListUnmanaged(CodeRow) = .empty;
    var it = codes.iterator();
    while (it.next()) |e| try rows.append(arena, .{ .code = e.key_ptr.*, .c = e.value_ptr.* });
    std.sort.block(CodeRow, rows.items, {}, lessByCode);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(arena, "code    count     fp     tp    unk\n");
    for (rows.items) |r| {
        const line = try std.fmt.allocPrint(arena, "{s:<7} {d:>5} {d:>6} {d:>6} {d:>6}\n", .{ r.code, r.c.count, r.c.fp, r.c.tp, r.c.unk });
        try out.appendSlice(arena, line);
    }
    try File.stdout().writeStreamingAll(io, out.items);
}

fn emitWorklist(arena: std.mem.Allocator, io: std.Io, rows: []const WorkRow, cap: ?usize) !void {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const n = if (cap) |m| @min(m, rows.len) else rows.len;
    for (rows[0..n]) |r| {
        const line = try std.fmt.allocPrint(arena, "{s}\t{d}:{d}\t{s}\n", .{ r.path, r.line, r.col, r.message });
        try out.appendSlice(arena, line);
    }
    try File.stdout().writeStreamingAll(io, out.items);
}

// ---------------------------------------------------------------------------
// Tests (pure; corpus-free).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseArgs: flags, values, and rejects" {
    try testing.expect(parseArgs(&.{"--help"}).?.help);
    try testing.expect(parseArgs(&.{"-h"}).?.help);

    const w = parseArgs(&.{ "--code", "E0802", "--bucket", "fp", "--max-per-code", "5" }).?;
    try testing.expectEqualStrings("E0802", w.code.?);
    try testing.expectEqual(Bucket.fp, w.bucket.?);
    try testing.expectEqual(@as(usize, 5), w.max_per_code.?);

    try testing.expectEqualStrings("out.tsv", parseArgs(&.{ "--tsv", "out.tsv" }).?.tsv.?);

    // malformed -> null
    try testing.expect(parseArgs(&.{"--code"}) == null); // missing value
    try testing.expect(parseArgs(&.{ "--bucket", "nope" }) == null); // bad bucket
    try testing.expect(parseArgs(&.{ "--max-per-code", "x" }) == null); // non-int
    try testing.expect(parseArgs(&.{"--frobnicate"}) == null); // unknown flag
    try testing.expect(parseArgs(&.{}).?.code == null); // empty -> defaults
}

test "escapeTsv escapes control + backslash" {
    const got = try escapeTsv(testing.allocator, "a\tb\nc\r\\d");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("a\\tb\\nc\\r\\\\d", got);

    const plain = try escapeTsv(testing.allocator, "no specials");
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("no specials", plain);
}
