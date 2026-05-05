//! Thin shim: forwards every export to `lspkit/diagnostics.zig`.
//!
//! The implementation now lives in the shared codec tree
//! (`lsp/lspkit/diagnostics.zig`). This file is kept so the existing
//! `bridge` build alias stays valid for tests that import it by name —
//! that rewire would touch ~10 unrelated test files for no behavior
//! change.

const lspkit = @import("lspkit");

pub const BridgedDiagnostics = lspkit.diagnostics.BridgedDiagnostics;
pub const toLspKitDiagnosticsBorrowed = lspkit.diagnostics.toLspKitDiagnosticsBorrowed;
pub const toLspKitDiagnosticsOwned = lspkit.diagnostics.toLspKitDiagnosticsOwned;
pub const buildPullReport = lspkit.diagnostics.buildPullReport;
pub const quickFixHintToLspKitBorrowed = lspkit.diagnostics.quickFixHintToLspKitBorrowed;
pub const quickFixHintToLspKitOwned = lspkit.diagnostics.quickFixHintToLspKitOwned;
pub const quickFixHintFromLspKit = lspkit.diagnostics.quickFixHintFromLspKit;
