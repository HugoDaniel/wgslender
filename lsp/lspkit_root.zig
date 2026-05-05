//! Public surface for the per-feature lsp-kit codec tree.
//!
//! Each per-feature module under `lsp/lspkit/` lives as a submodule of
//! this aggregator so the build graph registers a single `lspkit`
//! module. Native adapters reach helpers as `lspkit.primitives.*`,
//! `lspkit.diagnostics.*`, and so on (later PRs add the rest).

pub const primitives = @import("lspkit/primitives.zig");
pub const diagnostics = @import("lspkit/diagnostics.zig");
