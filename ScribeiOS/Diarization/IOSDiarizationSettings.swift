// ScribeiOS/Diarization/IOSDiarizationSettings.swift
//
// Speaker-separation settings on iPhone / iPad. The model download itself is
// the shared ScribeDiarizerModelManager (Scribe/Diarization/Portable).

import Foundation

/// The iPhone / iPad name for the shared model manager.
typealias IOSDiarizationModelManager = ScribeDiarizerModelManager

/// UserDefaults keys and readers for speaker separation on iPhone / iPad.
enum IOSDiarizationSettings {
    nonisolated static let enabledKey = "ios.diarization.enabled"
    nonisolated static let wifiOnlyKey = "ios.diarization.wifiOnly"
    nonisolated static let suggestNamesKey = "ios.diarization.suggestNames"

    static var isEnabled: Bool { bool(enabledKey, default: true) }
    static var wifiOnly: Bool { bool(wifiOnlyKey, default: true) }
    static var suggestNames: Bool { bool(suggestNamesKey, default: true) }

    private static func bool(_ key: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }
}
