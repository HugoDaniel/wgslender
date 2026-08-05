//! A path that does not resolve.
//!
//! The message has to say where the macro looked, because the answer is
//! surprising: paths are relative to the *package* being compiled, not to the
//! source file the macro was written in.

const SHADER: &str = wgslender::include_wgsl!("tests/fixtures/no_such_shader.wgsl");

fn main() {
    let _ = SHADER;
}
