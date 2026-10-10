// Scribe/Storage/NoteTemplateLibrary.swift
import Foundation

/// UserDefaults keys for note templates (Settings › Templates › Note templates).
enum NoteTemplateSettings {
    /// Vault-relative folder holding note templates. Default "Templates".
    static let folderKey = "noteTemplates.folder"
    static let defaultFolder = "Templates"
    /// Template id (vault-relative path) seeded into new daily notes; empty = none.
    static let dailyTemplateKey = "noteTemplates.dailyTemplate"
    /// Template id seeded into auto-created meeting notes; empty = none.
    static let meetingTemplateKey = "noteTemplates.meetingTemplate"

    /// The configured folder, sanitised to a vault-relative path.
    nonisolated static func folder(defaults: UserDefaults = .standard) -> String {
        sanitizedFolder(defaults.string(forKey: folderKey) ?? defaultFolder)
    }

    /// Strips leading/trailing slashes and refuses `..` / hidden components,
    /// falling back to the default. Keeps the folder inside the vault.
    nonisolated static func sanitizedFolder(_ raw: String) -> String {
        let components = raw
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." }
        guard !components.isEmpty,
              !components.contains(where: { $0 == ".." || $0.hasPrefix(".") }) else {
            return defaultFolder
        }
        return components.joined(separator: "/")
    }
}

/// One note template file in the vault.
struct NoteTemplateFile: Identifiable, Hashable, Sendable {
    /// Vault-relative path, e.g. `Templates/Weekly Review.md`. Stable id
    /// stored in Settings.
    let id: String
    /// Display name — the file name without extension (sub-folders shown as
    /// `Folder/Name`).
    let name: String
    let url: URL
}

/// Lists and loads note templates: markdown files in the vault's template
/// folder (recursively), excluding Scribe's own summary-template and recipe
/// folders and hidden files.
struct NoteTemplateLibrary: Sendable {
    let vaultRoot: URL
    let folder: String

    init(vaultRoot: URL, folder: String) {
        self.vaultRoot = vaultRoot
        self.folder = NoteTemplateSettings.sanitizedFolder(folder)
    }

    var folderURL: URL {
        vaultRoot.appendingPathComponent(folder, isDirectory: true)
    }

    /// Template files sorted by name.
    func list() -> [NoteTemplateFile] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [NoteTemplateFile] = []
        for case let url as URL in enumerator {
            if NoteFileStore.isInExcludedFolder(url, root: vaultRoot) {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "md" else { continue }
            guard let relative = VaultWriteGuard.relativePath(of: url.path, under: vaultRoot.path),
                  let inFolder = VaultWriteGuard.relativePath(of: url.path, under: folderURL.path) else { continue }
            let name = (inFolder as NSString).deletingPathExtension
            out.append(NoteTemplateFile(id: relative, name: name, url: url))
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The template's markdown with any frontmatter removed. nil when the
    /// file is missing / unreadable or `id` escapes the vault.
    func load(id: String) -> String? {
        guard !id.split(separator: "/").contains(where: { $0 == ".." }) else { return nil }
        let url = vaultRoot.appendingPathComponent(id)
        guard let data = try? Data(contentsOf: url),
              let contents = String(data: data, encoding: .utf8) else { return nil }
        return Self.templateBody(fromFileContents: contents)
    }

    /// Strips a leading `--- … ---` frontmatter block (a template saved as a
    /// note carries Scribe's id/title keys, which must not leak into notes
    /// made from it).
    nonisolated static func templateBody(fromFileContents contents: String) -> String {
        let decoded = NoteFrontmatterCodec.decodeFile(contents: contents, fallbackTitle: "", fallbackId: "")
        return decoded.body
    }

    /// Renders the template `id` (nil / empty id or a missing file → nil).
    func render(id: String?, context: NoteTemplateContext) -> RenderedNoteTemplate? {
        guard let id, !id.isEmpty, let body = load(id: id) else { return nil }
        return NoteTemplateRenderer.render(body, context: context)
    }
}

/// The Settings-chosen default templates for daily and meeting notes.
enum NoteTemplateDefaults {

    /// Body for a newly created daily note, or nil when no daily template is
    /// set (or it can't be read).
    nonisolated static func dailyNoteBody(
        fileStore: NoteFileStore?,
        date: Date,
        title: String,
        defaults: UserDefaults = .standard
    ) -> String? {
        guard let fileStore else { return nil }
        let library = NoteTemplateLibrary(vaultRoot: fileStore.directory.root,
                                          folder: NoteTemplateSettings.folder(defaults: defaults))
        let context = NoteTemplateContext(date: date, title: title)
        return library.render(id: defaults.string(forKey: NoteTemplateSettings.dailyTemplateKey), context: context)?.text
    }

    /// Body for an auto-created meeting note, or `fallback` when no meeting
    /// template is set (or it can't be read).
    nonisolated static func meetingNoteBody(
        fileStore: NoteFileStore?,
        fallback: String,
        title: String,
        meetingTitle: String?,
        attendees: [String],
        date: Date,
        defaults: UserDefaults = .standard
    ) -> String {
        guard let fileStore else { return fallback }
        let library = NoteTemplateLibrary(vaultRoot: fileStore.directory.root,
                                          folder: NoteTemplateSettings.folder(defaults: defaults))
        let context = NoteTemplateContext(date: date, title: title,
                                          meetingTitle: meetingTitle, meetingAttendees: attendees)
        guard let rendered = library.render(id: defaults.string(forKey: NoteTemplateSettings.meetingTemplateKey),
                                            context: context) else { return fallback }
        return rendered.text
    }
}
