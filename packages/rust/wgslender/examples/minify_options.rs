//! What each minification option costs, on a shader where it has work to do.
//!
//! ```text
//! cargo run -p wgslender --example minify_options
//! ```
//!
//! `MinifyOptions::default()` is not "every option off". Every field is an
//! override that stays absent until you set it, so the default means
//! *wgslender's own defaults* — `minify_with(source, &MinifyOptions::default())`
//! is `minify(source)`, byte for byte. Each row below is one override against
//! that baseline.
//!
//! The shader matters as much as the option, which is why two of them are
//! measured. An override can only cost what it has work to do: turning tree
//! shaking off costs nothing on a shader with no dead code, and a table that
//! printed a zero there would be describing the fixture rather than the option.
//! The shader below has three helpers nothing calls and two sibling scopes;
//! `demo.wgsl`, the package's own fixture, has neither.

use core::cmp::Ordering;
use core::fmt::Write as _;

use wgslender::{Error, MinifyOptions, minify_and_reflect, minify_with};

/// Three uncalled helpers, two sibling scopes, and two bindings a host program
/// would bind against by name.
const SHADER: &str = "\
struct Params {
    resolution: vec2f,
    time: f32,
    frame: u32,
}

@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var<storage, read_write> data: array<vec4f>;

fn luminance(color: vec3f) -> f32 {
    return dot(color, vec3f(0.2126, 0.7152, 0.0722));
}

fn unused_gamma(color: vec3f) -> vec3f {
    return pow(color, vec3f(1.0 / 2.2));
}

fn unused_saturation(color: vec3f, amount: f32) -> vec3f {
    let grey = vec3f(dot(color, vec3f(0.3333)));
    return mix(grey, color, amount);
}

fn unused_hash(seed: u32) -> f32 {
    var state = seed * 747796405u + 2891336453u;
    state = ((state >> 16u) ^ state) * 277803737u;
    return f32((state >> 22u) ^ state) / 4294967295.0;
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) id: vec3u) {
    let uv = vec2f(id.xy) / params.resolution;
    let index = id.y * u32(params.resolution.x) + id.x;
    if (uv.x < 0.5) {
        let shade = luminance(vec3f(uv, params.time));
        let tint = vec4f(shade, shade * 0.5, 1.0 - shade, 1.0);
        data[index] = tint;
    } else {
        let level = luminance(vec3f(uv.yx, f32(params.frame)));
        let color = vec4f(1.0 - level, level, level * 0.25, 1.0);
        data[index] = color;
    }
}
";

/// The same fixture the other examples use: everything in it is reachable, and
/// the `tree_shaking` row is a tie because of that.
const DEMO: &str = include_str!("../tests/fixtures/demo.wgsl");

fn main() -> Result<(), Error> {
    one_row_per_option()?;
    names()?;
    the_compression_pair()
}

/// Every override, priced against the default on both shaders.
fn one_row_per_option() -> Result<(), Error> {
    heading("1. one row per option");

    let baseline = minify_with(SHADER, &MinifyOptions::default())?.len();
    let demo_baseline = minify_with(DEMO, &MinifyOptions::default())?.len();

    println!("{:<37}{:>18}{:>18}", "", "this shader", "demo.wgsl");
    println!("{:<37}{:>18}{:>18}", "source", SHADER.len(), DEMO.len());
    println!("{:<37}{baseline:>18}{demo_baseline:>18}", "default()");

    for (label, options) in overrides() {
        let bytes = minify_with(SHADER, &options)?.len();
        let demo_bytes = minify_with(DEMO, &options)?.len();
        println!(
            "{label:<37}{:>18}{:>18}",
            priced(bytes, baseline),
            priced(demo_bytes, demo_baseline),
        );
    }

    println!(
        "\nFour of those rows are worth reading twice.\n\
         \n\
         `tree_shaking(false)` is the most expensive override on the left and free\n\
         on the right, because the price of keeping dead code is however much dead\n\
         code there is, and `demo.wgsl` has none. `minify_whitespace(false)` still\n\
         renames everything — it is the setting for reading the output rather than\n\
         for shipping it. `minify_syntax(false)` is the small one: it spells `0.5`\n\
         where the default writes `.5`. And the last row is a tie on both shaders,\n\
         which section 3 is about."
    );
    Ok(())
}

