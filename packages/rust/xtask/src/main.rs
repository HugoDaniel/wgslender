//! The local gate for the wgslender Rust workspace.
//!
//! This repository runs no CI by house rule, so the command set a CI job would
//! run lives here and is invoked on demand:
//!
//! ```text
//! cargo xtask check
//! ```
//!
//! Zero dependencies on purpose: a gate that fails to build is a gate that
//! stops being run.

use std::env;
use std::fmt::Write as _;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};

/// The workspace root, one directory above this crate.
///
/// Baked in at build time so that the gate runs the same way from wherever the
/// user happened to be standing.
const WORKSPACE_ROOT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/..");

/// The wgslender repository root: `packages/rust/xtask`, three levels up.
const REPO_ROOT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../..");

/// Where the vendored Zig sources go, matching `VENDOR_DIR` in
/// `wgslender-sys/build.rs`.
const VENDOR_DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../wgslender-sys/vendor");

/// Everything `zig build lib` reads, and nothing else.
///
/// Measured rather than assumed: these four paths build `libwgslender.a` in a
/// directory holding no others. `external/lsp-kit` is deliberately absent —
/// `lsp_kit` is a lazy *URL* dependency that only the LSP steps ask for, so the
/// library target never fetches it and a consumer never needs the network.
const VENDORED_PATHS: &[&str] = &["build.zig", "build.zig.zon", "src", "include"];

/// The directory the `EXAMPLES` table below claims to describe in full.
const EXAMPLES_DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../wgslender/examples");

/// The oldest toolchain the crates' `rust-version` promises to support.
const MSRV: &str = "1.85.0";

const USAGE: &str = "\
usage: cargo xtask <task>

tasks:
  check      formatting, clippy, tests, the doc build and the examples — the full gate
  examples   run every example, and check the table listing them is complete
  msrv       type-check the workspace with the declared minimum toolchain
  deny       audit dependencies with cargo-deny
  package    vendor the Zig sources and build the wgslender-sys tarball
  publish    the same, then upload all four crates to crates.io
";

/// Which binary a step runs.
///
/// `Cargo` resolves through `$CARGO`, so every step uses the same toolchain
/// that launched xtask. `Rustup` is looked up on `PATH`, because the one step
/// that needs it is precisely the step asking for a *different* toolchain.
#[derive(Clone, Copy)]
enum Program {
    Cargo,
    Rustup,
}

impl Program {
    fn command(self) -> Command {
        match self {
            Self::Cargo => Command::new(env::var_os("CARGO").unwrap_or_else(|| "cargo".into())),
            Self::Rustup => Command::new("rustup"),
        }
    }

    /// How the program is spelled when a human types it.
    fn name(self) -> &'static str {
        match self {
            Self::Cargo => "cargo",
            Self::Rustup => "rustup",
        }
    }
}

/// One command in a gate, named for what it proves.
struct Step {
    /// Printed before the step runs, and again if it fails.
    label: &'static str,
    program: Program,
    args: &'static [&'static str],
    /// Variables this step needs on top of the inherited environment.
    env: &'static [(&'static str, &'static str)],
}

impl Step {
    /// The step as a user would type it, so that a failure can be reproduced by
    /// hand without reading this file.
    fn command_line(&self) -> String {
        let mut line = String::new();
        for (key, value) in self.env {
            let _ = write!(line, "{key}=\"{value}\" ");
        }
        line.push_str(self.program.name());
        for arg in self.args {
            line.push(' ');
            line.push_str(arg);
        }
        line
    }
}

