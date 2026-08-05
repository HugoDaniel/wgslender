//! Fixtures shared by the integration tests.
//!
//! Every test binary compiles this module separately and uses a subset of it,
//! so unused items here are expected rather than dead.
#![allow(dead_code)]

/// Four binding kinds, a struct, a helper function and one compute entry point.
pub(crate) const DEMO: &str = include_str!("../fixtures/demo.wgsl");

/// Type-checks against nothing: `undeclared_variable` is never declared.
pub(crate) const INVALID: &str = include_str!("../fixtures/invalid.wgsl");

/// Valid, but trips two warning-severity diagnostics.
pub(crate) const WARNING: &str = include_str!("../fixtures/warning.wgsl");

/// Not WGSL at all — the parser bails on it.
pub(crate) const UNPARSEABLE: &str = "fn main( { let ; }";
