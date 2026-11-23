//! Hand-written command line parsing.
//!
//! The grammar is small enough that a parser generator would add more surface
//! than it removes: one command, at most one positional, and one flag. Parsing
//! is separated from execution so the accepted command lines are unit-tested
//! without spawning a process.

/// Which help page to print.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HelpTopic {
    General,
    Validate,
    Plan,
}

/// A parsed command line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Command {
    Help(HelpTopic),
    Version,
    Stages,
    Validate { file: String, json: bool },
    Plan { file: String, json: bool },
}

/// A command line the CLI refuses to run.
///
/// The caller prints the message and exits with code 2.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UsageError {
    message: String,
}

impl UsageError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl std::fmt::Display for UsageError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

/// Parse the arguments that follow the program name.
///
/// # Errors
///
/// Returns [`UsageError`] for a missing command, an unknown command or option,
/// a missing spec file, or an unexpected extra argument. Those all map to exit
/// code 2.
pub fn parse<I>(args: I) -> Result<Command, UsageError>
where
    I: IntoIterator<Item = String>,
{
    let mut args = args.into_iter();
    let Some(command) = args.next() else {
        return Err(UsageError::new("missing command"));
    };
    let rest: Vec<String> = args.collect();

    match command.as_str() {
        "help" => parse_help(&rest),
        "--help" | "-h" => Ok(Command::Help(HelpTopic::General)),
        "--version" | "-V" | "version" => {
            if rest.iter().any(|arg| is_help(arg)) {
                Ok(Command::Help(HelpTopic::General))
            } else {
                expect_no_arguments("version", &rest)?;
                Ok(Command::Version)
            }
        }
        "stages" => {
            if rest.iter().any(|arg| is_help(arg)) {
                Ok(Command::Help(HelpTopic::General))
            } else {
                expect_no_arguments("stages", &rest)?;
                Ok(Command::Stages)
            }
        }
        "validate" => parse_spec_command(Kind::Validate, rest),
        "plan" => parse_spec_command(Kind::Plan, rest),
        other => Err(UsageError::new(format!("unknown command `{other}`"))),
    }
}

/// The two commands that take a spec file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Validate,
    Plan,
}

impl Kind {
    fn name(self) -> &'static str {
        match self {
            Kind::Validate => "validate",
            Kind::Plan => "plan",
        }
    }

    fn help_topic(self) -> HelpTopic {
        match self {
            Kind::Validate => HelpTopic::Validate,
            Kind::Plan => HelpTopic::Plan,
        }
    }
}

fn parse_spec_command(kind: Kind, rest: Vec<String>) -> Result<Command, UsageError> {
    let mut json = false;
    let mut file: Option<String> = None;
    let mut positional_only = false;

    for arg in rest {
        if !positional_only {
            if arg == "--json" {
                json = true;
                continue;
            }
            if is_help(&arg) {
                return Ok(Command::Help(kind.help_topic()));
            }
            if arg == "--" {
                positional_only = true;
                continue;
            }
            if arg.starts_with('-') {
                return Err(UsageError::new(format!(
                    "unknown option `{arg}` for `{}`",
                    kind.name()
                )));
            }
        }

        if file.is_some() {
            return Err(UsageError::new(format!("unexpected argument `{arg}`")));
        }
        file = Some(arg);
    }

    let file =
        file.ok_or_else(|| UsageError::new(format!("`{}` needs a spec file", kind.name())))?;

    Ok(match kind {
        Kind::Validate => Command::Validate { file, json },
        Kind::Plan => Command::Plan { file, json },
    })
}

fn parse_help(rest: &[String]) -> Result<Command, UsageError> {
    match rest {
        [] => Ok(Command::Help(HelpTopic::General)),
        [topic] => match topic.as_str() {
            "validate" => Ok(Command::Help(HelpTopic::Validate)),
            "plan" => Ok(Command::Help(HelpTopic::Plan)),
            "version" | "stages" | "help" => Ok(Command::Help(HelpTopic::General)),
            other => Err(UsageError::new(format!("unknown help topic `{other}`"))),
        },
        _ => Err(UsageError::new("`help` takes at most one topic")),
    }
}

fn expect_no_arguments(command: &str, rest: &[String]) -> Result<(), UsageError> {
    match rest {
        [] => Ok(()),
        [arg] => Err(UsageError::new(format!(
            "`{command}` takes no arguments, got `{arg}`"
        ))),
        args => Err(UsageError::new(format!(
            "`{command}` takes no arguments, got {} arguments",
            args.len()
        ))),
    }
}

fn is_help(arg: &str) -> bool {
    arg == "--help" || arg == "-h"
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_args(args: &[&str]) -> Result<Command, UsageError> {
        parse(args.iter().map(|arg| (*arg).to_string()))
    }

    #[test]
    fn parses_validate_and_plan_with_optional_json() {
        assert_eq!(
            parse_args(&["validate", "spec.yaml"]),
            Ok(Command::Validate {
                file: "spec.yaml".to_string(),
                json: false,
            })
        );
        assert_eq!(
            parse_args(&["validate", "spec.yaml", "--json"]),
            Ok(Command::Validate {
                file: "spec.yaml".to_string(),
                json: true,
            })
        );
        assert_eq!(
            parse_args(&["validate", "--json", "spec.yaml"]),
            Ok(Command::Validate {
                file: "spec.yaml".to_string(),
                json: true,
            })
        );
        assert_eq!(
            parse_args(&["plan", "spec.yaml", "--json"]),
            Ok(Command::Plan {
                file: "spec.yaml".to_string(),
                json: true,
            })
        );
    }

    #[test]
    fn parses_version_stages_and_help() {
        assert_eq!(parse_args(&["version"]), Ok(Command::Version));
        assert_eq!(parse_args(&["--version"]), Ok(Command::Version));
        assert_eq!(parse_args(&["stages"]), Ok(Command::Stages));
        assert_eq!(
            parse_args(&["--help"]),
            Ok(Command::Help(HelpTopic::General))
        );
        assert_eq!(
            parse_args(&["help", "validate"]),
            Ok(Command::Help(HelpTopic::Validate))
        );
        assert_eq!(
            parse_args(&["plan", "--help"]),
            Ok(Command::Help(HelpTopic::Plan))
        );
    }

    #[test]
    fn rejects_missing_and_unknown_commands() {
        assert!(parse_args(&[]).is_err());
        assert!(parse_args(&["frobnicate"]).is_err());
        assert!(parse_args(&["help", "frobnicate"]).is_err());
    }

    #[test]
    fn rejects_missing_spec_file() {
        for command in ["validate", "plan"] {
            let error = parse_args(&[command]).expect_err("missing file must be rejected");
            assert!(error.to_string().contains(command), "error: {error}");
        }
    }

    #[test]
    fn rejects_unknown_options_and_extra_positionals() {
        assert!(parse_args(&["validate", "--bogus", "spec.yaml"]).is_err());
        assert!(parse_args(&["validate", "a.yaml", "b.yaml"]).is_err());
        assert!(parse_args(&["version", "extra"]).is_err());
    }

    #[test]
    fn double_dash_allows_a_dashed_path() {
        assert_eq!(
            parse_args(&["validate", "--", "-spec.yaml"]),
            Ok(Command::Validate {
                file: "-spec.yaml".to_string(),
                json: false,
            })
        );
    }
}
