import Darwin
import Foundation

// Top-level entry point. All argument parsing lives in CLI.swift so it can be
// unit-tested by invoking the built executable; the only job here is to hand
// back the documented exit code.
let status = CLI.main(Array(CommandLine.arguments.dropFirst()))
exit(status)
