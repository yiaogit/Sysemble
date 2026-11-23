//! Sysemble command line interface.
//!
//! The CLI only parses arguments, calls `sysemble-core`, and formats the
//! result; validation and planning rules stay in the core crate. See
//! `docs/plan/P0-workplan.md` for the frozen command contract.

mod args;
mod output;

use std::path::Path;
use std::process::ExitCode;

use sysemble_core::{
    load_spec, resolve_plan, validate_spec, Diagnostic, SpecError, Stage, API_VERSION, VERSION,
};

use args::{Command, HelpTopic};

/// Everything went as asked.
const EXIT_OK: u8 = 0;
/// The spec is invalid, unparseable, or cannot be planned.
const EXIT_SPEC: u8 = 1;
/// Bad usage, or the spec file could not be read.
const EXIT_USAGE_OR_IO: u8 = 2;

fn main() -> ExitCode {
    ExitCode::from(run())
}

fn run() -> u8 {
    let command = match args::parse(std::env::args().skip(1)) {
        Ok(command) => command,
        Err(error) => {
            report_usage_error(&error);
            return EXIT_USAGE_OR_IO;
        }
    };

    match command {
        Command::Help(topic) => {
            print_help(topic);
            EXIT_OK
        }
        Command::Version => {
            println!("sysemble {VERSION} (spec {API_VERSION})");
            EXIT_OK
        }
        Command::Stages => {
            for stage in Stage::ALL {
                println!("{}", stage.as_str());
            }
            EXIT_OK
        }
        Command::Validate { file, json } => validate_command(&file, json),
        Command::Plan { file, json } => plan_command(&file, json),
    }
}

/// `sysemble validate <file> [--json]`.
fn validate_command(file: &str, json: bool) -> u8 {
    let spec = match load_spec(Path::new(file)) {
        Ok(spec) => spec,
        Err(error) => return report_spec_error(&error, json),
    };

    let diagnostics = validate_spec(&spec);

    if json {
        match output::diagnostics_json(&diagnostics) {
            Ok(encoded) => println!("{encoded}"),
            Err(error) => {
                eprintln!("error: cannot encode diagnostics as JSON: {error}");
                return EXIT_USAGE_OR_IO;
            }
        }
    } else {
        for diagnostic in &diagnostics {
            eprintln!("{}", output::diagnostic_line(diagnostic));
        }
    }

    if diagnostics.iter().any(Diagnostic::is_error) {
        EXIT_SPEC
    } else {
        EXIT_OK
    }
}

/// `sysemble plan <file> [--json]`.
///
/// `--json` is accepted for compatibility but changes nothing: the plan is
/// always the pretty JSON document on stdout. On failure, diagnostics go to
/// stderr in the same human-readable format as `validate`.
fn plan_command(file: &str, _json: bool) -> u8 {
    let spec = match load_spec(Path::new(file)) {
        Ok(spec) => spec,
        Err(error) => return report_spec_error(&error, false),
    };

    match resolve_plan(&spec) {
        Ok(plan) => {
            match output::plan_json(&plan) {
                Ok(encoded) => println!("{encoded}"),
                Err(error) => {
                    eprintln!("error: cannot encode plan as JSON: {error}");
                    return EXIT_USAGE_OR_IO;
                }
            }
            eprintln!("{}", output::plan_summary(&plan));
            EXIT_OK
        }
        Err(error) => {
            eprintln!("error: {error}");
            for diagnostic in error.validation_errors() {
                eprintln!("{}", output::diagnostic_line(diagnostic));
            }
            EXIT_SPEC
        }
    }
}

/// Report a spec that could not be loaded and return the matching exit code.
///
/// An unreadable file is an IO problem (exit 2); a file that is readable but
/// not a valid build spec is a spec error (exit 1). With `--json`, the failure
/// is still emitted as a diagnostics array so machine consumers always get
/// parseable output.
fn report_spec_error(error: &SpecError, json: bool) -> u8 {
    if json {
        let diagnostic = output::spec_error_diagnostic(error);
        match output::diagnostics_json(&[diagnostic]) {
            Ok(encoded) => println!("{encoded}"),
            Err(encode_error) => {
                eprintln!("error: cannot encode diagnostics as JSON: {encode_error}");
                return EXIT_USAGE_OR_IO;
            }
        }
    } else {
        eprintln!("error: {error}");
    }

    match error {
        SpecError::Read { .. } => EXIT_USAGE_OR_IO,
        SpecError::Parse { .. } => EXIT_SPEC,
    }
}

fn report_usage_error(error: &args::UsageError) {
    eprintln!("error: {error}");
    eprintln!("usage: sysemble <command> [args]");
    eprintln!("run `sysemble --help` for details");
}

fn print_help(topic: HelpTopic) {
    match topic {
        HelpTopic::General => {
            println!("sysemble {VERSION} (spec {API_VERSION})");
            println!();
            println!("usage: sysemble <command> [args]");
            println!();
            println!("commands:");
            println!("  validate <file> [--json]  validate a build spec");
            println!("  plan <file> [--json]      resolve a build plan and print it as JSON");
            println!("  version                   print version and spec revision");
            println!("  stages                    print the build lifecycle");
            println!("  help [command]            print this help");
            println!();
            println!("options:");
            println!("  -h, --help     print help");
            println!("  -V, --version  print version");
            println!();
            println!("exit codes:");
            println!("  0  success");
            println!("  1  invalid or unplannable spec");
            println!("  2  usage error or unreadable spec file");
        }
        HelpTopic::Validate => {
            println!("sysemble validate");
            println!();
            println!("Parse a build spec and report validation diagnostics.");
            println!();
            println!("usage: sysemble validate <file> [--json]");
            println!();
            println!("arguments:");
            println!("  <file>      path to a buildspec.yaml (JSON is also accepted)");
            println!();
            println!("options:");
            println!("  --json      print diagnostics as a pretty JSON array to stdout");
            println!("  -h, --help  print this help");
            println!();
            println!("Diagnostics go to stderr as `error[code] /path: message`.");
            println!();
            println!("exit codes:");
            println!("  0  no validation errors (warnings may still be printed)");
            println!("  1  validation errors, or the spec could not be parsed");
            println!("  2  usage error or unreadable spec file");
        }
        HelpTopic::Plan => {
            println!("sysemble plan");
            println!();
            println!("Resolve a build spec into a build plan.");
            println!();
            println!("usage: sysemble plan <file> [--json]");
            println!();
            println!("arguments:");
            println!("  <file>      path to a buildspec.yaml (JSON is also accepted)");
            println!();
            println!("options:");
            println!(
                "  --json      accepted for compatibility; the plan is always printed as JSON"
            );
            println!("  -h, --help  print this help");
            println!();
            println!("The pretty-printed plan JSON goes to stdout; a one-line summary goes to");
            println!("stderr. Diagnostics for an unplannable spec go to stderr.");
            println!();
            println!("exit codes:");
            println!("  0  plan resolved");
            println!("  1  spec is invalid, or its base is not supported by the P0 planner");
            println!("  2  usage error or unreadable spec file");
        }
    }
}
