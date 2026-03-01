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

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
            process.arguments = args

            let pipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            // Read output in background
            Task.detached { [weak self] in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                let output = String(data: data, encoding: .utf8) ?? ""
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

                await MainActor.run {
                    // Stream individual file lines to log
                    for line in output.components(separatedBy: "\n") {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty {
                            self?.appendLog(trimmed)
                        }
                    }
                    if !errorOutput.isEmpty {
                        for line in errorOutput.components(separatedBy: "\n") {
                            let trimmed = line.trimmingCharacters(in: .whitespaces)
                            // Filter out common macOS system errors that are harmless
                            if !trimmed.isEmpty && !(self?.shouldFilterError(trimmed) ?? false) {
                                self?.appendLog("⚠ \(trimmed)")
                            }
                        }
                    }
                }

                if process.terminationStatus != 0 && process.terminationStatus != 23 {
                    // 23 = partial transfer (some files couldn't be transferred)
                    continuation.resume(throwing: SyncError.rsyncFailed(Int(process.terminationStatus), errorOutput))
                } else {
                    continuation.resume(returning: output)
                }
            }
        }
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
