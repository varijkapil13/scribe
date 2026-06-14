import Foundation

/// Resolves the iCloud-Drive ubiquity-container location for the note vault.
///
/// Notes are files, so they sync best via iCloud Drive (which also keeps them
/// Obsidian-compatible and visible in the Files app) rather than CloudKit.
///
/// ⚠️ Hazard handled deliberately: `url(forUbiquityContainerIdentifier:)`
/// BLOCKS the first time it's called and must never run on the app's launch /
/// main path. `resolveNotesURL()` does it on a detached background task; the
/// resolved path is then meant to be written into `NotesDirectory`'s
/// `notesVaultPath` override, so every subsequent launch reads a plain stored
/// path with no blocking iCloud call. The path-shaping itself is pure and
/// unit-tested; the container resolution + the eventual file migration are
/// DEVICE-VALIDATION-REQUIRED (need a real iCloud account + provisioned
/// `iCloud.com.varij.scribe`).
enum ICloudVaultLocator {
    static let containerIdentifier = "iCloud.com.varij.scribe"

    /// Pure: the vault lives at `<container>/Documents/Scribe/Notes`. Mirrors
    /// `NotesDirectory`'s local layout so reconcile logic is identical whether
    /// the vault is local or in iCloud. Unit-testable without iCloud.
    static func notesURL(forContainer container: URL) -> URL {
        container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Scribe", isDirectory: true)
            .appendingPathComponent("Notes", isDirectory: true)
    }

    /// Resolves the iCloud notes-vault URL off the main thread. Returns `nil`
    /// when the user isn't signed into iCloud or the container isn't
    /// provisioned (caller falls back to the local vault). Never call on launch.
    static func resolveNotesURL() async -> URL? {
        await Task.detached(priority: .utility) {
            guard let container = FileManager.default.url(
                forUbiquityContainerIdentifier: containerIdentifier
            ) else { return nil }
            return notesURL(forContainer: container)
        }.value
    }
}
