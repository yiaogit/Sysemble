// Rosetta for Linux support (P1-e6a).
//
// `probe` reports VZLinuxRosettaDirectoryShare.availability and `run --rosetta`
// refuses to boot unless the host status is `installed`. The availability query
// is a host capability check: it works without the virtualization entitlement
// and without building a VM configuration.
//
// A test-only environment override exists so the notInstalled/notSupported
// branches can be exercised without uninstalling Rosetta from the host. It is
// never set by the helper or by the desktop app; production behavior always
// comes from Virtualization.framework.

import Foundation
import Virtualization

enum RosettaAvailability: String {
    case installed
    case notInstalled
    case notSupported
    case unknown

    /// Why `run --rosetta` cannot continue; nil when Rosetta is installed.
    var blockingMessage: String? {
        switch self {
        case .installed:
            return nil
        case .notInstalled:
            return "Rosetta for Linux is not installed on this host. Install it with "
                + "'softwareupdate --install-rosetta' (add --agree-to-license for a "
                + "non-interactive install) and re-run with --rosetta."
        case .notSupported:
            return "Rosetta for Linux is not supported on this host "
                + "(VZLinuxRosettaDirectoryShare.availability = notSupported). "
                + "The VM cannot translate x86_64 Linux binaries."
        case .unknown:
            return "Rosetta for Linux availability could not be determined on this host, "
                + "so --rosetta cannot be used safely."
        }
    }
}

struct RosettaStatus {
    let availability: RosettaAvailability
    /// Diagnostic detail for `unknown` and for the test override; otherwise nil.
    let reason: String?

    var isInstalled: Bool { availability == .installed }

    /// Text for `probe` and for `run --rosetta` failures. `reason` is carried
    /// through so an override or an unrecognized framework value is visible.
    var note: String? {
        guard let message = availability.blockingMessage else {
            guard let reason else { return nil }
            return "Rosetta for Linux status: \(reason)."
        }
        guard let reason else { return message }
        return message + " (\(reason))"
    }

    /// Test-only. Documented in engine/vm/macos/README.md.
    static let overrideVariable = "SYSEMBLE_VM_TEST_ROSETTA_AVAILABILITY"

    static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RosettaStatus {
        if let raw = environment[overrideVariable], !raw.isEmpty {
            guard let forced = RosettaAvailability(rawValue: raw) else {
                return RosettaStatus(
                    availability: .unknown,
                    reason: "invalid \(overrideVariable)='\(raw)' "
                        + "(expected installed|notInstalled|notSupported|unknown)"
                )
            }
            return RosettaStatus(
                availability: forced,
                reason: "test override \(overrideVariable)=\(raw)"
            )
        }

        let availability = VZLinuxRosettaDirectoryShare.availability
        switch availability {
        case .installed:
            return RosettaStatus(availability: .installed, reason: nil)
        case .notInstalled:
            return RosettaStatus(availability: .notInstalled, reason: nil)
        case .notSupported:
            return RosettaStatus(availability: .notSupported, reason: nil)
        @unknown default:
            return RosettaStatus(
                availability: .unknown,
                reason: "VZLinuxRosettaDirectoryShare.availability returned an "
                    + "unrecognized value (\(availability.rawValue))"
            )
        }
    }
}
