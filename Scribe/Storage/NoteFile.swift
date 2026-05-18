import Foundation

/// Parsed representation of a `.md` note file on disk.
///
/// A `NoteFile` is the in-memory shape of a single file under the notes
/// storage root: stable `id` (UUID, frontmatter-pinned for wiki-link
/// stability), `frontmatter` metadata, and the markdown `body` below the
/// frontmatter block. Round-trips losslessly through `NoteFileStore`.
///
/// Wiki-links resolve through `id`, not filename, so renames don't break
/// references. The filename is derived from `frontmatter.title` and is
/// allowed to drift independently — the source of truth is `id`.
struct NoteFile: Equatable {
    var id: String
    var frontmatter: NoteFrontmatter
    var body: String

    init(id: String, frontmatter: NoteFrontmatter, body: String) {
        self.id = id
        self.frontmatter = frontmatter
        self.body = body
    }
}

/// Flat YAML-subset metadata stored in the `--- ... ---` frontmatter block
/// at the top of every note file. Mirrors the columns previously held on
/// the `notes` SQLite table, minus the body (which is the file content).
///
/// Encoding is deterministic so file diffs stay clean — keys emitted in a
/// fixed order, dates as ISO 8601 with fractional seconds, empty values
/// emitted as `key: ` (not `null`) for Obsidian compatibility.
struct NoteFrontmatter: Equatable {
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var notebookId: String?
    var tags: [String]
    var isDailyNote: Bool
    var dailyDate: Date?

    init(
        title: String,
        createdAt: Date,
        updatedAt: Date,
        notebookId: String? = nil,
        tags: [String] = [],
        isDailyNote: Bool = false,
        dailyDate: Date? = nil
    ) {
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.notebookId = notebookId
        self.tags = tags
        self.isDailyNote = isDailyNote
        self.dailyDate = dailyDate
    }
}
