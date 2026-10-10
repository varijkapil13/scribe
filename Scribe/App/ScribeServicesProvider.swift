import AppKit

/// System Services menu provider ("New Scribe Note from Selection", "Add
/// Selection as Scribe Task"), registered as `NSApp.servicesProvider` by
/// `ScribeEntryRouter.install(delegate:)`.
///
/// The selectors must match the `NSMessage` values declared under
/// `NSServices` in Info.plist: AppKit calls `<NSMessage>:userData:error:`.
/// Services are always delivered on the main thread.
@MainActor
final class ScribeServicesProvider: NSObject {

    /// `NSMessage` = `newNoteFromSelection`.
    @objc(newNoteFromSelection:userData:error:)
    func newNoteFromSelection(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let text = Self.selectedText(on: pasteboard),
              let fields = SelectionCaptureParser.noteFields(from: text) else {
            error.pointee = "No text was selected." as NSString
            return
        }
        ScribeEntryRouter.shared.createNote(title: fields.title, body: fields.body)
    }

    /// `NSMessage` = `addSelectionAsTask`.
    @objc(addSelectionAsTask:userData:error:)
    func addSelectionAsTask(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let text = Self.selectedText(on: pasteboard),
              let fields = SelectionCaptureParser.taskFields(from: text) else {
            error.pointee = "No text was selected." as NSString
            return
        }
        ScribeEntryRouter.shared.createTask(title: fields.title, notes: fields.notes, dueText: nil)
    }

    private static func selectedText(on pasteboard: NSPasteboard) -> String? {
        pasteboard.string(forType: .string)
    }
}
