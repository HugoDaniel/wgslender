//! Per-root composed analysis shared by the native LSP and CLI
//! (pngine-shaders phase 05, Task 2).
//!
//! Phase 03 built this pipeline inside `lsp/handler/pngine_analysis.zig`:
//! copy the assembled text into an arena, parse it, run `Validator.analyze`,
//! merge parser diagnostics, and attach the DCE/liveness side table so the
//! lint rules can judge the whole assembled unit. The CLI needs exactly the
//! same unit analysis for composed validate/lint, so the pipeline lives
//! here rather than being copied a second time. The LSP cache still owns
//! invalidation and retained lifetime; this module owns only one
//! assembly-to-analysis conversion.

const std = @import("std");
const Diagnostic = @import("../Diagnostic.zig");
const Dce = @import("../Dce.zig");
const Lexer = @import("../Lexer.zig");
const Liveness = @import("../Liveness.zig");
const Parser = @import("../Parser.zig");
const Validator = @import("../Validator.zig");
const Assemble = @import("Assemble.zig");

const Allocator = std.mem.Allocator;

/// Parse and validate one assembled root. The result owns one arena:
/// the copied source, the AST module, the diagnostics, and the liveness
/// bit-set. Caller must `deinit` exactly once.
///
/// On a parse failure the result has `valid = false`, a `null` module, and
/// only the parser diagnostics — the same shape `Validator.analyze` produces
/// for callers that distinguish "parsed" from "recovered".
pub fn analyze(
    gpa: Allocator,
    assembled: *const Assemble.Assembled,
    options: Validator.Options,
) !Validator.AnalysisResult {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const owned_source = try alloc.allocSentinel(u8, assembled.text.len, 0);
    @memcpy(owned_source, assembled.text);

    const tokens = try Lexer.tokenize(alloc, owned_source);
    var parser = try Parser.init(alloc, owned_source, tokens);
    const module = parser.parse() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const diags = try alloc.create(Diagnostic);
            diags.* = try Diagnostic.init(alloc, owned_source);
            diags.line_offset = options.line_offset;
            Parser.mergeErrorsInto(parser.errors.items, diags, alloc);
            var failed = Validator.AnalysisResult{
                .valid = false,
                .diagnostics = diags,
            };
            failed._arena = arena;
            return failed;
        },
    };

    var analyzed = try Validator.analyze(alloc, module, options);
    Parser.mergeErrorsInto(parser.errors.items, analyzed.diagnostics, alloc);
    if (parser.errors.items.len > 0) analyzed.valid = false;

    // B.M5: liveness is a side-table owned by the analysis arena. Mirror
    // `Handler.analyzeFromParse` so composed lint can consume it unchanged.
    if (Liveness.init(alloc, module.symbols.items.len)) |liveness_init| {
        var liveness = liveness_init;
        _ = Dce.mark(alloc, module, &liveness) catch {};
        analyzed.liveness = liveness;
    } else |_| {}

    analyzed._arena = arena;
    return analyzed;
}
