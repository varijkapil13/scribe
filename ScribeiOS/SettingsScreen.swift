import SwiftUI

/// iOS settings — currently the iCloud sync controls. The toggle drives the
/// same `CloudKitSyncService.enabledDefaultsKey` flag the coordinator checks,
/// so sync stays off until the user opts in. "Sync now" runs a round-trip.
///
/// ⚠️ Live sync needs a real iCloud account + the provisioned
/// `iCloud.com.varij.scribe` container; until then `sync()` is a safe no-op.
struct SettingsScreen: View {
    @AppStorage(CloudKitSyncService.enabledDefaultsKey) private var iCloudSyncEnabled = false
    @State private var syncState: SyncState = .idle

    enum SyncState: Equatable {
        case idle, syncing, done
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Sync tasks with iCloud", isOn: $iCloudSyncEnabled)
                } header: {
                    Text("iCloud")
                } footer: {
                    Text("Keep your tasks in sync across iPhone, iPad, and Mac. Requires being signed into iCloud. Notes sync via the iCloud Drive vault.")
                }

                if iCloudSyncEnabled {
                    Section {
                        Button(action: runSync) {
                            HStack {
                                Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                                Spacer()
                                status
                            }
                        }
                        .disabled(syncState == .syncing)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    @ViewBuilder private var status: some View {
        switch syncState {
        case .idle:    EmptyView()
        case .syncing: ProgressView()
        case .done:    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:  Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func runSync() {
        syncState = .syncing
        Task {
            do {
                try await TaskSyncCoordinator.live.sync()
                syncState = .done
            } catch {
                syncState = .failed(error.localizedDescription)
            }
        }
    }
}
