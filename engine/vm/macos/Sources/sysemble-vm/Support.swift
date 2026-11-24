// Small, dependency-free helpers shared by the probe and run paths.
//
// Everything here deliberately uses Foundation/Darwin only: the helper is a
// single executable built by SwiftPM with no third-party packages.

import Darwin
import Foundation

/// A failure that maps to one of the exit codes frozen by the P1-e3 workplan:
/// 2 = usage, 3 = image/path, 4 = VM lifecycle. Any other error is reported as
/// exit code 1 (unexpected internal failure).
struct HelperError: Error, CustomStringConvertible {
    let code: Int32
    let message: String

    var description: String { message }

    static func usage(_ message: String) -> HelperError {
        HelperError(code: 2, message: message)
    }

    static func paths(_ message: String) -> HelperError {
        HelperError(code: 3, message: message)
    }

    static func vm(_ message: String) -> HelperError {
        HelperError(code: 4, message: message)
    }
}

/// Expand `~`, resolve `.`/`..`, and make the path absolute without resolving
/// symlinks (the path the caller named is what we check and report).
func absolutePath(_ value: String) -> String {
    let expanded = (value as NSString).expandingTildeInPath
    return URL(fileURLWithPath: expanded).standardizedFileURL.path
}

func isDirectory(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
    return exists && isDir.boolValue
}

func isRegularFile(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
    return exists && !isDir.boolValue
}

func fileSize(_ path: String) -> UInt64? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attributes[.size] as? NSNumber else {
        return nil
    }
    return size.uint64Value
}

func writeStderr(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

/// Emit a deterministic JSON object on stdout. Sorted keys keep the output
/// diff-friendly; withoutEscapingSlashes keeps paths readable.
func emitJSON(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

/// Human-readable macOS version such as "26.6.2".
func macOSVersion() -> String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
}

/// Host architecture from uname(3): "arm64" on Apple Silicon.
func hostArchitecture() -> String {
    var info = utsname()
    guard uname(&info) == 0 else { return "unknown" }
    return withUnsafePointer(to: &info.machine) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: 256) {
            String(cString: $0)
        }
    }
}

/// Tail of a text file, capped by bytes and lines. Used for the guest log and
/// the serial log on failure: the full logs stay on disk as evidence.
func tailText(path: String, maxLines: Int = 100, maxBytes: Int = 256 * 1024) -> String {
    guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
    defer { try? handle.close() }

    let size = (try? handle.seekToEnd()) ?? 0
    let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
    do {
        try handle.seek(toOffset: start)
    } catch {
        return ""
    }
    guard let data = try? handle.readToEnd() else { return "" }

    var lines = String(decoding: data, as: UTF8.self)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    if start > 0 && !lines.isEmpty {
        // The byte window may start in the middle of a line.
        lines.removeFirst()
    }
    if lines.count > maxLines {
        lines = Array(lines.suffix(maxLines))
    }
    while let last = lines.last, last.isEmpty {
        lines.removeLast()
    }
    return lines.joined(separator: "\n")
}

/// Truncate an existing regular file, creating it when absent. Used for the
/// serial log so a re-run does not mix in the previous boot's output.
func truncateFile(at path: String) throws {
    if !FileManager.default.fileExists(atPath: path) {
        guard FileManager.default.createFile(atPath: path, contents: nil) else {
            throw HelperError.paths("could not create file: \(path)")
        }
    }
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    try handle.truncate(atOffset: 0)
}

struct ProcessResult {
    let status: Int32
    let stderr: String
}

/// Run a host utility, capturing stderr. Returns nil when it cannot be
/// launched (for example because /bin/cp is missing).
func runProcess(_ executable: String, _ arguments: [String]) -> ProcessResult? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    let errorPipe = Pipe()
    process.standardError = errorPipe

    do {
        try process.run()
    } catch {
        return nil
    }
    // Read before waitUntilExit to avoid a pipe-buffer deadlock.
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ProcessResult(
        status: process.terminationStatus,
        stderr: String(decoding: errorData, as: UTF8.self)
    )
}

/// Flatten NSError's localized fields and userInfo into one line. The VZ
/// domain sometimes carries the useful sentence (for example the missing
/// entitlement reason) only in NSLocalizedFailureReason, not in
/// `String(describing:)`.
func detailedErrorDescription(_ error: Error) -> String {
    let nsError = error as NSError
    var pieces: [String] = []
    func append(_ value: String?) {
        guard let value, !value.isEmpty, !pieces.contains(value) else { return }
        pieces.append(value)
    }

    append(String(describing: error))
    append(nsError.localizedDescription)
    append(nsError.localizedFailureReason)
    append(nsError.localizedRecoverySuggestion)
    for key in nsError.userInfo.keys.sorted(by: { "\($0)" < "\($1)" }) {
        if let value = nsError.userInfo[key] {
            append("\(key)=\(value)")
        }
    }
    return pieces.joined(separator: " | ")
}
