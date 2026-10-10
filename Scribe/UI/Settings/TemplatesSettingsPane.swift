import SwiftUI

/// Settings → Templates: default summary template, auto-pick, automatic
/// template summaries, and template folder management.
///
/// Templates and recipes are markdown files in `<vault>/Templates/`; edit
/// them in any editor (or in Finder via "Reveal Templates Folder").
struct TemplatesSettingsPane: View {
    @AppStorage(TemplateSettings.defaultTemplateKey) private var defaultTemplateId: String = BuiltInTemplates.defaultTemplateId
    @AppStorage(TemplateSettings.autoPickKey) private var autoPick: Bool = true
    @AppStorage(TemplateSettings.useForAutoSummaryKey) private var useForAutoSummary: Bool = false
    @AppStorage("autoSummarize") private var autoSummarize: Bool = false

    @State private var templates: [SummaryTemplate] = []
    @State private var recipeCount: Int = 0
    @State private var confirmRestore: Bool = false

    var body: some View {
        Form {
            Section {
                Picker("Default template", selection: $defaultTemplateId) {
                    ForEach(templates) { template in
                        Text(template.name).tag(template.id)
                    }
                    if !templates.contains(where: { $0.id == defaultTemplateId }) {
                        Text("\(defaultTemplateId) (missing)").tag(defaultTemplateId)
                    }
                }
                if let selected = templates.first(where: { $0.id == defaultTemplateId }),
                   !selected.description.isEmpty {
                    Text(selected.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Auto-pick template from meeting title", isOn: $autoPick)
                    Text("Matches each template's keywords (e.g. \"1:1\", \"standup\", \"interview\") against the recording and note titles; falls back to the default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Use template for automatic summaries", isOn: $useForAutoSummary)
                    Text(autoSummarize
                         ? "After a recording stops, also write a template summary into the recording's note."
                         : "Requires \"Auto-summarize after recording\" in Intelligence settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Summary templates")
            } footer: {
                Text("Template summaries are stored inside the note between <!-- scribe:summary --> markers, so anything you type around them is never overwritten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("\(templates.count) templates · \(recipeCount) recipes")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reveal Templates Folder") {
                        TemplatesFolderActions.reveal()
                    }
                    Button("Restore Built-in Templates…") {
                        confirmRestore = true
                    }
                }
            } header: {
                Text("Files")
            } footer: {
                Text("Templates live in Templates/Summaries and recipes in Templates/Recipes inside your notes vault. Each file has name/description (and optional match keywords) frontmatter followed by the instructions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            NoteTemplatesSettingsSection()
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .confirmationDialog(
            "Restore built-in templates?",
            isPresented: $confirmRestore
        ) {
            Button("Restore") {
                if let message = TemplatesFolderActions.restoreBuiltIns() {
                    AppState.shared.report(message)
                } else {
                    AppState.shared.notify("Built-in templates restored")
                }
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Edited copies of the built-in templates and recipes are replaced. Templates you created are kept.")
        }
    }

    private func reload() {
        guard let store = SummaryTemplateStore.current() else {
            templates = SummaryTemplateStore.sorted(BuiltInTemplates.summaries)
            recipeCount = BuiltInTemplates.recipes.count
            return
        }
        templates = store.listTemplates()
        recipeCount = store.listRecipes().count
    }
}
