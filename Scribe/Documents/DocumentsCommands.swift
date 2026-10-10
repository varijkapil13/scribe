// Scribe/Documents/DocumentsCommands.swift
import SwiftUI

/// File › Import / Export submenus (importers, PDF/image as note, vault zip,
/// HTML export of the focused note).
struct DocumentsMenuCommands: Commands {

    var body: some Commands {
        CommandGroup(before: .importExport) {
            Menu("Import") {
                ForEach(NoteImportKind.allCases) { kind in
                    Button(kind.menuTitle) {
                        DocumentImportController.shared.beginImport(kind)
                    }
                }
            }
            Menu("Export") {
                Button("Notes Vault as ZIP…") {
                    VaultZipExporter.exportInteractively()
                }
                NoteHTMLExportMenuItem()
            }
            Divider()
        }
    }
}

private struct NoteHTMLExportMenuItem: View {
    @FocusedValue(\.scribeNote) private var note

    var body: some View {
        Button("Note as HTML…") {
            guard let note else { return }
            NoteHTMLExport.exportInteractively(noteId: note.noteId)
        }
        .disabled(note == nil)
    }
}

/// Starts the documents features' background services. Called once at
/// launch from `AppDelegate`.
@MainActor
enum DocumentsServices {
    static func start() {
        LockedNoteSession.shared.start()
        AttachmentOCRIndexer.shared.start()
    }
}
