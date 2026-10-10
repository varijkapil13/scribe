import Foundation

/// Decides what opening a Markdown file in Scribe (Finder "Open With",
/// dropping on the Dock icon, `open -a Scribe file.md`) should do.
///
/// - a note file inside the current vault → open that note;
/// - a file outside the vault (or in a vault folder Scribe doesn't index,
///   like `templates/summaries`) → import a copy as a new note;
/// - anything that isn't a Markdown file → ignore.
///
/// Pure (path arithmetic only, no file IO), so it's unit-tested without a
/// vault on disk.
enum MarkdownOpenClassifier {

    enum Disposition: Equatable, Sendable {
        /// The file is a note in the vault; `relativePath` is vault-relative
        /// (`/`-separated, no leading slash).
        case vaultNote(relativePath: String)
        /// The file lives outside the vault, or in a vault folder that isn't
        /// indexed as notes — import a copy.
        case importCopy
        /// Not a Markdown file.
        case unsupported
    }

    /// File extensions Scribe treats as Markdown (case-insensitive).
    nonisolated static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    nonisolated static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// Classifies `fileURL` against `vaultRoot` (nil when no vault is
    /// configured, in which case every Markdown file is imported).
    ///
    /// Both paths are standardized (`..`, `.`, duplicate slashes) and the
    /// macOS `/private` alias is ignored on either side, so
    /// `/var/folders/…` and `/private/var/folders/…` compare equal. Symlinks
    /// are resolved by the caller (`resolvingSymlinksInPath()`) when the
    /// files exist — this function never touches the disk.
    nonisolated static func classify(fileURL: URL, vaultRoot: URL?) -> Disposition {
        guard fileURL.isFileURL, isMarkdown(fileURL) else { return .unsupported }
        guard let vaultRoot else { return .importCopy }

        let filePath = fileURL.standardizedFileURL.path
        let rootPath = vaultRoot.standardizedFileURL.path
        guard let relative = VaultWriteGuard.relativePath(of: filePath, under: rootPath) else {
            return .importCopy
        }

        let components = relative.split(separator: "/").map(String.init)
        // Hidden files / folders (".obsidian", ".trash", ".DS_Store"-style)
        // are never indexed as notes.
        if components.contains(where: { $0.hasPrefix(".") }) {
            return .importCopy
        }
        if NoteFileStore.isInExcludedFolder(fileURL.standardizedFileURL, root: vaultRoot.standardizedFileURL) {
            return .importCopy
        }
        // The vault indexes `.md` only (NoteFileStore.listEntries); a
        // `.markdown` file sitting in the vault isn't a note yet.
        guard fileURL.pathExtension.lowercased() == "md" else { return .importCopy }
        return .vaultNote(relativePath: relative)
    }

    /// Title for an imported file that has no `title:` frontmatter: the file
    /// name without its extension, or "Imported Note" when that is blank.
    nonisolated static func fallbackTitle(for fileURL: URL) -> String {
        let name = fileURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Imported Note" : name
    }
}
