// Scribe/UI/Notes/NoteDetailView.swift
import SwiftUI

struct NoteDetailView: View {
    @StateObject private var vm: NoteDetailViewModel
    var onNavigate: (String) -> Void

    init(note: Note, onNavigate: @escaping (String) -> Void) {
        _vm = StateObject(wrappedValue: NoteDetailViewModel(note: note))
        self.onNavigate = onNavigate
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField("Title", text: Binding(
                    get: { vm.note.title },
                    set: { vm.note.title = $0; vm.markDirty() }
                ))
                .font(.title2.bold())
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Divider()

                NoteEditorView(
                    text: Binding(
                        get: { vm.note.body },
                        set: { vm.note.body = $0; vm.markDirty() }
                    ),
                    noteStore: .shared,
                    onNavigate: { anchor in vm.handleWikiLinkNavigate(anchor: anchor) }
                )
                .padding(8)
            }

            Divider()

            NoteBacklinksView(backlinks: vm.backlinks, onNavigate: onNavigate)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save") { vm.save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!vm.isDirty)
            }
        }
        .onAppear { vm.onNavigate = onNavigate }
        .alert("Error", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }
}
