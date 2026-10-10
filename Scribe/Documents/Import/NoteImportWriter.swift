// Scribe/Documents/Import/NoteImportWriter.swift
import Foundation

/// Writes imported drafts into the vault. Never overwrites anything: every
/// note gets a fresh id, titles that already exist (in the vault or earlier
/// in the same import) get a numeric suffix, attachments go to new files in
/// `attachments/<noteId>/`, and `NoteFileStore.write` itself picks a free
/// file name. After writing, one reconcile pass indexes the new files
/// (dates, tags and links included) in SQLite.
///
/// Synchronous and nonisolated: run it off the main actor.
struct NoteImportWriter: Sendable {
    let noteStore: NoteStore
    let fileStore: NoteFileStore
    let dbManager: DatabaseManager
    /// Vault root holding `attachments/`.
    let attachmentsRoot: URL

    init(noteStore: NoteStore, fileStore: NoteFileStore, dbManager: DatabaseManager, attachmentsRoot: URL) {
        self.noteStore = noteStore
        self.fileStore = fileStore
        self.dbManager = dbManager
        self.attachmentsRoot = attachmentsRoot
    }

    /// Writes `drafts`, reporting `(completed, total)` after each one.
    func write(
        _ drafts: [ImportedNoteDraft],
        into summary: inout NoteImportSummary,
        now: Date = Date(),
        isCancelled: @Sendable () -> Bool = { false },
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) {
        var takenTitles = Set(((try? noteStore.allNoteTitles()) ?? []).map { $0.lowercased() })
        var notebookCache = NotebookPathCache(noteStore: noteStore)
        var wroteAny = false

        for (index, draft) in drafts.enumerated() {
            if isCancelled() {
                summary.warnings.append("The import was cancelled; \(drafts.count - index) item\(drafts.count - index == 1 ? " was" : "s were") not imported.")
                break
            }
            let sourceName = draft.sourceName.isEmpty ? draft.title : draft.sourceName
            do {
                let noteId = UUID().uuidString
                let requestedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = MarkdownImportRewriter.uniqueTitle(requestedTitle, taken: &takenTitles)
                let renamed = title.caseInsensitiveCompare(requestedTitle.isEmpty ? "Untitled" : requestedTitle) != .orderedSame

                let body = saveAttachments(of: draft, noteId: noteId, summary: &summary)
                let notebookId = try notebookCache.notebookId(for: draft.notebookPath, summary: &summary)

                let created = draft.createdAt ?? draft.updatedAt ?? now
                let updated = max(draft.updatedAt ?? created, created)
                let file = NoteFile(
                    id: noteId,
                    frontmatter: NoteFrontmatter(
                        title: title,
                        createdAt: created,
                        updatedAt: updated,
                        notebookId: notebookId,
                        tags: NoteStore.normalizeTags(draft.tags.map(Self.cleanTag)),
                        extra: draft.extra.filter { !NoteFrontmatterCodec.knownKeys.contains($0.key) }
                    ),
                    body: body
                )
                try fileStore.write(file)
                wroteAny = true
                summary.items.append(NoteImportItemResult(
                    sourceName: sourceName,
                    outcome: .imported(noteId: noteId, title: title, renamed: renamed)
                ))
            } catch {
                summary.items.append(NoteImportItemResult(
                    sourceName: sourceName,
                    outcome: .failed(reason: error.localizedDescription)
                ))
            }
            progress(index + 1, drafts.count)
        }

        guard wroteAny else { return }
        do {
            try NoteIndexReconciler(fileStore: fileStore, dbManager: dbManager).reconcile()
        } catch {
            summary.warnings.append("The notes were written, but indexing them failed (\(error.localizedDescription)). They'll appear after Scribe re-reads the notes folder.")
        }
    }

    /// Saves the draft's attachments and returns the body with every
    /// placeholder replaced by the saved file's vault-relative path. A
    /// failed attachment's placeholder becomes its file name.
    func saveAttachments(of draft: ImportedNoteDraft, noteId: String, summary: inout NoteImportSummary) -> String {
        var body = draft.body
        // Longest placeholder first so `…-1` never clobbers `…-10`.
        for placeholder in draft.attachments.keys.sorted(by: { $0.count > $1.count }) {
            guard let source = draft.attachments[placeholder] else { continue }
            do {
                let data: Data
                switch source.content {
                case .data(let bytes): data = bytes
                case .file(let url): data = try Data(contentsOf: url)
                }
                let saved = try EditorAttachmentFiles.save(
                    data: data,
                    suggestedName: source.filename,
                    mimeType: source.mimeType,
                    noteId: noteId,
                    root: attachmentsRoot
                )
                body = body.replacingOccurrences(of: placeholder, with: saved.relativePath)
                summary.attachmentsSaved += 1
            } catch {
                body = body.replacingOccurrences(of: placeholder, with: source.filename.replacingOccurrences(of: " ", with: "%20"))
                summary.attachmentsFailed += 1
            }
        }
        return body
    }

    /// Tags may not contain spaces or `#` in Scribe.
    static func cleanTag(_ tag: String) -> String {
        var cleaned = tag.trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix("#") { cleaned.removeFirst() }
        return cleaned.replacingOccurrences(of: " ", with: "-")
    }
}

/// Resolves notebook paths to ids, reusing existing notebooks with the same
/// name under the same parent and creating missing ones.
struct NotebookPathCache {
    let noteStore: NoteStore
    private var known: [Notebook]?
    private var cache: [String: String] = [:]

    init(noteStore: NoteStore) {
        self.noteStore = noteStore
    }

    mutating func notebookId(for path: [String], summary: inout NoteImportSummary) throws -> String? {
        let cleaned = path
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        if known == nil { known = try noteStore.fetchAllNotebooks() }
        var parentId: String?
        for depth in 1...cleaned.count {
            let key = cleaned.prefix(depth).joined(separator: "\u{1F}")
            if let cached = cache[key] {
                parentId = cached
                continue
            }
            let name = cleaned[depth - 1]
            if let existing = known?.first(where: {
                $0.parentId == parentId && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                parentId = existing.id
            } else {
                let created = try noteStore.createNotebook(name: name, parentId: parentId)
                known?.append(created)
                summary.notebooksCreated += 1
                parentId = created.id
            }
            cache[key] = parentId
        }
        return parentId
    }
}
