// Scribe/Documents/Import/DocumentImportController.swift
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Thread-safe cancel flag shared with the background import.
final class ImportCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Drives File › Import › …: the open panel, the progress sheet, the
/// background read + write, and the summary.
@MainActor
final class DocumentImportController: ObservableObject {

    static let shared = DocumentImportController()

    enum Phase: Equatable {
        case idle
        case working
        case finished(NoteImportSummary)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress = NoteImportProgress(phase: "", completed: 0, total: 0)
    @Published private(set) var kind: NoteImportKind = .markdownFolder

    var isWorking: Bool { phase == .working }

    private var sheetWindow: NSWindow?
    private var cancelFlag = ImportCancellationFlag()

    private init() {}

    // MARK: - Entry

    func beginImport(_ kind: NoteImportKind) {
        guard !isWorking else {
            sheetWindow?.makeKeyAndOrderFront(nil)
            return
        }
        guard let fileStore = NoteStore.shared.fileStore else {
            AppState.shared.report("Scribe's notes folder isn't available, so nothing can be imported right now.")
            return
        }
        guard let urls = chooseSources(for: kind), !urls.isEmpty else { return }

        self.kind = kind
        cancelFlag = ImportCancellationFlag()
        phase = .working
        progress = NoteImportProgress(phase: "Reading \(kind.sourceLabel)…", completed: 0, total: 0)
        presentSheet()

        let flag = cancelFlag
        let writer = NoteImportWriter(
            noteStore: .shared,
            fileStore: fileStore,
            dbManager: .shared,
            attachmentsRoot: AttachmentsDirectory.defaultRoot()
        )
        Task {
            let summary = await Task.detached(priority: .userInitiated) { () -> NoteImportSummary in
                Self.runImport(kind: kind, urls: urls, writer: writer, flag: flag)
            }.value
            self.finish(summary)
        }
    }

    func cancel() {
        cancelFlag.cancel()
        progress.phase = "Cancelling…"
    }

    func dismiss() {
        guard !isWorking else { return }
        if let window = sheetWindow {
            if let parent = window.sheetParent {
                parent.endSheet(window)
            } else {
                window.orderOut(nil)
            }
        }
        sheetWindow = nil
        phase = .idle
    }

    /// Opens the first imported note in the main window.
    func showImportedNotes() {
        guard case .finished(let summary) = phase, let noteId = summary.firstImportedNoteId else {
            dismiss()
            return
        }
        dismiss()
        NotificationCenter.default.post(name: .scribeNavigate, object: MainSelection.note(noteId))
    }

    // MARK: - Background work

    nonisolated private static func runImport(
        kind: NoteImportKind,
        urls: [URL],
        writer: NoteImportWriter,
        flag: ImportCancellationFlag
    ) -> NoteImportSummary {
        var summary = NoteImportSummary(sourceLabel: kind.sourceLabel)
        var scratchFolders: [URL] = []
        defer {
            for folder in scratchFolders { try? FileManager.default.removeItem(at: folder) }
        }

        // 1. Read the source into drafts.
        var read = NoteImportReadResult()
        switch kind {
        case .evernote:
            read = NoteImportSources.readEvernote(urls)
        case .documents:
            read = NoteImportSources.readDocuments(urls, isCancelled: { flag.isCancelled }, progress: { done, total in
                Self.report(phase: "Recognizing text…", done, total)
            })
        case .notion, .markdownFolder, .appleNotes:
            for url in urls {
                let root: URL
                do {
                    let prepared = try ImportInputPreparer.prepareFolder(url)
                    if let scratch = prepared.scratch { scratchFolders.append(scratch) }
                    root = prepared.root
                } catch {
                    summary.warnings.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    continue
                }
                let part: NoteImportReadResult
                switch kind {
                case .notion: part = NoteImportSources.readNotion(root: root)
                case .appleNotes: part = NoteImportSources.readAppleNotes(root: root)
                default: part = NoteImportSources.readMarkdownFolder(root: root)
                }
                read.drafts += part.drafts
                read.warnings += part.warnings
            }
        }
        summary.warnings += read.warnings
        if read.drafts.isEmpty {
            if summary.warnings.isEmpty {
                summary.warnings.append("Nothing to import was found.")
            }
            return summary
        }

        // 2. Write them into the vault.
        report(phase: "Importing notes…", 0, read.drafts.count)
        writer.write(
            read.drafts,
            into: &summary,
            isCancelled: { flag.isCancelled },
            progress: { done, total in Self.report(phase: "Importing notes…", done, total) }
        )
        return summary
    }

    nonisolated private static func report(phase: String, _ done: Int, _ total: Int) {
        let update = NoteImportProgress(phase: phase, completed: done, total: total)
        Task { @MainActor in
            DocumentImportController.shared.applyProgress(update)
        }
    }

    private func applyProgress(_ update: NoteImportProgress) {
        guard isWorking else { return }
        progress = update
    }

    private func finish(_ summary: NoteImportSummary) {
        phase = .finished(summary)
        if summary.importedCount > 0 {
            // New image / PDF attachments: let the OCR indexer pick them up.
            AttachmentOCRIndexer.shared.requestPass(after: 5)
        }
    }

    // MARK: - Panels + sheet

