//! Builds and links the wgslender C static library.
//!
//! Resolution order:
//!
//! 1. `WGSLENDER_LIB_DIR` — link a prebuilt `libwgslender.a` from that directory
//!    and do nothing else. This is both the "I already built it" escape hatch and
//!    the fallback for targets the mapping below does not know.
//! 2. `DOCS_RS` — link a stub library whose every symbol aborts. The docs.rs
//!    sandbox has neither Zig nor a network, so the real one cannot be built
//!    there; see [`build_stub_library`] for why an empty answer is not enough.
//! 3. Otherwise build the library from Zig sources with `zig build lib`,
//!    installing it into this crate's `OUT_DIR` so that host and target builds
//!    never write to the same prefix. The sources are either vendored into this
//!    crate or the repository it lives in — see [`Sources`].

use std::env;
use std::fmt::Write as _;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Where `cargo xtask package` copies the Zig sources, relative to this crate.
const VENDOR_DIR: &str = "vendor";

/// Which tree `zig build lib` is pointed at, and therefore which of the two
/// situations this build script is in.
///
/// The distinction is worth a name because the failure modes have nothing in
/// common: a published crate whose vendored copy is missing was packaged
/// wrongly and nothing the user does will fix it, while a checkout that cannot
/// see the repository root is a checkout someone moved.
enum Sources {
    /// Copied into the crate at package time. What every published `.crate`
    /// carries, and what a consumer builds from.
    Vendored(PathBuf),
    /// The wgslender repository this crate lives in. What the workspace builds
    /// from, so that an edit to `src/*.zig` is picked up without re-vendoring.
    Repository(PathBuf),
}

impl Sources {
    fn path(&self) -> &Path {
        match self {
            Self::Vendored(path) | Self::Repository(path) => path,
        }
    }
}

fn main() {
    println!("cargo:rerun-if-env-changed=WGSLENDER_LIB_DIR");
    println!("cargo:rerun-if-env-changed=DOCS_RS");

    if let Some(lib_dir) = env::var_os("WGSLENDER_LIB_DIR") {
        emit_link_directives(Path::new(&lib_dir));
        return;
    }
    if env::var_os("DOCS_RS").is_some() {
        let out_dir = out_dir();
        build_stub_library(&out_dir);
        emit_link_directives(&out_dir);
        return;
    }

    let sources = zig_sources();
    let out_dir = out_dir();
    build_static_library(&build_root(&sources, &out_dir), &out_dir);
    emit_link_directives(&out_dir.join("lib"));
    emit_rerun_directives(&sources);
}

/// Where `zig build` is run, which for a published crate is never the crate's
/// own directory.
///
/// Zig writes `.zig-cache/` and — when the global cache already holds a
/// dependency the manifest declares — `zig-pkg/` beside the `build.zig` it is
/// given. Cargo checksums the files of an unpacked crate and fails the publish
/// verification over any that appear, so the vendored copy is staged into
/// `OUT_DIR` and built there. A repository checkout has no such rule and is
/// built where it stands, which is also what keeps `rerun-if-changed` pointed
/// at the files a developer actually edits.
fn build_root(sources: &Sources, out_dir: &Path) -> PathBuf {
    let vendored = match sources {
        Sources::Vendored(path) => path,
        Sources::Repository(path) => return path.clone(),
    };

    let staged = out_dir.join("zig-src");
    if let Err(err) = fs::remove_dir_all(&staged)
        && err.kind() != io::ErrorKind::NotFound
    {
        fail(&format!("could not clear {}: {err}", staged.display()));
    }
    if let Err(err) = copy_recursively(vendored, &staged) {
        fail(&format!(
            "could not stage the vendored sources into {}: {err}",
            staged.display()
        ));
    }
    staged
}

/// Copies a file, or a directory and everything under it.
fn copy_recursively(from: &Path, to: &Path) -> io::Result<()> {
    if from.is_dir() {
        fs::create_dir_all(to)?;
        for entry in fs::read_dir(from)? {
            let entry = entry?;
            copy_recursively(&entry.path(), &to.join(entry.file_name()))?;
        }
        return Ok(());
    }
    if let Some(parent) = to.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::copy(from, to)?;
    Ok(())
}

