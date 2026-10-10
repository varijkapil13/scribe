import Foundation

/// Pure checks run on a backup archive's entry listing *before* anything is
/// extracted, so a crafted archive can't write outside the scratch folder.
enum ScribeBackupArchiveSafety {

    /// Entry names that would escape the extraction folder: absolute paths,
    /// home-relative paths, or any `..` component.
    nonisolated static func unsafeEntryNames(_ names: [String]) -> [String] {
        names.filter { !isSafeEntryName($0) }
    }

    nonisolated static func isSafeEntryName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true } // blank listing lines are noise
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix("\\") { return false }
        let components = trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return !components.contains { $0 == ".." }
    }

    /// Whether a zipinfo long listing (`unzip -Z`) contains symbolic links.
    /// Entry lines start with a Unix mode string; a leading `l` is a symlink.
    /// Backups never contain links (they are skipped when the vault is
    /// staged), so any link means the archive wasn't written by Scribe — and
    /// a link followed by a file "inside" it is the classic way to write
    /// outside the extraction folder.
    nonisolated static func containsSymlinkEntries(longListing: String) -> Bool {
        longListing
            .split(whereSeparator: \.isNewline)
            .contains { line in
                guard line.first == "l" else { return false }
                // Mode strings are 10 characters (`lrwxr-xr-x`); require the
                // shape so a header line can't trip it.
                let mode = line.prefix(10)
                return mode.count == 10 && mode.dropFirst().allSatisfy { "rwxsStT-".contains($0) }
            }
    }
}