/// The gate, in the order a failure is cheapest to fix.
const CHECK: &[Step] = &[
    Step {
        label: "formatting",
        program: Program::Cargo,
        args: &["fmt", "--all", "--", "--check"],
        env: &[],
    },
    Step {
        label: "clippy",
        program: Program::Cargo,
        args: &[
            "clippy",
            "--workspace",
            "--all-targets",
            "--",
            "-D",
            "warnings",
        ],
        env: &[],
    },
    Step {
        label: "clippy, every feature",
        program: Program::Cargo,
        args: &[
            "clippy",
            "--workspace",
            "--all-targets",
            "--all-features",
            "--",
            "-D",
            "warnings",
        ],
        env: &[],
    },
    // `cargo test` runs the doctests along with everything else, so there is no
    // separate `--doc` step: it would only run them a second time.
    Step {
        label: "tests and doctests",
        program: Program::Cargo,
        args: &["test", "--workspace"],
        env: &[],
    },
    // The default features are one point in the matrix. An optional feature
    // nothing ever compiles is an optional feature that has stopped working.
    Step {
        label: "tests and doctests, every feature",
        program: Program::Cargo,
        args: &["test", "--workspace", "--all-features"],
        env: &[],
    },
    // And the other end: a caller who wants the library and none of the
    // conveniences must still get a crate that builds.
    Step {
        label: "no features at all",
        program: Program::Cargo,
        args: &[
            "check",
            "--workspace",
            "--all-targets",
            "--no-default-features",
        ],
        env: &[],
    },
    Step {
        label: "documentation",
        program: Program::Cargo,
        args: &["doc", "--workspace", "--no-deps", "--all-features"],
        env: &[(
            "RUSTDOCFLAGS",
            "-D rustdoc::broken_intra_doc_links -D rustdoc::private_intra_doc_links",
        )],
    },
];

/// One runnable example, and the features it needs beyond the defaults.
struct Example {
    /// The file stem under `wgslender/examples/`, which is also what Cargo is
    /// given as `--example`.
    name: &'static str,
    /// Passed as `--features`. Empty for everything the default features build;
    /// a row asks for exactly what its example needs, which incidentally proves
    /// the feature gating still gates.
    features: &'static [&'static str],
}

/// Every example the facade crate ships.
///
/// The gate already *compiles* these — the clippy and check steps pass
/// `--all-targets` — which proves only that they build. This table is what
/// makes them run. An example that panics on its first unwrap, or that prints
/// nothing at all, has demonstrated nothing, and until this table existed it
/// passed the gate anyway.
///
/// Hand-written rather than globbed, so that adding an example is a deliberate
/// row. [`examples_are_all_listed`] is what stops the list from rotting.
const EXAMPLES: &[Example] = &[
    Example {
        name: "minify",
        features: &[],
    },
    Example {
        name: "reflect_types",
        features: &[],
    },
    Example {
        name: "wgsl_module",
        features: &[],
    },
    Example {
        name: "embed_compressed",
        features: &["compress"],
    },
    Example {
        name: "validate",
        features: &[],
    },
    Example {
        name: "lint",
        features: &[],
    },
    Example {
        name: "compile",
        features: &[],
    },
    Example {
        name: "refactor",
        features: &[],
    },
    Example {
        name: "minify_options",
        features: &[],
    },
    Example {
        name: "include_wgsl",
        features: &[],
    },
];

/// Type-checking with the declared minimum toolchain, which is a promise the
/// current toolchain cannot keep on its behalf.
///
/// With every feature on: an optional dependency is a promise about the
/// minimum too, and the ones that carry no `rust-version` of their own can
/// only be found out about by trying.
const MSRV_CHECK: &[Step] = &[Step {
    label: "minimum supported rust version",
    program: Program::Rustup,
    args: &[
        "run",
        MSRV,
        "cargo",
        "check",
        "--workspace",
        "--all-targets",
        "--all-features",
    ],
    env: &[],
}];

const DENY: &[Step] = &[Step {
    label: "dependency audit",
    program: Program::Cargo,
    args: &["deny", "check"],
    env: &[],
}];

