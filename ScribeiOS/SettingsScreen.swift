import SwiftUI
import UIKit
import UserNotifications

/// iOS / iPadOS settings, grouped into sections.
///
/// EXTENSION POINT for other areas: each area owns one clearly marked slot
/// below (`// MARK: - Slot: <area>`). Add your `Section { … }` (or a
/// `NavigationLink` to your own pane view in a new file under
/// ScribeiOS/<Area>/) at your slot only, so parallel edits never touch the
/// same lines.
///
/// ⚠️ Live iCloud sync needs a real iCloud account + the provisioned
/// `iCloud.com.varij.scribe` container; until then `sync()` is a safe no-op.
struct SettingsScreen: View {
    @AppStorage(CloudKitSyncService.enabledDefaultsKey) private var iCloudSyncEnabled = false
    @AppStorage("iCloudNotesEnabled") private var iCloudNotesEnabled = false
    @AppStorage(ScribeMobileAppearance.storageKey) private var appearanceRaw: String = ScribeMobileAppearance.system.rawValue
    @AppStorage(EntryPointSettings.handoffEnabledKey) private var handoffEnabled = true
    @AppStorage(EntryPointSettings.allowCaptureLinksKey) private var allowCaptureLinks = true

    @State private var syncState: SyncState = .idle
    @State private var notesState: SyncState = .idle
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

    @Environment(\.openURL) private var openURL

    enum SyncState: Equatable {
        case idle, syncing, done
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - iCloud (shell; notes vault rows: ios-notes)
                iCloudSection

                // MARK: - Slot: notes (ios-notes)

                // MARK: - Slot: tasks (ios-tasks)
                Section { NavigationLink { TasksSettingsScreen() } label: { Label("Tasks", systemImage: "checklist") } }

                // MARK: - Slot: recording (ios-recording)
                RecordingSettingsSection()

                // MARK: - Slot: system integrations (ios-system: Siri, widgets, Share)
                ScribeiOSSystemSettingsSection()

                // MARK: - Appearance (shell)
                appearanceSection

                // MARK: - Notifications (shell)
                notificationsSection

                // MARK: - Links & Handoff (shell)
                linksSection

                // MARK: - About (shell) — keep last
                aboutSection
            }
            .navigationTitle("Settings")
            .task { await refreshNotificationStatus() }
        }
    }

    // MARK: - iCloud

    @ViewBuilder private var iCloudSection: some View {
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
                    statusIcon(notesState)
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
                        statusIcon(syncState)
                    }
                }
                .disabled(syncState == .syncing)
                .hoverEffect(.highlight)
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: $appearanceRaw) {
                ForEach(ScribeMobileAppearance.allCases, id: \.self) { appearance in
                    Text(appearance.title).tag(appearance.rawValue)
                }
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("System follows your device's Light or Dark setting.")
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section {
            HStack {
                Text("Task reminders")
                Spacer()
                Text(notificationStatusText)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            if notificationStatus == .notDetermined {
                Button("Allow Notifications") {
                    Task {
                        _ = await TaskReminderScheduler.shared.ensureAuthorized()
                        await refreshNotificationStatus()
                    }
                }
                .hoverEffect(.highlight)
            } else {
                Button("Open Notification Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .hoverEffect(.highlight)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Reminders for tasks with a reminder time, with Mark Done and Snooze actions.")
        }
    }

    private var notificationStatusText: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: return "On"
        case .denied:                               return "Off"
        case .notDetermined:                        return "Not set up"
        @unknown default:                           return "Unknown"
        }
    }

    private func refreshNotificationStatus() async {
        notificationStatus = await Self.currentNotificationStatus()
    }

    /// Reads the authorization status off the main actor so only the
    /// (Sendable) enum crosses back.
    nonisolated private static func currentNotificationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: - Links & Handoff

    private var linksSection: some View {
        Section {
            Toggle("Handoff", isOn: $handoffEnabled)
            Toggle("Links can start recording", isOn: $allowCaptureLinks)
        } header: {
            Text("Links & Handoff")
        } footer: {
            Text("Handoff lets you continue the note or task you're viewing on your Mac or another device. scribe:// links from Shortcuts and other apps always open notes and tasks.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Self.versionString)
            if let url = URL(string: "https://github.com/varijkapil13/scribe") {
                Link(destination: url) {
                    Label("Scribe on GitHub", systemImage: "arrow.up.right.square")
                }
                .hoverEffect(.highlight)
            }
        }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    // MARK: - Helpers

    @ViewBuilder private func statusIcon(_ state: SyncState) -> some View {
        switch state {
        case .idle:
            EmptyView()
        case .syncing:
            ProgressView()
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Done")
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Failed: \(message)")
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
