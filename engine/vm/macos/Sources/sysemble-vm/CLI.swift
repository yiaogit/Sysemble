// Command-line surface for the Sysemble macOS VM helper.
//
// The grammar is intentionally small and frozen by docs/plan/P1-e3-workplan.md
// section 2.3:
//
//   sysemble-vm probe [--json]
//   sysemble-vm run --image-dir <dir> --repo <dir> --out <dir> --plan <plan.json>
//                   [--cpus 4] [--memory-mb 4096] [--ready-timeout 180]
//                   [--timeout 1800] [--no-clone] [--json]
//
// No third-party argument parser is used; unknown options, missing values, and
// invalid numbers all exit 2 before any filesystem or VM work happens.

import Foundation

enum CLI {
    static let usageText = """
    sysemble-vm - macOS Virtualization.framework helper for Sysemble (P1-e3)

    Usage:
      sysemble-vm probe [--json]
      sysemble-vm run --image-dir <dir> --repo <dir> --out <dir> --plan <plan.json>
                    [--cpus 4] [--memory-mb 4096] [--ready-timeout 180]
                    [--timeout 1800] [--no-clone] [--rosetta] [--job <name>]
                    [--dry-run] [--json]
      sysemble-vm --help

    probe:
      Report whether this host can run a Virtualization.framework VM and
      whether this executable's signature carries com.apple.security.virtualization.
      Always exits 0 unless the arguments are invalid.

    run:
      Boot the Linux image in --image-dir, share --repo read-only at /work and
      --out read-write at /export, then execute the frozen guest job protocol
      (ready -> job.sh -> done/log) and exit with the guest's exit code.
      --no-clone uses <image-dir>/disk.img in place instead of cloning it to
      <out>/vm-disk.img.
      --rosetta attaches the Rosetta for Linux virtiofs share (tag "rosetta")
      after checking VZLinuxRosettaDirectoryShare.availability; when Rosetta is
      not installed the helper exits 3 with the softwareupdate hint.
      --job <name> runs bash /export/<name> instead of the frozen minimal build.
      <name> must be a basename of a file already present in --out.
      --dry-run validates the inputs, prepares --out, publishes job.sh, prints
      its exact contents, and exits before cloning a disk or starting a VM.

    Exit codes:
      0   success (probe: always unless arguments are invalid)
      2   usage error
      3   image/path error
      4   VM start failure or protocol timeout (ready/job)
      130 interrupted by SIGINT, 143 by SIGTERM
      n   the guest's exit code, read from <out>/.sysemble-vm/done
    """

    static func main(_ arguments: [String]) -> Int32 {
        do {
            return try dispatch(arguments)
        } catch let error as HelperError {
            writeStderr("sysemble-vm: error: \(error.message)")
            if error.code == 2 {
                writeStderr("")
                writeStderr(usageText)
            }
            return error.code
        } catch {
            writeStderr("sysemble-vm: error: \(error)")
            return 1
        }
    }

    private static func dispatch(_ arguments: [String]) throws -> Int32 {
        guard let command = arguments.first else {
            throw HelperError.usage("missing command")
        }
        if command == "--help" || command == "-h" {
            print(usageText)
            return 0
        }

        let rest = Array(arguments.dropFirst())
        switch command {
        case "probe":
            return try runProbe(rest)
        case "run":
            return try runRun(rest)
        default:
            throw HelperError.usage("unknown command: \(command)")
        }
    }

    private static func runProbe(_ arguments: [String]) throws -> Int32 {
        var json = false
        for argument in arguments {
            switch argument {
            case "--json":
                json = true
            case "--help", "-h":
                print(usageText)
                return 0
            default:
                throw HelperError.usage("unexpected argument for probe: \(argument)")
            }
        }
        return Probe.run(json: json)
    }