/// Building the tarball, with verification left on.
///
/// Verification is the whole point: it unpacks what would be published and
/// builds it, which is the only thing that can prove the vendored sources are
/// complete. `--allow-dirty` is not a shortcut around a dirty tree — `vendor/`
/// is untracked by design, and cargo counts untracked files as dirt.
const PACKAGE: &[Step] = &[Step {
    label: "package wgslender-sys",
    program: Program::Cargo,
    args: &["package", "--package", "wgslender-sys", "--allow-dirty"],
    env: &[],
}];

/// Publishing all four crates, in the order their dependencies allow.
///
/// One `cargo publish` rather than four: cargo orders a multi-package publish
/// itself and waits for each crate to appear in the index before the next one
/// that depends on it, which is the part that is tedious and easy to get wrong
/// by hand.
///
/// This exists for the same reason [`PACKAGE`] does — publishing runs the same
/// packaging and verification, so it needs the same vendored sources. A bare
/// `cargo publish` fails, and says why.
const PUBLISH: &[Step] = &[Step {
    label: "publish to crates.io",
    program: Program::Cargo,
    args: &[
        "publish",
        "--package",
        "wgslender-sys",
        "--package",
        "wgslender-core",
        "--package",
        "wgslender-macros",
        "--package",
        "wgslender",
        "--allow-dirty",
    ],
    env: &[],
}];

/// Whether a tool an optional task needs is installed.
enum Availability {
    Present,
    Missing,
}

/// Whether everything a gate ran passed.
///
/// A named pair rather than a `bool`, for the same reason [`Availability`] is
/// one: at a call site `false` reads as easily as "did not run" as it does as
/// "ran and said no", and those are different answers.
#[derive(Clone, Copy)]
enum Outcome {
    Passed,
    Failed,
}

impl Outcome {
    /// Runs `next` only after a pass, so that the first failure is the last
    /// thing printed and the one the user reads.
    fn and_then(self, next: impl FnOnce() -> Self) -> Self {
        match self {
            Self::Passed => next(),
            Self::Failed => Self::Failed,
        }
    }

    /// The exit code, plus the one `all green` — which belongs to the whole
    /// task, not to each gate inside it.
    fn report(self) -> ExitCode {
        match self {
            Self::Passed => {
                println!("\nall green");
                ExitCode::SUCCESS
            }
            Self::Failed => ExitCode::FAILURE,
        }
    }
}

fn main() -> ExitCode {
    let mut args = env::args().skip(1);
    let task = args.next();
    if let Some(extra) = args.next() {
        eprintln!("xtask: unexpected argument {extra:?}\n\n{USAGE}");
        return ExitCode::FAILURE;
    }

    match task.as_deref() {
        // The examples go last: they are the slowest step, and the least likely
        // to fail once the rest is green.
        Some("check") => run(CHECK).and_then(examples).report(),
        Some("examples") => examples().report(),
        Some("msrv") => msrv(),
        Some("deny") => deny(),
        Some("package") => with_vendored_sources(PACKAGE),
        Some("publish") => with_vendored_sources(PUBLISH),
        Some(unknown) => {
            eprintln!("xtask: no task named {unknown:?}\n\n{USAGE}");
            ExitCode::FAILURE
        }
        None => {
            eprint!("{USAGE}");
            ExitCode::FAILURE
        }
    }
}

/// The vendored Zig sources, present for exactly as long as the packaging run
/// that needs them.
///
/// A guard rather than a copy-then-delete pair, because `cargo package` fails
/// sometimes and 2.5 MB of Zig left behind in a directory the repository does
/// not track is a puzzle for whoever runs `git status` next. Dropping it is the
/// only way it goes away, so there is no path that forgets.
struct VendoredSources {
    dir: PathBuf,
}

