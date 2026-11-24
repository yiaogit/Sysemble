// swift-tools-version: 5.9
// Sysemble macOS VM helper (P1-e3b).
//
// A single, dependency-free executable that wraps Virtualization.framework:
// `probe` reports whether this host can run a VM, `run` boots the E3a Linux
// image and speaks the file-based job protocol from docs/plan/P1-e3-workplan.md
// section 2.2. The deployment target is macOS 13; Virtualization.framework's
// Linux VM APIs used here are available from macOS 11/12, and the class-level
// `VZVirtualMachine.isSupported` query is only consulted on macOS 14+ (see
// Sources/sysemble-vm/Probe.swift).

import PackageDescription

let package = Package(
    name: "sysemble-vm",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "sysemble-vm", targets: ["sysemble-vm"])
    ],
    targets: [
        .executableTarget(
            name: "sysemble-vm",
            path: "Sources/sysemble-vm"
        )
    ]
)
