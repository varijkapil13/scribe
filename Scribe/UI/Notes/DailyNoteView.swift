// Scribe/UI/Notes/DailyNoteView.swift
import SwiftUI

struct DailyNoteView: View {
    @State private var selectedNote: Note? = nil
    var onNavigate: (String) -> Void

    var body: some View {
        HSplitView {
            // ── Calendar sidebar ─────────────────────────────────────────
            VStack(spacing: 0) {
                NoteCalendarView { date in
                    withAnimation(.easeInOut(duration: DesignTokens.Motion.fast)) {
                        selectedNote = try? NoteStore.shared.dailyNote(for: date)
                    }
                }
            }
            .frame(minWidth: 240, idealWidth: 260, maxWidth: 300)
            .background(DesignTokens.Palette.surfaceSunken)

            // ── Note pane ────────────────────────────────────────────────
            if let note = selectedNote {
                NoteDetailView(note: note, onNavigate: onNavigate)
                    .id(note.id)
            } else {
                VStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "calendar")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.quaternary)
                    Text("Pick a date")
                        .font(DesignTokens.Typography.section)
                        .foregroundStyle(.secondary)
                    Text("Select a day to view or create that day's note.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            selectedNote = try? NoteStore.shared.dailyNote(for: Date())
        }
    }
}