/// The three overrides that decide which names survive, and what the smallest
/// of them costs elsewhere.
fn names() -> Result<(), Error> {
    heading("2. the names a host program binds against");

    let plain = minify_and_reflect(SHADER, &MinifyOptions::default())?;
    let mangled = minify_and_reflect(
        SHADER,
        &MinifyOptions::default().mangle_external_bindings(true),
    )?;

    println!(
        "{:<26}{:<12}mangle_external_bindings(true)",
        "binding", "default()"
    );
    for (before, after) in plain
        .reflection
        .bindings
        .iter()
        .zip(&mangled.reflection.bindings)
    {
        let slot = format!("@group({}) @binding({})", before.group, before.binding);
        println!("{slot:<26}{:<12}{}", before.name_mapped, after.name_mapped);
    }
    println!(
        "{:<26}{:<12}{}",
        "minified bytes", plain.minified_size, mangled.minified_size
    );

    println!(
        "\nThat is the smallest output in this example and the only one that changes\n\
         the shader's API. It is safe for a host program that reads `name_mapped`\n\
         out of the reflection — which is the column above, and what `wgsl_module!`\n\
         generates from — and fatal for one that passes the string `\"params\"` to\n\
         `createBindGroup`. The default leaves those two names alone for exactly\n\
         that reason."
    );

    println!("\nthe other two, and the name each one kept:");
    for (label, options, name) in [
        (
            "keep_names([\"luminance\"])",
            MinifyOptions::default().keep_names(["luminance"]),
            "luminance",
        ),
        (
            "preserve_uniform_struct_types(true)",
            MinifyOptions::default().preserve_uniform_struct_types(true),
            "Params",
        ),
    ] {
        let minified = minify_with(SHADER, &options)?;
        println!(
            "  {label:<38}{}",
            excerpt(&minified, name).unwrap_or_else(|| format!("{name} was renamed away")),
        );
    }

    println!(
        "\n`keep_names` is the general form and takes any identifier; the struct one\n\
         is worth its own flag because a renamed uniform block breaks anything\n\
         matching on the type name rather than on the binding."
    );
    Ok(())
}

/// The pair that leaves the byte count where it found it.
fn the_compression_pair() -> Result<(), Error> {
    heading("3. the two options that are not about size");

    println!("{:<24}{:>22}{:>24}", "", "minified bytes", "distinct names");
    println!(
        "{:<24}{:>10}{:>12}{:>12}{:>12}",
        "shader", "default", "sort+scope", "default", "sort+scope"
    );

    // Generated rather than a fixture, because the effect is a function of how
    // many scopes there are, and this walks that curve.
    let mut rows = vec![("this shader".to_owned(), SHADER.to_owned())];
    for scopes in [4, 12, 32] {
        rows.push((format!("{scopes} sibling scopes"), sibling_scopes(scopes)));
    }

    for (label, source) in &rows {
        let plain = minify_with(source, &MinifyOptions::default())?;
        let paired = minify_with(source, &compressible())?;
        println!(
            "{label:<24}{:>10}{:>12}{:>12}{:>12}",
            plain.len(),
            paired.len(),
            alphabet(&plain),
            alphabet(&paired),
        );
    }

    println!(
        "\nThe last two columns are how many distinct word-shaped tokens each output\n\
         uses — a crude count rather than a lexer, but it counts the right thing.\n\
         `sort_declarations` groups similar declarations together and\n\
         `scope_local_rename` hands the same short names out again in scopes that\n\
         cannot see each other, so the text says less with fewer different words.\n\
         \n\
         Neither is a size optimisation, and the top two rows are ties to the byte.\n\
         The second of them is the whole point: the same shader at exactly the same\n\
         length, with a quarter of its distinct words gone. Only the alphabet moved.\n\
         \n\
         DEFLATE and the byte-pair encoder behind `compile` are both paid in\n\
         repetition rather than in length, which is why `compile` turns the pair on\n\
         regardless of the options it is handed, and why `include_wgsl_compressed!`\n\
         defaults them on. The README's figure for what that is worth after gzip is\n\
         5–29%. Past enough scopes the raw count moves as well — the bottom row is\n\
         smaller before anything is compressed at all — and it keeps moving: on a\n\
         28 855-byte shader from this repository, which lives outside the published\n\
         package and so cannot be run here, the pair minifies to 7 722 bytes against\n\
         the default's 8 266."
    );
    Ok(())
}

