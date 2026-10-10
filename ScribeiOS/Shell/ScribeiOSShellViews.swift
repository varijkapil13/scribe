import SwiftUI

// Small shell-owned views: the quick-add task sheet (⌘⇧N / New Task), the
// iPhone's floating Liquid Glass "New" button, and the standalone iPad note
// window.

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

// MARK: - Floating New button (iPhone)

/// A floating Liquid Glass button (bottom trailing, above the tab bar) that
/// offers New Note / New Task. Shown on compact width only — on iPad the
/// menu bar and ⌘N / ⌘⇧N cover it.
struct ScribeFloatingNewButton: View {
    let navigator: ScribeiOSNavigator

    var body: some View {
        Menu {
            Button {
                navigator.newNote()
            } label: {
                Label("New Note", systemImage: "square.and.pencil")
            }
            Button {
                navigator.presentNewTask()
            } label: {
                Label("New Task", systemImage: "checklist")
            }
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .imageScale(.large)
                .frame(width: 56, height: 56)
                .contentShape(Circle())
                .scribeFloatingGlass()
        }
        .hoverEffect(.lift)
        .accessibilityLabel("New")
        .accessibilityHint("Creates a note or a task")
        .padding(.trailing, 20)
        .padding(.bottom, 16)
    }
}

extension View {
    /// Liquid Glass for a floating circular control.
    /// CI-COMPILE NOTE: the only use of the iOS 26 `glassEffect` API in the
    /// shell; if its signature differs, fix it here (falling back to
    /// `.background(.regularMaterial, in: Circle())` is fine).
    func scribeFloatingGlass() -> some View {
        glassEffect(.regular.interactive(), in: Circle())
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
