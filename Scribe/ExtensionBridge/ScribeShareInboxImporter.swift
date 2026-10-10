// Scribe/ExtensionBridge/ScribeShareInboxImporter.swift
//
// App side of the Share extension hand-off: turns each `ShareInbox/<id>/`
// folder (see Scribe/Shared/ScribeSharePayload.swift) into a note, an entry
// appended to the "Inbox" note, or a task — images saved as note
// attachments — and deletes the folder. Stores and roots are injected so
// tests run against an in-memory database and temp folders.

import Foundation

/// Pure text composition for imported shares (unit-tested).
enum ScribeShareComposer {

    /// Title of the note "Append to Inbox note" writes into (created when
    /// missing, matched case-insensitively).
    static let inboxNoteTitle = "Inbox"

    /// Fallback when a share has nothing to derive a title from.
    static let fallbackTitle = "Shared item"

    private static let maxDerivedTitleLength = 80

    /// The typed title, else the first non-blank line of the text, else the
    /// first URL's host (or the URL), else "Shared item".
    static func resolvedTitle(for payload: ScribeSharePayload) -> String {
        let typed = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        if let line = firstLine(of: payload.text) {
            return clipped(line)
        }
        if let raw = payload.urls.first {
            if let host = URL(string: raw)?.host, !host.isEmpty { return host }
            return clipped(raw)
        }
        return fallbackTitle
    }

    /// Markdown for the shared text, links and images (in that order),
    /// separated by blank lines. `dropFirstLine` omits the text's first line
    /// when it already became the title.
    static func body(for payload: ScribeSharePayload, imageLinks: [String], dropFirstLine: Bool = false) -> String {
        var sections: [String] = []
        var text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if dropFirstLine {
            text = remainderAfterFirstLine(text)
        }
        if !text.isEmpty { sections.append(text) }
        let links = payload.urls.map { "- <\($0)>" }
        if !links.isEmpty { sections.append(links.joined(separator: "\n")) }
        let images = imageLinks.map { "![](\($0))" }
        if !images.isEmpty { sections.append(images.joined(separator: "\n")) }
        return sections.joined(separator: "\n\n")
    }

    /// Whether `resolvedTitle` came from the text's first line (so the body
    /// shouldn't repeat it).
    static func titleUsesFirstLine(_ payload: ScribeSharePayload) -> Bool {
        payload.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && firstLine(of: payload.text) != nil
    }

    /// A dated `###` section for the Inbox note.
    static func inboxEntry(for payload: ScribeSharePayload, imageLinks: [String], timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let stamp = formatter.string(from: payload.createdAt)
        let heading = "### \(resolvedTitle(for: payload)) · \(stamp)"
        let body = self.body(for: payload, imageLinks: imageLinks, dropFirstLine: titleUsesFirstLine(payload))
        return body.isEmpty ? heading : "\(heading)\n\n\(body)"
    }

    /// `entry` appended after `existing`, separated by one blank line.
    static func appending(_ entry: String, to existing: String) -> String {
        let trimmed = existing.replacingOccurrences(
            of: "\\s+$", with: "", options: .regularExpression
        )
        return trimmed.isEmpty ? entry + "\n" : trimmed + "\n\n" + entry + "\n"
    }

    // MARK: - Helpers

