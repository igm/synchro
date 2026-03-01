import Foundation

enum SyncMode: String, CaseIterable {
    case bidirectional
    case mirror

    var label: String {
        switch self {
        case .bidirectional: "Bidirectional"
        case .mirror: "Mirror"
        }
    }

    var description: String {
        switch self {
        case .bidirectional: "Copies newer/missing files both ways. Never deletes."
        case .mirror: "Source → Target. Deletes extra files in target."
        }
    }

    var symbol: String {
        switch self {
        case .bidirectional: "arrow.left.arrow.right"
        case .mirror: "arrow.right"
        }
    }
}

struct SyncConfiguration {
    var sourceURL: URL?
    var targetURL: URL?
    var mode: SyncMode = .bidirectional
    var dryRun: Bool = true
    var useChecksum: Bool = false

    var isValid: Bool {
        guard let source = sourceURL, let target = targetURL else { return false }
        let s = source.standardizedFileURL.path
        let t = target.standardizedFileURL.path
        if s == t { return false }
        if s.hasPrefix(t + "/") || t.hasPrefix(s + "/") { return false }
        return true
    }

    var validationError: String? {
        guard sourceURL != nil else { return "Select a source folder" }
        guard targetURL != nil else { return "Select a target folder" }
        guard let source = sourceURL, let target = targetURL else { return nil }
        let s = source.standardizedFileURL.path
        let t = target.standardizedFileURL.path
        if s == t { return "Source and target are the same directory" }
        if t.hasPrefix(s + "/") { return "Target is a subdirectory of source" }
        if s.hasPrefix(t + "/") { return "Source is a subdirectory of target" }
        return nil
    }
}

enum SyncPhase: Equatable {
    case idle
    case scanning
    case pass1
    case pass2
    case completed
    case error(String)

    var label: String {
        switch self {
        case .idle: "Ready"
        case .scanning: "Scanning…"
        case .pass1: "Pass 1: Source → Target"
        case .pass2: "Pass 2: Target → Source"
        case .completed: "Completed"
        case .error(let msg): "Error: \(msg)"
        }
    }
}

struct SyncProgress {
    var phase: SyncPhase = .idle
    var currentFile: String?
    var filesProcessed: Int = 0
    var bytesTransferred: Int64 = 0
    var totalBytes: Int64?
}

struct SyncResult {
    var filesCopied: Int = 0
    var filesDeleted: Int = 0
    var bytesTransferred: Int64 = 0
    var duration: TimeInterval = 0
    var errors: [String] = []
    var logOutput: String = ""

    var isSuccess: Bool { errors.isEmpty }
}
