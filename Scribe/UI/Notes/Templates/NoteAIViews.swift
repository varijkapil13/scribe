import SwiftUI
import AppKit

// MARK: - Folder actions

@MainActor
enum TemplatesFolderActions {
    /// Seeds (if needed) and opens `Templates/` in Finder.
    static func reveal() {
        guard let store = SummaryTemplateStore.current() else { return }
        try? store.seedIfNeeded()
        NSWorkspace.shared.activateFileViewerSelecting([store.summariesFolder, store.recipesFolder])
    }

    /// Rewrites the built-in templates + recipes. Returns an error message on failure.
    static func restoreBuiltIns() -> String? {
        guard let store = SummaryTemplateStore.current() else {
            return "The notes vault isn't available."
        }
        do {
            try store.restoreBuiltIns()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - Session menu (Re-summarize with… / Run recipe)

/// "Re-summarize with…" menu for one recording: regenerates a template summary
/// into the note's `<!-- scribe:summary:<id> -->` block, or runs a recipe.
/// Used in the note's recording section and the transcript action bar.
struct SessionTemplateActionsMenu: View {
    let session: Session
    @StateObject private var controller = NoteAIController()

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Menu {
                let suggestedId = controller.suggestedTemplate(for: session)?.id
                Section("Re-summarize with") {
                    ForEach(controller.templates) { template in
                        Button {
                            Task { await controller.resummarize(session: session, template: template) }
                        } label: {
                            Text(template.id == suggestedId ? "\(template.name) (suggested)" : template.name)
                        }
                    }
                }
                if !controller.recipes.isEmpty {
                    Section("Run recipe") {
                        ForEach(controller.recipes) { recipe in
                            Button(recipe.name) {
                                Task {
                                    await controller.run(
                                        recipe: recipe,
                                        title: session.title,
                                        sessions: [session],
                                        noteBody: controller.noteBody(for: session),
                                        noteId: session.noteId
                                    )
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Reveal Templates Folder") { TemplatesFolderActions.reveal() }
            } label: {
                Label("Re-summarize with…", systemImage: "wand.and.stars")
            }
            .fixedSize()
            .disabled(controller.isBusy)
            .help("Regenerate this recording's summary with a template, or run a recipe")

            statusView
        }
        .onAppear { controller.reloadLists() }
        .sheet(item: $controller.recipeResult) { result in
            NoteAIResultSheet(
                title: result.recipe.name,
                markdown: result.markdown,
                onInsert: result.noteId == nil ? nil : { controller.insertIntoNote(result) }
            )
        }
        .sheet(item: $controller.standaloneSummary) { result in
            NoteAIResultSheet(title: "\(result.recipe.name) summary", markdown: result.markdown, onInsert: nil)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if let busy = controller.busyLabel {
            ProgressView().controlSize(.small)
            Text(busy).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else if let error = controller.errorMessage {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.small)
            Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        } else if let success = controller.lastSuccess {
            Text(success).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

// MARK: - Note-level AI (Enhance notes + recipes)

/// Adds the note toolbar "Notes AI" menu (Enhance notes, Run recipe), its
/// preview sheets, and replays Scribe-generated edits written to this note
/// elsewhere onto the in-memory body. Applied to `NoteDetailView`.
struct NoteAIFeaturesModifier: ViewModifier {
    @ObservedObject var vm: NoteDetailViewModel
    @StateObject private var controller = NoteAIController()

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) { menu }
            }
            .onAppear { controller.reloadLists() }
            .onReceive(NotificationCenter.default.publisher(for: .scribeNoteAIEditApplied)) { notification in
                guard let noteId = notification.object as? String,
                      noteId == vm.note.id,
                      let edit = notification.userInfo?[NoteAIEdit.userInfoKey] as? NoteAIEdit
                else { return }
                // Disk already holds the edit; replay it in memory so the
                // editor shows it and unsaved typing survives the next autosave.
                let updated = edit.apply(to: vm.note.body)
                if updated != vm.note.body { vm.note.body = updated }
            }
            .onChange(of: controller.errorMessage) { _, newValue in
                if let message = newValue {
                    AppState.shared.report(message)
                    controller.errorMessage = nil
                }
            }
            .sheet(item: $controller.enhanceResult) { result in
                EnhancePreviewSheet(
                    result: result,
                    notesChangedSinceStart: NoteScribeBlocks.userContent(body: vm.note.body) != result.originalUserNotes,
                    onAccept: {
                        vm.note.body = NoteScribeBlocks.replaceUserContent(body: vm.note.body, with: result.enhanced)
                        vm.markDirty()
                        AppState.shared.notify("Notes enhanced")
                    }
                )
            }
            .sheet(item: $controller.recipeResult) { result in
                NoteAIResultSheet(
                    title: result.recipe.name,
                    markdown: result.markdown,
                    onInsert: {
                        vm.note.body = NoteScribeBlocks.appendSection(
                            body: vm.note.body,
                            heading: result.recipe.name,
                            content: result.markdown
                        )
                        vm.markDirty()
                    }
                )
            }
    }

    private var menu: some View {
        Menu {
            Button("Enhance Notes") {
                Task {
                    await controller.enhance(noteBody: vm.note.body, title: vm.note.title, sessions: vm.sessions)
                }
            }
            .disabled(vm.sessions.isEmpty || controller.isBusy)
            Menu("Run Recipe") {
                ForEach(controller.recipes) { recipe in
                    Button(recipe.name) {
                        Task {
                            await controller.run(
                                recipe: recipe,
                                title: vm.note.title,
                                sessions: vm.sessions,
                                noteBody: vm.note.body,
                                noteId: vm.note.id
                            )
                        }
                    }
                }
            }
            .disabled(controller.isBusy || controller.recipes.isEmpty)
            Divider()
            Button("Reveal Templates Folder") { TemplatesFolderActions.reveal() }
        } label: {
            Label(controller.busyLabel ?? "Notes AI",
                  systemImage: controller.isBusy ? "hourglass" : "sparkles")
        }
        // Locked notes stay out of AI features (their stored body is
        // ciphertext, so AI edits written to the note would be dropped).
        .disabled(vm.isLockedNote)
        .help(controller.busyLabel ?? "Enhance your notes with the recording, or run a recipe")
    }
}

// MARK: - Sheets

/// Read-only result with Copy / Cancel / (optional) Insert into note.
struct NoteAIResultSheet: View {
    let title: String
    let markdown: String
    let onInsert: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text(title).font(.headline)
            ScrollView {
                Text(verbatim: markdown)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 260)
            HStack {
                Button("Copy") { TemplatesFolderActions.copyToPasteboard(markdown) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if let onInsert {
                    Button("Insert into Note") {
                        onInsert()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(minWidth: 540, minHeight: 420)
    }
}

/// Preview of "Enhance notes" — never writes until the user accepts.
/// AI-added lines (prefixed `›`) are tinted so they're easy to review.
struct EnhancePreviewSheet: View {
    let result: NoteAIController.EnhanceResult
    let notesChangedSinceStart: Bool
    let onAccept: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var lines: [String] {
        result.enhanced.components(separatedBy: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text("Enhanced notes").font(.headline)
            Text("Your lines are kept as written; lines starting with › were added from the recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if notesChangedSinceStart {
                Label("You edited the note while this was generating. Accepting replaces those edits.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line.isEmpty ? " " : line)
                            .font(.callout)
                            .foregroundStyle(NoteAIPromptBuilder.isAIAddedLine(line) ? Color.accentColor : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .textSelection(.enabled)
            }
            .frame(minHeight: 300)
            HStack {
                Button("Copy") { TemplatesFolderActions.copyToPasteboard(result.enhanced) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Accept") {
                    onAccept()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(minWidth: 580, minHeight: 480)
    }
}
