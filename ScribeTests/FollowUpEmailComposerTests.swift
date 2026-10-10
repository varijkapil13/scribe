import XCTest
@testable import Scribe

/// "Draft follow-up email": recipients, the deterministic template, parsing
/// the model's reply, and the mailto fallback.
final class FollowUpEmailComposerTests: XCTestCase {

    private func summary(
        _ text: String = "We agreed to ship v2 next week.",
        decisions: [String] = ["Ship v2"],
        actions: [ActionItem] = [],
        questions: [String] = ["Budget?"]
    ) -> MeetingSummary {
        MeetingSummary(
            id: UUID(),
            sessionId: "s",
            summary: text,
            keyDecisions: decisions,
            actionItems: actions,
            keyTopics: [],
            followUpQuestions: questions,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func item(_ text: String, owner: String? = nil, due: String? = nil) -> ActionItem {
        ActionItem(id: UUID(), description: text, assignee: owner, deadline: due, priority: nil, sourceText: "")
    }

    // MARK: - Recipients

    func testRecipientsFilterAndDedupe() {
        let attendees = [
            CalendarAttendee(name: "Ana", email: "a@x.com"),
            CalendarAttendee(name: "Ben"),
            CalendarAttendee(name: "Cy", email: "A@X.com"),
            CalendarAttendee(name: "Dee", email: "not an email"),
            CalendarAttendee(name: "Eve", email: "e@y.org"),
        ]
        XCTAssertEqual(FollowUpEmailComposer.recipients(from: attendees), ["a@x.com", "e@y.org"])
        XCTAssertEqual(FollowUpEmailComposer.recipients(from: attendees, excluding: ["E@Y.org"]), ["a@x.com"])
    }

    func testPlausibleEmail() {
        XCTAssertTrue(FollowUpEmailComposer.isPlausibleEmail("a@b.co"))
        XCTAssertFalse(FollowUpEmailComposer.isPlausibleEmail("a@b"))
        XCTAssertFalse(FollowUpEmailComposer.isPlausibleEmail("@b.com"))
        XCTAssertFalse(FollowUpEmailComposer.isPlausibleEmail("a b@c.com"))
        XCTAssertFalse(FollowUpEmailComposer.isPlausibleEmail("a@.com"))
        XCTAssertFalse(FollowUpEmailComposer.isPlausibleEmail("a@b."))
        XCTAssertFalse(FollowUpEmailComposer.isPlausibleEmail("a@b@c.com"))
    }

    func testParseRecipients() {
        XCTAssertEqual(
            FollowUpEmailComposer.parseRecipients("a@x.com; <b@y.com>, junk,\nA@x.com"),
            ["a@x.com", "b@y.com"]
        )
        XCTAssertEqual(FollowUpEmailComposer.parseRecipients(""), [])
    }

    // MARK: - Template

    func testSubject() {
        XCTAssertEqual(FollowUpEmailComposer.subject(title: "Weekly Sync", dateLabel: "Oct 10, 2026"),
                       "Follow-up: Weekly Sync (Oct 10, 2026)")
        XCTAssertEqual(FollowUpEmailComposer.subject(title: "  ", dateLabel: ""), "Follow-up: our meeting")
    }

    func testNamesHelpers() {
        XCTAssertEqual(FollowUpEmailComposer.joinNames([]), "")
        XCTAssertEqual(FollowUpEmailComposer.joinNames(["Ana"]), "Ana")
        XCTAssertEqual(FollowUpEmailComposer.joinNames(["Ana", "Ben"]), "Ana and Ben")
        XCTAssertEqual(FollowUpEmailComposer.joinNames(["Ana", "Ben", "Cy"]), "Ana, Ben and Cy")

        let attendees = [
            CalendarAttendee(name: "Ana Smith", email: "a@x.com"),
            CalendarAttendee(name: "", email: "b@x.com"),
            CalendarAttendee(name: "Ben Jones"),
            CalendarAttendee(name: "ana lee"),
        ]
        XCTAssertEqual(FollowUpEmailComposer.firstNames(attendees), ["Ana", "Ben"])
        let crowd = (0..<5).map { CalendarAttendee(name: "Person\($0) X") }
        XCTAssertEqual(FollowUpEmailComposer.firstNames(crowd), [], "Large groups get \"Hi all\"")
    }

    func testTemplateBodyHasAllSections() {
        let body = FollowUpEmailComposer.templateBody(
            title: "Launch sync",
            summary: summary(),
            fallbackSummary: nil,
            actionItems: [item("Send deck", owner: "Ana", due: "Friday"), item("Book room")],
            highlights: ["1:05 Pricing", "- 2:00 Dates"],
            attendeeFirstNames: ["Ana", "Ben"]
        )
        XCTAssertTrue(body.hasPrefix("Hi Ana and Ben,\n\nThanks for joining Launch sync."))
        XCTAssertTrue(body.contains("Summary\nWe agreed to ship v2 next week."))
        XCTAssertTrue(body.contains("Decisions\n- Ship v2"))
        XCTAssertTrue(body.contains("Action items\n- Send deck — Ana (due Friday)\n- Book room"))
        XCTAssertTrue(body.contains("Open questions\n- Budget?"))
        XCTAssertTrue(body.contains("Highlights\n- 1:05 Pricing\n- 2:00 Dates"))
        XCTAssertTrue(body.hasSuffix("Best,"))
        XCTAssertFalse(body.contains("I'll share notes"))
    }

    func testTemplateWithoutSummaryUsesFallbackAndPlaceholder() {
        let empty = FollowUpEmailComposer.templateBody(
            title: "", summary: nil, fallbackSummary: nil, actionItems: [], highlights: [], attendeeFirstNames: []
        )
        XCTAssertTrue(empty.hasPrefix("Hi all,\n\nThanks for joining our meeting."))
        XCTAssertTrue(empty.contains("I'll share notes and next steps shortly."))

        let live = FollowUpEmailComposer.templateBody(
            title: "T", summary: nil, fallbackSummary: "Live notes.", actionItems: [], highlights: [], attendeeFirstNames: []
        )
        XCTAssertTrue(live.contains("Summary\nLive notes."))
    }

    func testTemplateDraft() {
        let draft = FollowUpEmailComposer.template(
            title: "Weekly Sync",
            dateLabel: "Oct 10",
            summary: summary(),
            fallbackSummary: nil,
            actionItems: [],
            highlights: [],
            attendees: [CalendarAttendee(name: "Ana Smith", email: "ana@x.com")]
        )
        XCTAssertEqual(draft.subject, "Follow-up: Weekly Sync (Oct 10)")
        XCTAssertEqual(draft.recipients, ["ana@x.com"])
        XCTAssertTrue(draft.body.hasPrefix("Hi Ana,"))
        XCTAssertFalse(draft.usedModel)
    }

    // MARK: - Model output

    func testParseModelEmail() {
        let plain = FollowUpEmailComposer.parseModelEmail("Subject: Recap of sync\n\nHi team,\nThanks.", fallbackSubject: "F")
        XCTAssertEqual(plain.subject, "Recap of sync")
        XCTAssertEqual(plain.body, "Hi team,\nThanks.")

        let bold = FollowUpEmailComposer.parseModelEmail("**Subject:** Next steps\nBody", fallbackSubject: "F")
        XCTAssertEqual(bold.subject, "Next steps")
        XCTAssertEqual(bold.body, "Body")

        let none = FollowUpEmailComposer.parseModelEmail("Hi all,\nRecap.", fallbackSubject: "F")
        XCTAssertEqual(none.subject, "F")
        XCTAssertEqual(none.body, "Hi all,\nRecap.")

        let emptySubject = FollowUpEmailComposer.parseModelEmail("Subject:\nBody", fallbackSubject: "F")
        XCTAssertEqual(emptySubject.subject, "F")
        XCTAssertEqual(emptySubject.body, "Subject:\nBody")
    }

    func testMailtoURL() throws {
        let draft = FollowUpEmailDraft(subject: "Follow-up: Sync", body: "Hi all,\nRecap", recipients: ["a@x.com", "b@y.com"])
        let url = try XCTUnwrap(FollowUpEmailComposer.mailtoURL(for: draft))
        XCTAssertEqual(url.scheme, "mailto")
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:a@x.com,b@y.com?"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "subject" })?.value, "Follow-up: Sync")
        XCTAssertEqual(items.first(where: { $0.name == "body" })?.value, "Hi all,\nRecap")
    }

    func testSummaryShareText() {
        let text = FollowUpEmailComposer.summaryShareText(
            title: "Weekly Sync",
            summary: summary(actions: [item("Send deck", owner: "Ana")]),
            highlights: ["- 1:05 Pricing"]
        )
        XCTAssertTrue(text.hasPrefix("# Weekly Sync\n\nWe agreed to ship v2 next week."))
        XCTAssertTrue(text.contains("## Decisions\n- Ship v2"))
        XCTAssertTrue(text.contains("## Action items\n- Send deck — Ana"))
        XCTAssertTrue(text.contains("## Open questions\n- Budget?"))
        XCTAssertTrue(text.hasSuffix("## Highlights\n- 1:05 Pricing"))
    }
}
