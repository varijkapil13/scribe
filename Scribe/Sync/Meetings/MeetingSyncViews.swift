import SwiftUI

// Small SwiftUI pieces for meeting sync, shared by the Mac and the iPhone /
// iPad app (SwiftUI only — no AppKit / UIKit).

/// "from iPhone" / "from Mac" badge on a meeting recorded on another device.
/// Renders nothing for meetings recorded here. The lookup is a primary-key
/// read, done in `body` so a list that reloads after a sync shows it fresh.
struct MeetingOriginBadge: View {
    let sessionId: String

    var body: some View {
        if let origin = try? MeetingSyncLocalStore.shared.originDevice(sessionId: sessionId) {
            Label(origin.originBadgeLabel, systemImage: "icloud")
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                .accessibilityLabel("Recorded \(origin.originBadgeLabel)")
        }
    }
}

/// Shown where the player would be when a meeting's audio is in iCloud but
/// not on this device: tapping downloads it, then `onDownloaded` reloads the
/// player. Renders nothing otherwise.
struct MeetingAudioDownloadButton: View {
    let sessionId: String
    var onDownloaded: @MainActor (String) -> Void

    @ObservedObject private var scheduler = MeetingSyncScheduler.shared
    @State private var isDownloading = false
    @State private var errorMessage: String?

    var body: some View {
        if isDownloading || errorMessage != nil || scheduler.canDownloadAudio(sessionId: sessionId) {
            VStack(alignment: .leading, spacing: 4) {
                Button(action: download) {
                    HStack(spacing: 6) {
                        if isDownloading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "icloud.and.arrow.down")
                        }
                        Text(isDownloading ? "Downloading recording…" : "Download recording from iCloud")
                    }
                }
                .disabled(isDownloading)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func download() {
        isDownloading = true
        errorMessage = nil
        Task {
            do {
                let path = try await scheduler.downloadAudio(sessionId: sessionId)
                isDownloading = false
                onDownloaded(path)
            } catch {
                isDownloading = false
                errorMessage = "Couldn't download the recording: \(error.localizedDescription)"
            }
        }
    }
}

/// Settings rows for meeting sync: the "Sync meetings" sub-toggle of the
/// existing iCloud opt-in, "Sync recording audio", status and Sync Now.
/// Used by the Mac's Storage & Sync pane and the iOS Settings iCloud section.
struct MeetingSyncSettingsSection: View {
    @AppStorage(CloudKitSyncService.enabledDefaultsKey) private var iCloudSyncEnabled = false
    @AppStorage(MeetingSyncSettings.enabledKey) private var syncMeetings = false
    @AppStorage(MeetingSyncSettings.audioEnabledKey) private var syncAudio = false
    @ObservedObject private var scheduler = MeetingSyncScheduler.shared

    var body: some View {
        Section {
            Toggle("Sync meetings", isOn: $syncMeetings)
                .disabled(!iCloudSyncEnabled)
            if iCloudSyncEnabled && syncMeetings {
                Toggle("Sync recording audio", isOn: $syncAudio)
                if !CloudKitAvailability.isCloudKitEntitled {
                    Label("This build of Scribe isn't set up for iCloud, so meetings stay on this device for now.", systemImage: "icloud.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        Button("Sync Meetings Now") { scheduler.syncNow() }
                            .disabled(scheduler.isSyncing)
                        if scheduler.isSyncing {
                            ProgressView().controlSize(.small)
                        }
                        Spacer(minLength: 0)
                        statusText
                    }
                }
            }
        } header: {
            Text("Meetings")
        } footer: {
            Text(footerText)
        }
    }

    @ViewBuilder private var statusText: some View {
        if let error = scheduler.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
        } else if let date = scheduler.lastSyncedAt {
            Text("Synced \(date.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footerText: String {
        if !iCloudSyncEnabled {
            return "Turn on iCloud sync above to sync meetings between your Mac, iPhone and iPad."
        }
        return "Transcripts, speaker names, bookmarks and summaries of finished recordings appear on your other devices. A recording syncs once it ends. Recording audio (up to 200 MB per file) is uploaded only with “Sync recording audio” on, and downloads on another device when you ask for it."
    }
}
