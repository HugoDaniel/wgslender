//! Embedding a shader the way a size-conscious program wants it: validated and
//! minified while this example is compiled, DEFLATE-compressed into it, and
//! inflated at run time only if something asks for the text.
//!
//! ```text
//! cargo run -p wgslender --features compress --example embed_compressed
//! ```
//!
//! What a real program does with the last line is hand it to the GPU —
//! `device.create_shader_module(wgpu::ShaderModuleDescriptor {
//! source: wgpu::ShaderSource::Wgsl(SHADER.as_str().into()), .. })` — which is
//! the first and only moment the text has to exist.

/// The bytes that actually land in the binary.
///
/// A `static`, because the constructor is `const`. Any path relative to your
/// own crate root works; this one points at the package's test fixture, that
/// being the shader this package ships.
static SHADER: wgslender::CompressedWgsl =
    wgslender::include_wgsl_compressed!("tests/fixtures/demo.wgsl");

/// The same file unprocessed, so the example can show what the two compile-time
/// passes bought. A real program would not carry this.
const AS_WRITTEN: &str = include_str!("../tests/fixtures/demo.wgsl");

fn main() {
    let written = AS_WRITTEN.len();
    let minified = SHADER.len();
    let stored = SHADER.compressed_len();

    println!("as written   {written:>4} bytes");
    println!(
        "minified     {minified:>4} bytes   {}% of it",
        percent(minified, written)
    );
    println!(
        "compressed   {stored:>4} bytes   {}% — this is what ships",
        percent(stored, written)
    );
    println!();
    println!("{}", SHADER.as_str());
}

/// `part` as a whole-number percentage of `whole`, in integers: a size report
/// is not worth a rounding argument.
fn percent(part: usize, whole: usize) -> usize {
    if whole == 0 { 0 } else { part * 100 / whole }
}
