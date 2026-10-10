import Foundation

/// Owns the user's custom vocabulary list.
///
/// Persistence: a markdown file at
/// `~/Library/Application Support/Scribe/vocabulary.md` (format documented on
/// `VocabularyFile`). A file rather than UserDefaults so power users can edit
/// it in any text editor; `reload()` re-reads it, and every transcription
/// pipeline start calls `reload()` so hand edits take effect on the next
/// recording / dictation without restarting Scribe.
@MainActor
final class VocabularyStore: ObservableObject {

    static let shared = VocabularyStore(fileURL: VocabularyStore.defaultFileURL())

    @Published private(set) var entries: [VocabularyEntry] = []
    /// Last load/save failure, for the settings pane. `nil` when healthy.
    @Published private(set) var lastError: String?

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        reload()
    }

    nonisolated static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("Scribe", isDirectory: true)
            .appendingPathComponent("vocabulary.md")
    }

    // MARK: - Derived

    /// Terms handed to the transcriber as contextual strings.
    var contextualStrings: [String] { VocabularyFile.contextualStrings(for: entries) }

    func makeCorrector() -> VocabularyCorrector { VocabularyCorrector(entries: entries) }

    // MARK: - Load / save

    /// Re-reads the file. A missing file is an empty vocabulary, not an error.
    func reload() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            entries = []
            return
        }
        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            entries = VocabularyFile.parse(text)
            lastError = nil
        } catch {
            Log.speech.error("Vocabulary load failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't read \(fileURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try VocabularyFile.serialize(entries).write(to: fileURL, atomically: true, encoding: .utf8)
            lastError = nil
        } catch {
            Log.speech.error("Vocabulary save failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't save \(fileURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: - Editing

    /// Adds an entry. Returns `false` when the term is empty or an identical
    /// entry already exists.
    @discardableResult
    func add(term: String, heardAs: String? = nil) -> Bool {
        let entry = VocabularyEntry(term: term, heardAs: heardAs)
        guard !entry.term.isEmpty, !entries.contains(where: { $0.id == entry.id }) else { return false }
        entries.append(entry)
        save()
        return true
    }

    func remove(_ entry: VocabularyEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        for index in offsets.sorted(by: >) where entries.indices.contains(index) {
            entries.remove(at: index)
        }
        save()
    }

    func removeAll() {
        entries = []
        save()
    }
}
