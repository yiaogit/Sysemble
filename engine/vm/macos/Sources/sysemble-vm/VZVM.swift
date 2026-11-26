// Build the VZVirtualMachineConfiguration for the Sysemble engine VM.
//
// Device set (frozen by the workplan): virtio-blk root disk, two virtiofs
// shares (repo read-only, out read-write), virtio-net NAT, virtio entropy, and
// one virtio console serial port whose output goes to <out>/vm-serial.log.
// There is no graphics device, no SSH, and no vsock in this prototype.

import Foundation
import Virtualization

enum VZVMBuilder {
    /// Kernel command line frozen by the P1-e3 workplan. The E3a image boots a
    /// raw ext4 root on /dev/vda and starts the systemd multi-user target,
    /// whose sysemble-vm-agent.service handles the file protocol.
    static let kernelCommandLine =
        "console=hvc0 root=/dev/vda rw rootfstype=ext4 systemd.unit=multi-user.target"

    static let repoTag = "sysemble-repo"
    static let outTag = "sysemble-out"
    static let rosettaTag = "rosetta"

    /// Validate CPU/memory against the ranges Virtualization.framework reports
    /// for this host. These are usage errors (exit 2), checked before --out is
    /// touched.
    static func validateResources(cpus: Int, memoryMB: Int) throws {
        let minimumCPUs = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        let maximumCPUs = VZVirtualMachineConfiguration.maximumAllowedCPUCount
        guard cpus >= minimumCPUs && cpus <= maximumCPUs else {
            throw HelperError.usage(
                "--cpus \(cpus) is outside this host's Virtualization.framework range "
                    + "\(minimumCPUs)...\(maximumCPUs)"
            )
        }

        let bytesPerMiB: UInt64 = 1024 * 1024
        guard memoryMB > 0, UInt64(memoryMB) <= UInt64.max / bytesPerMiB else {
            throw HelperError.usage("--memory-mb \(memoryMB) is not a valid memory size")
        }
        let memoryBytes = UInt64(memoryMB) * bytesPerMiB
        let minimumMemory = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let maximumMemory = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        guard memoryBytes >= minimumMemory && memoryBytes <= maximumMemory else {
            throw HelperError.usage(
                "--memory-mb \(memoryMB) is outside this host's Virtualization.framework "
                    + "range \(minimumMemory / bytesPerMiB)...\(maximumMemory / bytesPerMiB) MiB"
            )
        }
    }

    static func makeConfiguration(
        imageDirectory: URL,
        diskImage: URL,
        repo: URL,
        out: URL,
        cpus: Int,
        memoryMB: Int,
        rosetta: Bool,
        serialRead: FileHandle,
        serialWrite: FileHandle
    ) throws -> VZVirtualMachineConfiguration {
        try validateResources(cpus: cpus, memoryMB: memoryMB)

        let bootLoader = VZLinuxBootLoader(
            kernelURL: imageDirectory.appendingPathComponent("vmlinuz")
        )
        bootLoader.initialRamdiskURL = imageDirectory.appendingPathComponent("initrd.img")
        bootLoader.commandLine = kernelCommandLine

        let disk: VZDiskImageStorageDeviceAttachment
        do {
            disk = try VZDiskImageStorageDeviceAttachment(
                url: diskImage,
                readOnly: false,
                cachingMode: .cached,
                synchronizationMode: .fsync
            )
        } catch {
            throw HelperError.paths(
                "cannot attach disk image \(diskImage.path): \(error). Expected a raw image "
                    + "whose size is a multiple of 512 bytes."
            )
        }
        let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: disk)

        let repoShare = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: repo, readOnly: true)
        )
        let repoDevice = VZVirtioFileSystemDeviceConfiguration(tag: repoTag)
        repoDevice.share = repoShare

        let outShare = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: out, readOnly: false)
        )
        let outDevice = VZVirtioFileSystemDeviceConfiguration(tag: outTag)
        outDevice.share = outShare

        var directorySharingDevices: [VZDirectorySharingDeviceConfiguration] = [
            repoDevice, outDevice
        ]
        if rosetta {
            // VZLinuxRosettaDirectoryShare.availability was already checked as
            // installed by Runner; init() can still fail (for example if the
            // host policy changed between the check and here).
            let rosettaShare: VZLinuxRosettaDirectoryShare
            do {
                rosettaShare = try VZLinuxRosettaDirectoryShare()
            } catch {
                throw HelperError.vm(
                    "cannot attach the Rosetta for Linux directory share: "
                        + "\(detailedErrorDescription(error)). Run "
                        + "'softwareupdate --install-rosetta' and retry."
                )
            }
            let rosettaDevice = VZVirtioFileSystemDeviceConfiguration(tag: rosettaTag)
            rosettaDevice.share = rosettaShare
            directorySharingDevices.append(rosettaDevice)
        }

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()

        let entropy = VZVirtioEntropyDeviceConfiguration()

        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: serialRead,
            fileHandleForWriting: serialWrite
        )

        let configuration = VZVirtualMachineConfiguration()
        configuration.bootLoader = bootLoader
        configuration.storageDevices = [blockDevice]
        configuration.directorySharingDevices = directorySharingDevices
        configuration.networkDevices = [network]
        configuration.entropyDevices = [entropy]
        configuration.serialPorts = [serial]
        configuration.cpuCount = cpus
        configuration.memorySize = UInt64(memoryMB) * 1024 * 1024

        do {
            try configuration.validate()
        } catch {
            let detail = detailedErrorDescription(error)
            let lowered = detail.lowercased()
            let hint = lowered.contains("entitlement")
                || lowered.contains("com.apple.security.virtualization")
                ? " Hint: run bash engine/vm/macos/build.sh to ad-hoc sign the helper "
                    + "with com.apple.security.virtualization."
                : ""
            throw HelperError.vm(
                "Virtualization.framework rejected the VM configuration: \(detail).\(hint)"
            )
        }
        return configuration
    }
}
