// Scribe/UI/Notes/PowerNotes/VersionHistoryWindow.swift
import AppKit
import SwiftUI

/// Opens one "Version History" window per note (File › Version History…, the
/// note inspector).
@MainActor
final class VersionHistoryWindowController: NSObject, NSWindowDelegate {
    static let shared = VersionHistoryWindowController()

    private var windows: [String: NSWindow] = [:]

    func show(noteId: String, title: String) {
        if let existing = windows[noteId] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        guard let versionStore = NoteStore.shared.versionStore else {
            AppState.shared.report("Version history isn't available.")
            return
        }
        let model = VersionHistoryModel(noteId: noteId, noteStore: .shared, versionStore: versionStore)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Version History \u{2014} \(title.isEmpty ? "Untitled" : title)"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: VersionHistoryView(model: model))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("ScribeVersionHistory")
        windows[noteId] = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== window }
    }
}

/// State for the version history window: the note's versions, the selected
/// one's content and its diff against the current note.
@MainActor
final class VersionHistoryModel: ObservableObject {
    @Published private(set) var versions: [NoteVersionRecord] = []
    @Published var selectedId: NoteVersionRecord.ID? {
        didSet { loadSelection() }
    }
    @Published private(set) var selectedBody: String = ""
    @Published private(set) var diff: [NoteLineDiff.Line] = []
    @Published private(set) var currentBody: String = ""
    @Published var errorMessage: String?

    let noteId: String
    private let noteStore: NoteStore
    private let versionStore: NoteVersionStore

    init(noteId: String, noteStore: NoteStore, versionStore: NoteVersionStore) {
        self.noteId = noteId
        self.noteStore = noteStore
        self.versionStore = versionStore
        reload()
    }

    var selected: NoteVersionRecord? {
        versions.first { $0.id == selectedId }
    }

    func reload() {
        currentBody = (try? noteStore.fetchNote(id: noteId))?.body ?? ""
        do {
            versions = try versionStore.versions(noteId: noteId)
        } catch {
            versions = []
            errorMessage = error.localizedDescription
        }
        if selectedId == nil || !versions.contains(where: { $0.id == selectedId }) {
            selectedId = versions.first?.id
        }
        loadSelection()
    }

    private func loadSelection() {
        guard let selected else {
            selectedBody = ""
            diff = []
            return
        }
        do {
            selectedBody = try versionStore.loadBody(selected)
            // How the current note differs from this version.
            diff = NoteLineDiff.diff(old: selectedBody, new: currentBody)
        } catch {
            selectedBody = ""
            diff = []
            errorMessage = error.localizedDescription
        }
    }

    /// Restores the selected version. The current content is snapshotted
    /// first (`.restore` bypasses the throttle), open editors flush their
    /// unsaved edits before the write and reload after it.
    func restoreSelected() {
        guard let selected else { return }
        let ids: Set<String> = [noteId]
        NotificationCenter.default.post(name: .scribeNoteWillChangeInApp, object: nil,
                                        userInfo: [NoteVaultChange.noteIdsKey: ids])
        do {
            let body = try versionStore.loadBody(selected)
            guard var note = try noteStore.fetchNote(id: noteId) else {
                errorMessage = "This note no longer exists."
                return
            }
            guard note.body != body else {
                AppState.shared.notify("This version matches the current note")
                return
            }
            note.body = body
            let tags = try noteStore.tags(for: noteId)
            try noteStore.updateNote(note, tags: tags, versionReason: .restore)
            NotificationCenter.default.post(name: .scribeNoteChangedInApp, object: nil,
                                            userInfo: [NoteVaultChange.noteIdsKey: ids])
            AppState.shared.notify("Version restored")
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    static func label(for version: NoteVersionRecord) -> String {
        version.createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    static func sizeLabel(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

struct VersionHistoryView: View {
    @ObservedObject var model: VersionHistoryModel
    @State private var showDiff = true
    @State private var confirmRestore = false

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedId) {
                if model.versions.isEmpty {
                    Text("No earlier versions yet. Scribe keeps a version before saves that change the note (at most one every five minutes), and always before outside changes or Scribe edits replace it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.versions) { version in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(VersionHistoryModel.label(for: version))
                        Text("\(version.versionReason.label) \u{00B7} \(VersionHistoryModel.sizeLabel(version.byteCount))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(version.id)
                    .accessibilityElement(children: .combine)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
        }
        .frame(minWidth: 640, minHeight: 400)
        // Keep "current" in step with saves made while the window is open.
        .onReceive(NotificationCenter.default.publisher(for: .scribeNoteEditorDidSave)) { notification in
            if let id = notification.userInfo?["noteId"] as? String, id == model.noteId { model.reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .scribeNoteChangedInApp)) { _ in model.reload() }
        .alert("Couldn't complete that", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog("Restore this version?", isPresented: $confirmRestore) {
            Button("Restore") { model.restoreSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The note's current content is saved as a version first, so you can switch back.")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if model.selected != nil {
            VStack(spacing: 0) {
                HStack {
                    Picker("Show", selection: $showDiff) {
                        Text("Changes Since").tag(true)
                        Text("Version Text").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    if showDiff {
                        let counts = NoteLineDiff.summary(model.diff)
                        Text("+\(counts.added) \u{2212}\(counts.removed)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(counts.added) lines added, \(counts.removed) lines removed since this version")
                    }
                    Spacer()
                    Button {
                        model.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh")
                    .accessibilityLabel("Refresh versions")
                    Button("Restore This Version\u{2026}") { confirmRestore = true }
                        .disabled(model.selectedBody == model.currentBody)
                }
                .padding(DesignTokens.Spacing.sm)
                Divider()
                if showDiff {
                    VersionDiffView(lines: model.diff)
                } else {
                    ScrollView {
                        Text(model.selectedBody)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(DesignTokens.Spacing.md)
                    }
                }
            }
        } else {
            Text("Select a version")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Line diff: removed lines (in the version, not the note) red, added lines
/// (in the note, not the version) green.
struct VersionDiffView: View {
    let lines: [NoteLineDiff.Line]

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker(line.kind))
                            .foregroundStyle(color(line.kind))
                            .frame(width: 12)
                        Text(line.text.isEmpty ? " " : line.text)
                            .foregroundStyle(line.kind == .unchanged ? Color.secondary : Color.primary)
                    }
                    .font(.system(.callout, design: .monospaced))
                    .padding(.horizontal, DesignTokens.Spacing.sm)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(line.kind))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityText(line))
                }
            }
            .textSelection(.enabled)
            .padding(.vertical, DesignTokens.Spacing.xs)
        }
    }

    private func marker(_ kind: NoteLineDiff.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "\u{2212}"
        case .unchanged: return " "
        }
    }

    private func color(_ kind: NoteLineDiff.Kind) -> Color {
        switch kind {
        case .added: return .green
        case .removed: return .red
        case .unchanged: return .secondary
        }
    }

    private func background(_ kind: NoteLineDiff.Kind) -> Color {
        switch kind {
        case .added: return Color.green.opacity(0.12)
        case .removed: return Color.red.opacity(0.12)
        case .unchanged: return .clear
        }
    }

    private func accessibilityText(_ line: NoteLineDiff.Line) -> String {
        switch line.kind {
        case .added: return "Added: \(line.text)"
        case .removed: return "Removed: \(line.text)"
        case .unchanged: return line.text
        }
    }
}
