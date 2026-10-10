// Scribe/UI/Notes/PowerNotes/UnlinkedMentionsSection.swift
import SwiftUI

/// One note's unlinked mentions.
struct UnlinkedMentionGroup: Identifiable, Equatable, Sendable {
    let noteId: String
    let noteTitle: String
    let mentions: [UnlinkedMention]
    var id: String { noteId }
}

/// Notes that mention a note's title (or frontmatter aliases) in plain text
/// without linking to it, found through the notes FTS index and confirmed by
/// `UnlinkedMentionMatcher`.
@MainActor
final class UnlinkedMentionsModel: ObservableObject {
    @Published private(set) var groups: [UnlinkedMentionGroup] = []
    @Published private(set) var isLoading = false

    private let store: NoteStore
    private var noteId: String = ""
    private var title: String = ""
    private var generation = 0

    init(store: NoteStore) {
        self.store = store
    }

    var mentionCount: Int { groups.reduce(0) { $0 + $1.mentions.count } }

    /// (Re)loads mentions of `noteId` / `title` off the main actor.
    func load(noteId: String, title: String) {
        self.noteId = noteId
        self.title = title
        generation += 1
        let token = generation
        let store = self.store
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else {
            groups = []
            isLoading = false
            return
        }
        isLoading = true
        Task { [weak self] in
            let found: [UnlinkedMentionGroup] = await Task.detached(priority: .utility) {
                let aliases = store.aliases(forNoteId: noteId)
                let results = (try? store.unlinkedMentions(ofNoteId: noteId, title: title, aliases: aliases)) ?? []
                return results.map {
                    UnlinkedMentionGroup(noteId: $0.note.id, noteTitle: $0.note.title, mentions: $0.mentions)
                }
            }.value
            guard let self, self.generation == token else { return }
            self.groups = found
            self.isLoading = false
        }
    }

    func reload() { load(noteId: noteId, title: title) }

    /// Turns one mention into `[[Title]]` (or `[[Title|text]]`) in its note,
    /// through `NoteStore` (vault write path, index + links updated).
    func link(_ mention: UnlinkedMention, in group: UnlinkedMentionGroup) {
        apply(to: group.noteId) { body in
            guard let fresh = Self.relocate(mention, in: body) else { return nil }
            return UnlinkedMentionMatcher.linking(fresh, in: body, title: self.title)
        }
    }

    /// Links every mention in the group's note.
    func linkAll(in group: UnlinkedMentionGroup) {
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

    /// The same mention in a (possibly re-saved) body: same offset and text,
    /// else the same text on the same line.
    nonisolated static func relocate(_ mention: UnlinkedMention, in body: String) -> UnlinkedMention? {
        let fresh = UnlinkedMentionMatcher.mentions(of: [mention.term], in: body)
        return fresh.first { $0.location == mention.location && $0.matchedText == mention.matchedText }
            ?? fresh.first { $0.line == mention.line && $0.matchedText == mention.matchedText }
    }

    private func apply(to sourceId: String, _ transform: (String) -> String?) {
        let ids: Set<String> = [sourceId]
        // Open editors of the source note save unsaved edits first.
        NotificationCenter.default.post(name: .scribeNoteWillChangeInApp, object: nil,
                                        userInfo: [NoteVaultChange.noteIdsKey: ids])
        do {
            guard var source = try store.fetchNote(id: sourceId) else { return }
            guard let newBody = transform(source.body) else {
                AppState.shared.report("That note changed since the mention was found. The list has been refreshed.")
                reload()
                return
            }
            source.body = newBody
            try store.updateNote(source, tags: try store.tags(for: sourceId))
            NotificationCenter.default.post(name: .scribeNoteChangedInApp, object: nil,
                                            userInfo: [NoteVaultChange.noteIdsKey: ids])
            AppState.shared.notify("Linked")
        } catch {
            AppState.shared.report(error)
        }
        reload()
    }
}

/// Note inspector additions: unlinked mentions and version history.
struct NotePowerInspectorSections: View {
    @ObservedObject var vm: NoteDetailViewModel
    let onNavigate: (String) -> Void
    @StateObject private var mentions = UnlinkedMentionsModel(store: .shared)

    var body: some View {
        Section {
            if mentions.isLoading && mentions.groups.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if mentions.groups.isEmpty {
                Text("No unlinked mentions")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(mentions.groups) { group in
                    groupView(group)
                }
            }
        } header: {
            HStack {
                Text("Unlinked Mentions")
                Spacer()
                Button {
                    mentions.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Search again")
                .accessibilityLabel("Refresh unlinked mentions")
            }
        }

        Section("History") {
            Button {
                vm.flushPendingSave()
                VersionHistoryWindowController.shared.show(noteId: vm.note.id, title: vm.note.title)
            } label: {
                Label("Version History\u{2026}", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.borderless)
        }
        .onAppear { mentions.load(noteId: vm.note.id, title: vm.note.title) }
        .onChange(of: vm.note.id) { _, _ in mentions.load(noteId: vm.note.id, title: vm.note.title) }
        .onChange(of: vm.note.title) { _, _ in mentions.load(noteId: vm.note.id, title: vm.note.title) }
        .onChange(of: vm.backlinks) { _, _ in mentions.reload() }
    }

    /// The new link makes the source note a backlink of this one.
    private func refreshBacklinks() {
        vm.backlinks = (try? NoteStore.shared.backlinks(for: vm.note.id)) ?? vm.backlinks
    }

    @ViewBuilder
    private func groupView(_ group: UnlinkedMentionGroup) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack {
                Button {
                    onNavigate(group.noteId)
                } label: {
                    Label(group.noteTitle.isEmpty ? "Untitled" : group.noteTitle, systemImage: "doc.text")
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                Spacer()
                if group.mentions.count > 1 {
                    Button("Link All") {
                        mentions.linkAll(in: group)
                        refreshBacklinks()
                    }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Link every mention in this note")
                }
            }
            ForEach(group.mentions) { mention in
                HStack(alignment: .firstTextBaseline) {
                    Text(mention.context)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Link") {
                        mentions.link(mention, in: group)
                        refreshBacklinks()
                    }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Turn \u{201C}\(mention.matchedText)\u{201D} into a link to this note")
                        .accessibilityLabel("Link mention on line \(mention.line)")
                }
            }
        }
        .padding(.vertical, 2)
    }
}
