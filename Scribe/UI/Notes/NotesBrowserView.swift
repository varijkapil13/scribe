// Scribe/UI/Notes/NotesBrowserView.swift
import SwiftUI

/// Two-pane notes browser: note list on the left, detail on the right.
/// Used for All Notes / Unfiled / Notebook scopes. For `.all` and `.inbox`
/// the list pane offers a segmented chip to toggle between the two so those
/// filters don't need to take up dedicated sidebar rows.
struct NotesBrowserView: View {
    let initialScope: NoteListScope

    @State private var selectedNoteId: String?
    @State private var selectedNote: Note?
    @State private var activeScope: NoteListScope

    init(scope: NoteListScope) {
        self.initialScope = scope
        _activeScope = State(initialValue: scope)
    }

    private var showsScopeChips: Bool {
        switch initialScope {
        case .all, .inbox: return true
        case .notebook:    return false
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if showsScopeChips {
                    NotesScopeChipBar(activeScope: $activeScope)
                }
                NoteListView(scope: activeScope, selectedNoteId: $selectedNoteId)
                    .id(NoteListScopeID(scope: activeScope))
            }
            .frame(minWidth: 200, idealWidth: 260, maxWidth: 320)

            Group {
                if let note = selectedNote {
                    NoteDetailView(note: note, onNavigate: { noteId in
                        selectedNoteId = noteId
                    })
                    .id(note.id)
                } else {
                    VStack(spacing: DesignTokens.Spacing.sm) {
                        Image(systemName: "note.text")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.quaternary)
                        Text("No Note Selected")
                            .font(DesignTokens.Typography.section)
                            .foregroundStyle(.secondary)
                        Text("Choose a note from the list.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: selectedNoteId) {
            guard let id = selectedNoteId else { selectedNote = nil; return }
            selectedNote = try? NoteStore.shared.fetchNote(id: id)
        }
    }
}

/// Segmented control offering "All / Unfiled". Renders only when the parent
/// originally opened on `.all` or `.inbox` — for notebook views the chip
/// would be confusing.
private struct NotesScopeChipBar: View {
    @Binding var activeScope: NoteListScope

    var body: some View {
        HStack(spacing: 2) {
            chip(title: "All",     isActive: isAll)     { activeScope = .all }
            chip(title: "Unfiled", isActive: isInbox)   { activeScope = .inbox }
            Spacer()
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 6)
        .background(DesignTokens.Palette.surfaceElevated)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var isAll: Bool {
        if case .all = activeScope { return true } else { return false }
    }
    private var isInbox: Bool {
        if case .inbox = activeScope { return true } else { return false }
    }

    @ViewBuilder
    private func chip(title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.xs, style: .continuous)
                        .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }
}

/// Stable hashable identifier for a `NoteListScope` so SwiftUI can `.id()`
/// the inner list and force the view model to rebuild when the chip toggles.
private struct NoteListScopeID: Hashable {
    let scope: NoteListScope

    func hash(into hasher: inout Hasher) {
        switch scope {
        case .all:                 hasher.combine("all")
        case .inbox:               hasher.combine("inbox")
        case .notebook(let id):    hasher.combine("notebook"); hasher.combine(id)
        }
    }

    static func == (lhs: NoteListScopeID, rhs: NoteListScopeID) -> Bool {
        switch (lhs.scope, rhs.scope) {
        case (.all, .all):                 return true
        case (.inbox, .inbox):             return true
        case (.notebook(let a), .notebook(let b)): return a == b
        default: return false
        }
    }
}
