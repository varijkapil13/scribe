import Foundation

/// Reads, lists and seeds the vault's template files:
///
///     <vault>/Templates/Summaries/*.md
///     <vault>/Templates/Recipes/*.md
///
/// `NoteFileStore` skips `Templates/Summaries` and `Templates/Recipes`
/// (case-insensitively), so these files are never indexed as notes; a
/// user's own notes elsewhere under `Templates/` still are. Built-ins are
/// written on first use (only when a folder has no `.md` files, so a user
/// who deletes a built-in doesn't get it back); "Restore built-in templates"
/// rewrites them explicitly.
struct SummaryTemplateStore {

    static let templatesFolderName = "Templates"
    static let summariesFolderName = "Summaries"
    static let recipesFolderName = "Recipes"

    let vaultRoot: URL

    init(vaultRoot: URL) {
        self.vaultRoot = vaultRoot
    }

    /// Store for the current vault (follows vault moves via `NoteStore.shared`).
    static func current() -> SummaryTemplateStore? {
        if let root = NoteStore.shared.fileStore?.directory.root {
            return SummaryTemplateStore(vaultRoot: root)
        }
        if let directory = try? NotesDirectory.defaultLocation() {
            return SummaryTemplateStore(vaultRoot: directory.root)
        }
        return nil
    }

    var templatesRoot: URL {
        vaultRoot.appendingPathComponent(Self.templatesFolderName, isDirectory: true)
    }

    var summariesFolder: URL {
        templatesRoot.appendingPathComponent(Self.summariesFolderName, isDirectory: true)
    }

    var recipesFolder: URL {
        templatesRoot.appendingPathComponent(Self.recipesFolderName, isDirectory: true)
    }

    // MARK: - Seeding

    /// Writes the built-in summary templates and recipes into any folder that
    /// is missing or has no markdown files yet.
    func seedIfNeeded() throws {
        if markdownFiles(in: summariesFolder).isEmpty {
            try writeBuiltInSummaries(overwrite: false)
        }
        if markdownFiles(in: recipesFolder).isEmpty {
            try writeBuiltInRecipes(overwrite: false)
        }
    }

    /// Re-writes every built-in template and recipe, replacing edited copies
    /// of built-ins. User-created files are left alone.
    func restoreBuiltIns() throws {
        try writeBuiltInSummaries(overwrite: true)
        try writeBuiltInRecipes(overwrite: true)
    }

    private func writeBuiltInSummaries(overwrite: Bool) throws {
        try FileManager.default.createDirectory(at: summariesFolder, withIntermediateDirectories: true)
        for template in BuiltInTemplates.summaries {
            try write(template.serialized(), to: summariesFolder.appendingPathComponent("\(template.id).md"),
                      overwrite: overwrite)
        }
    }

    private func writeBuiltInRecipes(overwrite: Bool) throws {
        try FileManager.default.createDirectory(at: recipesFolder, withIntermediateDirectories: true)
        for recipe in BuiltInTemplates.recipes {
            try write(recipe.serialized(), to: recipesFolder.appendingPathComponent("\(recipe.id).md"),
                      overwrite: overwrite)
        }
    }

    private func write(_ contents: String, to url: URL, overwrite: Bool) throws {
        if !overwrite && FileManager.default.fileExists(atPath: url.path) { return }
        guard let data = contents.data(using: .utf8) else { return }
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Listing

    /// All summary templates (seeding first), General first then by name.
    /// Falls back to the in-memory built-ins if the folder can't be read.
    func listTemplates() -> [SummaryTemplate] {
        try? seedIfNeeded()
        let loaded = markdownFiles(in: summariesFolder).compactMap { url -> SummaryTemplate? in
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return SummaryTemplate.parse(raw, id: url.deletingPathExtension().lastPathComponent)
        }
        let templates = loaded.isEmpty ? BuiltInTemplates.summaries : loaded
        return Self.sorted(templates)
    }

    /// All recipes (seeding first), sorted by name.
    func listRecipes() -> [NoteRecipe] {
        try? seedIfNeeded()
        let loaded = markdownFiles(in: recipesFolder).compactMap { url -> NoteRecipe? in
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let recipe = NoteRecipe.parse(raw, id: url.deletingPathExtension().lastPathComponent)
            return recipe.prompt.isEmpty ? nil : recipe
        }
        let recipes = loaded.isEmpty ? BuiltInTemplates.recipes : loaded
        return recipes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func template(id: String) -> SummaryTemplate? {
        listTemplates().first { $0.id == id }
    }

    static func sorted(_ templates: [SummaryTemplate]) -> [SummaryTemplate] {
        templates.sorted { a, b in
            if a.id == BuiltInTemplates.defaultTemplateId { return b.id != BuiltInTemplates.defaultTemplateId }
            if b.id == BuiltInTemplates.defaultTemplateId { return false }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private func markdownFiles(in folder: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
