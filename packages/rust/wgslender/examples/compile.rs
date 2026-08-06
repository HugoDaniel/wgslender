//! A shader turned into a WebAssembly module that expands back into itself.
//!
//! ```text
//! cargo run -p wgslender --example compile
//! ```
//!
//! Three things, in the order a reader needs them: what the bytes are, when
//! producing them is worth it, and what makes the call fail.
//!
//! The middle one is the reason this example is longer than it looks like it
//! should be. **On a small shader the module is bigger than the minified text
//! it carries** — there is a fixed decoder to pay for — and an example that
//! showed only the happy row would sell a pessimisation. The table below shows
//! both sides of the crossover and says where it fell.
//!
//! `compile` is also one of only two calls in this crate that answer a bad
//! shader with `Err` rather than with a report full of diagnostics (`refactor`
//! is the other). Everywhere else the shader failing *is* the answer; here
//! there is nothing to hand back, and an empty module is something a caller
//! would embed by mistake.

use core::fmt::Write as _;

use wgslender::{Error, MinifyOptions, Strictness, compile, minify_with, validate};

/// The package's own fixture: a small shader, on the losing side of the
/// crossover.
const DEMO: &str = include_str!("../tests/fixtures/demo.wgsl");

/// WGSL that does not parse — an unclosed parameter list, and a `let` with
/// neither a name nor a value.
const UNPARSEABLE: &str = "fn main( { let ; }";

/// WGSL that parses and then means nothing: `undeclared_variable` is declared
/// nowhere.
const UNDECLARED: &str = "\
@compute @workgroup_size(1)
fn main() {
    let x = undeclared_variable;
}
";

fn main() -> Result<(), Error> {
    mechanics()?;
    when_it_pays()?;
    failure()
}

/// What is in the module, and what the two numbers on `CompiledShader` mean.
fn mechanics() -> Result<(), Error> {
    heading("1. what comes out");

    let compiled = compile(DEMO, &MinifyOptions::default())?;

    // The `Debug` impl is hand-written to print the length instead of 561 bytes
    // of hex, which is the only thing anyone wants from it at a breakpoint.
    println!("{compiled:?}");

    let head: Vec<String> = compiled
        .wasm
        .iter()
        .take(8)
        .map(|byte| format!("{byte:02x}"))
        .collect();
    println!("\nthe first eight bytes: {}", head.join(" "));
    println!("  00 61 73 6d   the magic number — \\0asm");
    println!("  01 00 00 00   the binary format version, 1");
    // Enforced, not just printed. The gate runs this example, and a header that
    // stopped being a wasm header would otherwise print `false` and pass.
    assert!(
        compiled.wasm.starts_with(b"\0asm"),
        "compile did not produce a wasm module"
    );
    println!(
        "  starts_with(b\"\\0asm\"): {}",
        compiled.wasm.starts_with(b"\0asm")
    );

    // What `generate` will write. `compile` forces declaration sorting and
    // scope-local renaming on top of whatever options it is given, because both
    // compress better, so those are the options to measure it with.
    let expanded = minify_with(DEMO, &compressible())?;

    println!(
        "\n{:<16}{:>6}  the source that went in",
        "original_size", compiled.original_size
    );
    println!(
        "{:<16}{:>6}  the module that came out",
        "wasm.len()",
        compiled.wasm.len()
    );
    println!(
        "{:<16}{:>6}  the minified text it will write",
        "generate()",
        expanded.len()
    );

    println!(
        "\nThe module imports nothing and exports two things: `memory`, and a\n\
         `generate() -> i32` that writes the minified WGSL at offset 0 and returns\n\
         how many bytes it wrote. That is the whole runtime:\n\
         \n\
         \x20   const {{ instance }} = await WebAssembly.instantiate(wasm);\n\
         \x20   const length = instance.exports.generate();\n\
         \x20   const wgsl = new TextDecoder().decode(\n\
         \x20       new Uint8Array(instance.exports.memory.buffer, 0, length),\n\
         \x20   );\n\
         \x20   device.createShaderModule({{ code: wgsl }});\n\
         \n\
         It is a compressed shader, not a compiled pipeline — the WGSL still goes to\n\
         `createShaderModule` on the other side. Note which number `original_size`\n\
         is: the input, not the output of `generate`, which is smaller because it is\n\
         minified."
    );
    Ok(())
}

