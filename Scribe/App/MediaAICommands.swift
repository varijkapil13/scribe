import SwiftUI

/// File-menu commands for media import and translation:
/// File › Import Recording…, Translate Note…, Translate Transcript….
/// The translate items act on the note in the key window (`scribeNote`).
struct MediaAICommands: Commands {

    var body: some Commands {
        CommandGroup(after: .importExport) {
            ImportRecordingMenuItem()
            TranslateMenuItems()
        }
    }
}

private struct ImportRecordingMenuItem: View {
    var body: some View {
        Button("Import Recording…") {
            MediaImportController.shared.presentOpenPanel()
        }
    }
}

private struct TranslateMenuItems: View {
    @FocusedValue(\.scribeNote) private var note
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Translate Note…") { open(.note) }
            .disabled(note == nil)
        Button("Translate Transcript…") { open(.transcript) }
            .disabled(note == nil)
    }

    private func open(_ source: ScribeTranslationRequest.Source) {
        guard let note else { return }
        openWindow(id: ScribeTranslationRequest.windowID, value: ScribeTranslationRequest(noteId: note.noteId, source: source))
    }
}
