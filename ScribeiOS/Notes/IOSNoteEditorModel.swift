// ScribeiOS/Notes/IOSNoteEditorModel.swift
//
// State behind one open note on iPhone / iPad: title, markdown body and tags,
// debounced autosave, protection against overwriting an edit that arrived
// through iCloud meanwhile (`NoteExternalEditPolicy` — the disk version is
// kept as a conflict copy, never silently dropped), reloads when the vault
// reconcile reports the file changed, and locked notes (`LockedNoteEnvelope`
// sealed with an iCloud-Keychain key, see IOSLockedNoteSession).

import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class IOSNoteEditorModel {

    enum LockPhase: Equatable {
        /// An ordinary note.
        case notLocked
        /// Locked: only the envelope is in memory (`body` is empty).
        case locked
        /// Unlocked: `body` holds the plaintext, saved sealed.
        case unlocked
    }

    let noteId: String

    private(set) var title: String = ""
    private(set) var body: String = ""
    private(set) var tags: [String] = []
    private(set) var note: Note?
    private(set) var lockPhase: LockPhase = .notLocked
    /// False once the note was deleted (here or on another device).
    private(set) var exists = true
    private(set) var isBusy = false
    var errorMessage: String?

    private let store: NoteStore
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loadedFingerprint: NoteFileFingerprint?
    /// The stored envelope while locked.
    @ObservationIgnored private var envelope: String?
    /// The key this note is sealed with while unlocked.
    @ObservationIgnored private var noteKey: SymmetricKey?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var activated = false

    /// Cheap: SwiftUI may create throwaway instances while re-rendering, so
    /// loading and observing start in `activate()`.
    init(noteId: String, store: NoteStore) {
        self.noteId = noteId
        self.store = store
    }

    /// Loads the note (or re-reads it when coming back to the screen) and
    /// starts listening for vault changes / re-locking. Idempotent.
    func activate() {
        if !activated || !dirty {
            load()
        }
        activated = true
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .noteVaultFilesChanged, object: nil, queue: .main) { [weak self] notification in
            let ids = NoteVaultChange.noteIds(from: notification) ?? []
            MainActor.assumeIsolated { self?.vaultFilesChanged(ids) }
        })
        observers.append(center.addObserver(forName: .scribeIOSLockedNotesWillLock, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relock() }
        })
    }

    /// Call when the editor goes off screen: saves and stops listening.
    func deactivate() {
        flush()
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
    }

    var hasUnsavedChanges: Bool { dirty }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    var isDailyNote: Bool { note?.isDailyNote ?? false }

    /// The daily note's date (`yyyy-MM-dd`, POSIX), when this is one.
    var dailyDate: Date? {
        guard let key = note?.dailyDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key)
    }

    // MARK: - Loading

    private func load() {
        guard let loaded = try? store.fetchNote(id: noteId) else {
            exists = false
            return
        }
        exists = true
        note = loaded
        title = loaded.title
        tags = (try? store.tags(for: noteId)) ?? []
        loadedFingerprint = store.currentFileFingerprint(forNoteId: noteId, reusing: nil)
        adoptBody(loaded.body)
        dirty = false
    }

    /// Classifies a body read from disk: plaintext, or an envelope that is
    /// opened right away when this note's key is already in memory.
    private func adoptBody(_ stored: String) {
        guard LockedNoteEnvelope.isLocked(stored) else {
            envelope = nil
            noteKey = nil
            lockPhase = .notLocked
            body = stored
            return
        }
        let known = (noteKey.map { [$0] } ?? []) + (IOSLockedNoteSession.shared.currentKeys() ?? [])
        if let key = LockedNoteKeySelection.key(for: stored, among: known),
           let plaintext = try? LockedNoteEnvelope.open(stored, key: key) {
            envelope = nil
            noteKey = key
            body = plaintext
            lockPhase = .unlocked
        } else {
            envelope = stored
            noteKey = nil
            body = ""
            lockPhase = .locked
        }
    }

    private func vaultFilesChanged(_ ids: Set<String>) {
        guard ids.contains(noteId) else { return }
        // Unsaved edits win; the next save keeps the disk version as a
        // conflict copy (see flush()).
        guard !dirty else { return }
        reloadFromDisk()
    }

    /// Re-reads the note (after a reconcile, a restore, or a rename).
    func reloadFromDisk() {
        saveTask?.cancel()
        load()
    }

    // MARK: - Editing

    func setTitle(_ value: String) {
        guard value != title else { return }
        title = value
        markDirty()
    }

    func setBody(_ value: String) {
        guard value != body, lockPhase != .locked else { return }
        body = value
        if lockPhase == .unlocked { IOSLockedNoteSession.shared.noteActivity() }
        markDirty()
    }

    /// Adds a tag normalised like `NoteStore.normalizeTags` (trimmed,
    /// leading `#` dropped, lowercased). No-op for blanks / duplicates.
    func addTag(_ raw: String) {
        var stripped = raw.trimmingCharacters(in: .whitespaces)
        while stripped.hasPrefix("#") { stripped.removeFirst() }
        guard let normalised = NoteStore.normalizeTags([stripped]).first,
              !normalised.isEmpty, !tags.contains(normalised) else { return }
        tags.append(normalised)
        markDirty()
    }

    func removeTag(_ tag: String) {
        guard let index = tags.firstIndex(of: tag) else { return }
        tags.remove(at: index)
        markDirty()
    }

    private func markDirty() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    // MARK: - Saving

    /// Writes pending edits now.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard dirty, var note else { return }

        let current = store.currentFileFingerprint(forNoteId: noteId, reusing: loadedFingerprint)
        let decision = NoteExternalEditPolicy.decide(
            loaded: loadedFingerprint,
            current: current,
            lastWrittenByScribe: store.lastWrittenFileFingerprint(forNoteId: noteId),
            hasUnsavedChanges: true
        )
        if decision == .keepBoth {
            // Someone (another device via iCloud, Files, Obsidian) changed the
            // file since we loaded it: keep their version as a conflict copy.
            do {
                _ = try store.preserveDiskVersionAsConflictCopy(noteId: noteId)
            } catch {
                errorMessage = "The version changed on another device couldn't be kept: \(error.localizedDescription)"
                return
            }
        }

        do {
            note.title = title
            note.body = try bodyForStorage()
            try store.updateNote(note, tags: tags)
            dirty = false
            loadedFingerprint = store.lastWrittenFileFingerprint(forNoteId: noteId) ?? current
            self.note = (try? store.fetchNote(id: noteId)) ?? note
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The body to write: sealed while unlocked, the envelope while locked,
    /// plaintext for ordinary notes. Never the plaintext of a locked note.
    private func bodyForStorage() throws -> String {
        switch lockPhase {
        case .notLocked:
            return body
        case .locked:
            guard let envelope else { throw IOSLockedNoteError.keyNotOnThisDevice }
            return envelope
        case .unlocked:
            guard let noteKey else { throw IOSLockedNoteError.keyNotOnThisDevice }
            return try LockedNoteEnvelope.seal(body, key: noteKey)
        }
    }

    // MARK: - Locking

    var isLockedNote: Bool { lockPhase != .notLocked }

    /// Encrypts this note (Face ID first; creates the shared key on first use).
    func lockNote() async {
        guard lockPhase == .notLocked, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let key = try await IOSLockedNoteSession.shared.sealingKey(
                reason: "Lock the note \u{201C}\(displayTitle)\u{201D}"
            )
            noteKey = key
            lockPhase = .unlocked
            dirty = true
            flush()
            guard !dirty else {
                // Not saved: stay an ordinary note.
                lockPhase = .notLocked
                noteKey = nil
                return
            }
            setLockedFrontmatterFlag(true)
        } catch IOSLockedNoteError.cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Decrypts this note into memory after Face ID / the passcode.
    func unlockNote() async {
        guard lockPhase == .locked, let envelope, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let keys = try await IOSLockedNoteSession.shared.unlock(
                reason: "Unlock the note \u{201C}\(displayTitle)\u{201D}"
            )
            guard let key = LockedNoteKeySelection.key(for: envelope, among: keys) else {
                throw IOSLockedNoteError.keyNotOnThisDevice
            }
            body = try LockedNoteEnvelope.open(envelope, key: key)
            noteKey = key
            self.envelope = nil
            lockPhase = .unlocked
        } catch IOSLockedNoteError.cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Stores this (unlocked) note as plaintext again.
    func removeLock() {
        guard lockPhase == .unlocked else { return }
        let key = noteKey
        lockPhase = .notLocked
        noteKey = nil
        dirty = true
        flush()
        guard !dirty else {
            lockPhase = .unlocked
            noteKey = key
            return
        }
        setLockedFrontmatterFlag(false)
    }

    /// Saves (sealed) and drops the plaintext.
    func relock() {
        guard lockPhase == .unlocked, let noteKey else { return }
        if dirty { flush() }
        let sealed = (try? LockedNoteEnvelope.seal(body, key: noteKey))
        let onDisk = store.diskEntry(forNoteId: noteId)?.file.body
        if let onDisk, LockedNoteEnvelope.isLocked(onDisk), !dirty {
            envelope = onDisk
        } else {
            envelope = sealed ?? onDisk
        }
        body = ""
        self.noteKey = nil
        lockPhase = .locked
    }

    /// Sets / clears `locked: true` in the frontmatter (for other tools; the
    /// envelope itself is what Scribe detects).
    private func setLockedFrontmatterFlag(_ locked: Bool) {
        guard let fileStore = store.fileStore,
              let entry = try? fileStore.locate(id: noteId) else { return }
        var file = entry.file
        file.frontmatter.setExtra(LockedNoteEnvelope.frontmatterKey, locked ? "true" : nil)
        guard file != entry.file else { return }
        do {
            _ = try fileStore.write(file)
            loadedFingerprint = store.lastWrittenFileFingerprint(forNoteId: noteId) ?? loadedFingerprint
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Info

    /// Word / character counts of the (plaintext) body.
    var wordCount: Int {
        body.split { $0.isWhitespace || $0.isNewline }.count
    }

    var characterCount: Int { body.count }

    /// The note's file, relative to the vault root.
    var relativeFilePath: String? {
        store.diskEntry(forNoteId: noteId)?.relativePath
    }
}
