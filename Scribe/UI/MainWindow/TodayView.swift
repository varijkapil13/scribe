// Scribe/UI/MainWindow/TodayView.swift
import SwiftUI

/// Unified "Today" destination: today's daily note on top, today's tasks
/// below, in a resizable vertical split. Replaces the separate "Today's
/// Note" and Tasks-"Today" sidebar entries — both used to be one click away
/// from the same date but on different surfaces, requiring two visits when
/// the user just wanted to plan the day.
struct TodayView: View {
    var onNavigate: (String) -> Void

    var body: some View {
        VSplitView {
            DailyNoteView(onNavigate: onNavigate)
                .frame(minHeight: 180, idealHeight: 380)

            VStack(spacing: 0) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "checklist")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text("TODAY'S TASKS")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.top, DesignTokens.Spacing.sm)
                .padding(.bottom, DesignTokens.Spacing.xs)

                TaskListView(filter: .today)
            }
            .frame(minHeight: 200, idealHeight: 280)
        }
    }
}