impl VendoredSources {
    /// Copies [`VENDORED_PATHS`] out of the repository and into the crate.
    ///
    /// Copied fresh every time rather than kept in the repository: a copy that
    /// lives in git is a copy that can disagree with the sources, and the only
    /// way to be sure it never does is for it not to outlive the command.
    fn place() -> io::Result<Self> {
        let dir = PathBuf::from(VENDOR_DIR);
        if let Err(err) = fs::remove_dir_all(&dir)
            && err.kind() != io::ErrorKind::NotFound
        {
            return Err(err);
        }
        fs::create_dir_all(&dir)?;

        let repo_root = Path::new(REPO_ROOT);
        for path in VENDORED_PATHS {
            copy_recursively(&repo_root.join(path), &dir.join(path))?;
        }
        Ok(Self { dir })
    }
}

impl Drop for VendoredSources {
    fn drop(&mut self) {
        if let Err(err) = fs::remove_dir_all(&self.dir) {
            eprintln!(
                "xtask: could not remove {}: {err}\n  \
                 delete it by hand — a published crate must not be built from a stale copy",
                self.dir.display()
            );
        }
    }
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

/// Vendors the Zig sources, runs `steps`, and takes them away again.
///
/// Packaging and publishing both need this. `cargo publish` runs the same
/// packaging and verification as `cargo package` before it uploads anything,
/// so it fails on a crate with no Zig in it exactly as packaging does.
fn with_vendored_sources(steps: &[Step]) -> ExitCode {
    println!("\n=== vendoring the Zig sources ===");
    let vendored = match VendoredSources::place() {
        Ok(vendored) => vendored,
        Err(err) => {
            eprintln!("xtask: could not vendor the Zig sources: {err}");
            return ExitCode::FAILURE;
        }
    };
    println!(
        "{} <- {}",
        vendored.dir.display(),
        VENDORED_PATHS.join(", ")
    );

    // Bound to a name, not to `_`: `_` drops at the end of the statement, which
    // would take the sources away before cargo reads them.
    let outcome = run(steps);
    drop(vendored);
    outcome.report()
}

/// Runs steps in order, stopping at the first one that fails.
fn run(steps: &[Step]) -> Outcome {
    for step in steps {
        println!("\n=== {} ===\n$ {}", step.label, step.command_line());

        let mut command = step.program.command();
        command.current_dir(WORKSPACE_ROOT).args(step.args);
        for (key, value) in step.env {
            command.env(key, value);
        }

        match command.status() {
            Ok(status) if status.success() => {}
            Ok(status) => {
                eprintln!("\nxtask: {} failed ({status})", step.label);
                return Outcome::Failed;
            }
            Err(err) => {
                eprintln!("\nxtask: could not run {}: {err}", step.command_line());
                return Outcome::Failed;
            }
        }
    }

    Outcome::Passed
}

/// Runs every example in [`EXAMPLES`], in order, stopping at the first failure.
///
/// An example has to exit zero *and* print something. The second half is the
/// point: these are documentation that happens to execute, and one that runs in
/// silence is documentation that says nothing.
fn examples() -> Outcome {
    println!("\n=== examples ===");

    if let Outcome::Failed = examples_are_all_listed() {
        return Outcome::Failed;
    }

    for example in EXAMPLES {
        let features = example.features.join(",");
        let mut args = vec!["run", "--package", "wgslender", "--example", example.name];
        if !features.is_empty() {
            args.push("--features");
            args.push(&features);
        }
        println!("$ cargo {}", args.join(" "));

        let mut command = Program::Cargo.command();
        command
            .current_dir(WORKSPACE_ROOT)
            .args(&args)
            // Cargo's progress goes to stderr, so letting that through means a
            // cold build still looks like something is happening. Only what the
            // example itself prints gets captured, which is what makes the
            // emptiness check below mean anything.
            .stderr(Stdio::inherit());

        let output = match command.output() {
            Ok(output) => output,
            Err(err) => {
                eprintln!("\nxtask: could not run the {} example: {err}", example.name);
                return Outcome::Failed;
            }
        };

        // Text, because text is what an example prints. Lossy, because a gate
        // that hits a mangled byte should say what it saw rather than refuse to
        // say anything.
        let printed = String::from_utf8_lossy(&output.stdout);

        if !output.status.success() {
            // Whatever it managed to print before it failed, which is usually
            // where the failure is.
            if !printed.trim().is_empty() {
                println!("{}", printed.trim_end());
            }
            eprintln!(
                "\nxtask: the {} example failed ({})",
                example.name, output.status
            );
            return Outcome::Failed;
        }

        if printed.trim().is_empty() {
            eprintln!(
                "\nxtask: the {} example printed nothing — an example that says \
                 nothing demonstrates nothing",
                example.name
            );
            return Outcome::Failed;
        }

        println!("  {} lines", printed.lines().count());
    }

    Outcome::Passed
}

/// Fails if `wgslender/examples/` holds an example [`EXAMPLES`] does not.
///
/// The table is the thing that runs, so a file missing from it is an example
/// that silently stops being checked the moment it is written. Directory-style
/// examples (`foo/main.rs`) count too, because Cargo builds those as well.
///
/// `std::fs`, rather than a crate that walks directories: xtask has no
/// dependencies on purpose, and a gate that fails to build is a gate that stops
/// being run.
fn examples_are_all_listed() -> Outcome {
    let dir = Path::new(EXAMPLES_DIR);
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(err) => {
            eprintln!("\nxtask: could not read {}: {err}", dir.display());
            return Outcome::Failed;
        }
    };

