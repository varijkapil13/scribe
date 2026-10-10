// ScribeiOS/Notes/NotesRootView.swift
//
// The Notes area on iPhone and iPad (wired into the app shell's tab /
// sidebar as its Notes destination).
//
// - iPad (regular width): a three-column NavigationSplitView —
//   destinations (Inbox, All Notes, Daily Notes, notebooks, tags) → the note
//   list (search + sort) → the editor, with the inspector as a trailing column.
// - iPhone (compact width): a NavigationStack — destinations → list → note,
//   landing on All Notes; the inspector is a sheet.
//
// iCloud vault observation + reconcile (IOSVaultSyncController) is driven by
// the shell's ScribeiOSBootstrap (launch + every activation); this view
// re-locks locked notes when the app leaves the foreground.

import SwiftUI

/// A screen on the iPhone navigation stack.
enum NotesCompactRoute: Hashable {
    case list(NotesSidebarItem)
    case note(String)
}

@MainActor
@Observable
final class NotesNavigationModel {
    var sidebarSelection: NotesSidebarItem? = .all
    var selectedNoteId: String?
    var compactPath: [NotesCompactRoute] = [.list(.all)]
    var columnVisibility: NavigationSplitViewVisibility = .all

    init() {}

    /// Opens `noteId` in whichever layout is showing.
    func open(_ noteId: String, compact: Bool) {
        if compact {
            if case .note(let current)? = compactPath.last, current == noteId { return }
            compactPath.append(.note(noteId))
        } else {
            selectedNoteId = noteId
        }
    }
}

struct NotesRootView: View {
    @State private var library = NotesLibraryModel(store: NoteStore.shared)
    @State private var navigation = NotesNavigationModel()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactLayout
            } else {
                regularLayout
            }
        }
        // Shell contract: scribe:// links, Handoff, Spotlight, search
        // results, ⌘N and scene restoration open notes here.
        .onScribeOpenRequest(.note) { id in
            navigation.open(id, compact: horizontalSizeClass == .compact)
        }
        .task {
            library.start()
            // Vault selection / observation is started at launch by
            // ScribeiOSBootstrap (and refreshed on every activation); this
            // only covers a scene shown before that ran. Idempotent.
            IOSVaultSyncController.shared.startIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                IOSLockedNoteSession.shared.lock()
            }
        }
        .alert("Notes", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.errorMessage ?? "")
        }
    }

    // MARK: - iPhone

    private var compactLayout: some View {
        NavigationStack(path: $navigation.compactPath) {
            NotesSidebarView(library: library, selection: nil) { item in
                navigation.compactPath.append(.list(item))
            }
            .navigationDestination(for: NotesCompactRoute.self) { route in
                switch route {
                case .list(let item):
                    NotesListColumn(library: library, navigation: navigation, item: item, compact: true)
                case .note(let id):
                    NoteEditorScreen(
                        noteId: id,
                        onOpenNote: { navigation.open($0, compact: true) },
                        onDeleted: {
                            if case .note(id)? = navigation.compactPath.last { navigation.compactPath.removeLast() }
                        }
                    )
                    .id(id)
                }
            }
        }
    }

    // MARK: - iPad

    private var regularLayout: some View {
        NavigationSplitView(columnVisibility: $navigation.columnVisibility) {
            NotesSidebarView(library: library, selection: $navigation.sidebarSelection, onSelect: nil)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            NotesListColumn(
                library: library,
                navigation: navigation,
                item: navigation.sidebarSelection ?? .all,
                compact: false
            )
            .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 460)
        } detail: {
            NavigationStack {
                if let id = navigation.selectedNoteId {
                    NoteEditorScreen(
                        noteId: id,
                        onOpenNote: { navigation.open($0, compact: false) },
                        onDeleted: { navigation.selectedNoteId = nil }
                    )
                    .id(id)
                } else {
                    ContentUnavailableView(
                        "No Note Selected",
                        systemImage: "doc.text",
                        description: Text("Choose a note, or create one with the compose button.")
                    )
                }
            }
        }
    }
}
