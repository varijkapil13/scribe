import AppKit
import SwiftUI

/// Drafts the follow-up email for a finished meeting: a deterministic
/// template right away (summary + action items + highlights), replaced by an
/// Apple Intelligence draft when the model is available.
@MainActor
final class FollowUpEmailModel: ObservableObject {

    @Published var subject: String = ""
    @Published var body: String = ""
    /// Editable "To:" field (comma-separated).
    @Published var recipientsText: String = ""
    @Published private(set) var isGenerating = false
    @Published private(set) var usedModel = false
    @Published private(set) var notice: String?

    private var generated = false

    /// Fills the draft (template first, then the model). Runs once per sheet.
    func prepare(
        session: Session,
        summary: MeetingSummary?,
        highlights: [String],
        transcriptStore: TranscriptStore
    ) async {
        guard !generated else { return }
        generated = true

        let actionItems = summary?.actionItems
            ?? (try? transcriptStore.fetchActionItems(sessionId: session.id))
            ?? []
        let title = session.calendarEventTitle?.isEmpty == false
            ? (session.calendarEventTitle ?? session.title)
            : session.title
        let draft = FollowUpEmailComposer.template(
            title: title,
            dateLabel: session.createdAt.formatted(date: .abbreviated, time: .omitted),
            summary: summary,
            fallbackSummary: nil,
            actionItems: actionItems,
            highlights: highlights,
            attendees: session.attendees
        )
        subject = draft.subject
        body = draft.body
        recipientsText = draft.recipients.joined(separator: ", ")

        guard let summary else {
            notice = "Generate a summary first for an Apple Intelligence draft. This is a template."
            return
        }
        let availability = AppleIntelligenceAvailability.current
        guard availability.isAvailable else {
            if case .unavailable(let reason) = availability {
                notice = "\(reason) This is a template draft."
            }
            return
        }

        isGenerating = true
        defer { isGenerating = false }
        do {
            let text = try await MeetingSummarizer.generateFollowUpEmail(summary: summary)
            let parsed = FollowUpEmailComposer.parseModelEmail(text, fallbackSubject: draft.subject)
            guard !parsed.body.isEmpty else { return }
            subject = parsed.subject
            body = parsed.body
            if !highlights.isEmpty {
                body += "\n\nHighlights\n" + highlights.map { $0.hasPrefix("- ") ? $0 : "- \($0)" }.joined(separator: "\n")
            }
            usedModel = true
        } catch {
            notice = "Couldn't draft with Apple Intelligence (\(error.localizedDescription)). This is a template."
        }
    }

    var draft: FollowUpEmailDraft {
        FollowUpEmailDraft(
            subject: subject,
            body: body,
            recipients: FollowUpEmailComposer.parseRecipients(recipientsText),
            usedModel: usedModel
        )
    }

    /// Opens a new message in the user's mail app with recipients, subject
    /// and body filled in. Falls back to a `mailto:` link.
    func composeInMail() {
        let draft = self.draft
        if Self.performComposeService(draft) { return }
        if let url = FollowUpEmailComposer.mailtoURL(for: draft) {
            NSWorkspace.shared.open(url)
        }
    }

    /// `NSSharingService(named: .composeEmail)` — isolated here so a change
    /// in the AppKit API surface is a one-function fix.
    private static func performComposeService(_ draft: FollowUpEmailDraft) -> Bool {
        guard let service = NSSharingService(named: .composeEmail) else { return false }
        service.recipients = draft.recipients
        service.subject = draft.subject
        let items: [Any] = [draft.body]
        guard service.canPerform(withItems: items) else { return false }
        service.perform(withItems: items)
        return true
    }

    func copyToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("Subject: \(subject)\n\n\(body)", forType: .string)
    }
}

/// Sheet for reviewing / editing / sending the follow-up email.
struct FollowUpEmailSheet: View {
    let session: Session
    let summary: MeetingSummary?
    let highlights: [String]
    let onClose: () -> Void

    @StateObject private var model = FollowUpEmailModel()

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack {
                Text("Follow-up email")
                    .font(DesignTokens.Typography.section)
                if model.isGenerating {
                    ProgressView().controlSize(.small)
                    Text("Drafting with Apple Intelligence…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.usedModel {
                    Label("Drafted with Apple Intelligence", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leading, horizontalSpacing: DesignTokens.Spacing.sm, verticalSpacing: DesignTokens.Spacing.sm) {
                GridRow {
                    Text("To:").foregroundStyle(.secondary)
                    TextField("name@example.com, …", text: $model.recipientsText)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Subject:").foregroundStyle(.secondary)
                    TextField("Subject", text: $model.subject)
                        .textFieldStyle(.roundedBorder)
                }
            }

            TextEditor(text: $model.body)
                .font(.body)
                .frame(minHeight: 260)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                        .strokeBorder(DesignTokens.Palette.cardBorder, lineWidth: 1)
                )
                .disabled(model.isGenerating)

            HStack {
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    model.copyToPasteboard()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                ShareLink(item: model.body, subject: Text(model.subject)) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                Button {
                    model.composeInMail()
                } label: {
                    Label("Open in Mail", systemImage: "envelope")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isGenerating || model.body.isEmpty)
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(minWidth: 560, minHeight: 480)
        .task {
            await model.prepare(
                session: session,
                summary: summary,
                highlights: highlights,
                transcriptStore: .shared
            )
        }
    }
}
