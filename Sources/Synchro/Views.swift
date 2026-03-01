import SwiftUI
import UniformTypeIdentifiers

// MARK: - Folder Drop Zone

struct FolderDropZone: View {
    let label: String
    let url: URL?
    let onSelect: () -> Void
    let onDrop: (URL) -> Void

    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 12) {
            Text(label)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .tracking(1.5)

            if let url {
                VStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.blue)
                    Text(url.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                    Text(url.deletingLastPathComponent().path(percentEncoded: false))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("Drop folder here")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("or click to browse")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: url == nil ? [6, 3] : [])
                )
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let urlString = String(data: data, encoding: .utf8),
                  let url = URL(string: urlString) else { return }

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue else { return }

            DispatchQueue.main.async {
                onDrop(url)
            }
        }
        return true
    }
}

// MARK: - Sync Mode Picker

struct SyncModePicker: View {
    @Binding var mode: SyncMode
    @State private var localMode: SyncMode?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Mode", selection: $mode) {
                ForEach(SyncMode.allCases, id: \.self) { m in
                    Label(m.label, systemImage: m.symbol)
                        .tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            
            // Explanation text
            Text(modeExplanation(for: localMode ?? mode))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 320, alignment: .leading)
        }
        .onAppear {
            localMode = mode
        }
        .onChange(of: mode) { newValue in
            localMode = newValue
        }
    }
    
    private func modeExplanation(for syncMode: SyncMode) -> String {
        switch syncMode {
        case .bidirectional:
            return "Copies newer or missing files in both directions. Files are never deleted automatically, making this the safest option."
        case .mirror:
            return "Makes target an exact copy of source. Files in target that don't exist in source will be deleted."
        }
    }
}

// MARK: - Progress Section

struct ProgressSection: View {
    let progress: SyncProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if progress.phase != .completed {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Text(progress.phase.label)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                if progress.filesProcessed > 0 {
                    Text("\(progress.filesProcessed) file\(progress.filesProcessed == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if let file = progress.currentFile {
                Text(file)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

// MARK: - Results View

struct ResultsView: View {
    let result: SyncResult
    let dryRun: Bool

    var body: some View {
        HStack(spacing: 20) {
            if result.isSuccess {
                Image(systemName: dryRun ? "eye.fill" : "checkmark.circle.fill")
                    .foregroundStyle(dryRun ? .blue : .green)
                    .font(.title2)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.title2)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(dryRun ? "Dry Run Complete" : (result.isSuccess ? "Sync Complete" : "Completed with Errors"))
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(formatDuration(result.duration))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
    }

    private var summaryText: String {
        var parts: [String] = []
        if result.filesCopied > 0 {
            parts.append("\(result.filesCopied) file\(result.filesCopied == 1 ? "" : "s") copied")
        }
        if result.filesDeleted > 0 {
            parts.append("\(result.filesDeleted) deleted")
        }
        if result.bytesTransferred > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: result.bytesTransferred, countStyle: .file))
        }
        if parts.isEmpty {
            return "No changes"
        }
        return parts.joined(separator: " · ")
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        if interval < 1 { return "< 1s" }
        if interval < 60 { return String(format: "%.0fs", interval) }
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return "\(minutes)m \(seconds)s"
    }
}

// MARK: - Log View

struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(lineColor(for: line))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: lines.count) { newCount in
                if newCount > 0 {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(newCount - 1, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func lineColor(for line: String) -> Color {
        if line.hasPrefix("⚠") { return .yellow }
        if line.hasPrefix("Error") { return .red }
        if line.contains("complete") { return .green }
        if line.hasPrefix("Pass") || line.hasPrefix("Mirror") { return .blue }
        return .primary.opacity(0.7)
    }
}
