// Scribe/Documents/Export/VaultZipExporter.swift
//
// File › Export › Notes Vault as ZIP…: every Markdown note plus its
// attachments (and any other non-hidden files in the vault), in one zip with
// the vault's folder structure. Locked notes stay encrypted.

import AppKit
import Foundation
import UniformTypeIdentifiers

enum VaultZipExporter {

    enum ExportError: Error, LocalizedError {
        case noVault
        case zipFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .noVault: return "Scribe's notes folder isn't available."
            case .zipFailed(let status): return "The zip archive couldn't be created (status \(status))."
            }
        }
    }

    /// Default archive name, e.g. `Scribe Notes 2026-10-10.zip`.
    nonisolated static func defaultFileName(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Scribe Notes \(formatter.string(from: now)).zip"
    }

    /// Vault-relative paths to export: every regular, non-hidden file.
    /// Hidden folders (`.obsidian`, `.git`, `.trash`) and Scribe's internal
    /// templates are left out.
    nonisolated static func exportablePaths(under root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [String] = []
        for case let url as URL in enumerator {
            if NoteFileStore.isInExcludedFolder(url, root: root) {
                enumerator.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let relative = VaultWriteGuard.relativePath(of: url.path, under: root.path) else { continue }
            out.append(relative)
        }
        return out.sorted()
    }

    /// Copies the exportable files into a staging folder named
    /// `folderName` and zips it to `destination`. Returns the file count.
    @discardableResult
    nonisolated static func export(root: URL, to destination: URL, folderName: String) throws -> Int {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("ScribeExport-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        let staging = scratch.appendingPathComponent(folderName, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let paths = exportablePaths(under: root)
        for relative in paths {
            let source = root.appendingPathComponent(relative)
            let target = staging.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: target)
        }

        let archive = scratch.appendingPathComponent("export.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", staging.path, archive.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ExportError.zipFailed(process.terminationStatus) }

        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: archive)
        } else {
            try fm.moveItem(at: archive, to: destination)
        }
        return paths.count
    }

    /// Save panel + background export + result banner.
    @MainActor
    static func exportInteractively() {
        guard let root = NoteStore.shared.fileStore?.directory.root else {
            AppState.shared.report(ExportError.noVault.localizedDescription)
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Notes"
        panel.message = "Saves every note as Markdown, with its attachments, in one zip file. Locked notes stay locked."
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFileName(now: Date())
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let folderName = destination.deletingPathExtension().lastPathComponent
        AppState.shared.notify("Exporting notes…")
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Int, any Error> in
                Result { try export(root: root, to: destination, folderName: folderName) }
            }.value
            switch result {
            case .success(let count):
                AppState.shared.notify("Exported \(count) file\(count == 1 ? "" : "s") to \u{201C}\(destination.lastPathComponent)\u{201D}")
            case .failure(let error):
                AppState.shared.report("Couldn't export the notes: \(error.localizedDescription)")
            }
        }
    }
}
