// Scribe/UI/Notes/PowerNotes/NoteTemplatePicker.swift
import AppKit
import SwiftUI

extension NoteTemplateLibrary {
    /// The library for the open vault and the configured template folder.
    static func currentVault() -> NoteTemplateLibrary? {
        guard let root = NoteStore.shared.fileStore?.directory.root else { return nil }
        return NoteTemplateLibrary(vaultRoot: root, folder: NoteTemplateSettings.folder())
    }
}

/// Presents the template picker (File › New Note from Template…, ⌥⌘N, and the
/// editor's "/Template…" slash command) in a small panel and applies the pick.
@MainActor
final class NoteTemplatePanelController: NSObject, NSWindowDelegate {
    static let shared = NoteTemplatePanelController()

    private var panel: NSPanel?

    /// New note from a template: asks for a title, renders the template,
    /// creates the note and opens it in the main window.
    func presentNewNote(openMainWindow: @escaping @MainActor () -> Void) {
        let library = NoteTemplateLibrary.currentVault()
        present(
            library: library,
            mode: .newNote(defaultTitle: "")
        ) { [weak self] file, title in
            self?.close()
            Self.createNote(from: file, library: library, title: title, openMainWindow: openMainWindow)
        }
    }

    /// Inserts a rendered template at the caret of `coordinator`'s editor.
    func presentInsert(into coordinator: WebMarkdownEditor.Coordinator) {
        let library = NoteTemplateLibrary.currentVault()
        let noteTitle = coordinator.attachmentNoteId
            .flatMap { try? NoteStore.shared.fetchNote(id: $0) }?.title ?? ""
        present(library: library, mode: .insert) { [weak self, weak coordinator] file, _ in
            self?.close()
            guard let coordinator, let library else { return }
            let context = NoteTemplateContext(date: Date(), title: noteTitle,
                                              clipboard: NSPasteboard.general.string(forType: .string))
            guard let rendered = library.render(id: file.id, context: context) else {
                AppState.shared.report("The template \u{201C}\(file.name)\u{201D} couldn't be read.")
                return
            }
            coordinator.run(NotePowerEditorCommands.insertTemplate(rendered))
        }
    }

    // MARK: - Creating

    private static func createNote(from file: NoteTemplateFile,
                                   library: NoteTemplateLibrary?,
                                   title rawTitle: String,
                                   openMainWindow: @MainActor () -> Void) {
        guard let library else { return }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = NoteTemplateContext(date: Date(), title: title,
                                          clipboard: NSPasteboard.general.string(forType: .string))
        guard let rendered = library.render(id: file.id, context: context) else {
            AppState.shared.report("The template \u{201C}\(file.name)\u{201D} couldn't be read.")
            return
        }
        let body = NoteTemplateRenderer.trimmedForNoteBody(rendered)
        do {
            let note = try NoteStore.shared.createNote(title: title, body: body.text)
            openMainWindow()
            NotificationCenter.default.post(name: .scribeNavigate, object: MainSelection.note(note.id))
            if let cursor = body.cursorOffset {
                placeCursor(offset: cursor, docLength: (body.text as NSString).length)
            }
        } catch {
            AppState.shared.report(error)
        }
    }

    /// Moves the caret of the newly opened note's editor once it has loaded.
    /// Best-effort: the JS side ignores it unless the document still has the
    /// template's length.
    private static func placeCursor(offset: Int, docLength: Int) {
        let command = NotePowerEditorCommands.setCursor(offset: offset, docLength: docLength)
        Task { @MainActor in
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(350))
                if WebEditorCommandCenter.shared.send(command) { return }
            }
        }
    }

    // MARK: - Panel

    private func present(library: NoteTemplateLibrary?,
                         mode: NoteTemplatePickerView.Mode,
                         onChoose: @escaping @MainActor (NoteTemplateFile, String) -> Void) {
        close()
        let templates = library?.list() ?? []
        let view = NoteTemplatePickerView(
            templates: templates,
            library: library,
            mode: mode,
            onChoose: onChoose,
            onCancel: { [weak self] in self?.close() }
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = mode.isInsert ? "Insert Template" : "New Note from Template"
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: view)
        panel.delegate = self
        panel.center()
        self.panel = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}

/// Commands this feature sends into the web editor (see editor-web/src/notepower.js).
enum NotePowerEditorCommands {
    static func insertTemplate(_ rendered: RenderedNoteTemplate) -> WebEditorCommand {
        var arg: [String: Any] = ["text": rendered.text]
        if let cursor = rendered.cursorOffset { arg["cursor"] = cursor }
        return WebEditorCommand(name: "insertTemplate", argumentJSON: WebEditorJS.jsonLiteral(arg, fallback: "null"))
    }

