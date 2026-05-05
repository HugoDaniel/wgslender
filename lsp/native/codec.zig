//! Per-feature lsp-kit adapters share these conversions between the
//! transport-agnostic `Handler` types and the lsp-kit JSON-shaped
//! types. Pure functions — no I/O, no allocation.

const lsp = @import("lsp");
const Handler = @import("Handler");

pub fn toLspKitPosition(p: Handler.Position) lsp.types.Position {
    return .{ .line = p.line, .character = p.character };
}

pub fn fromLspKitPosition(p: lsp.types.Position) Handler.Position {
    return .{ .line = p.line, .character = p.character };
}

pub fn toLspKitRange(r: Handler.Range) lsp.types.Range {
    return .{
        .start = toLspKitPosition(r.start),
        .end = toLspKitPosition(r.end),
    };
}

pub fn fromLspKitRange(r: lsp.types.Range) Handler.Range {
    return .{
        .start = fromLspKitPosition(r.start),
        .end = fromLspKitPosition(r.end),
    };
}

pub fn toLspKitSeverity(s: Handler.DiagnosticSeverity) lsp.types.Diagnostic.Severity {
    return switch (s) {
        .@"error" => .Error,
        .warning => .Warning,
        .information => .Information,
        .hint => .Hint,
    };
}

pub fn fromLspKitSeverity(s: ?lsp.types.Diagnostic.Severity) Handler.DiagnosticSeverity {
    return if (s) |sev| switch (sev) {
        .Error => .@"error",
        .Warning => .warning,
        .Information => .information,
        .Hint => .hint,
        _ => .information,
    } else .information;
}