/// The size curve, including the part of it where compiling loses.
fn when_it_pays() -> Result<(), Error> {
    heading("2. when it is worth doing");

    println!(
        "{:<28}{:>8}{:>10}{:>8}{:>12}",
        "shader", "source", "minified", "wasm", "wasm ÷ text"
    );

    // A synthetic shader rather than a fixture, so that the example can walk the
    // curve itself. Every helper is called — tree shaking would drop an uncalled
    // one, and the sizes would stop growing — and no two have the same body, so
    // that the ladder is not one long run of identical text.
    // Ordered by size, so the column of percentages is the curve.
    let mut rows = vec![
        measure("nothing but an entry point", &synthetic(0))?,
        measure("demo.wgsl", DEMO)?,
    ];
    for helpers in [4, 8, 16, 48] {
        let source = synthetic(helpers);
        rows.push(measure(&format!("{helpers} generated helpers"), &source)?);
    }

    let floor = rows.iter().map(|(_, wasm)| *wasm).min().unwrap_or_default();
    let largest_loss = rows.iter().filter(|(t, w)| w >= t).map(|(t, _)| *t).max();
    let smallest_win = rows.iter().filter(|(t, w)| w < t).map(|(t, _)| *t).min();
    let found = match (largest_loss, smallest_win) {
        (Some(loss), Some(win)) => format!("between {loss} and {win} bytes of minified text"),
        (None, Some(win)) => format!("below {win} bytes — every row here won"),
        (Some(loss), None) => format!("above {loss} bytes — no row here reached it"),
        (None, None) => "nothing was measured".to_string(),
    };
    println!(
        "\nA percentage over 100 means the module is the larger thing to ship. The\n\
         smallest module in that table is {floor} bytes, for a shader with nothing in\n\
         it: most of that is the decoder and the wasm framing, and it is paid whether\n\
         the shader is two lines or two thousand. Byte-pair encoding only starts to\n\
         outrun the fixed cost once there is enough repeated text to encode, and the\n\
         crossover in this run fell {found}.\n\
         \n\
         Take the winning rows as an upper bound rather than a forecast: even with\n\
         six different bodies, generated helpers repeat more than hand-written code\n\
         does, and repetition is what the encoder is paid in. On two real shaders\n\
         from this repository — which live outside the published package, so this\n\
         example cannot run them for you — the same curve is gentler: 4 292 bytes of\n\
         source minify to 1 116 and compile to 998 (89%), and 28 855 minify to 7 722\n\
         and compile to 4 676 (61%).\n\
         \n\
         So: a large shader — not a small one. For a small one the minified text is\n\
         the smaller artifact, and `include_wgsl!` already ships it."
    );
    Ok(())
}

/// The two ways a shader can be wrong, and the one that stops the compiler.
fn failure() -> Result<(), Error> {
    heading("3. what counts as failure");

    println!("compile({UNPARSEABLE:?})");
    match compile(UNPARSEABLE, &MinifyOptions::default()) {
        Err(Error::Compile(diagnostics)) => {
            println!(
                "  -> Err(Compile), carrying {} diagnostics:",
                diagnostics.len()
            );
            for diagnostic in &diagnostics {
                let position = format!("{}:{}", diagnostic.line, diagnostic.column);
                println!(
                    "     {position:<7}{:<7}{}",
                    // Parse errors carry no code — there is no rule that was
                    // broken, only a token that could not be read.
                    diagnostic.code.as_deref().unwrap_or("-"),
                    diagnostic.message,
                );
            }
        }
        Ok(compiled) => println!("  -> Ok, {} bytes", compiled.wasm.len()),
        // `Error` is `#[non_exhaustive]`, and anything else arriving here is the
        // call failing rather than the shader, so it goes back to the caller.
        Err(other) => return Err(other),
    }

    println!("\ncompile(a shader that parses and then means nothing)");
    let verdict = validate(UNDECLARED, Strictness::Default)?;
    let compiled = compile(UNDECLARED, &MinifyOptions::default())?;
    println!(
        "  validate -> valid: {}, errors: {}, the first of them: {}",
        verdict.valid,
        verdict.error_count,
        verdict
            .diagnostics
            .first()
            .map_or("none", |diagnostic| diagnostic.message.as_str()),
    );
    println!("  compile  -> Ok, {} bytes of wasm", compiled.wasm.len());

    println!(
        "\nOnly the parser stops `compile`. It never type-checks, so a shader that\n\
         is nonsense in every way except syntactically becomes a module that\n\
         faithfully expands back into that nonsense — and the failure surfaces at\n\
         `createShaderModule`, at run time, on someone else's machine. Call\n\
         `validate` first if the source is not already known good; `include_wgsl!`\n\
         does exactly that before it embeds anything."
    );
    Ok(())
}

