// Scribe/UI/Notes/DailyNoteView.swift
import SwiftUI

struct DailyNoteView: View {
    enum DailyState {
        case existing(Note)
        case draft(Date)    // date selected, note not yet persisted
    }

    @State private var state: DailyState
    var onNavigate: (String) -> Void

    init(onNavigate: @escaping (String) -> Void) {
        self.onNavigate = onNavigate
        _state = State(initialValue: Self.initialState(for: Date()))
    }

    var body: some View {
        HSplitView {
            // ── Calendar sidebar ─────────────────────────────────────────
            VStack(spacing: 0) {
                NoteCalendarView { date in
                    selectDate(date)
                }
            }
            .frame(minWidth: 240, idealWidth: 260, maxWidth: 300)
            .background(DesignTokens.Palette.surfaceSunken)

            // ── Content pane ─────────────────────────────────────────────
            Group {
                switch state {
                case .existing(let note):
                    NoteDetailView(note: note, onNavigate: onNavigate)
                        .id(note.id)

                case .draft(let date):
                    DraftDailyNoteView(date: date, onCreated: { note in
                        withAnimation(.easeInOut(duration: DesignTokens.Motion.fast)) {
                            state = .existing(note)
                        }
                    }, onNavigate: onNavigate)
                    .id(date)
                }
            }
        }
    }

    /// Synchronous lookup used for both the initial state (in `init`) and
    /// user-initiated date selections. Keeps the first render glitch-free —
    /// no placeholder flash, no onAppear-triggered cross-fade animation.
    private static func initialState(for date: Date) -> DailyState {
        if let note = try? NoteStore.shared.fetchExistingDailyNote(for: date) {
            return .existing(note)
        }
        return .draft(date)
    }

    private func selectDate(_ date: Date) {
        withAnimation(.easeInOut(duration: DesignTokens.Motion.fast)) {
            state = Self.initialState(for: date)
        }
    }
}

// MARK: - Today pane

/// Sidebar "Today's Note" destination. When today's daily note exists, shows
/// it directly (no calendar). When none exists yet, falls back to the full
/// `DailyNoteView` so the user can draft one.
///
/// The lookup runs synchronously in `init` — previously this fetch happened
/// in `.task`, which made `DailyNoteView` (with calendar sidebar) render for
/// one frame before swapping to `NoteDetailView`, producing a visible layout
/// shift glitch.
struct TodayNotePane: View {
    @State private var todayNote: Note?
    let onNavigate: (String) -> Void

    init(onNavigate: @escaping (String) -> Void) {
        self.onNavigate = onNavigate
        _todayNote = State(initialValue: try? NoteStore.shared.fetchExistingDailyNote(for: Date()))
    }

    var body: some View {
        if let note = todayNote {
            NoteDetailView(note: note, onNavigate: onNavigate)
                .id(note.id)
        } else {
            DailyNoteView(onNavigate: onNavigate)
        }
    }
}

// MARK: - Draft daily note editor

/// Shown when a date has no note yet. Displays the auto-generated title and
/// an empty body editor. On first non-empty keystroke the note is persisted
/// and the parent transitions to the full NoteDetailView.
private struct DraftDailyNoteView: View {
    let date: Date
    let onCreated: (Note) -> Void
    let onNavigate: (String) -> Void

    @State private var bodyText: String = ""
    @State private var hasCreated: Bool = false

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    private var noteTitle: String {
        "Daily Note \u{2013} \(Self.titleFormatter.string(from: date))"
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header (matches NoteDetailView layout) ────────────────────
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(noteTitle)
                    .font(DesignTokens.Typography.title2)
                    .foregroundStyle(.primary)

                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "pencil")
                        .imageScale(.small)
                    Text("Start writing to save this note")
                }
                .font(DesignTokens.Typography.eyebrow)
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            }
            .padding(.horizontal, DesignTokens.Spacing.xxxl)
            .padding(.top, DesignTokens.Spacing.xl)
            .padding(.bottom, DesignTokens.Spacing.lg)

            Divider()

            // ── Body editor ───────────────────────────────────────────────
            NoteEditorView(
                text: $bodyText,
                noteStore: .shared,
                onNavigate: onNavigate
            )
            .padding(.vertical, DesignTokens.Spacing.lg)
        }
        .onChange(of: bodyText) { _, newValue in
            guard !hasCreated else { return }
            // First non-whitespace character triggers note creation.
            guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            do {
                // dailyNote(for:) is atomic INSERT OR IGNORE — safe even if
                // race occurs (uniqueness constraint prevents duplicates).
                var note = try NoteStore.shared.dailyNote(for: date)
                note.body = newValue
                try NoteStore.shared.updateNote(note, tags: [])
                hasCreated = true
                onCreated(note)
            } catch {
                Log.app.error("DraftDailyNoteView: failed to persist note: \(error)")
            }
        }
    }
}
