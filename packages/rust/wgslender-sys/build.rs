//! Builds and links the wgslender C static library.
//!
//! Resolution order:
//!
//! 1. `WGSLENDER_LIB_DIR` — link a prebuilt `libwgslender.a` from that directory
//!    and do nothing else. This is both the "I already built it" escape hatch and
//!    the fallback for targets the mapping below does not know.
//! 2. `DOCS_RS` — emit nothing. The docs.rs sandbox has no Zig, and rustdoc does
//!    not link.
//! 3. Otherwise build the library from the wgslender repository this crate lives
//!    in, installing it into this crate's `OUT_DIR` so that host and target builds
//!    never write to the same prefix.

use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-env-changed=WGSLENDER_LIB_DIR");
    println!("cargo:rerun-if-env-changed=DOCS_RS");

    if let Some(lib_dir) = env::var_os("WGSLENDER_LIB_DIR") {
        emit_link_directives(Path::new(&lib_dir));
        return;
    }
    if env::var_os("DOCS_RS").is_some() {
        return;
    }

    let repo_root = repo_root();
    let out_dir = out_dir();
    build_static_library(&repo_root, &out_dir);
    emit_link_directives(&out_dir.join("lib"));
    emit_rerun_directives(&repo_root);
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

/// The wgslender repository root, three levels above
/// `<root>/packages/rust/wgslender-sys`.
fn repo_root() -> PathBuf {
    let Some(manifest_dir) = env::var_os("CARGO_MANIFEST_DIR") else {
        fail("CARGO_MANIFEST_DIR is unset, but cargo always sets it for build scripts")
    };
    let manifest_dir = PathBuf::from(manifest_dir);

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
            "expected the wgslender sources at {} but found no build.zig there. \
             Set WGSLENDER_LIB_DIR to a directory holding a prebuilt libwgslender.a instead.",
            root.display()
        ));
    }
    root
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

fn build_static_library(repo_root: &Path, out_dir: &Path) {
    let mut zig = Command::new("zig");
    zig.current_dir(repo_root)
        .args(["build", "lib", "-Doptimize=ReleaseFast", "-p"])
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
            repo_root.display(),
            String::from_utf8_lossy(&output.stderr)
        ));
    }
}

fn emit_link_directives(lib_dir: &Path) {
    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=static=wgslender");
}

fn emit_rerun_directives(repo_root: &Path) {
    for path in ["src", "include/wgslender.h", "build.zig", "build.zig.zon"] {
        println!("cargo:rerun-if-changed={}", repo_root.join(path).display());
    }
}
