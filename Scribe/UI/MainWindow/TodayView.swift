// Scribe/UI/MainWindow/TodayView.swift
import SwiftUI

/// Unified "Today" destination: the selected day's daily note, with a quiet
/// agenda column (next meeting, tasks due, overdue summary) on the right. The
/// full task list lives under the Tasks destinations.
///
/// The selected date lives in the shared ``DayPlanningModel`` so the Task
/// Calendar opens on the same day.
struct TodayView: View {
    var onNavigate: (String) -> Void

    @Environment(DayPlanningModel.self) private var dayPlanning

    var body: some View {
        HStack(spacing: 0) {
            DailyNoteView(selectedDate: selectedDateBinding, onNavigate: onNavigate)
                .environment(\.noteEditorOptionsInToolbar, false)
                .frame(minWidth: 380, maxWidth: .infinity)
                .layoutPriority(1)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(noteAccessibilityLabel)

            Rectangle()
                .fill(DesignTokens.Palette.hairline)
                .frame(width: 1)
                .accessibilityHidden(true)

            TodayAgendaView(selectedDate: dayPlanning.selectedDate)
                .frame(width: DesignTokens.Today.agendaWidth)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(agendaAccessibilityLabel)
        }
        .background(DesignTokens.Palette.ground)
    }

    /// Writes route through `select(_:)`, which normalises and de-dupes.
    private var selectedDateBinding: Binding<Date> {
        Binding(
            get: { dayPlanning.selectedDate },
            set: { dayPlanning.select($0) }
        )
    }

    private var selectedDate: Date { dayPlanning.selectedDate }

    private var noteAccessibilityLabel: String {
        Calendar.current.isDateInToday(selectedDate)
            ? "Today's daily note"
            : "Daily note for \(Self.longFormatter.string(from: selectedDate))"
    }

    private var agendaAccessibilityLabel: String {
        Calendar.current.isDateInToday(selectedDate)
            ? "Today's agenda"
            : "Agenda for \(Self.longFormatter.string(from: selectedDate))"
    }

    private static let longFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        return f
    }()
}
