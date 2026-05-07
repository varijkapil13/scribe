// Scribe/UI/Notes/NoteBacklinksView.swift
// Kept for backward compatibility — BacklinksBar is now embedded directly in
// NoteDetailView. This file exposes a standalone panel for future use (e.g.
// a floating inspector).
import SwiftUI

struct NoteBacklinksView: View {
    let backlinks: [Note]
    let onNavigate: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "link")
                    .imageScale(.small)
                Text("Linked from")
            }
            .font(DesignTokens.Typography.eyebrow)
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.top, DesignTokens.Spacing.md)
            .padding(.bottom, DesignTokens.Spacing.sm)

            Divider()

            if backlinks.isEmpty {
                VStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "link.badge.plus")
                        .font(.title3)
                        .foregroundStyle(.quaternary)
                    Text("No notes link here yet.")
                        .font(.caption)
                        .foregroundStyle(.quaternary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(DesignTokens.Spacing.xl)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(backlinks) { note in
                            Button {
                                onNavigate(note.id)
                            } label: {
                                HStack(spacing: DesignTokens.Spacing.xs) {
                                    Image(systemName: "note.text")
                                        .imageScale(.small)
                                        .foregroundStyle(.secondary)
                                    Text(note.title.isEmpty ? "(Untitled)" : note.title)
                                        .font(.callout)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.horizontal, DesignTokens.Spacing.md)
                                .padding(.vertical, DesignTokens.Spacing.sm)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, DesignTokens.Spacing.md)
                        }
                    }
                }
            }
        }
        .frame(width: 200)
        .background(DesignTokens.Palette.surfaceSunken)
    }
}