    private func chooseSources(for kind: NoteImportKind) -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = "Import \(kind.sourceLabel)"
        panel.prompt = "Import"
        panel.canCreateDirectories = false
        switch kind {
        case .evernote:
            panel.message = "Choose one or more Evernote exports (.enex)."
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            panel.allowedContentTypes = [UTType(filenameExtension: "enex") ?? .xml, .xml]
        case .notion:
            panel.message = "Choose a Notion export (Markdown & CSV) — the unzipped folder or the .zip."
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.zip, .folder]
        case .markdownFolder:
            panel.message = "Choose a folder of Markdown files (a Bear export or an Obsidian vault) or a .zip of one. Folders become notebooks."
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.zip, .folder]
        case .appleNotes:
            panel.message = "Choose a folder of notes exported from Apple Notes as HTML or Markdown files. Folders become notebooks."
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.zip, .folder]
        case .documents:
            panel.message = "Choose PDFs or images. Each becomes a note with the file attached and its text recognized."
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            panel.allowedContentTypes = [.pdf, .image]
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.urls
    }

    private func presentSheet() {
        if let existing = sheetWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: DocumentImportSheet(controller: self))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled]
        window.title = "Import"
        window.isReleasedWhenClosed = false
        sheetWindow = window
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow, parent.attachedSheet == nil {
            parent.beginSheet(window)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// Unzips a chosen `.zip` into a scratch folder (or passes a folder through).
enum ImportInputPreparer {

    struct Prepared: Sendable {
        var root: URL
        /// Scratch folder to delete afterwards.
        var scratch: URL?
    }

    enum PrepareError: Error, LocalizedError {
        case unzipFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .unzipFailed(let status): return "The archive couldn't be unzipped (status \(status))."
            }
        }
    }

    nonisolated static func prepareFolder(_ url: URL) throws -> Prepared {
        guard url.pathExtension.lowercased() == "zip" else {
            return Prepared(root: url, scratch: nil)
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScribeImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", url.path, scratch.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: scratch)
            throw PrepareError.unzipFailed(process.terminationStatus)
        }
        // Most archives wrap everything in one folder: import that folder
        // (it names the notebook) rather than the scratch directory.
        let items = (try? FileManager.default.contentsOfDirectory(
            at: scratch, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        let meaningful = items.filter { $0.lastPathComponent != "__MACOSX" }
        if meaningful.count == 1, let only = meaningful.first,
           (try? only.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return Prepared(root: only, scratch: scratch)
        }
        // Otherwise name the root after the archive.
        let named = scratch.appendingPathComponent(url.deletingPathExtension().lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
        for item in meaningful {
            try FileManager.default.moveItem(at: item, to: named.appendingPathComponent(item.lastPathComponent))
        }
        return Prepared(root: named, scratch: scratch)
    }
}

// MARK: - Sheet

struct DocumentImportSheet: View {
    @ObservedObject var controller: DocumentImportController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch controller.phase {
            case .idle, .working:
                working
            case .finished(let summary):
                finished(summary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                HStack {
                    Spacer()
                    Button("Done") { controller.dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Importing from \(controller.kind.sourceLabel)")
                .font(.headline)
            if controller.progress.total > 0 {
                ProgressView(value: controller.progress.fraction)
                Text("\(controller.progress.phase) \(controller.progress.completed) of \(controller.progress.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                Text(controller.progress.phase)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Existing notes are never changed — imported notes whose titles are already taken get a number added.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { controller.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func finished(_ summary: NoteImportSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(summary.headline,
                  systemImage: summary.failedCount == 0 && summary.importedCount > 0
                    ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.headline)
                .foregroundStyle(summary.failedCount == 0 && summary.importedCount > 0 ? Color.green : Color.orange)
                .fixedSize(horizontal: false, vertical: true)

            if summary.notebooksCreated > 0 || summary.attachmentsSaved > 0 {
                Text(detailLine(summary))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            let notable = summary.items.filter { item in
                switch item.outcome {
                case .imported(_, _, let renamed): return renamed
                case .failed, .skipped: return true
                }
            }
            if !notable.isEmpty || !summary.warnings.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(summary.warnings, id: \.self) { warning in
                            Text(warning)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        ForEach(notable) { item in
                            Text(describe(item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 180)
            }

            HStack {
                Spacer()
                if summary.firstImportedNoteId != nil {
                    Button("Show Notes") { controller.showImportedNotes() }
                }
                Button("Done") { controller.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func detailLine(_ summary: NoteImportSummary) -> String {
        var parts: [String] = []
        if summary.notebooksCreated > 0 {
            parts.append("\(summary.notebooksCreated) notebook\(summary.notebooksCreated == 1 ? "" : "s") created")
        }
        if summary.attachmentsSaved > 0 {
            parts.append("\(summary.attachmentsSaved) attachment\(summary.attachmentsSaved == 1 ? "" : "s") saved")
        }
        return parts.joined(separator: " · ")
    }

    private func describe(_ item: NoteImportItemResult) -> String {
        switch item.outcome {
        case .imported(_, let title, _):
            return "\(item.sourceName) → \u{201C}\(title)\u{201D}"
        case .skipped(let reason):
            return "Skipped \(item.sourceName): \(reason)"
        case .failed(let reason):
            return "Failed \(item.sourceName): \(reason)"
        }
    }
}
