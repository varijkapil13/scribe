// Scribe/UI/Notes/NoteSessionAutoSection.swift
import SwiftUI

/// Read-only block showing the AI summary, action items, and entities for
/// one bound session. The TranscriptDetailViewModel is owned and cached by
/// NoteDetailViewModel — passing in a cached instance instead of creating one
/// per chip click prevents NaturalLanguage analysis from re-running every
/// time the user switches sessions.
struct NoteSessionAutoSection: View {
    @ObservedObject var viewModel: TranscriptDetailViewModel
    let onOpenSession: (Session) -> Void
    let onConvertActionItem: (ActionItem, TodoTask) -> Void

    @State private var hasLoaded: Bool = false

    // (no custom init — synthesized memberwise init suffices)

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            header
            summaryBlock
            actionItemsBlock
            entitiesBlock
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Palette.surfaceSunken,
                    in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.cardBorder, lineWidth: 1)
        )
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            viewModel.loadSegments()
            viewModel.loadSummary()
            viewModel.loadAnalysis()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("From this recording")
                .font(DesignTokens.Typography.eyebrow)
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Open transcript") { onOpenSession(viewModel.session) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private var summaryBlock: some View {
        sectionLabel("Summary")
        if let summary = viewModel.meetingSummary {
            Text(summary.summary)
                .font(.callout)
                .foregroundStyle(.primary)
        } else if viewModel.isGeneratingSummary {
            ProgressView().controlSize(.small)
        } else if let summaryError = viewModel.summaryError {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .imageScale(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Couldn't generate summary")
                        .font(.callout)
                        .foregroundStyle(.primary)
                    Text(summaryError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Retry") {
                    Task { await viewModel.generateSummary() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else {
            Button("Generate summary") {
                Task { await viewModel.generateSummary() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Action items

    @ViewBuilder
    private var actionItemsBlock: some View {
        if let items = viewModel.meetingSummary?.actionItems, !items.isEmpty {
            sectionLabel("Action items")
            ForEach(items) { item in
                actionItemRow(item)
            }
        }
    }

    private func actionItemRow(_ item: ActionItem) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
            Image(systemName: viewModel.completedActionItems.contains(item.id)
                  ? "checkmark.circle.fill" : "circle")
                .imageScale(.small)
                .foregroundStyle(viewModel.completedActionItems.contains(item.id) ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.description)
                    .font(.callout)
                    .strikethrough(viewModel.completedActionItems.contains(item.id))
                if let assignee = item.assignee, !assignee.isEmpty {
                    Text(assignee)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if viewModel.convertedActionItems.contains(item.id) {
                Text("Linked")
                    .font(.caption2)
                    .foregroundStyle(.green)
            } else {
                Button("Convert to task") {
                    // Land the task in the bound note's project (its notebook)
                    // rather than always Inbox, carrying the source session id.
                    if let created = viewModel.convertActionItemToTask(
                        item,
                        projectId: viewModel.boundProjectId
                    ) {
                        onConvertActionItem(item, created)
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    // MARK: - Entities

    @ViewBuilder
    private var entitiesBlock: some View {
        if let entities = viewModel.transcriptAnalysis?.entities, !entities.isEmpty {
            sectionLabel("Mentioned")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    ForEach(entities) { entity in
                        Label(entity.text, systemImage: entity.type.systemImage)
                            .font(.caption)
                            .padding(.horizontal, DesignTokens.Spacing.sm)
                            .padding(.vertical, 2)
                            .background(
                                DesignTokens.Palette.surfaceElevated,
                                in: Capsule()
                            )
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.Typography.eyebrow)
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }
}