/// Stop the build with an actionable message.
fn fail(message: &str) -> ! {
    panic!("wgslender-sys: {message}");
}

fn out_dir() -> PathBuf {
    match env::var_os("OUT_DIR") {
        Some(dir) => PathBuf::from(dir),
        None => fail("OUT_DIR is unset, but cargo always sets it for build scripts"),
    }
}

/// The Zig sources to build: the vendored copy if this is a packaged crate,
/// otherwise the repository three levels above
/// `<root>/packages/rust/wgslender-sys`.
///
/// A tree counts only if it holds a `build.zig`, which is both what `zig build`
/// needs and the cheapest thing to check for.
fn zig_sources() -> Sources {
    let Some(manifest_dir) = env::var_os("CARGO_MANIFEST_DIR") else {
        fail("CARGO_MANIFEST_DIR is unset, but cargo always sets it for build scripts")
    };
    let manifest_dir = PathBuf::from(manifest_dir);

    let vendored = manifest_dir.join(VENDOR_DIR);
    if vendored.join("build.zig").is_file() {
        return Sources::Vendored(vendored);
    }

    let mut root = manifest_dir.clone();
    for _ in 0..3 {
        if !root.pop() {
            fail(&format!(
                "cannot reach a repository root above {}",
                manifest_dir.display()
            ));
        }
    }
    if !root.join("build.zig").is_file() {
        fail(&format!(
            "found no Zig sources: neither vendored at {} nor in a repository at {}. \
             A published crate carries its own copy, so this one was packaged without \
             `cargo xtask package`. Set WGSLENDER_LIB_DIR to a directory holding a \
             prebuilt libwgslender.a to build anyway.",
            vendored.display(),
            root.display()
        ));
    }
    Sources::Repository(root)
}

/// Zig's `-Dtarget` triple for a cargo target triple.
fn zig_target(cargo_target: &str) -> Option<&'static str> {
    Some(match cargo_target {
        "aarch64-apple-darwin" => "aarch64-macos",
        "x86_64-apple-darwin" => "x86_64-macos",
        "aarch64-unknown-linux-gnu" => "aarch64-linux-gnu",
        "x86_64-unknown-linux-gnu" => "x86_64-linux-gnu",
        "aarch64-unknown-linux-musl" => "aarch64-linux-musl",
        "x86_64-unknown-linux-musl" => "x86_64-linux-musl",
        "aarch64-pc-windows-msvc" => "aarch64-windows-msvc",
        "x86_64-pc-windows-msvc" => "x86_64-windows-msvc",
        _ => return None,
    })
}

fn build_static_library(sources: &Path, out_dir: &Path) {
    let mut zig = Command::new("zig");
    zig.current_dir(sources)
        .args([
            "build",
            "lib",
            "-Doptimize=ReleaseFast",
            // The LSP is the only part of the Zig build with a dependency, and
            // merely *asking* for a lazy one makes the build runner fetch it —
            // over the network, into `zig-pkg/` beside the sources. Neither is
            // acceptable here, and the static library does not need the LSP.
            "-Dlsp=false",
            "-p",
        ])
        .arg(out_dir);

    let target = env::var("TARGET").unwrap_or_default();
    let host = env::var("HOST").unwrap_or_default();
    if target != host {
        match zig_target(&target) {
            Some(triple) => zig.arg(format!("-Dtarget={triple}")),
            None => fail(&format!(
                "no zig target is mapped for {target}. Cross-compile libwgslender.a \
                 yourself and set WGSLENDER_LIB_DIR to the directory holding it."
            )),
        };
    }

    let output = match zig.output() {
        Ok(output) => output,
        Err(err) => fail(&format!(
            "could not run zig: {err}. Install Zig 0.16.0 (zigup 0.16.0) or set \
             WGSLENDER_LIB_DIR to a directory holding a prebuilt libwgslender.a."
        )),
    };
    if !output.status.success() {
        fail(&format!(
            "`zig build lib` failed in {}:\n{}",
            sources.display(),
            String::from_utf8_lossy(&output.stderr)
        ));
    }
}

