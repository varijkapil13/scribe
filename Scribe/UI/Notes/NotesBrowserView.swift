// Scribe/UI/Notes/NotesBrowserView.swift
import SwiftUI

/// Two-pane notes browser: note list on the left, detail on the right.
/// Used for All Notes / Unfiled / Notebook scopes. For `.all` and `.inbox`
/// the list header offers All / Unfiled tabs so those filters don't need
/// dedicated sidebar rows.
struct NotesBrowserView: View {
    let initialScope: NoteListScope

    /// Craft-style drill-down stack of note IDs. The list selects the root
    /// (`navPath.first`); clicking a wiki-link/backlink inside a note pushes a
    /// card; the breadcrumb + Back pop it. `navPath.last` is the displayed note.
    @State private var navPath: [String] = []
    @State private var currentNote: Note?
    @State private var titlesById: [String: String] = [:]
    @State private var activeScope: NoteListScope

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    /// List selection drives the ROOT of the nav stack (resets any drill-down).
    private var listSelection: Binding<String?> {
        Binding(
            get: { navPath.first },
            set: { newValue in
                navPath = newValue.map { [$0] } ?? []
            }
        )
    }

    var body: some View {
        HSplitView {
            NoteListView(scope: activeScope,
                         selectedNoteId: listSelection,
                         scopeChoice: showsScopeChips ? $activeScope : nil)
                .id(NoteListScopeID(scope: activeScope))
                .frame(minWidth: DesignTokens.Notes.listMinWidth,
                       idealWidth: DesignTokens.Notes.listWidth,
                       maxWidth: DesignTokens.Notes.listMaxWidth)

            detailColumn
        }
        .task(id: navPath.last) {
            guard let id = navPath.last else { currentNote = nil; return }
            let note = try? NoteStore.shared.fetchNote(id: id)
            currentNote = note
            if let note {
                titlesById[note.id] = note.title.isEmpty ? "Untitled" : note.title
            }
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        VStack(spacing: 0) {
            if navPath.count > 1 {
                breadcrumbBar
            }
            Group {
                if navPath.isEmpty {
                    emptyState
                } else if let note = currentNote {
                    NoteDetailView(note: note, onNavigate: { push($0) })
                        .id(note.id)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: currentNote?.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DesignTokens.Palette.ground)
    }

    // MARK: - Navigation

    private func push(_ noteId: String) {
        guard noteId != navPath.last else { return }
        navPath.append(noteId)
    }

    private func pop() {
        guard navPath.count > 1 else { return }
        navPath.removeLast()
    }

    private func popTo(index: Int) {
        guard index < navPath.count - 1 else { return }
        navPath = Array(navPath.prefix(index + 1))
    }

    private var breadcrumbBar: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Button(action: pop) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Back")
            .accessibilityLabel("Back")

            ForEach(Array(navPath.enumerated()), id: \.offset) { idx, id in
                if idx > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Button { popTo(index: idx) } label: {
                    Text(titlesById[id] ?? "Note")
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(idx == navPath.count - 1 ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(idx == navPath.count - 1)
                .accessibilityLabel("Go to \(titlesById[id] ?? "note")")
            }
            Spacer()
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, 6)
        .background(DesignTokens.Palette.ground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DesignTokens.Palette.hairline).frame(height: 1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "note.text")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DesignTokens.Palette.textTertiary.opacity(0.6))
            Text("No Note Selected")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.textSecondary)
            Text("Choose a note from the list.")
                .font(.system(size: 13))
                .foregroundStyle(DesignTokens.Palette.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
