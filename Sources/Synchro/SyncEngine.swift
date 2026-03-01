import Foundation
import SwiftUI

@MainActor
final class SyncEngine: ObservableObject {
    @Published var configuration = SyncConfiguration()
    @Published var progress = SyncProgress()
    @Published var isRunning = false
    @Published var lastResult: SyncResult?
    @Published var logLines: [String] = []

    private var currentTask: Task<Void, Never>?

    // MARK: - Bookmarks

    private static let sourceBookmarkKey = "sourceBookmark"
    private static let targetBookmarkKey = "targetBookmark"

    func saveBookmark(for url: URL, key: String) {
        // Start accessing the security-scoped resource before creating bookmark
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            appendLog("⚠ Failed to save bookmark: \(error.localizedDescription)")
        }
    }

    func restoreBookmark(key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            // If stale, re-save the bookmark with proper access
            if isStale {
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                saveBookmark(for: url, key: key)
            }
            
            return url
        } catch {
            appendLog("⚠ Failed to restore bookmark for \(key): \(error.localizedDescription)")
            // Clear the invalid bookmark
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
    }

    func setSource(_ url: URL) {
        configuration.sourceURL = url
        saveBookmark(for: url, key: Self.sourceBookmarkKey)
    }

    func setTarget(_ url: URL) {
        configuration.targetURL = url
        saveBookmark(for: url, key: Self.targetBookmarkKey)
    }

    func restorePreviousSession() {
        if configuration.sourceURL == nil {
            configuration.sourceURL = restoreBookmark(key: Self.sourceBookmarkKey)
        }
        if configuration.targetURL == nil {
            configuration.targetURL = restoreBookmark(key: Self.targetBookmarkKey)
        }
    }

    // MARK: - Sync

    func startSync() {
        guard !isRunning else { return }
        guard configuration.isValid else { return }

        isRunning = true
        logLines = []
        lastResult = nil
        progress = SyncProgress(phase: .scanning)

        currentTask = Task {
            let start = Date()
            var result = SyncResult()

            let sourceAccess = configuration.sourceURL!.startAccessingSecurityScopedResource()
            let targetAccess = configuration.targetURL!.startAccessingSecurityScopedResource()
            defer {
                if sourceAccess { configuration.sourceURL!.stopAccessingSecurityScopedResource() }
                if targetAccess { configuration.targetURL!.stopAccessingSecurityScopedResource() }
            }

            do {
                if configuration.mode == .mirror {
                    progress.phase = .pass1
                    appendLog("Mirror: \(configuration.sourceURL!.path) → \(configuration.targetURL!.path)")
                    let output = try await runRsync(
                        source: configuration.sourceURL!,
                        target: configuration.targetURL!,
                        delete: true
                    )
                    result.logOutput += output
                    parseStats(output, into: &result)
                } else {
                    // Pass 1: source → target
                    progress.phase = .pass1
                    appendLog("Pass 1: \(configuration.sourceURL!.path) → \(configuration.targetURL!.path)")
                    let output1 = try await runRsync(
                        source: configuration.sourceURL!,
                        target: configuration.targetURL!,
                        update: true
                    )
                    result.logOutput += output1
                    parseStats(output1, into: &result)

                    guard !Task.isCancelled else { throw CancellationError() }

                    // Pass 2: target → source
                    progress.phase = .pass2
                    appendLog("Pass 2: \(configuration.targetURL!.path) → \(configuration.sourceURL!.path)")
                    let output2 = try await runRsync(
                        source: configuration.targetURL!,
                        target: configuration.sourceURL!,
                        update: true
                    )
                    result.logOutput += output2
                    parseStats(output2, into: &result)
                }

                result.duration = Date().timeIntervalSince(start)
                progress.phase = .completed
                progress.currentFile = nil

                if configuration.dryRun {
                    appendLog("Dry run complete. No changes made.")
                } else {
                    appendLog("Sync complete.")
                }
            } catch is CancellationError {
                appendLog("Sync cancelled.")
                progress.phase = .error("Cancelled")
                result.errors.append("Cancelled by user")
            } catch {
                appendLog("Error: \(error.localizedDescription)")
                progress.phase = .error(error.localizedDescription)
                result.errors.append(error.localizedDescription)
            }

            result.duration = Date().timeIntervalSince(start)
            lastResult = result
            isRunning = false
        }
    }

    func cancelSync() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - rsync Execution

    private func runRsync(
        source: URL,
        target: URL,
        delete: Bool = false,
        update: Bool = false
    ) async throws -> String {
        var args = ["-a", "--human-readable", "--stats", "--itemize-changes"]

        if configuration.dryRun { args.append("--dry-run") }
        if configuration.useChecksum { args.append("--checksum") }
        if delete { args.append("--delete") }
        if update { args.append("--update") }

        args.append(source.path(percentEncoded: false) + "/")
        args.append(target.path(percentEncoded: false) + "/")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        process.arguments = args

        // Use a PTY for stdout so rsync line-buffers its output in real time.
        // When stdout is a pipe, rsync's C stdio full-buffers and we only see
        // output after rsync exits. A PTY looks like a terminal, forcing
        // line-buffered writes. Falls back to a plain Pipe if PTY creation fails.
        let pty = makePTY()
        let outReader: FileHandle
        let outWriter: FileHandle?
        if let pty {
            process.standardOutput = pty.secondary
            outReader = pty.primary
            outWriter = pty.secondary
        } else {
            let pipe = Pipe()
            process.standardOutput = pipe
            outReader = pipe.fileHandleForReading
            outWriter = nil
        }

        let errPipe = Pipe()
        process.standardError = errPipe

        try process.run()

        // Close our copy of the PTY secondary — the process inherited it
        outWriter?.closeFile()

        // Read stderr concurrently to avoid pipe buffer deadlock
        let stderrTask = Task.detached { () -> String in
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }

        // Stream stdout line by line for live progress
        var output = ""
        try await withTaskCancellationHandler {
            for try await line in outReader.bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    output += line + "\n"
                    appendLog(trimmed)
                    if let fileName = parseItemizeLine(trimmed) {
                        progress.currentFile = fileName
                        progress.filesProcessed += 1
                    }
                }
            }
        } onCancel: {
            process.terminate()
        }

        process.waitUntilExit()

        let errorOutput = await stderrTask.value
        if !errorOutput.isEmpty {
            for line in errorOutput.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && !shouldFilterError(trimmed) {
                    appendLog("⚠ \(trimmed)")
                }
            }
        }

        if process.terminationStatus != 0 && process.terminationStatus != 23 {
            // 23 = partial transfer (some files couldn't be transferred)
            throw SyncError.rsyncFailed(Int(process.terminationStatus), errorOutput)
        }

        return output
    }

    /// Create a pseudo-terminal pair. rsync line-buffers stdout when it detects
    /// a terminal, so a PTY ensures output streams in real time.
    private nonisolated func makePTY() -> (primary: FileHandle, secondary: FileHandle)? {
        let fd = posix_openpt(O_RDWR | O_NOCTTY)
        guard fd >= 0 else { return nil }
        guard grantpt(fd) == 0, unlockpt(fd) == 0, let name = ptsname(fd) else {
            close(fd)
            return nil
        }
        let sec = open(name, O_RDWR)
        guard sec >= 0 else { close(fd); return nil }

        // Disable OPOST so the terminal driver doesn't convert \n → \r\n
        var tio = termios()
        if tcgetattr(sec, &tio) == 0 {
            tio.c_oflag &= ~tcflag_t(OPOST)
            tcsetattr(sec, TCSANOW, &tio)
        }

        return (
            FileHandle(fileDescriptor: fd, closeOnDealloc: true),
            FileHandle(fileDescriptor: sec, closeOnDealloc: true)
        )
    }

    /// Parse rsync --itemize-changes line to extract the filename.
    /// Format: YXcstpoguax filename (11-char prefix + space + path)
    private func parseItemizeLine(_ line: String) -> String? {
        // Standard itemize: ">f..t...... path/to/file"
        if line.count > 12 {
            let first = line[line.startIndex]
            if "<>ch.".contains(first) {
                let idx = line.index(line.startIndex, offsetBy: 12)
                let fileName = String(line[idx...])
                return fileName.isEmpty ? nil : fileName
            }
        }
        // Delete format: "*deleting   path/to/file"
        if line.hasPrefix("*deleting") {
            let rest = String(line.dropFirst("*deleting".count))
                .trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    // MARK: - Parsing

    private func parseStats(_ output: String, into result: inout SyncResult) {
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("Number of regular files transferred:") {
                if let num = extractNumber(from: trimmed) {
                    result.filesCopied += num
                }
            } else if trimmed.hasPrefix("Number of deleted files:") {
                if let num = extractNumber(from: trimmed) {
                    result.filesDeleted += num
                }
            } else if trimmed.hasPrefix("Total transferred file size:") {
                if let bytes = extractBytes(from: trimmed) {
                    result.bytesTransferred += bytes
                }
            }
        }
    }

    private func extractNumber(from line: String) -> Int? {
        let parts = line.components(separatedBy: ":")
        guard parts.count >= 2 else { return nil }
        let numStr = parts[1]
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .joined()
        return Int(numStr)
    }

    private func extractBytes(from line: String) -> Int64? {
        let parts = line.components(separatedBy: ":")
        guard parts.count >= 2 else { return nil }
        let numStr = parts[1]
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: "")
            .components(separatedBy: " ")
            .first ?? ""
        return Int64(numStr)
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
    }

    private func shouldFilterError(_ line: String) -> Bool {
        // Filter out common macOS system errors that don't affect rsync operation
        let ignoredPatterns = [
            "cannot open file at line",
            "os_unix.c:",
            "open(/private/var/db/DetachedSignatures)",
            "Unable to obtain a task name port right",
            "Could not open() the item: [1: Operation not permitted]",
            "No such file or directory",
            "(os/kern) failure"
        ]
        
        return ignoredPatterns.contains { pattern in
            line.contains(pattern)
        }
    }
}

enum SyncError: LocalizedError {
    case rsyncFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .rsyncFailed(let code, let msg):
            "rsync exited with code \(code): \(msg)"
        }
    }
}