/// Builds a `libwgslender.a` in which every FFI symbol exists and aborts.
///
/// Documenting a library needs only its dependencies' metadata, so for most of
/// this workspace docs.rs never links and emitting nothing was enough. The
/// facade re-exports a **proc macro**, and rustc *loads* a proc-macro dylib
/// rather than reading its metadata — so that dylib is linked for real, and
/// every symbol `wgslender-core` references has to resolve. Without them,
/// `docs.rs/wgslender` fails with `can't find crate for wgslender_macros`,
/// which is how this was found: after publishing 1.2.0.
///
/// Aborting bodies are safe because documenting code does not run it. If one is
/// ever reached, aborting is the correct answer — there is no engine here.
///
/// The symbol list is read out of this crate's own `src/lib.rs`, which is the
/// exact set that can be referenced, so it cannot drift from what needs to
/// resolve. Over-collecting is harmless (an unused archive member); missing one
/// is not, and reading the declarations is what makes missing one impossible.
fn build_stub_library(out_dir: &Path) {
    let Some(manifest_dir) = env::var_os("CARGO_MANIFEST_DIR") else {
        fail("CARGO_MANIFEST_DIR is unset, but cargo always sets it for build scripts")
    };
    let declarations_path = PathBuf::from(manifest_dir).join("src/lib.rs");
    let declarations = match fs::read_to_string(&declarations_path) {
        Ok(source) => source,
        Err(err) => fail(&format!(
            "could not read {} to collect the FFI symbols: {err}",
            declarations_path.display()
        )),
    };

    let symbols = ffi_symbols(&declarations);
    if symbols.is_empty() {
        fail(&format!(
            "found no `fn wgslender_*` declarations in {} — the stub would link \
             but resolve nothing",
            declarations_path.display()
        ));
    }

    let mut program =
        String::from("/* Generated by build.rs for docs.rs. */\n#include <stdlib.h>\n");
    for symbol in &symbols {
        // Writing into a String cannot fail; the Result is discarded the way
        // xtask discards it, rather than unwrapped on a path that has no error.
        let _ = writeln!(program, "void {symbol}(void) {{ abort(); }}");
    }

    let source = out_dir.join("wgslender_stub.c");
    let object = out_dir.join("wgslender_stub.o");
    let archive = out_dir.join("libwgslender.a");
    if let Err(err) = fs::write(&source, program) {
        fail(&format!("could not write {}: {err}", source.display()));
    }

    // `cc` and `ar` rather than the `cc` crate: this path runs only on docs.rs,
    // whose image has both, and a build-dependency would be downloaded and
    // compiled by every consumer to serve a case none of them are in.
    run_tool(
        &env::var("CC").unwrap_or_else(|_| "cc".into()),
        &[
            "-c".as_ref(),
            source.as_os_str(),
            "-o".as_ref(),
            object.as_os_str(),
        ],
    );
    run_tool(
        &env::var("AR").unwrap_or_else(|_| "ar".into()),
        &["crs".as_ref(), archive.as_os_str(), object.as_os_str()],
    );
}

/// Every `wgslender_*` function named in `source`.
fn ffi_symbols(source: &str) -> Vec<String> {
    const DECLARATION: &str = "fn wgslender_";
    let mut symbols: Vec<String> = Vec::new();
    let mut rest = source;

    while let Some(start) = rest.find(DECLARATION) {
        let name: String = rest[start + "fn ".len()..]
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
            .collect();
        if !symbols.contains(&name) {
            symbols.push(name);
        }
        rest = &rest[start + DECLARATION.len()..];
    }

    symbols
}

/// Runs a build tool, failing with what it printed.
fn run_tool(program: &str, args: &[&std::ffi::OsStr]) {
    let output = match Command::new(program).args(args).output() {
        Ok(output) => output,
        Err(err) => fail(&format!(
            "could not run {program}: {err}. It is needed only to build the \
             docs.rs stub library."
        )),
    };
    if !output.status.success() {
        fail(&format!(
            "{program} failed while building the docs.rs stub library:\n{}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }
}

fn emit_link_directives(lib_dir: &Path) {
    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=static=wgslender");
}

/// The four paths `zig build lib` reads, which are also exactly what
/// `cargo xtask package` vendors.
fn emit_rerun_directives(sources: &Sources) {
    for path in ["src", "include/wgslender.h", "build.zig", "build.zig.zon"] {
        println!(
            "cargo:rerun-if-changed={}",
            sources.path().join(path).display()
        );
    }
}