    private static func firstLine(of text: String) -> String? {
        text.components(separatedBy: .newlines)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    private static func remainderAfterFirstLine(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        if !lines.isEmpty { lines.removeFirst() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clipped(_ text: String) -> String {
        guard text.count > maxDerivedTitleLength else { return text }
        return String(text.prefix(maxDerivedTitleLength - 1)) + "…"
    }
}

/// What importing one shared item produced.
struct ScribeShareImportOutcome: Equatable {
    enum Destination: Equatable {
        case note(id: String)
        case task(id: String)
    }

    let destination: Destination
    let message: String

    var selection: MainSelection {
        switch destination {
        case .note(let id): return .note(id)
        case .task(let id): return .task(id)
        }
    }
}

enum ScribeShareImportError: LocalizedError {
    case inboxNoteUnreadable

    var errorDescription: String? {
        switch self {
        case .inboxNoteUnreadable:
            return "The Inbox note couldn't be read from the vault, so the shared item wasn't added to it."
        }
    }
}

struct ScribeShareInboxImporter {

    let noteStore: NoteStore
    let taskStore: TaskStore
    let inbox: ScribeShareInbox
    /// Vault root that `attachments/<noteId>/` lives under.
    let attachmentsRoot: URL

    init(noteStore: NoteStore, taskStore: TaskStore, inbox: ScribeShareInbox, attachmentsRoot: URL) {
        self.noteStore = noteStore
        self.taskStore = taskStore
        self.inbox = inbox
        self.attachmentsRoot = attachmentsRoot
    }

    struct BatchResult {
        var outcomes: [ScribeShareImportOutcome] = []
        var failures: [String] = []
    }

    /// Imports every pending item. Successful and unreadable (corrupt)
    /// items are deleted; items whose import failed are kept for a retry.
    func importPending(timeZone: TimeZone) -> BatchResult {
        var result = BatchResult()
        for folder in inbox.pendingItemFolders() {
            let payload: ScribeSharePayload
            do {
                payload = try inbox.readPayload(in: folder)
            } catch {
                result.failures.append("A shared item couldn't be read and was discarded.")
                inbox.remove(folder)
                continue
            }
            guard payload.hasContent else {
                inbox.remove(folder)
                continue
            }
            do {
                result.outcomes.append(try importItem(payload, in: folder, timeZone: timeZone))
                inbox.remove(folder)
            } catch {
                result.failures.append("Couldn't import a shared item: \(error.localizedDescription)")
            }
        }
        return result
    }

    func importItem(_ payload: ScribeSharePayload, in folder: URL, timeZone: TimeZone) throws -> ScribeShareImportOutcome {
        switch payload.destination {
        case .newNote:
            return try importAsNote(payload, in: folder)
        case .appendToInbox:
            return try appendToInboxNote(payload, in: folder, timeZone: timeZone)
        case .newTask:
            return try importAsTask(payload, in: folder)
        }
    }

    // MARK: - Destinations

    private func importAsNote(_ payload: ScribeSharePayload, in folder: URL) throws -> ScribeShareImportOutcome {
        let title = ScribeShareComposer.resolvedTitle(for: payload)
        let dropFirst = ScribeShareComposer.titleUsesFirstLine(payload)
        var note = try noteStore.createNote(
            title: title,
            body: ScribeShareComposer.body(for: payload, imageLinks: [], dropFirstLine: dropFirst)
        )
        let links = saveImages(payload, in: folder, noteId: note.id)
        if !links.isEmpty {
            note.body = ScribeShareComposer.body(for: payload, imageLinks: links, dropFirstLine: dropFirst)
            try noteStore.updateNote(note, tags: [])
        }
        return ScribeShareImportOutcome(destination: .note(id: note.id), message: "Saved “\(title)” to your notes")
    }

    private func appendToInboxNote(_ payload: ScribeSharePayload, in folder: URL, timeZone: TimeZone) throws -> ScribeShareImportOutcome {
        var note: Note
        if let existing = try noteStore.resolveTitle(ScribeShareComposer.inboxNoteTitle) {
            note = existing
            // The DB row's body is only a placeholder when notes live on disk;
            // never append to it (that would replace the note with one entry).
            if noteStore.fileStore != nil {
                guard let entry = noteStore.diskEntry(forNoteId: existing.id) else {
                    throw ScribeShareImportError.inboxNoteUnreadable
                }
                note.body = entry.file.body
            } else if let fresh = try noteStore.fetchNote(id: existing.id) {
                note = fresh
            }
        } else {
            note = try noteStore.createNote(title: ScribeShareComposer.inboxNoteTitle, body: "")
        }
        let links = saveImages(payload, in: folder, noteId: note.id)
        let entry = ScribeShareComposer.inboxEntry(for: payload, imageLinks: links, timeZone: timeZone)
        note.body = ScribeShareComposer.appending(entry, to: note.body)
        let tags = try noteStore.tags(for: note.id)
        try noteStore.updateNote(note, tags: tags)
        NotificationCenter.default.post(
            name: .scribeNoteChangedInApp,
            object: nil,
            userInfo: [NoteVaultChange.noteIdsKey: Set([note.id])]
        )
        return ScribeShareImportOutcome(destination: .note(id: note.id), message: "Added to your Inbox note")
    }

    private func importAsTask(_ payload: ScribeSharePayload, in folder: URL) throws -> ScribeShareImportOutcome {
        let title = ScribeShareComposer.resolvedTitle(for: payload)
        let notes = ScribeShareComposer.body(
            for: payload,
            imageLinks: [],
            dropFirstLine: ScribeShareComposer.titleUsesFirstLine(payload)
        )
        let task = try taskStore.createTask(title: title, notes: notes)
        let message = payload.imageFileNames.isEmpty
            ? "Added task “\(title)”"
            : "Added task “\(title)” (images can only be saved to notes)"
        return ScribeShareImportOutcome(destination: .task(id: task.id), message: message)
    }

    /// Copies the payload's images into the note's attachments folder and
    /// returns their vault-relative paths. Unsafe names, missing files and
    /// failed copies are skipped.
    private func saveImages(_ payload: ScribeSharePayload, in folder: URL, noteId: String) -> [String] {
        var links: [String] = []
        for name in payload.imageFileNames {
            guard let url = inbox.imageURL(named: name, in: folder),
                  let data = try? Data(contentsOf: url) else { continue }
            do {
                let saved = try EditorAttachmentFiles.save(
                    data: data,
                    suggestedName: name,
                    mimeType: nil,
                    noteId: noteId,
                    root: attachmentsRoot
                )
                links.append(saved.relativePath)
            } catch {
                Log.app.error("Share import: couldn't save an image: \(error.localizedDescription, privacy: .private)")
            }
        }
        return links
    }
}
