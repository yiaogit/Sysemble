// `run`: boot the E3a image, speak the file-based job protocol, and return the
// guest's exit code.
//
// Protocol (docs/plan/P1-e3-workplan.md section 2.2), all under <out>:
//   .sysemble-vm/ready    guest -> host: agent mounted the shares
//   .sysemble-vm/job.sh   host -> guest: fixed build command (tmp + rename)
//   .sysemble-vm/log      guest -> host: full stdout/stderr of job.sh
//   .sysemble-vm/done     guest -> host: single-line exit code
//   vm-serial.log         guest console output (host -> /dev/null on the way in)
//
// The host never passes a host path into the guest: the kernel cmdline is
// fixed, job.sh only names /work, /export, and /out, and the plan is copied to
// <out>/plan.json (shared at /export).

import Darwin
import Foundation
import Virtualization

struct RunOptions {
    let imageDir: URL
    let repo: URL
    let out: URL
    let plan: URL
    let cpus: Int
    let memoryMB: Int
    let readyTimeout: TimeInterval
    let timeout: TimeInterval
    let cloneDisk: Bool
    let json: Bool
}

final class VMRunner: NSObject, VZVirtualMachineDelegate {
    private enum WaitOutcome {
        case found
        case timeout
        case interrupted(Int32)
        case failure(String)
    }

    private let options: RunOptions
    private let fileManager = FileManager.default

    private var vm: VZVirtualMachine?
    private var serialRead: FileHandle?
    private var serialWrite: FileHandle?
    private var signalSources: [DispatchSourceSignal] = []
    private var interruptedSignal: Int32?

    private var startFinished = false
    private var startFailure: Error?
    private var stopFinished = false
    private var stopFailure: Error?
    private var runtimeFailure: Error?
    private var guestStopped = false

    private var readySeen = false
    private var doneSeen = false
    private var runStartedAt = Date()

    private let jobCommand =
        "bash /work/engine/vm/guest/minimal-build.sh --plan /export/plan.json "
        + "--out /out --export /export"

    init(options: RunOptions) {
        self.options = options
    }

    // MARK: - Paths

    private var workDirectory: URL {
        options.out.appendingPathComponent(".sysemble-vm", isDirectory: true)
    }

    private var readyURL: URL { workDirectory.appendingPathComponent("ready") }
    private var doneURL: URL { workDirectory.appendingPathComponent("done") }
    private var jobURL: URL { workDirectory.appendingPathComponent("job.sh") }
    private var guestLogURL: URL { workDirectory.appendingPathComponent("log") }
    private var serialLogURL: URL { options.out.appendingPathComponent("vm-serial.log") }
    private var clonedDiskURL: URL { options.out.appendingPathComponent("vm-disk.img") }
    private var planCopyURL: URL { options.out.appendingPathComponent("plan.json") }

    // MARK: - Entry point

    func execute() -> Int32 {
        runStartedAt = Date()
        installSignalHandlers()

        do {
            // Usage-level resource checks happen before any path is touched.
            try VZVMBuilder.validateResources(cpus: options.cpus, memoryMB: options.memoryMB)
            try validateInputs()
            try prepareOutput()
            let diskImage = try prepareDisk()

            if let signal = interruptedSignal {
                return finishInterrupted(signal)
            }

            let configuration = try buildConfiguration(diskImage: diskImage)
            if let signal = interruptedSignal {
                return finishInterrupted(signal)
            }
            let virtualMachine = VZVirtualMachine(configuration: configuration, queue: .main)
            virtualMachine.delegate = self
            vm = virtualMachine

            return runVM(virtualMachine)
        } catch let error as HelperError {
            return finishEarly(with: error)
        } catch {
            return finishEarly(
                with: HelperError(code: 1, message: "unexpected failure: \(error)")
            )
        }
    }

    // MARK: - Input validation (exit 3)