    let mut unlisted = Vec::new();
    for entry in entries {
        let path = match entry {
            Ok(entry) => entry.path(),
            Err(err) => {
                eprintln!("\nxtask: could not read {}: {err}", dir.display());
                return Outcome::Failed;
            }
        };

        let name = if path.extension().is_some_and(|extension| extension == "rs") {
            path.file_stem()
        } else if path.join("main.rs").is_file() {
            path.file_name()
        } else {
            continue;
        };
        let Some(name) = name.and_then(|name| name.to_str()) else {
            continue;
        };

        if !EXAMPLES.iter().any(|example| example.name == name) {
            unlisted.push(name.to_owned());
        }
    }

    if unlisted.is_empty() {
        return Outcome::Passed;
    }

    unlisted.sort();
    eprintln!(
        "\nxtask: missing from the EXAMPLES table in xtask/src/main.rs, so the \
         gate would never run them: {}",
        unlisted.join(", ")
    );
    Outcome::Failed
}

/// A missing tool exits non-zero rather than reporting a pass: a check that did
/// not run has not passed.
fn missing(hint: &str) -> ExitCode {
    eprintln!("xtask: {hint}");
    ExitCode::FAILURE
}

fn msrv() -> ExitCode {
    match msrv_toolchain() {
        Availability::Present => run(MSRV_CHECK).report(),
        Availability::Missing => missing(&format!(
            "rustup has no {MSRV} toolchain — install it with \
             `rustup toolchain install {MSRV}`"
        )),
    }
}

fn deny() -> ExitCode {
    match cargo_deny() {
        Availability::Present => run(DENY).report(),
        Availability::Missing => missing(
            "cargo-deny is not installed — install it with `cargo install --locked cargo-deny`",
        ),
    }
}

/// Whether `rustup` knows a toolchain whose name starts with the MSRV, which is
/// how it lists `1.85.0-aarch64-apple-darwin` and friends.
fn msrv_toolchain() -> Availability {
    let Ok(output) = Command::new("rustup").args(["toolchain", "list"]).output() else {
        return Availability::Missing;
    };
    if !output.status.success() {
        return Availability::Missing;
    }
    let installed = String::from_utf8_lossy(&output.stdout);
    if installed.lines().any(|line| line.starts_with(MSRV)) {
        Availability::Present
    } else {
        Availability::Missing
    }
}

fn cargo_deny() -> Availability {
    match Program::Cargo
        .command()
        .args(["deny", "--version"])
        .output()
    {
        Ok(output) if output.status.success() => Availability::Present,
        _ => Availability::Missing,
    }
}
