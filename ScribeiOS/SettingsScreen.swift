import SwiftUI

/// iOS settings — currently the iCloud sync controls. The toggle drives the
/// same `CloudKitSyncService.enabledDefaultsKey` flag the coordinator checks,
/// so sync stays off until the user opts in. "Sync now" runs a round-trip.
///
/// ⚠️ Live sync needs a real iCloud account + the provisioned
/// `iCloud.com.varij.scribe` container; until then `sync()` is a safe no-op.
struct SettingsScreen: View {
    @AppStorage(CloudKitSyncService.enabledDefaultsKey) private var iCloudSyncEnabled = false
    @AppStorage("iCloudNotesEnabled") private var iCloudNotesEnabled = false
    @State private var syncState: SyncState = .idle
    @State private var notesState: SyncState = .idle

    enum SyncState: Equatable {
        case idle, syncing, done
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Sync tasks with iCloud", isOn: $iCloudSyncEnabled)
                    Toggle("Store notes in iCloud Drive", isOn: Binding(
                        get: { iCloudNotesEnabled },
                        set: { setNotesEnabled($0) }
                    ))
                    if notesState != .idle {
                        HStack {
                            Text("Notes vault")
                            Spacer()
                            notesStatus
                        }
                    }
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

    @ViewBuilder private var notesStatus: some View {
        switch notesState {
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

    /// Enables/disables the iCloud Drive notes vault via `ICloudVaultMigrator`.
    /// ⚠️ DEVICE-VALIDATION-REQUIRED: the live migrate/copy paths need a
    /// signed-in iCloud account and a provisioned container, so they can only
    /// be exercised on a real device, not in CI.
    private func setNotesEnabled(_ enabled: Bool) {
        if enabled {
            notesState = .syncing
            Task {
                do {
                    try await ICloudVaultMigrator.enableICloudVault()
                    iCloudNotesEnabled = true
                    notesState = .done
                } catch {
                    iCloudNotesEnabled = false
                    notesState = .failed(error.localizedDescription)
                }
            }
        } else {
            ICloudVaultMigrator.disableICloudVault()
            iCloudNotesEnabled = false
            notesState = .idle
        }
    }
}
