// Scribe/UI/Notes/NoteBacklinksView.swift
import SwiftUI

struct NoteBacklinksView: View {
    let backlinks: [Note]
    let onNavigate: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Linked from")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)

            Divider()

            if backlinks.isEmpty {
                Text("No notes link here yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(backlinks) { note in
                            Button {
                                onNavigate(note.id)
                            } label: {
                                Text(note.title.isEmpty ? "(Untitled)" : note.title)
                                    .font(.callout)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .frame(width: 220)
        .background(Color(.windowBackgroundColor).opacity(0.5))
    }
}
