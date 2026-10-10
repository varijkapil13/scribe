// ScribeiOS/Notes/NoteInspectorPanel.swift
//
// The note inspector on iPhone / iPad (`.inspector` — a trailing column on
// iPad, a sheet on iPhone): outline, backlinks, unlinked mentions (with
// one-tap linking, like the Mac) and note info.

import SwiftUI

/// One note's unlinked mentions of the open note.
struct IOSUnlinkedMentionGroup: Identifiable, Equatable, Sendable {
    let noteId: String
    let noteTitle: String
    let mentions: [UnlinkedMention]
    var id: String { noteId }
}

@MainActor
@Observable
final class NoteInspectorModel {
    private(set) var backlinks: [Note] = []
    private(set) var mentionGroups: [IOSUnlinkedMentionGroup] = []
    private(set) var isLoadingMentions = false
    var errorMessage: String?

    private let store: NoteStore
    @ObservationIgnored private var noteId = ""
    @ObservationIgnored private var title = ""
    @ObservationIgnored private var generation = 0

    init(store: NoteStore) {
        self.store = store
    }

    /// (Re)loads backlinks (main actor — one indexed query) and unlinked
    /// mentions (FTS + matching, off the main actor).
    func load(noteId: String, title: String) {
        self.noteId = noteId
        self.title = title
        backlinks = (try? store.backlinks(for: noteId)) ?? []
        generation += 1
        let token = generation
        let store = self.store
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else {
            mentionGroups = []
            isLoadingMentions = false
            return
        }
        isLoadingMentions = true
        Task { [weak self] in
            let found: [IOSUnlinkedMentionGroup] = await Task.detached(priority: .utility) {
                let aliases = store.aliases(forNoteId: noteId)
                let results = (try? store.unlinkedMentions(ofNoteId: noteId, title: title, aliases: aliases)) ?? []
                return results.map {
                    IOSUnlinkedMentionGroup(noteId: $0.note.id, noteTitle: $0.note.title, mentions: $0.mentions)
                }
            }.value
            guard let self, self.generation == token else { return }
            self.mentionGroups = found
            self.isLoadingMentions = false
        }
    }

    func reload() { load(noteId: noteId, title: title) }

    var mentionCount: Int { mentionGroups.reduce(0) { $0 + $1.mentions.count } }

    /// Turns one mention into `[[Title]]` in its note.
    func link(_ mention: UnlinkedMention, in group: IOSUnlinkedMentionGroup) {
        let title = self.title
        apply(to: group.noteId) { body in
            let fresh = UnlinkedMentionMatcher.mentions(of: [mention.term], in: body)
            guard let current = fresh.first(where: { $0.location == mention.location && $0.matchedText == mention.matchedText })
                    ?? fresh.first(where: { $0.line == mention.line && $0.matchedText == mention.matchedText }) else {
                return nil
            }
            return UnlinkedMentionMatcher.linking(current, in: body, title: title)
        }
    }

    /// Links every mention in the group's note.
    func linkAll(in group: IOSUnlinkedMentionGroup) {
        let terms = UnlinkedMentionMatcher.terms(title: title, aliases: store.aliases(forNoteId: noteId))
        let title = self.title
        apply(to: group.noteId) { body in
            var updated = body
            // Last first, so earlier offsets stay valid.
            for mention in UnlinkedMentionMatcher.mentions(of: terms, in: body).reversed() {
                if let next = UnlinkedMentionMatcher.linking(mention, in: updated, title: title) {
                    updated = next
                }
            }
            return updated == body ? nil : updated
        }
    }

    private func apply(to sourceId: String, _ transform: (String) -> String?) {
        do {
            guard var source = try store.fetchNote(id: sourceId) else { return }
            guard let newBody = transform(source.body) else {
                errorMessage = "That note changed since the mention was found. The list has been refreshed."
                reload()
                return
            }
            source.body = newBody
            try store.updateNote(source, tags: try store.tags(for: sourceId))
            // Editors showing that note reload (it is not the open one).
            NotificationCenter.default.post(name: .noteVaultFilesChanged, object: nil,
                                            userInfo: [NoteVaultChange.noteIdsKey: Set([sourceId])])
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }
}

struct NoteInspectorPanel: View {
    let editor: IOSNoteEditorModel
    let editorCommands: WebEditorModel
    @State private var model: NoteInspectorModel
    let onOpenNote: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    init(editor: IOSNoteEditorModel, editorCommands: WebEditorModel, store: NoteStore,
         onOpenNote: @escaping (String) -> Void) {
        self.editor = editor
        self.editorCommands = editorCommands
        _model = State(initialValue: NoteInspectorModel(store: store))
        self.onOpenNote = onOpenNote
    }

    var body: some View {
        NavigationStack {
            List {
                if !editorCommands.outline.isEmpty {
                    Section("Outline") {
                        ForEach(editorCommands.outline) { heading in
                            Button {
                                editorCommands.scrollTo(heading)
                            } label: {
                                Text(heading.text.isEmpty ? "Untitled heading" : heading.text)
                                    .padding(.leading, CGFloat(max(0, heading.level - 1)) * 12)
                                    .lineLimit(2)
                            }
                        }
                    }
                }

                Section("Backlinks") {
                    if model.backlinks.isEmpty {
                        Text("No notes link here yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.backlinks) { note in
                            Button {
                                onOpenNote(note.id)
                            } label: {
                                NoteLinkRow(title: NoteBrowserQuery.displayTitle(note), excerpt: note.bodyExcerpt)
                            }
                        }
                    }
                }

                Section {
                    if model.isLoadingMentions && model.mentionGroups.isEmpty {
                        ProgressView()
                    } else if model.mentionGroups.isEmpty {
                        Text("No unlinked mentions.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.mentionGroups) { group in
                            mentionGroup(group)
                        }
                    }
                } header: {
                    Text("Unlinked Mentions")
                } footer: {
                    Text("Notes that name this note without linking to it.")
                }

                Section("Info") {
                    infoRow("Words", "\(editor.wordCount)")
                    infoRow("Characters", "\(editor.characterCount)")
                    if let note = editor.note {
                        infoRow("Created", note.createdAt.formatted(date: .abbreviated, time: .shortened))
                        infoRow("Modified", note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    if !editor.tags.isEmpty {
                        infoRow("Tags", editor.tags.map { "#\($0)" }.joined(separator: " "))
                    }
                    if let path = editor.relativeFilePath {
                        infoRow("File", path)
                    }
                    infoRow("Stored", IOSVaultSyncController.shared.statusText)
                    if editor.isLockedNote {
                        infoRow("Locked", "Encrypted on disk")
                    }
                }
            }
            .navigationTitle("Note Info")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Unlinked Mentions", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
        .task(id: editor.noteId + "\u{1F}" + editor.title) {
            model.load(noteId: editor.noteId, title: editor.title)
        }
    }

    @ViewBuilder
    private func mentionGroup(_ group: IOSUnlinkedMentionGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    onOpenNote(group.noteId)
                } label: {
                    Text(group.noteTitle.isEmpty ? "Untitled" : group.noteTitle)
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                Spacer()
                if group.mentions.count > 1 {
                    Button("Link All") { model.linkAll(in: group) }
                        .font(.caption)
                        .buttonStyle(.bordered)
                }
            }
            ForEach(group.mentions) { mention in
                HStack(alignment: .firstTextBaseline) {
                    Text(mention.context)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Spacer(minLength: 8)
                    Button("Link") { model.link(mention, in: group) }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Link this mention")
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

/// Title + excerpt row used by backlinks.
struct NoteLinkRow: View {
    let title: String
    let excerpt: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let excerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}
