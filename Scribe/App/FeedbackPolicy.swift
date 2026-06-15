import Foundation

/// One feedback language (UX Cohesion Plan · Slice A1).
///
/// Scribe historically surfaced failures three different ways — an auto-dismiss
/// banner, a blocking `.alert`, and persistent inline red/green text — so the
/// same class of problem looked and behaved differently depending on where it
/// happened. This file pins the *single* convention and makes the routing a
/// pure function so CI can test it without a UI.
///
/// The convention (also documented in the plan):
/// - **Transient / recoverable / background failures → `.banner`.**
///   Recording, vault, autosave, mirror-to-disk, and export failures. These are
///   things the user can retry or ignore; they should never block the window.
///   Surfaced via `AppState.lastError` (the `ErrorBanner` channel).
/// - **Blocking, user-must-decide → `.alert`.** Rare: destructive confirmations
///   and genuine hard failures like "couldn't open the database". Reserved for
///   cases where continuing without a decision is wrong.
/// - **Inline field-level validation → `.inline`.** Only where it is tied to a
///   specific control (e.g. an invalid recurrence string shown next to its
///   field). Never a substitute for surfacing an actual operation failure.
/// - **Success confirmation → `.toast`.** A brief, auto-dismissing success
///   notice (e.g. "Moved 12 files"). Routed through the same banner host with a
///   success style rather than its own bespoke widget.

/// What kind of feedback a given event is. Callers classify the event; the
/// policy maps it to a channel. Keeping these separate is what lets the mapping
/// be a pure, testable function.
enum FeedbackCategory: Equatable {
    /// A transient / recoverable / background failure (recording, vault,
    /// autosave, mirror-to-disk, export). The overwhelming majority of failures.
    case recoverableFailure
    /// A hard failure the user must acknowledge or decide on before continuing
    /// (e.g. "couldn't open the database", a destructive confirmation).
    case blockingDecision
    /// Validation tied to a specific input control (e.g. a bad recurrence rule).
    case fieldValidation
    /// A successful operation worth confirming briefly.
    case success
}

/// Where a piece of feedback is shown.
enum FeedbackChannel: Equatable {
    /// The transient `ErrorBanner` over the main window, via `AppState.lastError`.
    case banner
    /// A blocking `.alert` the user must dismiss.
    case alert
    /// Inline text rendered next to the control it validates.
    case inline
    /// A brief success toast, via `AppState.lastNotice`.
    case toast
}

/// The single source of truth for "which channel does this feedback use?".
///
/// Pure and total so it can be unit-tested on CI (the only compiler available
/// for this project). Every UI site that reports feedback should classify its
/// event into a `FeedbackCategory` and let this decide the channel, instead of
/// hand-rolling a banner / alert / inline string ad hoc.
enum FeedbackPolicy {
    static func channel(for category: FeedbackCategory) -> FeedbackChannel {
        switch category {
        case .recoverableFailure: return .banner
        case .blockingDecision:   return .alert
        case .fieldValidation:    return .inline
        case .success:            return .toast
        }
    }
}
