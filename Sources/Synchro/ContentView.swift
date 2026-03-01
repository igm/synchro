import SwiftUI

struct ContentView: View {
    @StateObject private var engine = SyncEngine()
    @State private var showMirrorConfirmation = false
    @State private var showFolderPicker = false
    @State private var pendingPickerType: PickerType?
    
    enum PickerType {
        case source, target
    }

    var body: some View {
        VStack(spacing: 0) {
            // Folder panels
            HStack(spacing: 16) {
                FolderDropZone(
                    label: "SOURCE",
                    url: engine.configuration.sourceURL,
                    onSelect: { 
                        pendingPickerType = .source
                        showFolderPicker = true
                    },
                    onDrop: { engine.setSource($0) }
                )
                FolderDropZone(
                    label: "TARGET",
                    url: engine.configuration.targetURL,
                    onSelect: { 
                        pendingPickerType = .target
                        showFolderPicker = true
                    },
                    onDrop: { engine.setTarget($0) }
                )
            }
            .padding(20)

            Divider()

            // Options bar
            HStack(spacing: 24) {
                SyncModePicker(mode: $engine.configuration.mode)

                Spacer()

                Toggle("Dry Run", isOn: $engine.configuration.dryRun)
                    .toggleStyle(.checkbox)
                    .help("Preview changes without making them")

                Toggle("Checksum", isOn: $engine.configuration.useChecksum)
                    .toggleStyle(.checkbox)
                    .help("Use checksums for file comparison (slower but more reliable)")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .disabled(engine.isRunning)

            Divider()

            // Sync controls
            HStack(spacing: 16) {
                // Swap button
                Button {
                    swapDirectories()
                } label: {
                    Label("Swap Folders", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(.bordered)
                .disabled(engine.isRunning)
                .help("Swap source and target")

                Spacer()

                // Validation / status
                if let error = engine.configuration.validationError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(error)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Main sync button
                if engine.isRunning {
                    Button("Cancel Sync", role: .destructive) {
                        engine.cancelSync()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        initiateSync()
                    } label: {
                        Label(engine.configuration.dryRun ? "Preview Changes" : "Start Sync", 
                              systemImage: engine.configuration.mode.symbol)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!engine.configuration.isValid)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            // Progress
            if engine.isRunning || engine.progress.phase == .completed {
                ProgressSection(progress: engine.progress)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }

            // Results summary
            if let result = engine.lastResult, !engine.isRunning {
                ResultsView(result: result, dryRun: engine.configuration.dryRun)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                Divider()
            }

            // Log output
            LogView(lines: engine.logLines)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder]
        ) { result in
            guard case .success(let url) = result else {
                pendingPickerType = nil
                return
            }
            
            switch pendingPickerType {
            case .source:
                engine.setSource(url)
            case .target:
                engine.setTarget(url)
            case .none:
                break
            }
            
            pendingPickerType = nil
        }
        .confirmationDialog(
            "Mirror Mode Warning",
            isPresented: $showMirrorConfirmation,
            titleVisibility: .visible
        ) {
            Button("Mirror Sync", role: .destructive) {
                engine.startSync()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Files in target that don't exist in source will be permanently deleted. This cannot be undone.")
        }
        .onAppear {
            engine.restorePreviousSession()
        }
    }

    private func swapDirectories() {
        let source = engine.configuration.sourceURL
        let target = engine.configuration.targetURL
        // Use setSource/setTarget to properly save bookmarks
        if let newSource = target {
            engine.setSource(newSource)
        }
        if let newTarget = source {
            engine.setTarget(newTarget)
        }
    }

    private func initiateSync() {
        if engine.configuration.mode == .mirror && !engine.configuration.dryRun {
            showMirrorConfirmation = true
        } else {
            engine.startSync()
        }
    }
}
