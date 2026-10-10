import SwiftUI

/// Collapsible "Copilot" panel in the live recording view: the rolling
/// summary with live action items and open questions, an "Ask now" box, and
/// bookmarked moments ("Mark moment", ⌃⌥M).
struct LiveCopilotPanel: View {

    @ObservedObject var controller: LiveCopilotController

    @AppStorage(CopilotSettings.panelExpandedKey) private var isExpanded: Bool = true
    @AppStorage(CopilotSettings.liveSummaryEnabledKey) private var liveSummaryEnabled: Bool = true
    @AppStorage(CopilotSettings.liveSummaryIntervalKey) private var intervalMinutes: Int = CopilotSettings.defaultIntervalMinutes

    @State private var question: String = ""
    @State private var renaming: SessionBookmark?
    @State private var renameText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            header
            if isExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                        if let notice = controller.notice {
                            Label(notice, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        summaryBlock
                        listBlock(title: "Action items", systemImage: "checklist", items: controller.state.actionItems)
                        listBlock(title: "Open questions", systemImage: "questionmark.circle", items: controller.state.openQuestions)
                        if !controller.bookmarks.isEmpty {
                            highlightsBlock
                        }
                        askBlock
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 280)
                .transition(.opacity)
            }
        }
        .padding(DesignTokens.Spacing.md)
        .background(DesignTokens.Palette.surfaceElevated,
                    in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.cardBorder, lineWidth: 1)
        )
        .alert("Label this moment", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Label", text: $renameText)
            Button("Save") {
                if let bookmark = renaming {
                    controller.renameBookmark(bookmark, to: renameText)
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting copilot")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button {
                withAnimation(.easeInOut(duration: DesignTokens.Motion.fast)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Copilot")
                        .eyebrowStyle()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse copilot" : "Expand copilot")

            statusText

            Spacer(minLength: DesignTokens.Spacing.sm)

            Button {
                controller.markMoment(label: nil)
            } label: {
                Label(controller.bookmarks.isEmpty ? "Mark moment" : "Mark moment (\(controller.bookmarks.count))",
                      systemImage: "bookmark")
            }
            .controlSize(.small)
            .help("Bookmark this moment (⌃⌥M)")
            .accessibilityHint("Control Option M")

            Button {
                controller.refreshNow()
            } label: {
                Label("Update now", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .controlSize(.small)
            .disabled(controller.isUpdating)
            .help("Update the live summary now")
        }
    }

    @ViewBuilder
    private var statusText: some View {
        if controller.isUpdating {
            HStack(spacing: DesignTokens.Spacing.xs) {
                ProgressView().controlSize(.mini)
                Text("Updating…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let updated = controller.lastUpdated {
            Text("Updated \(updated, style: .relative) ago")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if !liveSummaryEnabled {
            Text("Live summary off")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Blocks

    @ViewBuilder
    private var summaryBlock: some View {
        let summary = controller.state.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            Text(summary)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if controller.state.isEmpty {
            Text(liveSummaryEnabled
                 ? "A running summary appears here every \(intervalMinutes) min of conversation. Use ↻ to update it now."
                 : "Live summary is off (Settings → Meeting Copilot). Use ↻ to update it once.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func listBlock(title: String, systemImage: String, items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Label(title, systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                        Text("•").foregroundStyle(.tertiary)
                        Text(item)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var highlightsBlock: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Label("Highlights", systemImage: "bookmark.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    ForEach(controller.bookmarks, id: \.self) { bookmark in
                        bookmarkChip(bookmark)
                    }
                }
            }
        }
    }

    private func bookmarkChip(_ bookmark: SessionBookmark) -> some View {
        let stamp = SessionBookmarkFormatter.shortTimestamp(ms: bookmark.offsetMs)
        let text = bookmark.trimmedLabel.map { "\(stamp) \($0)" } ?? stamp
        return Text(text)
            .font(.caption.monospacedDigit())
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            .contextMenu {
                Button("Label…") {
                    renameText = bookmark.label ?? ""
                    renaming = bookmark
                }
                Button("Delete", role: .destructive) {
                    controller.deleteBookmark(bookmark)
                }
            }
            .help("Right-click to label or delete")
            .accessibilityLabel("Bookmark at \(stamp)\(bookmark.trimmedLabel.map { ", \($0)" } ?? "")")
    }

    private var askBlock: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                TextField("Ask about this meeting — e.g. what did Priya say about the deadline?", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button("Ask", action: submit)
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.isAnswering)
            }
            if controller.isAnswering {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    ProgressView().controlSize(.mini)
                    Text("Thinking…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let answer = controller.answer {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    HStack {
                        Text(answer.question)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            controller.clearAnswer()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Dismiss answer")
                    }
                    Text(answer.answer)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let notice = answer.notice {
                        Text(notice)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(DesignTokens.Spacing.sm)
                .background(DesignTokens.Palette.surfaceSunken,
                            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
            }
        }
    }

    private func submit() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        controller.ask(trimmed)
    }
}
