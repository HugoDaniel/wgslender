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
use std::process::{Command, ExitCode};

/// The workspace root, one directory above this crate.
///
/// Baked in at build time so that the gate runs the same way from wherever the
/// user happened to be standing.
const WORKSPACE_ROOT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/..");

/// The oldest toolchain the crates' `rust-version` promises to support.
const MSRV: &str = "1.85.0";

const USAGE: &str = "\
usage: cargo xtask <task>

tasks:
  check   formatting, clippy, tests, doctests and the doc build — the full gate
  msrv    type-check the workspace with the declared minimum toolchain
  deny    audit dependencies with cargo-deny
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
    // `cargo test` runs the doctests along with everything else, so there is no
    // separate `--doc` step: it would only run them a second time.
    Step {
        label: "tests and doctests",
        program: Program::Cargo,
        args: &["test", "--workspace"],
        env: &[],
    },
    Step {
        label: "documentation",
        program: Program::Cargo,
        args: &["doc", "--workspace", "--no-deps"],
        env: &[(
            "RUSTDOCFLAGS",
            "-D rustdoc::broken_intra_doc_links -D rustdoc::private_intra_doc_links",
        )],
    },
];

/// Type-checking with the declared minimum toolchain, which is a promise the
/// current toolchain cannot keep on its behalf.
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
    ],
    env: &[],
}];

const DENY: &[Step] = &[Step {
    label: "dependency audit",
    program: Program::Cargo,
    args: &["deny", "check"],
    env: &[],
}];

/// Whether a tool an optional task needs is installed.
enum Availability {
    Present,
    Missing,
}

fn main() -> ExitCode {
    let mut args = env::args().skip(1);
    let task = args.next();
    if let Some(extra) = args.next() {
        eprintln!("xtask: unexpected argument {extra:?}\n\n{USAGE}");
        return ExitCode::FAILURE;
    }

    match task.as_deref() {
        Some("check") => run(CHECK),
        Some("msrv") => msrv(),
        Some("deny") => deny(),
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

/// Runs steps in order, stopping at the first one that fails.
fn run(steps: &[Step]) -> ExitCode {
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
                return ExitCode::FAILURE;
            }
            Err(err) => {
                eprintln!("\nxtask: could not run {}: {err}", step.command_line());
                return ExitCode::FAILURE;
            }
        }
    }

    println!("\nall green");
    ExitCode::SUCCESS
}

/// A missing tool exits non-zero rather than reporting a pass: a check that did
/// not run has not passed.
fn missing(hint: &str) -> ExitCode {
    eprintln!("xtask: {hint}");
    ExitCode::FAILURE
}

fn msrv() -> ExitCode {
    match msrv_toolchain() {
        Availability::Present => run(MSRV_CHECK),
        Availability::Missing => missing(&format!(
            "rustup has no {MSRV} toolchain — install it with \
             `rustup toolchain install {MSRV}`"
        )),
    }
}

fn deny() -> ExitCode {
    match cargo_deny() {
        Availability::Present => run(DENY),
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
