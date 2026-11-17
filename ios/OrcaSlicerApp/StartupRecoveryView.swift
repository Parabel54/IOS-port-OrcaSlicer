import SwiftUI

struct StartupRecoveryView: View {
    @StateObject private var documents = DocumentInbox()
    @State private var loadProfiles: Bool?
    @State private var needsRecovery = StartupRecovery().interrupted
    @State private var preparing = false
    @State private var errorMessage = ""
    @State private var checkedStartup = false

    var body: some View {
        Group {
            if let loadProfiles {
                OrcaRootView(loadSystemProfiles: loadProfiles, documents: documents)
            } else {
                VStack(spacing: 20) {
                    Text(needsRecovery ? "Startup recovery" : "Starting OrcaSlicer")
                        .font(.title2.bold())
                    if preparing || !needsRecovery {
                        ProgressView("Preparing profiles…")
                    }
                    if needsRecovery {
                        Text("The previous startup did not finish. You can open without system profiles or rebuild their generated cache. Projects, user presets, and printer credentials are preserved.")
                        Button("Open without system profiles") {
                            Task { await start(loadSystemProfiles: false, rebuild: false) }
                        }
                        Button("Rebuild profile cache and retry") {
                            Task { await start(loadSystemProfiles: true, rebuild: true) }
                        }
                    }
                    if !errorMessage.isEmpty { Text(errorMessage).font(.caption) }
                }
                .padding(24)
                .buttonStyle(.bordered)
                .disabled(preparing)
            }
        }
        .onOpenURL { documents.receive($0) }
        .task {
            guard !checkedStartup else { return }
            checkedStartup = true
            if !needsRecovery { await start(loadSystemProfiles: true, rebuild: false) }
        }
    }

    @MainActor
    private func start(loadSystemProfiles: Bool, rebuild: Bool) async {
        guard !preparing else { return }
        preparing = true
        errorMessage = ""
        let recovery = StartupRecovery()
        do {
            if loadSystemProfiles {
                try await Task.detached(priority: .userInitiated) {
                    try recovery.prepareProfiles(rebuild: rebuild)
                }.value
            }
            // Let the recovery/loading screen render before synchronous native startup.
            try await Task.sleep(nanoseconds: 100_000_000)
            recovery.begin()
            loadProfiles = loadSystemProfiles
        } catch {
            needsRecovery = true
            errorMessage = error.localizedDescription
        }
        preparing = false
    }
}
