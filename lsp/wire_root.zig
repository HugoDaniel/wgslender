//! Public surface for the per-feature wire (manual-JSON) codec tree.
//!
//! Reached as a single registered `wire` module. The WASM transport
//! consumes these helpers directly (lsp-kit-free); native parity tests
//! pull the same encoders from PR3 onward to assert byte-equivalence
//! between the two transports.

pub const primitives = @import("wire/primitives.zig");
pub const diagnostics = @import("wire/diagnostics.zig");
pub const navigation = @import("wire/navigation.zig");
pub const call_hierarchy = @import("wire/call_hierarchy.zig");
