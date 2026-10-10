// ScribeiOS/Notes/NoteVersionHistoryView.swift
//
// Version history on iPhone / iPad: the snapshots `NoteVersionStore` keeps
// (taken before saves, external changes, Scribe edits and restores — same
// store and policy as the Mac), a line diff against the current note
// (`NoteLineDiff`), and restore (the current content is snapshotted first, so
// a restore is itself undoable from here).

import SwiftUI

@MainActor
@Observable
final class NoteVersionHistoryModel {
    let noteId: String

    private(set) var versions: [NoteVersionRecord] = []
    private(set) var currentBody = ""
    var errorMessage: String?

    private let store: NoteStore

    init(noteId: String, store: NoteStore) {
        self.noteId = noteId
        self.store = store
        reload()
    }

    var isAvailable: Bool { store.versionStore != nil }

    func reload() {
        guard let versionStore = store.versionStore else { return }
        do {
            versions = try versionStore.versions(noteId: noteId)
            currentBody = (try store.fetchNote(id: noteId))?.body ?? ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func body(of version: NoteVersionRecord) -> String? {
        do {
            return try store.versionStore?.loadBody(version)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func diff(for version: NoteVersionRecord) -> [NoteLineDiff.Line] {
        guard let old = body(of: version) else { return [] }
        return NoteLineDiff.diff(old: old, new: currentBody)
    }

    /// Restores `version` over the note. Returns true when the note changed.
    func restore(_ version: NoteVersionRecord) -> Bool {
        do {
            guard let versionStore = store.versionStore else { return false }
            let restored = try versionStore.loadBody(version)
            guard var note = try store.fetchNote(id: noteId) else {
                errorMessage = "This note no longer exists."
                return false
            }
            guard note.body != restored else { return false }
            note.body = restored
            let tags = try store.tags(for: noteId)
            try store.updateNote(note, tags: tags, versionReason: .restore)
            reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    static func label(for version: NoteVersionRecord) -> String {
        version.createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}

struct NoteVersionHistoryView: View {
    @State private var model: NoteVersionHistoryModel
    /// Saves the open editor's pending edits before a restore.
    let flushEditor: () -> Void
    /// Reloads the open editor after a restore.
    let onRestored: () -> Void

    @Environment(\.dismiss) private var dismiss

    init(noteId: String, store: NoteStore, flushEditor: @escaping () -> Void, onRestored: @escaping () -> Void) {
        _model = State(initialValue: NoteVersionHistoryModel(noteId: noteId, store: store))
        self.flushEditor = flushEditor
        self.onRestored = onRestored
    }

    var body: some View {
        NavigationStack {
            Group {
                if !model.isAvailable || model.versions.isEmpty {
                    ContentUnavailableView(
                        "No Earlier Versions",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Scribe keeps a version before you change a note, at most every few minutes.")
                    )
                } else {
                    List(model.versions) { version in
                        NavigationLink {
                            NoteVersionDetailView(model: model, version: version) {
                                flushEditor()
                                if model.restore(version) {
                                    onRestored()
                                    dismiss()
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(NoteVersionHistoryModel.label(for: version))
                                    .font(.body)
                                Text(version.versionReason.label + " · " + ByteCountFormatter.string(fromByteCount: Int64(version.byteCount), countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Version History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Version History", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
        .onAppear {
            flushEditor()
            model.reload()
        }
    }
}

private struct NoteVersionDetailView: View {
    let model: NoteVersionHistoryModel
    let version: NoteVersionRecord
    let onRestore: () -> Void

    @State private var showDiff = true
    @State private var confirmRestore = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if showDiff {
                    let lines = model.diff(for: version)
                    let counts = NoteLineDiff.summary(lines)
                    Text("\(counts.added) added · \(counts.removed) removed since this version")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        DiffLineRow(line: line)
                    }
                } else {
                    Text(model.body(of: version) ?? "")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(NoteVersionHistoryModel.label(for: version))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $showDiff) {
                    Text("Changes").tag(true)
                    Text("Version").tag(false)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Restore This Version") { confirmRestore = true }
            }
        }
        .confirmationDialog("Restore this version?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore") { onRestore() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current content is kept in the history, so you can switch back.")
        }
    }
}

private struct DiffLineRow: View {
    let line: NoteLineDiff.Line

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .foregroundStyle(color)
                .frame(width: 12)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .unchanged ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.footnote, design: .monospaced))
        .padding(.vertical, 1)
        .background(background)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var marker: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "−"
        case .unchanged: return " "
        }
    }

    private var color: Color {
        switch line.kind {
        case .added: return .green
        case .removed: return .red
        case .unchanged: return .secondary
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: return Color.green.opacity(0.12)
        case .removed: return Color.red.opacity(0.12)
        case .unchanged: return .clear
        }
    }

    private var accessibilityText: String {
        switch line.kind {
        case .added: return "Added: \(line.text)"
        case .removed: return "Removed: \(line.text)"
        case .unchanged: return line.text
        }
    }
}
