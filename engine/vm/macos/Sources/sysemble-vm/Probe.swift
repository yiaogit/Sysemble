// `probe`: report whether this host can run Virtualization.framework and
// whether this executable is signed with the virtualization entitlement.
//
// The entitlement check deliberately builds a minimal VZ configuration and
// calls validate(); it never starts a VM. Apple documents this as the runtime
// check that fails when com.apple.security.virtualization is missing.
//
// Exit code is always 0 (except for invalid arguments), because probe is a
// diagnostic, not a gate: CI on a macOS runner reports supported=false instead
// of failing.

import Foundation
import Virtualization

enum SupportedStatus {
    case known(Bool)
    case unknown
}

struct ProbeResult {
    let supported: SupportedStatus
    let entitled: Bool
    let architecture: String
    let macOS: String
    let cpus: Int
    let reason: String

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "entitled": entitled,
            "arch": architecture,
            "macos": macOS,
            "cpus": cpus,
            "reason": reason
        ]
        switch supported {
        case .known(let value):
            object["supported"] = value
        case .unknown:
            object["supported"] = "unknown"
        }
        return object
    }

    var supportedText: String {
        switch supported {
        case .known(let value):
            return value ? "true" : "false"
        case .unknown:
            return "unknown"
        }
    }
}

enum Probe {
    static func run(json: Bool) -> Int32 {
        let result = detect()
        if json {
            do {
                try emitJSON(result.jsonObject)
            } catch {
                // JSONSerialization cannot fail for the primitives above, but
                // keep probe's exit contract even if it somehow does.
                writeStderr("sysemble-vm: error: could not encode probe JSON: \(error)")
                return 0
            }
        } else {
            printHuman(result)
        }
        return 0
    }

    private static func printHuman(_ result: ProbeResult) {
        print("sysemble-vm probe")
        print("  supported: \(result.supportedText)")
        print("  entitled:  \(result.entitled ? "true" : "false")")
        print("  arch:      \(result.architecture)")
        print("  macos:     \(result.macOS)")
        print("  cpus:      \(result.cpus)")
        print("  reason:    \(result.reason)")
    }

    private static func detect() -> ProbeResult {
        let architecture = hostArchitecture()
        let macOS = macOSVersion()
        let cpus = ProcessInfo.processInfo.processorCount
        var notes: [String] = []

        var supported: SupportedStatus = .unknown
        if #available(macOS 14.0, *) {
            let isSupported = VZVirtualMachine.isSupported
            supported = .known(isSupported)
            if !isSupported {
                notes.append(
                    "VZVirtualMachine.isSupported is false: this host cannot start a "
                        + "Virtualization.framework VM (hardware, OS policy, or a "
                        + "nested-virtualization restriction such as a CI runner)."
                )
            }
        } else {
            notes.append(
                "VZVirtualMachine.isSupported is only consulted on macOS 14+; "
                    + "reporting 'unknown' on macOS \(macOS)."
            )
        }

        let entitlement = checkEntitlement()
        if !entitlement.entitled {
            notes.append(entitlement.explanation)
        } else if let note = entitlement.note {
            notes.append(note)
        }

        if architecture != "arm64" {
            notes.append(
                "host architecture is \(architecture); the E3a guest image is arm64-only, "
                    + "so this prototype cannot boot it on this host."
            )
        }

        if notes.isEmpty {
            notes.append(
                "ok: Virtualization.framework is supported and "
                    + "VZVirtualMachineConfiguration.validate() accepted the signature."
            )
        }

        return ProbeResult(
            supported: supported,
            entitled: entitlement.entitled,
            architecture: architecture,
            macOS: macOS,
            cpus: cpus,
            reason: notes.joined(separator: " ")
        )
    }

    private struct EntitlementCheck {
        let entitled: Bool
        let explanation: String
        let note: String?
    }

    /// Build a throw-away 1 MiB kernel/initrd/disk and ask VZ to validate a
    /// configuration that references them. An unsigned process fails before
    /// any guest code runs; no VM is started.
    private static func checkEntitlement() -> EntitlementCheck {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("sysemble-vm-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let megabyte = Data(count: 1024 * 1024)
            for name in ["vmlinuz", "initrd.img", "disk.img"] {
                try megabyte.write(to: directory.appendingPathComponent(name))
            }
        } catch {
            // Without the throw-away image we cannot ask VZ to validate. Report
            // false conservatively, but make clear this is a setup failure and
            // not a rejected signature.
            return EntitlementCheck(
                entitled: false,
                explanation:
                    "could not create probe files under \(directory.path): \(error). "
                        + "Entitlement could not be determined.",
                note: nil
            )
        }

        do {
            let bootLoader = VZLinuxBootLoader(
                kernelURL: directory.appendingPathComponent("vmlinuz")
            )
            bootLoader.initialRamdiskURL = directory.appendingPathComponent("initrd.img")
            bootLoader.commandLine = "console=hvc0"

            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: directory.appendingPathComponent("disk.img"),
                readOnly: true
            )
            let disk = VZVirtioBlockDeviceConfiguration(attachment: attachment)

            let configuration = VZVirtualMachineConfiguration()
            configuration.bootLoader = bootLoader
            configuration.storageDevices = [disk]
            configuration.cpuCount = VZVirtualMachineConfiguration.minimumAllowedCPUCount
            configuration.memorySize = VZVirtualMachineConfiguration.minimumAllowedMemorySize

            try configuration.validate()
            return EntitlementCheck(
                entitled: true,
                explanation: "",
                note: nil
            )
        } catch {
            let detail = detailedErrorDescription(error)
            let lowered = detail.lowercased()
            let mentionsEntitlement = lowered.contains("entitlement")
                || lowered.contains("com.apple.security.virtualization")
            // A host that cannot virtualize at all reports a support error, not
            // a signing error. Do not blame the signature for that; report it
            // as a note instead. The boolean still means "validate() did not
            // reject the signature".
            let mentionsUnsupportedHost = lowered.contains("not supported")
                || lowered.contains("unsupported")
                || lowered.contains("nested virtualization")

            if mentionsEntitlement {
                return EntitlementCheck(
                    entitled: false,
                    explanation:
                        "VZVirtualMachineConfiguration.validate() rejected this executable: "
                            + "\(detail). Re-run engine/vm/macos/build.sh so the binary is "
                            + "ad-hoc signed with com.apple.security.virtualization.",
                    note: nil
                )
            }
            if mentionsUnsupportedHost {
                return EntitlementCheck(
                    entitled: true,
                    explanation: "",
                    note:
                        "VZVirtualMachineConfiguration.validate() failed for a host-support "
                            + "reason, not a signing reason: \(detail)"
                )
            }
            if lowered.contains("virtualization") {
                return EntitlementCheck(
                    entitled: false,
                    explanation:
                        "VZVirtualMachineConfiguration.validate() failed while loading "
                            + "Virtualization.framework: \(detail). Sign the helper with "
                            + "com.apple.security.virtualization.",
                    note: nil
                )
            }
            return EntitlementCheck(
                entitled: true,
                explanation: "",
                note:
                    "VZVirtualMachineConfiguration.validate() returned a non-entitlement "
                        + "error: \(detail)"
            )
        }
    }
}
