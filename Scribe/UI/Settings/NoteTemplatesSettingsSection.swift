// Scribe/UI/Settings/NoteTemplatesSettingsSection.swift
import SwiftUI

/// Settings › Templates › Note templates: the vault folder holding note
/// templates and the default templates for new daily notes and auto-created
/// meeting notes. (Embedded in `TemplatesSettingsPane`.)
struct NoteTemplatesSettingsSection: View {
    @AppStorage(NoteTemplateSettings.folderKey) private var folder: String = NoteTemplateSettings.defaultFolder
    @AppStorage(NoteTemplateSettings.dailyTemplateKey) private var dailyTemplate: String = ""
    @AppStorage(NoteTemplateSettings.meetingTemplateKey) private var meetingTemplate: String = ""

    @State private var templates: [NoteTemplateFile] = []

    var body: some View {
        Section {
            TextField("Templates folder", text: $folder, prompt: Text(NoteTemplateSettings.defaultFolder))
                .onSubmit(reload)
            picker("Daily note template", selection: $dailyTemplate)
            picker("Meeting note template", selection: $meetingTemplate)
            HStack {
                Text(templates.count == 1 ? "1 note template" : "\(templates.count) note templates")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reveal Folder") {
                    if let library = NoteTemplateLibrary.currentVault() {
                        NoteTemplateFolderActions.reveal(library)
                    }
                }
                Button("Create Sample Template") {
                    if let library = NoteTemplateLibrary.currentVault() {
                        NoteTemplateFolderActions.createSample(in: library)
                        reload()
                    }
                }
            }
        } header: {
            Text("Note templates")
        } footer: {
            Text("Markdown files in this vault folder (Summaries and Recipes excluded). Use File \u{203A} New Note from Template\u{2026} (\u{2325}\u{2318}N) or type /template in a note. Variables: {{date}}, {{date:yyyy-MM-dd}}, {{time}}, {{weekday}}, {{title}}, {{cursor}}, {{meeting.title}}, {{meeting.attendees}}, {{clipboard}}.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: reload)
        .onChange(of: folder) { _, _ in reload() }
    }

    private func picker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag("")
            ForEach(templates) { file in
                Text(file.name).tag(file.id)
            }
            let current = selection.wrappedValue
            if !current.isEmpty && !templates.contains(where: { $0.id == current }) {
                Text("\((current as NSString).lastPathComponent) (missing)").tag(current)
            }
        }
    }

    private func reload() {
        templates = NoteTemplateLibrary.currentVault()?.list() ?? []
    }
}