    private static func runRun(_ arguments: [String]) throws -> Int32 {
        var values: [String: String] = [:]
        var noClone = false
        var rosetta = false
        var dryRun = false
        var json = false

        var index = 0
        while index < arguments.count {
            let raw = arguments[index]
            let (name, inlineValue) = splitOption(raw)

            switch name {
            case "--help", "-h":
                if inlineValue != nil {
                    throw HelperError.usage("\(name) does not take a value")
                }
                print(usageText)
                return 0
            case "--json", "--no-clone", "--rosetta", "--dry-run":
                if inlineValue != nil {
                    throw HelperError.usage("\(name) does not take a value")
                }
                switch name {
                case "--json": json = true
                case "--no-clone": noClone = true
                case "--rosetta": rosetta = true
                default: dryRun = true
                }
                index += 1
            case "--image-dir", "--repo", "--out", "--plan",
                 "--cpus", "--memory-mb", "--ready-timeout", "--timeout", "--job":
                if let inlineValue {
                    guard !inlineValue.isEmpty else {
                        throw HelperError.usage("\(name) requires a non-empty value")
                    }
                    values[name] = inlineValue
                    index += 1
                } else {
                    guard index + 1 < arguments.count else {
                        throw HelperError.usage("\(name) requires a value")
                    }
                    let value = arguments[index + 1]
                    guard !value.isEmpty else {
                        throw HelperError.usage("\(name) requires a non-empty value")
                    }
                    values[name] = value
                    index += 2
                }
            default:
                if raw.hasPrefix("-") {
                    throw HelperError.usage("unknown option for run: \(raw)")
                }
                throw HelperError.usage("unexpected argument for run: \(raw)")
            }
        }

        for required in ["--image-dir", "--repo", "--out", "--plan"] where values[required] == nil {
            throw HelperError.usage("missing required option \(required)")
        }

        if let job = values["--job"] {
            try validateJobName(job)
        }

        let cpus = try positiveInt(values, "--cpus", default: 4)
        let memoryMB = try positiveInt(values, "--memory-mb", default: 4096)
        let readyTimeout = try positiveInt(values, "--ready-timeout", default: 180)
        let timeout = try positiveInt(values, "--timeout", default: 1800)

        let outPath = absolutePath(values["--out"]!)
        if outPath == "/" {
            throw HelperError.usage("--out must not resolve to the filesystem root")
        }

        let options = RunOptions(
            imageDir: URL(fileURLWithPath: absolutePath(values["--image-dir"]!)),
            repo: URL(fileURLWithPath: absolutePath(values["--repo"]!)),
            out: URL(fileURLWithPath: outPath),
            plan: URL(fileURLWithPath: absolutePath(values["--plan"]!)),
            cpus: cpus,
            memoryMB: memoryMB,
            readyTimeout: TimeInterval(readyTimeout),
            timeout: TimeInterval(timeout),
            cloneDisk: !noClone,
            rosetta: rosetta,
            job: values["--job"],
            dryRun: dryRun,
            json: json
        )
        // Keep a strong reference for the whole run: the VZ completion handlers
        // capture the runner weakly and must outlive this call.
        let runner = VMRunner(options: options)
        return runner.execute()
    }

    /// Accept both "--opt value" and "--opt=value". Flags must not carry a
    /// value; the caller checks that.
    private static func splitOption(_ argument: String) -> (String, String?) {
        guard argument.hasPrefix("--"), let separator = argument.firstIndex(of: "=") else {
            return (argument, nil)
        }
        let name = String(argument[..<separator])
        let value = String(argument[argument.index(after: separator)...])
        return (name, value)
    }

    /// `--job` is a debugging override, not a general host->guest path channel:
    /// only a basename inside --out is accepted (P1-e6a).
    private static func validateJobName(_ name: String) throws {
        guard !name.contains("/") else {
            throw HelperError.usage(
                "--job must be a basename inside --out, not a path: '\(name)'"
            )
        }
        guard name != ".", name != "..", !name.contains("..") else {
            throw HelperError.usage("--job must not be '.' or contain '..': '\(name)'")
        }
    }

    private static func positiveInt(
        _ values: [String: String],
        _ name: String,
        default defaultValue: Int
    ) throws -> Int {
        guard let raw = values[name] else { return defaultValue }
        guard let value = Int(raw), value > 0 else {
            throw HelperError.usage("\(name) requires a positive integer, got '\(raw)'")
        }
        return value
    }
}
