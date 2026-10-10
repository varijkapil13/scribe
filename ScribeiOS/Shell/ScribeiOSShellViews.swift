import SwiftUI

// Small shell-owned views: the quick-add task sheet (⌘⇧N / New Task) and
// the standalone iPad note window.

// MARK: - New Task sheet

/// Quick-add sheet: one field with the Tasks quick-add grammar
/// (`#tag +project !priority` + natural dates).
struct ScribeQuickTaskSheet: View {
    let onCreated: (TodoTask) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var errorMessage: String?
    /// Return in the field fires both `onSubmit` and the Add button's
    /// `.defaultAction` shortcut on a hardware keyboard; create only once.
    @State private var didCreate = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Add a task…", text: $text)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(create)
                        .accessibilityLabel("Task")
                } footer: {
                    Text("Try “draft deck tomorrow 5pm #work !high”.")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: create)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func create() {
        guard !didCreate else { return }
        do {
            guard let task = try ScribeMobileTaskCreation.createTask(fromQuickAdd: text, store: .shared) else { return }
            didCreate = true
            dismiss()
            onCreated(task)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Note window (iPad)

/// Root of a standalone note window (`WindowGroup(id:for: String.self)`),
/// opened from a row's "Open in New Window" or by dragging a note row to the
/// edge of the screen (the drag carries an `openNoteWindow` activity).
struct ScribeNoteWindowRoot: View {
    @Binding var noteId: String?

    var body: some View {
        NavigationStack {
            if let noteId {
                NoteEditorScreen(noteId: noteId)
                    .id(noteId)
            } else {
                ContentUnavailableView(
                    "No Note",
                    systemImage: "doc.text",
                    description: Text("Drag a note here, or choose Open in New Window on a note.")
                )
            }
        }
        // Stage Manager / Split View: keep the editor usable when shrunk.
        .frame(minWidth: 320, minHeight: 360)
        .onContinueUserActivity(ScribeMobileWindows.openNoteWindowActivityType) { activity in
            if case .note(let id)? = ScribeMobileRoute.fromActivity(
                type: activity.activityType,
                userInfo: activity.userInfo
            ) {
                noteId = id
            }
        }
    }
}