    private func validateInputs() throws {
        guard isDirectory(options.imageDir.path) else {
            throw HelperError.paths("image directory not found: \(options.imageDir.path)")
        }

        for name in ["disk.img", "vmlinuz", "initrd.img"] {
            let path = options.imageDir.appendingPathComponent(name).path
            guard isRegularFile(path) else {
                throw HelperError.paths(
                    "image is incomplete: missing regular file \(path) "
                        + "(expected disk.img, vmlinuz, initrd.img)"
                )
            }
            guard let size = fileSize(path), size > 0 else {
                throw HelperError.paths("image file is empty: \(path)")
            }
        }

        let diskPath = options.imageDir.appendingPathComponent("disk.img").path
        if let size = fileSize(diskPath), size % 512 != 0 {
            throw HelperError.paths(
                "disk.img size \(size) is not a multiple of 512 bytes: \(diskPath)"
            )
        }

        guard isDirectory(options.repo.path) else {
            throw HelperError.paths("repository directory not found: \(options.repo.path)")
        }
        for relative in ["builders/debian/build.sh", "engine/vm/guest/minimal-build.sh"] {
            let path = options.repo.appendingPathComponent(relative).path
            guard isRegularFile(path) else {
                throw HelperError.paths(
                    "repository is missing \(relative): expected \(path). "
                        + "E3a (engine/vm/guest/) must be delivered before run can work."
                )
            }
        }

        guard isRegularFile(options.plan.path) else {
            throw HelperError.paths("plan file not found: \(options.plan.path)")
        }
        if let size = fileSize(options.plan.path), size == 0 {
            throw HelperError.paths("plan file is empty: \(options.plan.path)")
        }
    }

    // MARK: - Host-side preparation (exit 3)

    private func prepareOutput() throws {
        if fileManager.fileExists(atPath: options.out.path) {
            guard isDirectory(options.out.path) else {
                throw HelperError.paths(
                    "--out exists but is not a directory: \(options.out.path)"
                )
            }
        } else {
            do {
                try fileManager.createDirectory(
                    at: options.out,
                    withIntermediateDirectories: true
                )
            } catch {
                throw HelperError.paths(
                    "cannot create --out \(options.out.path): \(error)"
                )
            }
        }

        do {
            try fileManager.createDirectory(
                at: workDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw HelperError.paths(
                "cannot create \(workDirectory.path): \(error)"
            )
        }

        // Only ASCII protocol filenames: the out share is backed by a
        // case-insensitive APFS volume on the development Mac.
        for stale in ["ready", "done", "job.sh", "job.sh.tmp", "log"] {
            let url = workDirectory.appendingPathComponent(stale)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                throw HelperError.paths("cannot remove stale \(url.path): \(error)")
            }
        }

        if options.plan.path != planCopyURL.path {
            do {
                let data = try Data(contentsOf: options.plan)
                try data.write(to: planCopyURL, options: .atomic)
            } catch {
                throw HelperError.paths(
                    "cannot copy plan to \(planCopyURL.path): \(error)"
                )
            }
        }
        writeStderr("host: prepared \(workDirectory.path) and \(planCopyURL.path)")
    }

