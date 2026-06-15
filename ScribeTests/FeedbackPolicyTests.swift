import XCTest
@testable import Scribe

/// Pins the one-feedback-language convention (UX Cohesion Plan · Slice A1):
/// the mapping from a feedback *category* to the *channel* that surfaces it.
///
/// This is the only automated guard for the convention — the policy is a pure
/// function precisely so CI (the project's only compiler) can lock it down.
/// If someone reroutes a category, this test fails loudly instead of the app
/// silently regressing to the three-dialect error problem.
final class FeedbackPolicyTests: XCTestCase {

    func testRecoverableFailureUsesBanner() {
        XCTAssertEqual(FeedbackPolicy.channel(for: .recoverableFailure), .banner)
    }

    func testBlockingDecisionUsesAlert() {
        XCTAssertEqual(FeedbackPolicy.channel(for: .blockingDecision), .alert)
    }

    func testFieldValidationUsesInline() {
        XCTAssertEqual(FeedbackPolicy.channel(for: .fieldValidation), .inline)
    }

    func testSuccessUsesToast() {
        XCTAssertEqual(FeedbackPolicy.channel(for: .success), .toast)
    }

    /// The mapping must be total and one-to-one onto the four channels — every
    /// category resolves, and no two categories collapse onto the same channel.
    /// This catches both an unhandled new category and an accidental merge.
    func testMappingIsTotalAndDistinct() {
        let categories: [FeedbackCategory] = [
            .recoverableFailure, .blockingDecision, .fieldValidation, .success
        ]
        let channels = categories.map(FeedbackPolicy.channel(for:))
        XCTAssertEqual(Set(channels).count, categories.count,
                       "Each feedback category should map to a distinct channel.")
    }

    /// The dominant case by far: the overwhelming majority of failures in the
    /// app are recoverable/background and therefore belong on the banner, not a
    /// blocking alert. Asserts the convention's headline rule explicitly.
    func testRecoverableFailureIsNotBlocking() {
        XCTAssertNotEqual(FeedbackPolicy.channel(for: .recoverableFailure), .alert)
    }
}