    static func setCursor(offset: Int, docLength: Int) -> WebEditorCommand {
        WebEditorCommand(name: "setCursorOffset",
                         argumentJSON: WebEditorJS.jsonLiteral(["offset": offset, "docLength": docLength], fallback: "null"))
    }

    static func copyBlockLink(noteTitle: String) -> WebEditorCommand {
        WebEditorCommand(name: "copyBlockLink",
                         argumentJSON: WebEditorJS.jsonLiteral(["title": noteTitle], fallback: "null"))
    }

    static func embedContent(target: String, found: Bool, title: String, markdown: String) -> WebEditorCommand {
        let arg: [String: Any] = ["target": target, "found": found, "title": title, "markdown": markdown]
        return WebEditorCommand(name: "embedContent", argumentJSON: WebEditorJS.jsonLiteral(arg, fallback: "null"))
    }
}

// MARK: - Picker view

struct NoteTemplatePickerView: View {
    enum Mode {
        case newNote(defaultTitle: String)
        case insert

        var isInsert: Bool {
            if case .insert = self { return true }
            return false
        }
    }

    let templates: [NoteTemplateFile]
    let library: NoteTemplateLibrary?
    let mode: Mode
    let onChoose: @MainActor (NoteTemplateFile, String) -> Void
    let onCancel: @MainActor () -> Void

    @State private var query = ""
    @State private var selection: NoteTemplateFile.ID?
    @State private var title = ""
    @FocusState private var titleFocused: Bool

    private var filtered: [NoteTemplateFile] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return templates }
        return templates.filter { $0.name.lowercased().contains(q) }
    }

    private var selected: NoteTemplateFile? {
        templates.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            if templates.isEmpty {
                emptyState
            } else {
                TextField("Filter templates", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Filter templates")
                HSplitView {
                    List(filtered, selection: $selection) { file in
                        Label(file.name, systemImage: "doc.text")
                            .tag(file.id)
                    }
                    .frame(minWidth: 180)
                    preview
                        .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
                }
                if !mode.isInsert {
                    TextField("Note title", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .focused($titleFocused)
                        .accessibilityLabel("Title for the new note")
                }
            }
            HStack {
                Text("Variables: {{date}}, {{time}}, {{title}}, {{cursor}}, {{weekday}}, {{meeting.title}}, {{clipboard}}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(mode.isInsert ? "Insert" : "Create") {
                    if let selected { onChoose(selected, title) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
        }
        .padding(DesignTokens.Spacing.md)
        .frame(minWidth: 480, minHeight: 340)
        .onAppear {
            selection = templates.first?.id
            if case .newNote(let defaultTitle) = mode { title = defaultTitle }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let selected, let content = library?.load(id: selected.id) {
            ScrollView {
                Text(content.isEmpty ? "Empty template" : content)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(content.isEmpty ? Color.secondary : Color.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignTokens.Spacing.sm)
            }
            .accessibilityLabel("Template preview")
        } else {
            Text("Select a template")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No note templates yet")
                .font(.headline)
            Text("Add markdown files to the \u{201C}\(library?.folder ?? NoteTemplateSettings.defaultFolder)\u{201D} folder in your notes vault. Templates can use variables such as {{date}} and {{title}}.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let library {
                Button("Create Sample Template") {
                    NoteTemplateFolderActions.createSample(in: library)
                    onCancel()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Finder / file actions for the note-template folder.
@MainActor
enum NoteTemplateFolderActions {
    static let sampleFileName = "Meeting Notes.md"

    static let sampleTemplate = """
    # {{title}}

    **Date:** {{date:EEEE, d MMMM yyyy}} · {{time}}
    **Attendees:** {{meeting.attendees}}

    ## Agenda
    - {{cursor}}

    ## Notes

    ## Action items
    - [ ]
    """

    static func reveal(_ library: NoteTemplateLibrary) {
        try? FileManager.default.createDirectory(at: library.folderURL, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([library.folderURL])
    }

    /// Writes a sample template (never overwriting an existing file).
    static func createSample(in library: NoteTemplateLibrary) {
        do {
            try FileManager.default.createDirectory(at: library.folderURL, withIntermediateDirectories: true)
            let url = library.folderURL.appendingPathComponent(sampleFileName)
            guard !FileManager.default.fileExists(atPath: url.path) else {
                AppState.shared.notify("\u{201C}\(sampleFileName)\u{201D} already exists")
                return
            }
            try Data(sampleTemplate.utf8).write(to: url, options: .atomic)
            AppState.shared.notify("Sample template created")
        } catch {
            AppState.shared.report(error)
        }
    }
}
