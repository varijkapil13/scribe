// Scribe/Documents/Locking/NoteDetailViewModel+Locking.swift
//
// Locked notes in the note editor. A locked note's file holds an armored
// AES-GCM block (`LockedNoteEnvelope`) instead of its body; the editor shows
// an unlock view until Touch ID / the password releases the key, keeps the
// plaintext in memory only, seals it again on every save, and drops it when
// `LockedNoteSession` locks (idle, sleep, window close).

import Combine
import CryptoKit
import Foundation

enum LockedNotePhase: Equatable, Sendable {
    /// An ordinary note.
    case notLocked
    /// Locked and not unlocked: `note.body` holds the envelope.
    case locked
    /// Unlocked: `note.body` holds the plaintext (memory only).
    case unlocked
}

/// Per-editor locking state that isn't published. Only touched by its
/// (main-actor) view model.
final class LockedNoteEditorState {
    var key: SymmetricKey?
    var cancellables: [AnyCancellable] = []
    var isBusy = false

    init() {}
}

extension NoteDetailViewModel {

    // MARK: - Wiring

    /// Classifies the loaded body and subscribes to re-lock events. Called
    /// once from `init`.
    func installLocking() {
        adoptLoadedBodyForLocking()
        NotificationCenter.default.publisher(for: .scribeLockedNotesWillLock)
            .sink { [weak self] _ in
                self?.relock()
            }
            .store(in: &lockState.cancellables)
        // Editing an unlocked note counts as activity for the idle re-lock.
        objectWillChange
            .sink { [weak self] _ in
                guard let self, self.lockPhase == .unlocked else { return }
                LockedNoteSession.shared.noteActivity()
            }
            .store(in: &lockState.cancellables)
    }

    /// Call after `note.body` was (re)loaded from disk: decrypts it when the
    /// key is in memory, otherwise shows the note as locked.
    func adoptLoadedBodyForLocking() {
        guard LockedNoteEnvelope.isLocked(note.body) else {
            lockState.key = nil
            if lockPhase != .notLocked { lockPhase = .notLocked }
            return
        }
        if let key = lockState.key ?? LockedNoteSession.shared.currentKey(),
           let plaintext = try? LockedNoteEnvelope.open(note.body, key: key) {
            lockState.key = key
            note.body = plaintext
            lockPhase = .unlocked
        } else {
            lockState.key = nil
            lockPhase = .locked
        }
    }

    /// The body to write to disk: sealed while unlocked, as-is otherwise
    /// (the envelope while locked, plaintext for ordinary notes). Never
    /// returns the plaintext of a locked note.
    func bodyForStorage() throws -> String {
        guard lockPhase == .unlocked else { return note.body }
        guard let key = lockState.key else { throw LockedNoteEnvelopeError.wrongKey }
        return try LockedNoteEnvelope.seal(note.body, key: key)
    }

    var isLockedNote: Bool { lockPhase != .notLocked }

    private var displayTitle: String {
        note.title.isEmpty ? "Untitled" : note.title
    }

    // MARK: - Actions

    /// Encrypts this note (creating the per-Mac key on first use).
    func lockNote() async {
        guard lockPhase == .notLocked, !lockState.isBusy else { return }
        lockState.isBusy = true
        defer { lockState.isBusy = false }
        do {
            let key = try await LockedNoteSession.shared.unlock(
                reason: "lock the note \u{201C}\(displayTitle)\u{201D}",
                creatingKeyIfNeeded: true
            )
            lockState.key = key
            lockPhase = .unlocked
            isDirty = true
            save()
            guard !isDirty, storedBodyIsLocked() != false, lockPhase == .unlocked else {
                // The sealed version didn't reach disk (or the save adopted
                // an external edit instead): stay an ordinary note.
                if lockPhase == .unlocked, storedBodyIsLocked() != true {
                    lockPhase = .notLocked
                    lockState.key = nil
                }
                if storedBodyIsLocked() != true {
                    errorMessage = "\u{201C}\(displayTitle)\u{201D} couldn't be locked because it couldn't be saved. Try again."
                }
                return
            }
            setLockedFrontmatterFlag(true)
        } catch LockedNoteKeychainError.cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Decrypts this note into memory after Touch ID / the password.
    func unlockNote() async {
        guard lockPhase == .locked, !lockState.isBusy else { return }
        lockState.isBusy = true
        defer { lockState.isBusy = false }
        do {
            let key = try await LockedNoteSession.shared.unlock(
                reason: "unlock the note \u{201C}\(displayTitle)\u{201D}",
                creatingKeyIfNeeded: false
            )
            let plaintext = try LockedNoteEnvelope.open(note.body, key: key)
            lockState.key = key
            note.body = plaintext
            lockPhase = .unlocked
        } catch LockedNoteKeychainError.cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Stores this (unlocked) note as plaintext again.
    func removeLock() {
        guard lockPhase == .unlocked else { return }
        let key = lockState.key
        lockPhase = .notLocked
        lockState.key = nil
        isDirty = true
        save()
        guard !isDirty, storedBodyIsLocked() != true else {
            // Still encrypted on disk: keep treating it as locked.
            lockPhase = .unlocked
            lockState.key = key
            return
        }
        setLockedFrontmatterFlag(false)
    }

    /// Saves pending edits (sealed) and drops the plaintext.
    func relock() {
        guard lockPhase == .unlocked else { return }
        if isDirty { save() }
        let onDisk = store.diskEntry(forNoteId: note.id)?.file.body
        if let onDisk, LockedNoteEnvelope.isLocked(onDisk), !isDirty {
            note.body = onDisk
        } else if let key = lockState.key, let sealed = try? LockedNoteEnvelope.seal(note.body, key: key) {
            // Not on disk (or the save failed): keep only the sealed form in
            // memory, so a later save still writes ciphertext.
            note.body = sealed
        } else {
            note.body = onDisk ?? ""
        }
        lockState.key = nil
        lockPhase = .locked
    }

    /// Whether the note's file currently holds an envelope; nil when there
    /// is no file to check (no vault, e.g. logic tests without disk).
    func storedBodyIsLocked() -> Bool? {
        guard let body = store.diskEntry(forNoteId: note.id)?.file.body else { return nil }
        return LockedNoteEnvelope.isLocked(body)
    }

    /// Sets / clears `locked: true` in the note's frontmatter (for other
    /// tools; Scribe itself detects the envelope).
    func setLockedFrontmatterFlag(_ locked: Bool) {
        guard let fileStore = store.fileStore,
              let entry = try? fileStore.locate(id: note.id) else { return }
        var file = entry.file
        file.frontmatter.setExtra(LockedNoteEnvelope.frontmatterKey, locked ? "true" : nil)
        guard file != entry.file else { return }
        do {
            _ = try fileStore.write(file)
            rebaseOnOwnLatestWrite()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