/// Every override this example prices, in the order the option struct declares
/// them, with `keep_names` beside the flags it generalises.
fn overrides() -> Vec<(&'static str, MinifyOptions)> {
    vec![
        (
            "minify_whitespace(false)",
            MinifyOptions::default().minify_whitespace(false),
        ),
        (
            "minify_identifiers(false)",
            MinifyOptions::default().minify_identifiers(false),
        ),
        (
            "minify_syntax(false)",
            MinifyOptions::default().minify_syntax(false),
        ),
        (
            "tree_shaking(false)",
            MinifyOptions::default().tree_shaking(false),
        ),
        (
            "mangle_external_bindings(true)",
            MinifyOptions::default().mangle_external_bindings(true),
        ),
        (
            "preserve_uniform_struct_types(true)",
            MinifyOptions::default().preserve_uniform_struct_types(true),
        ),
        (
            "keep_names([\"luminance\"])",
            MinifyOptions::default().keep_names(["luminance"]),
        ),
        ("sort_declarations + scope_local_rename", compressible()),
    ]
}

/// The two overrides that exist for the compressor rather than for the reader.
fn compressible() -> MinifyOptions {
    MinifyOptions::default()
        .sort_declarations(true)
        .scope_local_rename(true)
}

/// A shader whose size is mostly scopes: `count` helpers with the same shape,
/// each called once.
fn sibling_scopes(count: usize) -> String {
    let mut source =
        String::from("@group(0) @binding(0) var<storage, read_write> data: array<f32>;\n\n");
    // The discarded `Result`s below belong to `fmt::Write`, not to anything that
    // happens here: writing into a `String` has no failure to report.
    for n in 0..count {
        let _ = write!(
            source,
            "fn stage_{n}(value: f32) -> f32 {{\n    \
             let scaled = value * {n}.5;\n    \
             let folded = scaled - floor(scaled);\n    \
             let mixed = mix(folded, scaled, 0.25);\n    \
             return mixed + {n}.0;\n\
             }}\n\n"
        );
    }
    source.push_str(
        "@compute @workgroup_size(64)\n\
         fn main(@builtin(global_invocation_id) id: vec3u) {\n\
         \x20   var value = data[id.x];\n",
    );
    for n in 0..count {
        let _ = writeln!(source, "    value = stage_{n}(value);");
    }
    source.push_str("    data[id.x] = value;\n}\n");
    source
}

/// How many distinct word-shaped tokens the text uses — identifiers, keywords
/// and numbers alike.
///
/// Not a lexer, and it does not need to be: what matters is the size of the
/// alphabet a compressor has to build a dictionary over, and every one of those
/// counts towards it.
fn alphabet(text: &str) -> usize {
    let mut words: Vec<&str> = Vec::new();
    let mut start = None;
    for (index, byte) in text.bytes().enumerate() {
        let in_a_word = byte.is_ascii_alphanumeric() || byte == b'_';
        match (in_a_word, start) {
            (true, None) => start = Some(index),
            (false, Some(from)) => {
                words.extend(text.get(from..index));
                start = None;
            }
            _ => {}
        }
    }
    words.extend(start.and_then(|from| text.get(from..)));
    words.sort_unstable();
    words.dedup();
    words.len()
}

/// A size and what it cost against the baseline, so a row can be read without
/// subtracting anything.
fn priced(bytes: usize, baseline: usize) -> String {
    match bytes.cmp(&baseline) {
        Ordering::Greater => format!("{bytes} (+{})", bytes - baseline),
        Ordering::Less => format!("{bytes} (-{})", baseline - bytes),
        Ordering::Equal => format!("{bytes} (same)"),
    }
}

/// The neighbourhood of `name` in the minified text, as evidence it survived.
fn excerpt(minified: &str, name: &str) -> Option<String> {
    let at = minified.find(name)?;
    let from = minified[..at]
        .rfind(['{', ';', '}'])
        .map_or(0, |mark| mark + 1);
    let rest = minified.get(at..)?;
    let to = at + rest.find(['(', ';', '{']).unwrap_or(rest.len());
    Some(format!("…{}…", minified.get(from..to)?))
}

/// A section rule, so three sections of output read as three sections.
fn heading(title: &str) {
    println!("\n{title}");
    println!("{}", "-".repeat(title.chars().count()));
}
