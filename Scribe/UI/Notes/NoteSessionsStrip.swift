// Scribe/UI/Notes/NoteSessionsStrip.swift
import SwiftUI

/// Horizontal strip of session chips at the top of a Note detail view.
/// Tapping a chip selects it; the parent view renders the per-session
/// auto-section beneath the strip for the selected chip.
struct NoteSessionsStrip: View {
    let sessions: [Session]
    @Binding var selectedSessionId: String?
    var onStartRecording: (() -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                ForEach(sessions) { session in
                    SessionChip(
                        session: session,
                        isSelected: session.id == selectedSessionId
                    ) {
                        if selectedSessionId == session.id {
                            selectedSessionId = nil
                        } else {
                            selectedSessionId = session.id
                        }
                    }
                }

                if let onStartRecording {
                    Button(action: onStartRecording) {
                        HStack(spacing: DesignTokens.Spacing.xs) {
                            Image(systemName: "record.circle")
                                .imageScale(.small)
                            Text("New recording")
                                .font(.callout)
                        }
                        .padding(.horizontal, DesignTokens.Spacing.sm)
                        .padding(.vertical, DesignTokens.Spacing.xs)
                        .background(
                            DesignTokens.Palette.surfaceElevated,
                            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm,
                                                 style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                                .strokeBorder(DesignTokens.Palette.cardBorder, lineWidth: 1)
                        )
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, DesignTokens.Spacing.sm)
        }
        .background(DesignTokens.Palette.surfaceSunken)
    }
}

private struct SessionChip: View {
    let session: Session
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                statusIndicator
                VStack(alignment: .leading, spacing: 0) {
                    Text(displayTitle)
                        .font(.callout)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if isSelected {
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background(
                isSelected
                    ? DesignTokens.Palette.surfaceElevated
                    : DesignTokens.Palette.surfaceElevated.opacity(0.6),
                in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : DesignTokens.Palette.cardBorder,
                        lineWidth: 1
                    )
            )
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    private var displayTitle: String {
        session.title.isEmpty ? "Untitled Session" : session.title
    }

    private var subtitle: String {
        let date = session.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        if let secs = session.durationSeconds {
            let mins = max(secs / 60, 1)
            return "\(date) · \(mins)m"
        }
        return date
    }

    private var statusIndicator: some View {
        Group {
            if session.endedAt == nil {
                Circle()
                    .fill(DesignTokens.Palette.recording)
                    .frame(width: 8, height: 8)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .imageScale(.small)
                    .foregroundStyle(.green)
            }
        }
    }
}