    private func prepareDisk() throws -> URL {
        let source = options.imageDir.appendingPathComponent("disk.img")
        guard options.cloneDisk else {
            writeStderr(
                "note: --no-clone: using \(source.path) in place; the guest will write "
                    + "to the image disk."
            )
            return source
        }

        let destination = clonedDiskURL
        if fileManager.fileExists(atPath: destination.path) {
            do {
                try fileManager.removeItem(at: destination)
            } catch {
                throw HelperError.paths("cannot replace \(destination.path): \(error)")
            }
        }

        let sourceSize = fileSize(source.path) ?? 0
        var cloneIssue = "cp -c could not be launched"
        if let result = runProcess(
            "/bin/cp",
            ["-c", source.path, destination.path]
        ) {
            if result.status == 0,
                let clonedSize = fileSize(destination.path),
                clonedSize == sourceSize {
                writeStderr("disk: APFS clone \(source.path) -> \(destination.path)")
                return destination
            }
            if result.status != 0 {
                let detail = result.stderr
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cloneIssue = "cp -c exited \(result.status)"
                if !detail.isEmpty {
                    cloneIssue += ": \(detail.prefix(200))"
                }
            } else {
                cloneIssue = "cp -c produced a file with an unexpected size"
            }
        }

        // Clonefile is unavailable (non-APFS volume, old OS, or cp failure):
        // fall back to a plain copy and say why.
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            throw HelperError.paths(
                "cannot copy disk image \(source.path) -> \(destination.path): \(error)"
            )
        }
        writeStderr(
            "disk: full copy \(source.path) -> \(destination.path) "
                + "(APFS clone unavailable: \(cloneIssue))"
        )
        return destination
    }

    private func buildConfiguration(diskImage: URL) throws -> VZVirtualMachineConfiguration {
        do {
            try truncateFile(at: serialLogURL.path)
        } catch {
            throw HelperError.paths(
                "cannot truncate serial log \(serialLogURL.path): \(error)"
            )
        }
        guard let writeHandle = FileHandle(forWritingAtPath: serialLogURL.path) else {
            throw HelperError.paths(
                "cannot open serial log for writing: \(serialLogURL.path)"
            )
        }
        guard let readHandle = FileHandle(forReadingAtPath: "/dev/null") else {
            try? writeHandle.close()
            throw HelperError.paths("cannot open /dev/null for the serial input side")
        }

        do {
            let configuration = try VZVMBuilder.makeConfiguration(
                imageDirectory: options.imageDir,
                diskImage: diskImage,
                repo: options.repo,
                out: options.out,
                cpus: options.cpus,
                memoryMB: options.memoryMB,
                serialRead: readHandle,
                serialWrite: writeHandle
            )
            serialRead = readHandle
            serialWrite = writeHandle
            return configuration
        } catch {
            try? readHandle.close()
            try? writeHandle.close()
            throw error
        }
    }

    // MARK: - VM lifecycle and protocol

    private func runVM(_ virtualMachine: VZVirtualMachine) -> Int32 {
        runStartedAt = Date()
        writeStderr(
            "vm: starting \(options.cpus) vCPU, \(options.memoryMB) MiB, "
                + "disk \(options.cloneDisk ? "clone" : "in place"), "
                + "serial \(serialLogURL.path)"
        )

        virtualMachine.start { [weak self] result in
            guard let self else { return }
            self.startFinished = true
            if case .failure(let error) = result {
                self.startFailure = error
            }
        }

        switch waitForStart(timeout: min(60, options.readyTimeout)) {
        case .found:
            break
        case .interrupted(let signal):
            return finishInterrupted(signal)
        case .timeout:
            return fail(
                HelperError.vm(
                    "VM did not finish starting within \(Int(min(60, options.readyTimeout)))s. "
                        + "See \(serialLogURL.path)."
                ),
                includeSerialLog: true
            )
        case .failure(let message):
            return fail(
                HelperError.vm(
                    "VM failed to start: \(message). "
                        + "Run bash engine/vm/macos/build.sh to sign the helper and "
                        + "check \(serialLogURL.path)."
                ),
                includeSerialLog: true
            )
        }

        writeStderr(
            "vm: started; waiting up to \(Int(options.readyTimeout))s for "
                + "\(readyURL.path)"
        )
        switch waitForFile(readyURL, timeout: options.readyTimeout) {
        case .found:
            readySeen = true
            writeStderr("vm: guest ready")
        case .timeout:
            return fail(
                HelperError.vm(
                    "guest did not write ready within \(Int(options.readyTimeout))s "
                        + "(\(readyURL.path)). The image kernel/initrd or "
                        + "sysemble-vm-agent.service did not start; see the serial log."
                ),
                includeSerialLog: true,
                includeGuestLog: true
            )
        case .interrupted(let signal):
            return finishInterrupted(signal)
        case .failure(let message):
            return fail(
                HelperError.vm("while waiting for ready: \(message)"),
                includeSerialLog: true,
                includeGuestLog: true
            )
        }

        do {
            try publishJob()
        } catch let error as HelperError {
            return fail(error, includeSerialLog: true, includeGuestLog: true)
        } catch {
            return fail(
                HelperError.vm("cannot publish job.sh: \(error)"),
                includeSerialLog: true,
                includeGuestLog: true
            )
        }

        writeStderr(
            "vm: job.sh dispatched; waiting up to \(Int(options.timeout))s for "
                + "\(doneURL.path)"
        )
        switch waitForFile(doneURL, timeout: options.timeout) {
        case .found:
            doneSeen = true
        case .timeout:
            return fail(
                HelperError.vm(
                    "guest did not write done within \(Int(options.timeout))s "
                        + "(\(doneURL.path)). The job is still running or the agent "
                        + "died; see the guest log and serial log."
                ),
                includeSerialLog: true,
                includeGuestLog: true
            )
        case .interrupted(let signal):
            return finishInterrupted(signal)
        case .failure(let message):
            return fail(
                HelperError.vm("while waiting for done: \(message)"),
                includeSerialLog: true,
                includeGuestLog: true
            )
        }

        guard let rawExitCode = readDoneCode() else {
            return fail(
                HelperError.vm(
                    "guest wrote an empty or unreadable exit code to \(doneURL.path)"
                ),
                includeSerialLog: true,
                includeGuestLog: true
            )
        }
        guard let exitCode = Int32(rawExitCode) else {
            return fail(
                HelperError.vm(
                    "guest wrote an invalid exit code to \(doneURL.path): '\(rawExitCode)'"
                ),
                includeSerialLog: true,
                includeGuestLog: true
            )
        }

        let log = tailText(path: guestLogURL.path, maxLines: 100)
        if !options.json {
            print("---- guest log (tail, \(guestLogURL.path)) ----")
            print(log.isEmpty ? "(empty)" : log)
            print("---- end guest log ----")
        }

        let elapsed = Date().timeIntervalSince(runStartedAt)
        let stopMessage = stopVM()
        if let stopMessage {
            writeStderr("sysemble-vm: warning: \(stopMessage)")
        }

        if options.json {
            emitResult(rc: exitCode, elapsed: elapsed, ready: true, done: true, error: nil)
        } else {
            print("guest exit code: \(exitCode)")
        }
        return exitCode
    }

    private func waitForStart(timeout: TimeInterval) -> WaitOutcome {
        let deadline = Date().addingTimeInterval(timeout)
        while !startFinished {
            if let signal = interruptedSignal {
                return .interrupted(signal)
            }
            if Date() >= deadline {
                return .timeout
            }
            pump(0.05)
        }
        if let error = startFailure {
            return .failure(detailedErrorDescription(error))
        }
        guard let state = vm?.state else {
            return .failure("internal error: VM disappeared during start")
        }
        if state == .running {
            return .found
        }
        if state == .error {
            return .failure("Virtualization.framework put the VM in the error state")
        }
        return .failure("VM start finished but its state is \(state)")
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval) -> WaitOutcome {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let signal = interruptedSignal {
                return .interrupted(signal)
            }
            // The file is the protocol's source of truth: the guest may write
            // `done` and power off immediately, so accept it before the
            // guestDidStop delegate flag makes this look like an early exit.
            if fileManager.fileExists(atPath: url.path) {
                return .found
            }
            if let failure = runtimeFailure {
                return .failure("VM stopped with an error: \(detailedErrorDescription(failure))")
            }
            if guestStopped {
                return .failure("guest stopped unexpectedly before writing \(url.lastPathComponent)")
            }
            if let state = vm?.state, state == .error {
                return .failure("VM entered the error state")
            }
            pump(0.2)
        }
        return fileManager.fileExists(atPath: url.path) ? .found : .timeout
    }

    private func publishJob() throws {
        let temporary = workDirectory.appendingPathComponent("job.sh.tmp")
        do {
            try Data((jobCommand + "\n").utf8).write(to: temporary)
        } catch {
            throw HelperError.vm(
                "cannot write \(temporary.path): \(error)"
            )
        }

        if rename(temporary.path, jobURL.path) != 0 {
            let errorNumber = errno
            let reason = String(cString: strerror(errorNumber))
            try? fileManager.removeItem(at: temporary)
            throw HelperError.vm(
                "cannot atomically publish \(jobURL.path): \(reason) (errno \(errorNumber))"
            )
        }
        writeStderr("host: published job.sh atomically")
    }

    private func readDoneCode() -> String? {
        // The guest writes `echo $? > done`; a reader can briefly observe an
        // empty file while the write is in flight.
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if let text = try? String(contentsOf: doneURL, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed.split(whereSeparator: { $0.isNewline })
                        .first
                        .map(String.init) ?? trimmed
                }
            }
            pump(0.05)
        } while Date() < deadline
        return nil
    }

    private func stopVM() -> String? {
        guard let virtualMachine = vm else {
            closeSerialHandles()
            return nil
        }
        if virtualMachine.state == .stopped || virtualMachine.state == .error {
            closeSerialHandles()
            return nil
        }

        // A signal can arrive while start() is still in flight. stop() is not a
        // valid transition from .starting, so give the start a short grace
        // period first; if it never settles the process exit still tears down
        // the VM.
        if virtualMachine.state == .starting {
            let startDeadline = Date().addingTimeInterval(10)
            while virtualMachine.state == .starting && Date() < startDeadline {
                pump(0.05)
            }
        }

        if virtualMachine.state == .stopping {
            let stateDeadline = Date().addingTimeInterval(15)
            while virtualMachine.state != .stopped && Date() < stateDeadline {
                pump(0.05)
            }
            closeSerialHandles()
            if virtualMachine.state != .stopped {
                return "VM did not reach the stopped state within 15s "
                    + "(state: \(virtualMachine.state))"
            }
            return nil
        }

        stopFinished = false
        stopFailure = nil
        virtualMachine.stop { [weak self] error in
            guard let self else { return }
            self.stopFinished = true
            self.stopFailure = error
        }

        let deadline = Date().addingTimeInterval(15)
        while virtualMachine.state != .stopped && Date() < deadline {
            pump(0.05)
            if stopFinished && virtualMachine.state != .stopping {
                break
            }
        }
        let stateDeadline = Date().addingTimeInterval(2)
        while virtualMachine.state != .stopped && Date() < stateDeadline {
            pump(0.05)
        }

        closeSerialHandles()

        if virtualMachine.state != .stopped {
            return "VM did not reach the stopped state within 15s "
                + "(state: \(virtualMachine.state))"
        }
        if let stopFailure {
            // The guest can stop itself between canStop and stop(); the state is
            // what matters, so report the stale callback only as a note.
            writeStderr(
                "vm: note: stop() reported \(stopFailure) after the VM was already stopped"
            )
        }
        return nil
    }

    private func closeSerialHandles() {
        if let serialWrite {
            try? serialWrite.synchronize()
            try? serialWrite.close()
        }
        if let serialRead {
            try? serialRead.close()
        }
        serialWrite = nil
        serialRead = nil
    }

    private func pump(_ interval: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: interval))
    }

    // MARK: - Signals

    private func installSignalHandlers() {
        let handlers: [(Int32, Int32)] = [(SIGINT, 130), (SIGTERM, 143)]
        for (signalNumber, exitCode) in handlers {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                if self.interruptedSignal == nil {
                    self.interruptedSignal = exitCode
                    writeStderr(
                        "sysemble-vm: received signal \(signalNumber); stopping VM"
                    )
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - Results

    private func finishEarly(with error: HelperError) -> Int32 {
        writeStderr("sysemble-vm: error: \(error.message)")
        if options.json {
            emitResult(rc: error.code, elapsed: Date().timeIntervalSince(runStartedAt),
                       ready: readySeen, done: doneSeen, error: error.message)
        }
        return error.code
    }

    private func finishInterrupted(_ signalNumber: Int32) -> Int32 {
        writeStderr("sysemble-vm: interrupted; stopping VM")
        let stopMessage = stopVM()
        if let stopMessage {
            writeStderr("sysemble-vm: warning: \(stopMessage)")
        }
        if options.json {
            emitResult(rc: signalNumber, elapsed: Date().timeIntervalSince(runStartedAt),
                       ready: readySeen, done: doneSeen,
                       error: "interrupted by signal \(signalNumber == 130 ? "SIGINT" : "SIGTERM")")
        }
        return signalNumber
    }

    private func fail(
        _ error: HelperError,
        includeSerialLog: Bool = false,
        includeGuestLog: Bool = false
    ) -> Int32 {
        writeStderr("sysemble-vm: error: \(error.message)")
        if includeSerialLog {
            printLogTail(serialLogURL, label: "vm-serial.log")
        }
        if includeGuestLog {
            printLogTail(guestLogURL, label: "guest log")
        }

        let stopMessage = stopVM()
        if let stopMessage {
            writeStderr("sysemble-vm: warning: \(stopMessage)")
        }

        if options.json {
            emitResult(rc: error.code, elapsed: Date().timeIntervalSince(runStartedAt),
                       ready: readySeen, done: doneSeen, error: error.message)
        }
        return error.code
    }

    private func printLogTail(_ url: URL, label: String, maxLines: Int = 40) {
        guard fileManager.fileExists(atPath: url.path) else {
            writeStderr("---- \(label): not found (\(url.path)) ----")
            return
        }
        let text = tailText(path: url.path, maxLines: maxLines)
        writeStderr("---- \(label) (tail, \(url.path)) ----")
        writeStderr(text.isEmpty ? "(empty)" : text)
        writeStderr("---- end \(label) ----")
    }

    private func emitResult(
        rc: Int32,
        elapsed: TimeInterval,
        ready: Bool,
        done: Bool,
        error: String?
    ) {
        // JSONSerialization prints a binary Double as 92.539000000000001;
        // NSDecimalNumber keeps the documented millisecond precision readable.
        let milliseconds = Int((elapsed * 1000).rounded())
        let elapsedText = String(
            format: "%d.%03d",
            milliseconds / 1000,
            milliseconds % 1000
        )
        var object: [String: Any] = [
            "rc": Int(rc),
            "elapsed_seconds": NSDecimalNumber(string: elapsedText),
            "ready": ready,
            "done": done,
            "log_path": guestLogURL.path,
            "serial_log": serialLogURL.path,
            "work_dir": workDirectory.path
        ]
        if let error {
            object["error"] = error
        }
        do {
            try emitJSON(object)
        } catch {
            writeStderr("sysemble-vm: error: could not encode run JSON: \(error)")
        }
    }

    // MARK: - VZVirtualMachineDelegate

    @objc(guestDidStopVirtualMachine:)
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        guestStopped = true
    }

    @objc(virtualMachine:didStopWithError:)
    func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        didStopWithError error: Error
    ) {
        runtimeFailure = error
    }
}
