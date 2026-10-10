// ScribeiOS/Notes/NoteTemplateSheet.swift
//
// Note templates on iPhone / iPad — the same vault templates and renderer as
// the Mac (`NoteTemplateLibrary` lists `<vault>/Templates/*.md`,
// `NoteTemplateRenderer` fills {{date}}, {{title}}, {{cursor}}, …). Used for
// "New Note from Template" in the note list and "Insert Template" (also the
// editor's /Template slash command) in the editor.

import SwiftUI
import UIKit

extension NoteTemplateLibrary {
    /// The library for the open vault and the configured template folder.
    static func iosCurrentVault(store: NoteStore) -> NoteTemplateLibrary? {
        guard let root = store.fileStore?.directory.root else { return nil }
        return NoteTemplateLibrary(vaultRoot: root, folder: NoteTemplateSettings.folder())
    }
}

@MainActor
enum NoteTemplateActions {
    /// Renders `file` for a note titled `title` (clipboard text available
    /// to `{{clipboard}}`).
    static func render(_ file: NoteTemplateFile, library: NoteTemplateLibrary, title: String) -> RenderedNoteTemplate? {
        let context = NoteTemplateContext(date: Date(), title: title, clipboard: UIPasteboard.general.string)
        return library.render(id: file.id, context: context)
    }

    /// Creates a note from `file`; returns its id.
    static func createNote(from file: NoteTemplateFile, library: NoteTemplateLibrary, title rawTitle: String,
                           notebookId: String?, store: NoteStore) throws -> String? {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rendered = render(file, library: library, title: title) else { return nil }
        let body = NoteTemplateRenderer.trimmedForNoteBody(rendered)
        return try store.createNote(title: title, body: body.text, notebookId: notebookId).id
    }

    static let sampleFileName = "Meeting Notes.md"
    static let sampleTemplate = """
    # {{title}}

    **Date:** {{date:EEEE, d MMMM yyyy}} · {{time}}

    ## Agenda
    - {{cursor}}

    ## Notes

    ## Action items
    - [ ]
    """

    /// Writes a sample template into the template folder (never overwrites).
    static func createSample(in library: NoteTemplateLibrary) throws {
        try FileManager.default.createDirectory(at: library.folderURL, withIntermediateDirectories: true)
        let url = library.folderURL.appendingPathComponent(sampleFileName)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try Data(sampleTemplate.utf8).write(to: url, options: .atomic)
    }
}

struct NoteTemplateSheet: View {
    enum Mode {
        case newNote
        case insert
    }

    let mode: Mode
    let library: NoteTemplateLibrary?
    /// Called with the chosen template (and, for a new note, the title).
    let onChoose: (NoteTemplateFile, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var templates: [NoteTemplateFile] = []
    @State private var query = ""
    @State private var title = ""
    @State private var preview: NoteTemplateFile?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if templates.isEmpty {
                    emptyState
                } else {
                    List {
                        if mode == .newNote {
                            Section("Title") {
                                TextField("Note title", text: $title)
                                    .accessibilityLabel("Title for the new note")
                            }
                        }
                        Section("Templates") {
                            ForEach(filtered) { file in
                                Button {
                                    onChoose(file, title)
                                    dismiss()
                                } label: {
                                    Label(file.name, systemImage: "doc.text")
                                }
                                .contextMenu {
                                    Button("Preview") { preview = file }
                                }
                                .swipeActions(edge: .trailing) {
                                    Button("Preview") { preview = file }
                                        .tint(.blue)
                                }
                            }
                        }
                    }
                    .searchable(text: $query, prompt: "Filter templates")
                }
            }
            .navigationTitle(mode == .newNote ? "New from Template" : "Insert Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(item: $preview) { file in
                NavigationStack {
                    ScrollView {
                        Text(library?.load(id: file.id) ?? "")
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle(file.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { preview = nil }
                        }
                    }
                }
            }
            .alert("Templates", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .task { reload() }
    }

    private var filtered: [NoteTemplateFile] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return templates }
        return templates.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private func reload() {
        templates = library?.list() ?? []
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Note Templates", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("Add markdown files to the \u{201C}\(library?.folder ?? NoteTemplateSettings.defaultFolder)\u{201D} folder in your notes vault. Templates can use variables such as {{date}}, {{title}} and {{cursor}}.")
        } actions: {
            if let library {
                Button("Create Sample Template") {
                    do {
                        try NoteTemplateActions.createSample(in: library)
                        reload()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }
}