/// One row of the size table: minify it, compile it, print both against the
/// source, and hand the two sizes back for the crossover.
fn measure(label: &str, source: &str) -> Result<(usize, usize), Error> {
    let minified = minify_with(source, &compressible())?.len();
    let wasm = compile(source, &MinifyOptions::default())?.wasm.len();
    println!(
        "{label:<28}{:>8}{:>10}{:>8}{:>11}%",
        source.len(),
        minified,
        wasm,
        percent(wasm, minified),
    );
    Ok((minified, wasm))
}

/// The options `compile` minifies with, so that the text in the table is the
/// text the module carries rather than a differently-minified near-miss.
fn compressible() -> MinifyOptions {
    MinifyOptions::default()
        .sort_declarations(true)
        .scope_local_rename(true)
}

/// A shader of roughly controllable size: `helpers` chained functions, each one
/// called, over one storage buffer.
fn synthetic(helpers: usize) -> String {
    // `write!` into an accumulator rather than `map(format!).collect()`: one
    // allocation instead of one per helper. Writing into a `String` cannot fail
    // — the `Result` belongs to the trait, not to anything that happens here.
    let declarations = (0..helpers).fold(String::new(), |mut out, n| {
        let _ = write!(
            out,
            "fn stage_{n}(value: f32, weight: f32) -> f32 {{\n{}\n}}\n\n",
            body(n)
        );
        out
    });
    let calls = (0..helpers).fold(String::new(), |mut out, n| {
        let _ = writeln!(out, "    value = stage_{n}(value, {}.0);", n + 1);
        out
    });

    format!(
        "@group(0) @binding(0) var<storage, read_write> data: array<f32>;\n\n\
         {declarations}\
         @compute @workgroup_size(64)\n\
         fn main(@builtin(global_invocation_id) id: vec3u) {{\n\
         \x20   var value = data[id.x];\n\
         {calls}\
         \x20   data[id.x] = value;\n\
         }}\n"
    )
}

/// One of six bodies, picked by index, so that the generated ladder is not a
/// single run of identical text for the encoder to swallow whole.
fn body(n: usize) -> String {
    match n % 6 {
        0 => format!(
            "    let scaled = value * weight + {n}.0;\n    return scaled - floor(scaled / 8.0) * 8.0;"
        ),
        1 => format!("    return mix(value, weight, fract(value * {n}.5));"),
        2 => format!(
            "    let angle = value * {n}.0 + weight;\n    return sin(angle) * cos(angle * 0.5);"
        ),
        3 => format!("    return clamp(value + weight * {n}.25, -{n}.0, {n}.0);"),
        4 => format!(
            "    let ramp = smoothstep(0.0, {n}.0, value);\n    return ramp * weight + value;"
        ),
        _ => format!(
            "    var acc = value;\n    for (var i = 0u; i < {n}u; i = i + 1u) {{\n        acc = acc * 0.5 + weight;\n    }}\n    return acc;"
        ),
    }
}

/// `part` as a whole-number percentage of `whole`, in integers: a size report is
/// not worth a rounding argument.
fn percent(part: usize, whole: usize) -> usize {
    if whole == 0 { 0 } else { part * 100 / whole }
}

/// A section rule, so three sections of output read as three sections.
fn heading(title: &str) {
    println!("\n{title}");
    println!("{}", "-".repeat(title.chars().count()));
}
