//! Sysemble command line interface.
//!
//! Only the scaffolding is here: `version` and `stages`. The build, plan, and
//! validate commands arrive in P0 (see docs/roadmap.md).

use sysemble_core::{Stage, API_VERSION, VERSION};

fn usage() {
    println!("sysemble {VERSION} (spec {API_VERSION})");
    println!();
    println!("usage: sysemble <command>");
    println!();
    println!("commands:");
    println!("  version   print version and spec revision");
    println!("  stages    print the build lifecycle");
    println!();
    println!("The build engine is not implemented yet; see docs/roadmap.md.");
}

fn main() {
    let command = std::env::args().nth(1);
    match command.as_deref() {
        None | Some("version") | Some("--version") => usage(),
        Some("stages") => {
            for stage in Stage::ALL {
                println!("{}", stage.as_str());
            }
        }
        Some(other) => {
            eprintln!("unknown command: {other}");
            usage();
            std::process::exit(2);
        }
    }
}
