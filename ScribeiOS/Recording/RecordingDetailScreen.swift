// ScribeiOS/Recording/RecordingDetailScreen.swift
//
// One recording on iPhone / iPad: playback of the retained audio with
// tap-to-seek on the transcript, speaker labels (renameable), bookmarked
// highlights, the on-device summary and its action items (→ tasks), and a
// link to the meeting note.

import SwiftUI
import UIKit

struct RecordingDetailScreen: View {
    let sessionId: String

    @State private var controller = MobileRecordingController.shared
    @State private var player = MobileTranscriptPlayer()
    @State private var session: Session?
    @State private var segments: [Segment] = []
    @State private var summary: MeetingSummary?
    @State private var bookmarks: [SessionBookmark] = []
    @State private var resolver = SpeakerNameResolver()
    @State private var convertedActionItemIds: Set<String> = []
    @State private var noteTitle: String?
    @State private var renamingSpeakerKey: String?
    @State private var speakerNameDraft = ""
    @State private var message: String?

    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            headerSection
            if player.isAvailable { playerSection }
            if controller.processingSessionIds.contains(sessionId) {
                Section {
                    Label("Summarizing on this device…", systemImage: "sparkles")
                        .foregroundStyle(.secondary)
                }
            }
            if let summary { summarySections(summary) }
            if !bookmarks.isEmpty { highlightsSection }
            transcriptSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(session?.title ?? "Recording")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task(id: controller.recordingsVersion) { load() }
        .onDisappear { player.stop() }
        .alert("Rename Speaker", isPresented: renamePresented) {
            TextField("Name", text: $speakerNameDraft)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renamingSpeakerKey = nil }
        } message: {
            Text("Used for this recording's transcript, summary and meeting note.")
        }
        .alert("Recording", isPresented: messagePresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            if let session {
                LabeledContent("Recorded") {
                    Text(session.createdAt, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                }
                if let seconds = session.durationSeconds {
                    LabeledContent("Length", value: MobileRecordingTitle.elapsedLabel(seconds: Double(seconds)))
                }
                if let event = session.calendarEventTitle, !event.isEmpty {
                    LabeledContent("Calendar event", value: event)
                }
                if !session.attendees.isEmpty {
                    LabeledContent("Attendees", value: session.attendees.map(\.displayName).joined(separator: ", "))
                }
                if let noteId = session.noteId, let url = URL(string: "scribe://note/\(noteId)") {
                    Button {
                        openURL(url)
                    } label: {
                        Label(noteTitle.map { "Open “\($0)”" } ?? "Open Meeting Note", systemImage: "doc.text")
                    }
                }
            } else {
                Text("This recording no longer exists.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var playerSection: some View {
        Section {
            VStack(spacing: 10) {
                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(toMs: Int($0 * 1_000)) }
                    ),
                    in: 0...max(player.duration, 0.1)
                )
                .accessibilityLabel("Playback position")
                HStack {
                    Text(MobileRecordingTitle.elapsedLabel(seconds: player.currentTime))
                        .monospacedDigit()
                    Spacer()
                    Button {
                        player.skip(by: -15)
                    } label: {
                        Image(systemName: "gobackward.15")
                    }
                    .accessibilityLabel("Back 15 seconds")
                    Button {
                        player.togglePlay()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 40))
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    Button {
                        player.skip(by: 15)
                    } label: {
                        Image(systemName: "goforward.15")
                    }
                    .accessibilityLabel("Forward 15 seconds")
                    Spacer()
                    Text(MobileRecordingTitle.elapsedLabel(seconds: player.duration))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .font(.title3)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private func summarySections(_ summary: MeetingSummary) -> some View {
        Section("Summary") {
            Text(summary.summary)
                .textSelection(.enabled)
            if !summary.keyDecisions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Key decisions").font(.subheadline.weight(.semibold))
                    ForEach(Array(summary.keyDecisions.enumerated()), id: \.offset) { _, decision in
                        Text("• \(decision)")
                    }
                }
            }
        }
        if !summary.actionItems.isEmpty {
            Section("Action Items") {
                ForEach(summary.actionItems) { item in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.description)
                            let detail = [item.assignee, item.deadline.map { "due \($0)" }]
                                .compactMap { $0 }
                                .filter { !$0.isEmpty }
                                .joined(separator: " · ")
                            if !detail.isEmpty {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if convertedActionItemIds.contains(item.id.uuidString) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .accessibilityLabel("Added to tasks")
                        } else {
                            Button {
                                convert(item)
                            } label: {
                                Label("Add Task", systemImage: "plus.circle")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Add as task")
                        }
                    }
                }
            }
        }
        if !summary.followUpQuestions.isEmpty {
            Section("Open Questions") {
                ForEach(Array(summary.followUpQuestions.enumerated()), id: \.offset) { _, question in
                    Text(question)
                }
            }
        }
    }

    private var highlightsSection: some View {
        Section("Highlights") {
            ForEach(bookmarks) { bookmark in
                Button {
                    player.seek(toMs: bookmark.offsetMs)
                } label: {
                    HStack {
                        Image(systemName: "bookmark.fill").foregroundStyle(.orange)
                        Text(bookmark.trimmedLabel ?? "Marked moment")
                        Spacer()
                        Text(SessionBookmarkFormatter.shortTimestamp(ms: bookmark.offsetMs))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!player.isAvailable)
            }
        }
    }

    private var transcriptSection: some View {
        Section {
            if segments.isEmpty {
                Text(controller.sessionId == sessionId
                     ? "Recording… the transcript fills in as it is finalized."
                     : "No transcript.")
                    .foregroundStyle(.secondary)
            }
            ForEach(segments) { segment in
                Button {
                    if player.isAvailable { player.seek(toMs: segment.startMs) }
                } label: {
                    MobileTranscriptLineView(
                        speaker: resolver.displayName(for: segment),
                        startMs: segment.startMs,
                        text: segment.text,
                        isLive: false
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(isCurrent(segment) ? Color.accentColor.opacity(0.12) : nil)
                .contextMenu {
                    Button("Rename Speaker…", systemImage: "person.crop.circle") {
                        beginRename(key: SpeakerNameResolver.effectiveKey(for: segment))
                    }
                    Button("Copy Text", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = segment.text
                    }
                }
            }
        } header: {
            Text("Transcript")
        } footer: {
            if player.isAvailable, !segments.isEmpty {
                Text("Tap a line to play from there.")
            }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Summarize Again", systemImage: "sparkles") {
                    controller.runPostProcessing(sessionId: sessionId, summarize: true)
                }
                .disabled(segments.isEmpty || controller.processingSessionIds.contains(sessionId)
                          || !RecordingPostProcessor.isSummarizerAvailable)
                Button("Update Meeting Note", systemImage: "doc.badge.arrow.up") {
                    controller.runPostProcessing(sessionId: sessionId, summarize: false)
                }
                .disabled(segments.isEmpty || controller.processingSessionIds.contains(sessionId))
                ShareLink(item: shareText) {
                    Label("Share Transcript", systemImage: "square.and.arrow.up")
                }
                .disabled(segments.isEmpty)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: - Actions

    private func load() {
        let store = TranscriptStore.shared
        session = try? store.fetchSession(id: sessionId)
        segments = (try? store.fetchSegments(sessionId: sessionId)) ?? []
        summary = try? store.fetchSummary(sessionId: sessionId)
        bookmarks = SessionBookmarkFormatter.sorted((try? SessionBookmarkStore.shared.fetch(sessionId: sessionId)) ?? [])
        resolver = store.speakerResolver(sessionId: sessionId)
        noteTitle = session?.noteId.flatMap { try? NoteStore.shared.fetchNote(id: $0) }?.title
        if let summary {
            convertedActionItemIds = Set(summary.actionItems.compactMap { item -> String? in
                let id = item.id.uuidString
                return (try? TaskStore.shared.fetchTaskForActionItem(id)) != nil ? id : nil
            })
        }
        // Audio only once the recording has finished (the file is still
        // being written while it runs).
        if controller.sessionId != sessionId, !player.isAvailable, let session {
            let directory = SessionAudioLocator.directory(
                storedPath: session.audioDirectory,
                sessionId: session.id,
                currentRoot: SessionAudioStorage.defaultRoot(),
                fileExists: { FileManager.default.fileExists(atPath: $0) }
            )
            let file = directory.flatMap { dir in
                SessionAudioLocator.playableFile(in: dir, fileExists: { FileManager.default.fileExists(atPath: $0) })
            }
            player.load(url: file)
        }
    }

    private func convert(_ item: ActionItem) {
        let created = RecordingPostProcessor(
            transcriptStore: TranscriptStore.shared,
            noteStore: NoteStore.shared,
            taskStore: TaskStore.shared,
            bookmarkStore: SessionBookmarkStore.shared
        ).convertActionItems([item], sessionId: sessionId, noteId: session?.noteId)
        if created > 0 {
            convertedActionItemIds.insert(item.id.uuidString)
        } else if (try? TaskStore.shared.fetchTaskForActionItem(item.id.uuidString)) != nil {
            convertedActionItemIds.insert(item.id.uuidString)
        } else {
            message = "Couldn't add the task."
        }
    }

    private func isCurrent(_ segment: Segment) -> Bool {
        guard player.isPlaying || player.currentTime > 0 else { return false }
        let ms = player.currentMs
        return ms >= segment.startMs && ms <= max(segment.endMs, segment.startMs + 500)
    }

    private func beginRename(key: String) {
        renamingSpeakerKey = key
        speakerNameDraft = resolver.displayName(forKey: key)
    }

    private func commitRename() {
        guard let key = renamingSpeakerKey else { return }
        renamingSpeakerKey = nil
        let name = speakerNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try TranscriptStore.shared.setSpeakerName(name, forKey: key, sessionId: sessionId)
            resolver = TranscriptStore.shared.speakerResolver(sessionId: sessionId)
            // Rewrite the transcript / highlights in the note with the name.
            controller.runPostProcessing(sessionId: sessionId, summarize: false)
        } catch {
            message = "Couldn't rename the speaker: \(error.localizedDescription)"
        }
    }

    private var shareText: String {
        let title = session?.title ?? "Recording"
        let body = MeetingNoteRecap.transcriptMarkdown(segments: segments, speakerName: { resolver.displayName(for: $0) }) ?? ""
        return "# \(title)\n\n" + body
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renamingSpeakerKey != nil },
            set: { if !$0 { renamingSpeakerKey = nil } }
        )
    }

    private var messagePresented: Binding<Bool> {
        Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )
    }
}
