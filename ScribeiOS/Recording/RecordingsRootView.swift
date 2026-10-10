// ScribeiOS/Recording/RecordingsRootView.swift
//
// The Record area on iPhone / iPad: the list of recordings, a big Record
// button (microphone only — "In-person / speakerphone"), importing audio /
// video files, the live recording screen and each recording's transcript.
//
// Shell integration (ScribeiOS/Shell, owned by the shell area):
//   • `navigator.recordRequest` (scribe://record/start|stop) →
//     `Task { await MobileRecordingController.shared.perform(.start / .stop) }`
//   • `.onScribeOpenRequest(.meeting) { id in openRecording(id) }` →
//     `RecordingsRootView(openSessionId:)` below pushes that transcript.

import SwiftUI
import UniformTypeIdentifiers

struct RecordingsRootView: View {
    /// A recording to open (deep link / Handoff / Spotlight); pushed when it
    /// changes. Share sheets / other areas can hand files to
    /// `MobileMediaImporter.shared.importFiles(_:)`.
    let openSessionId: String?

    @State private var controller = MobileRecordingController.shared
    @State private var importer = MobileMediaImporter.shared
    @State private var sessions: [Session] = []
    @State private var path: [String] = []
    @State private var isLivePresented = false
    @State private var isFileImporterPresented = false

    init() {
        self.openSessionId = nil
    }

    init(openSessionId: String?) {
        self.openSessionId = openSessionId
    }

    var body: some View {
        NavigationStack(path: $path) {
            list
                .navigationTitle("Record")
                .navigationDestination(for: String.self) { sessionId in
                    RecordingDetailScreen(sessionId: sessionId)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isFileImporterPresented = true
                        } label: {
                            Label("Import Audio or Video", systemImage: "square.and.arrow.down")
                        }
                        .disabled(controller.isActive)
                    }
                }
                .safeAreaInset(edge: .bottom) { recordBar }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: MediaImportFormats.contentTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): importer.importFiles(urls)
            case .failure(let error): importer.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $isLivePresented) {
            LiveRecordingScreen(controller: controller)
                .presentationDragIndicator(.visible)
        }
        .alert("Recording", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.errorMessage ?? importer.errorMessage ?? "")
        }
        .task(id: controller.recordingsVersion) { reload() }
        .onChange(of: importer.lastImportedSessionId) { _, id in
            reload()
            if let id { path = [id] }
        }
        .onChange(of: importer.isImporting) { _, _ in reload() }
        .onChange(of: controller.phase) { old, new in
            if old == .idle, new != .idle { isLivePresented = true }
            if new == .idle, old != .idle { isLivePresented = false }
        }
        .onChange(of: controller.lastFinishedSessionId) { _, id in
            if let id { path = [id] }
        }
        .onChange(of: openSessionId, initial: true) { _, id in
            if let id, !id.isEmpty { path = [id] }
        }
    }

    // MARK: - List

    private var list: some View {
        List {
            if let progress = importer.progress {
                Section("Importing") {
                    MobileImportProgressRow(progress: progress) { importer.cancel() }
                }
            }
            if !sessions.isEmpty {
                Section("Recordings") {
                    ForEach(sessions) { session in
                        NavigationLink(value: session.id) {
                            MobileRecordingRow(
                                session: session,
                                isProcessing: controller.processingSessionIds.contains(session.id),
                                isLive: controller.sessionId == session.id
                            )
                        }
                    }
                    .onDelete(perform: delete)
                }
            }
        }
        .overlay {
            if sessions.isEmpty, importer.progress == nil {
                ContentUnavailableView {
                    Label("No Recordings Yet", systemImage: "waveform")
                } description: {
                    Text("Record a meeting in the room or on speakerphone, or import an audio or video file. Scribe transcribes on this device and writes the summary into a meeting note.")
                }
            }
        }
        .refreshable { reload() }
    }

    // MARK: - Record bar

    @ViewBuilder private var recordBar: some View {
        VStack(spacing: 6) {
            if controller.isActive {
                Button {
                    isLivePresented = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: controller.phase == .paused ? "pause.circle.fill" : "record.circle")
                            .foregroundStyle(controller.phase == .paused ? Color.orange : Color.red)
                            .symbolEffect(.pulse, isActive: controller.phase == .recording)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(controller.title.isEmpty ? "Recording" : controller.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(controller.statusMessage ?? (controller.phase == .paused ? "Paused" : "Tap to show the live transcript"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(MobileRecordingTitle.elapsedLabel(seconds: controller.elapsedSeconds))
                            .font(.headline)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    Task { await controller.start(linkingNoteId: nil) }
                } label: {
                    Label("Record", systemImage: "record.circle.fill")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(importer.isImporting)
                .accessibilityHint("Starts recording with the microphone and transcribing on this device.")
                Text(MobileRecordingDefaults.captureModeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
    }

    // MARK: - Data

    private var errorPresented: Binding<Bool> {
        Binding(
            // The live screen shows recording errors itself while it's up.
            get: { !isLivePresented && (controller.errorMessage != nil || importer.errorMessage != nil) },
            set: { presented in
                if !presented {
                    controller.errorMessage = nil
                    importer.errorMessage = nil
                }
            }
        )
    }

    private func reload() {
        let all = (try? TranscriptStore.shared.fetchAllSessions()) ?? []
        sessions = all.sorted { $0.createdAt > $1.createdAt }
    }

    private func delete(at offsets: IndexSet) {
        let doomed = offsets.compactMap { sessions.indices.contains($0) ? sessions[$0] : nil }
        for session in doomed where session.id != controller.sessionId {
            do {
                try TranscriptStore.shared.deleteSession(id: session.id)
            } catch {
                controller.errorMessage = "Couldn't delete the recording: \(error.localizedDescription)"
            }
        }
        reload()
    }
}

// MARK: - Rows

/// One recording in the list.
struct MobileRecordingRow: View {
    let session: Session
    let isProcessing: Bool
    let isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if isLive {
                    Image(systemName: "record.circle").foregroundStyle(.red)
                }
                Text(session.title.isEmpty ? "Recording" : session.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Text(session.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                if let seconds = session.durationSeconds, session.endedAt != nil {
                    Text("·")
                    Text(MobileRecordingTitle.elapsedLabel(seconds: Double(seconds)))
                        .monospacedDigit()
                }
                if isProcessing {
                    Text("·")
                    Label("Summarizing", systemImage: "sparkles")
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let event = session.calendarEventTitle, !event.isEmpty, event != session.title {
                Label(event, systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The running import.
struct MobileImportProgressRow: View {
    let progress: MobileMediaImporter.Progress
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(progress.fileName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .font(.subheadline)
            }
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !progress.preview.isEmpty {
                Text(progress.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if progress.queued > 0 {
                Text("\(progress.queued) more waiting")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
