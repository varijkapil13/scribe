import Foundation

/// Shared list of recognition languages supported by Scribe. Used by both
/// the Settings picker and the Overlay quick-switcher so the two UIs stay in
/// sync automatically.
enum LanguageOptions {

    /// The BCP-47-ish short codes Scribe exposes to users, in display order.
    /// `"auto"` is surfaced first as "Auto-detect" (falls back to the system
    /// default locale). Currently scoped to English, German, and Hindi; add
    /// new entries here and they appear in Settings + the overlay picker
    /// automatically.
    static let supported: [(code: String, name: String)] = [
        ("auto", "Auto-detect (system)"),
        ("en",   "English"),
        ("de",   "German"),
        ("hi",   "Hindi"),
    ]

    /// Human-readable name for a stored language code. Falls back to the code
    /// itself if not listed (e.g. regional variants).
    static func displayName(for code: String) -> String {
        supported.first(where: { $0.code == code })?.name ?? code
    }

    /// Short two-letter code for a given stored value — used in the overlay
    /// status line where space is tight.
    static func shortLabel(for code: String) -> String {
        if code.isEmpty || code.lowercased() == "auto" { return "AUTO" }
        if code.contains("-") {
            return code.split(separator: "-").first.map { String($0).uppercased() } ?? code.uppercased()
        }
        return code.uppercased()
    }
}
