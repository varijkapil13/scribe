// Scribe/Storage/LockedNoteEnvelope.swift
import CryptoKit
import Foundation

/// Why a locked note's envelope couldn't be opened.
enum LockedNoteEnvelopeError: Error, Equatable, LocalizedError {
    /// The text has no `BEGIN SCRIBE LOCKED NOTE` block.
    case notLocked
    /// The block is there but its structure or base64 payload is broken.
    case malformed
    /// Written by a newer Scribe with an envelope format this one can't read.
    case unsupportedVersion(Int)
    /// Sealed with a different key (another Mac, or a reset key).
    case wrongKey
    /// The ciphertext (or its authenticated header) was modified.
    case tampered
    /// Decrypted bytes aren't UTF-8 text.
    case notText

    var errorDescription: String? {
        switch self {
        case .notLocked:
            return "This note isn't locked."
        case .malformed:
            return "The locked note is damaged and can't be read."
        case .unsupportedVersion(let version):
            return "This note was locked by a newer version of Scribe (format \(version))."
        case .wrongKey:
            return "This note was locked on another Mac or with a different key, so it can't be unlocked here."
        case .tampered:
            return "The locked note was changed outside Scribe and can't be decrypted."
        case .notText:
            return "The unlocked note isn't readable text."
        }
    }
}

/// The armored ciphertext block a locked note's markdown file stores in
/// place of its body. Pure CryptoKit (AES-GCM, 256-bit key), no Keychain or
/// UI — the key comes from `LockedNoteKeychain` on macOS.
///
/// Wire format (the note's title stays in clear in the frontmatter, which
/// also carries `locked: true` for other tools):
///
/// ```
/// -----BEGIN SCRIBE LOCKED NOTE-----
/// Version: 1
/// Key: 1a2b3c4d
///
/// <base64 of nonce ‖ ciphertext ‖ tag, wrapped at 64 columns>
/// -----END SCRIBE LOCKED NOTE-----
/// ```
///
/// The `Version` and `Key` header values are bound into the AES-GCM
/// authenticated data, so editing them is detected just like editing the
/// ciphertext. A fresh random nonce is used for every seal.
enum LockedNoteEnvelope {

    static let beginMarker = "-----BEGIN SCRIBE LOCKED NOTE-----"
    static let endMarker = "-----END SCRIBE LOCKED NOTE-----"
    static let currentVersion = 1
    /// Base64 line width inside the block.
    static let lineWidth = 64

    /// Frontmatter key flagging a locked note (`locked: true`).
    static let frontmatterKey = "locked"

    /// What list previews, Spotlight and search show instead of content.
    /// Also the marker `bodyExcerpt` carries in SQLite, so DB-only readers
    /// (Spotlight, attachment search) can tell a note is locked.
    static let excerptPlaceholder = "[Locked note]"

    // MARK: - Detection

    /// True when `body` is (starts with) a locked-note block.
    nonisolated static func isLocked(_ body: String) -> Bool {
        var trimmed = Substring(body)
        while let first = trimmed.first, first.isWhitespace || first.isNewline {
            trimmed = trimmed.dropFirst()
        }
        return trimmed.hasPrefix(beginMarker)
    }

    /// Short, non-secret identifier of a key (first 4 bytes of a labelled
    /// SHA-256), so opening with the wrong key reports `.wrongKey` instead
    /// of looking like tampering.
    nonisolated static func keyIdentifier(for key: SymmetricKey) -> String {
        var material = key.withUnsafeBytes { Data($0) }
        material.append(Data("scribe-locked-note-key-id".utf8))
        let digest = Array(SHA256.hash(data: material))
        return digest.prefix(4).map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
    }

    // MARK: - Seal / open

    /// Encrypts `plaintext` into an armored block.
    nonisolated static func seal(_ plaintext: String, key: SymmetricKey) throws -> String {
        let keyId = keyIdentifier(for: key)
        let box = try AES.GCM.seal(
            Data(plaintext.utf8),
            using: key,
            authenticating: associatedData(version: currentVersion, keyId: keyId)
        )
        guard let combined = box.combined else { throw LockedNoteEnvelopeError.malformed }
        var lines = [beginMarker, "Version: \(currentVersion)", "Key: \(keyId)", ""]
        lines.append(contentsOf: wrap(combined.base64EncodedString(), width: lineWidth))
        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    /// Decrypts an armored block. Anything after the end marker is ignored.
    nonisolated static func open(_ armored: String, key: SymmetricKey) throws -> String {
        let parsed = try parse(armored)
        guard parsed.version == currentVersion else {
            throw LockedNoteEnvelopeError.unsupportedVersion(parsed.version)
        }
        guard parsed.keyId == keyIdentifier(for: key) else {
            throw LockedNoteEnvelopeError.wrongKey
        }
        // nonce (12) + tag (16); an empty note has no ciphertext bytes.
        guard let data = Data(base64Encoded: parsed.payload), data.count >= 28 else {
            throw LockedNoteEnvelopeError.malformed
        }
        let plain: Data
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            plain = try AES.GCM.open(
                box,
                using: key,
                authenticating: associatedData(version: parsed.version, keyId: parsed.keyId)
            )
        } catch {
            throw LockedNoteEnvelopeError.tampered
        }
        guard let text = String(data: plain, encoding: .utf8) else {
            throw LockedNoteEnvelopeError.notText
        }
        return text
    }

    // MARK: - Parsing

    struct Parsed: Equatable {
        var version: Int
        var keyId: String
        /// Base64 payload with all whitespace removed.
        var payload: String
    }

    /// Splits an armored block into header values and payload.
    nonisolated static func parse(_ armored: String) throws -> Parsed {
        let lines = armored
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let begin = lines.firstIndex(of: beginMarker) else {
            throw LockedNoteEnvelopeError.notLocked
        }
        guard let end = lines[(begin + 1)...].firstIndex(of: endMarker) else {
            throw LockedNoteEnvelopeError.malformed
        }
        var headers: [String: String] = [:]
        var index = begin + 1
        while index < end, !lines[index].isEmpty {
            let line = lines[index]
            guard let colon = line.firstIndex(of: ":") else { throw LockedNoteEnvelopeError.malformed }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
            index += 1
        }
        guard let versionText = headers["version"], let version = Int(versionText),
              let keyId = headers["key"], !keyId.isEmpty else {
            throw LockedNoteEnvelopeError.malformed
        }
        let payload = lines[index..<end].joined()
        guard !payload.isEmpty else { throw LockedNoteEnvelopeError.malformed }
        return Parsed(version: version, keyId: keyId, payload: payload)
    }

    // MARK: - Helpers

    private nonisolated static func associatedData(version: Int, keyId: String) -> Data {
        Data("scribe-locked-note|v\(version)|\(keyId)".utf8)
    }

    private nonisolated static func wrap(_ text: String, width: Int) -> [String] {
        var out: [String] = []
        var current = text[...]
        while !current.isEmpty {
            out.append(String(current.prefix(width)))
            current = current.dropFirst(width)
        }
        return out
    }
}
