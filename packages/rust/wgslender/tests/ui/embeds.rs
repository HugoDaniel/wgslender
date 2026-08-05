//! The shape every other case in this directory is a deviation from: a shader
//! that exists and type-checks, embedded as a constant.
//!
//! The path is a demonstration of the macro's own rule rather than an accident.
//! trybuild compiles these files as a generated package under
//! `target/tests/trybuild/`, so `CARGO_MANIFEST_DIR` — the only anchor a
//! proc-macro has — is that generated package, and reaching this crate's
//! fixtures means climbing back out of it.

const SHADER: &str = wgslender::include_wgsl!("../../../../wgslender/tests/fixtures/demo.wgsl");

fn main() {
    assert!(SHADER.contains("@compute"));
}
