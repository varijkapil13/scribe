import Foundation
import os

/// Centralized logger so call sites can write `Log.audio.info(...)` instead
/// of carrying around `Logger` instances. Subsystem mirrors the bundle
/// identifier; one logger per major subsystem.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.varij.scribe"

    static let app          = Logger(subsystem: subsystem, category: "app")
    static let audio        = Logger(subsystem: subsystem, category: "audio")
    static let speech       = Logger(subsystem: subsystem, category: "speech")
    static let storage      = Logger(subsystem: subsystem, category: "storage")
    static let intelligence = Logger(subsystem: subsystem, category: "intelligence")
    static let ui           = Logger(subsystem: subsystem, category: "ui")
}
