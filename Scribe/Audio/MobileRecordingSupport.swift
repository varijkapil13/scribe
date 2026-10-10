import Foundation

// MARK: - iPhone / iPad recording: portable rules
//
// Pure (Foundation-only) decisions behind the iOS / iPadOS recorder
// (ScribeiOS/Recording). They live under Scribe/ so the macOS `swift test`
// job compiles and unit-tests them; the iOS target compiles the same file.
// Nothing here touches AVAudioSession / AVAudioEngine — the iOS capture code
// maps the system's raw notification values into these types and asks them
// what to do.

/// Labels and keys for recordings made on iPhone / iPad.
///
/// iOS can only record the microphone (no other app's or system audio), so a
/// phone recording is always the room: the people around the device, or a
/// call on speakerphone.
enum MobileRecordingDefaults {

    /// Speaker key stamped on live iPhone / iPad recordings. A custom key (not
    /// `"you"` / `"remote"`), so `SpeakerNameResolver` shows it verbatim and
    /// the user can rename it per session.
    nonisolated static let speakerKey = "In person"

    /// Speaker key stamped on audio / video files imported on iPhone / iPad.
    nonisolated static let importedSpeakerKey = "Speaker"

    /// The capture mode as shown in the UI.
    nonisolated static let captureModeLabel = "In-person / speakerphone"

    /// Coalescing used for the live transcript: shorter paragraphs than an
    /// import (`ImportedTranscriptCoalescer`) so the feed stays readable.
    nonisolated static let liveMaxSpanMs = 30_000
    nonisolated static let liveMaxGapMs = 2_500
}

// MARK: - Audio session events

/// Why the audio route changed — a portable mirror of
/// `AVAudioSession.RouteChangeReason` (same raw values).
enum MobileAudioRouteChange: Equatable, Sendable {
    case unknown
    case newDeviceAvailable
    case oldDeviceUnavailable
    case categoryChange
    case routeOverride
    case wakeFromSleep
    case noSuitableRouteForCategory
    case routeConfigurationChange

    /// Maps `AVAudioSession.RouteChangeReason.rawValue`.
    init(rawReason: UInt) {
        switch rawReason {
        case 1: self = .newDeviceAvailable
        case 2: self = .oldDeviceUnavailable
        case 3: self = .categoryChange
        case 4: self = .routeOverride
        case 6: self = .wakeFromSleep
        case 7: self = .noSuitableRouteForCategory
        case 8: self = .routeConfigurationChange
        default: self = .unknown
        }
    }
}

/// An audio-session interruption (a phone or FaceTime call, Siri, an alarm),
/// mapped from `AVAudioSession.interruptionNotification`'s user info.
enum MobileAudioInterruption: Equatable, Sendable {
    case began
    case ended(shouldResume: Bool)

    /// `typeRaw`: `AVAudioSession.InterruptionType.rawValue` (began = 1,
    /// ended = 0). `optionsRaw`: `AVAudioSession.InterruptionOptions.rawValue`
    /// (`shouldResume` = 1). Nil for a notification without a type.
    init?(typeRaw: UInt?, optionsRaw: UInt?) {
        guard let typeRaw else { return nil }
        switch typeRaw {
        case 1:
            self = .began
        case 0:
            let options = optionsRaw ?? 0
            self = .ended(shouldResume: options & 1 == 1)
        default:
            return nil
        }
    }
}

/// What the recorder should do about an audio-session event.
enum MobileRecordingAudioAction: Equatable, Sendable {
    case ignore
    /// Stop feeding audio (the session stays open).
    case pause
    /// Feed audio again after a pause this policy caused.
    case resume
    /// Rebuild the input tap: the input device or its format changed
    /// (AirPods connected / removed, a wired headset, CarPlay).
    case restartInput
}

/// Interruption and route-change rules for an iPhone / iPad recording.
enum MobileRecordingInterruptionPolicy {

    /// An incoming call pauses a running recording (iOS takes the mic away
    /// anyway). A recording the user already paused stays as it is.
    nonisolated static func action(
        for interruption: MobileAudioInterruption,
        isCapturing: Bool,
        isPausedByUser: Bool,
        wasPausedByInterruption: Bool
    ) -> MobileRecordingAudioAction {
        switch interruption {
        case .began:
            return isCapturing && !isPausedByUser ? .pause : .ignore
        case .ended(let shouldResume):
            // Only resume what the interruption paused, and only when iOS says
            // it's appropriate (it isn't after e.g. the user started music).
            return wasPausedByInterruption && shouldResume ? .resume : .ignore
        }
    }

    /// A new or removed input device restarts the tap (the hardware format
    /// usually changes: AirPods' HFP mic runs at 16–24 kHz, the built-in mic
    /// at 48 kHz). With no usable route at all the recording pauses.
    nonisolated static func action(
        for change: MobileAudioRouteChange,
        isCapturing: Bool
    ) -> MobileRecordingAudioAction {
        guard isCapturing else { return .ignore }
        switch change {
        case .newDeviceAvailable, .oldDeviceUnavailable, .routeOverride, .routeConfigurationChange:
            return .restartInput
        case .noSuitableRouteForCategory:
            return .pause
        case .unknown, .categoryChange, .wakeFromSleep:
            return .ignore
        }
    }
}

// MARK: - Level meter

/// Maps a linear peak amplitude (0…1) onto a 0…1 meter value on a decibel
/// scale, so quiet speech still moves the meter.
enum MobileAudioLevelScale {

    /// Peaks at or below this read as silence.
    nonisolated static let floorDecibels: Double = -50

    nonisolated static func normalized(linearPeak: Float) -> Double {
        let peak = Double(linearPeak)
        guard peak.isFinite, peak > 0 else { return 0 }
        let decibels = 20 * log10(min(peak, 1))
        guard decibels > floorDecibels else { return 0 }
        return min(max((decibels - floorDecibels) / -floorDecibels, 0), 1)
    }

    /// Fast attack, slow release: the meter jumps up with speech and falls
    /// back smoothly.
    nonisolated static func smoothed(previous: Double, next: Double) -> Double {
        let factor = next > previous ? 0.6 : 0.2
        return previous + (next - previous) * factor
    }
}

// MARK: - Retained audio location

/// Finds a session's audio folder on iPhone / iPad.
///
/// Sessions store the folder as an absolute path, but an iOS app's container
/// path changes when the app is reinstalled or restored onto a new device, so
/// a stored path can go stale while the files still sit under the current
/// audio root with the same session id.
enum SessionAudioLocator {

    /// The folder holding the session's audio, or nil when there is none.
    nonisolated static func directory(
        storedPath: String?,
        sessionId: String,
        currentRoot: URL,
        fileExists: (String) -> Bool
    ) -> URL? {
        if let storedPath, !storedPath.isEmpty {
            let stored = URL(fileURLWithPath: storedPath, isDirectory: true)
            if playableFile(in: stored, fileExists: fileExists) != nil { return stored }
        }
        let fallback = SessionAudioStorage.directory(forSessionId: sessionId, root: currentRoot)
        return playableFile(in: fallback, fileExists: fileExists) != nil ? fallback : nil
    }

    /// The file to play: the microphone track (live recordings), else the
    /// "system" track (imports write their audio there).
    nonisolated static func playableFile(in directory: URL, fileExists: (String) -> Bool) -> URL? {
        let mic = SessionAudioStorage.micFileURL(in: directory)
        if fileExists(mic.path) { return mic }
        let system = SessionAudioStorage.systemFileURL(in: directory)
        if fileExists(system.path) { return system }
        return nil
    }
}

// MARK: - Titles

/// Titles for notes / sessions recorded on iPhone / iPad.
enum MobileRecordingTitle {

    /// "Weekly Sync — Oct 9, 2026" for a matched calendar event, else
    /// "In-person meeting on Oct 9, 2026 at 10:30".
    nonisolated static func noteTitle(
        event: CalendarEventInfo?,
        date: Date,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        if let event {
            return CalendarNoteFormatter.noteTitle(for: event, date: date, locale: locale, timeZone: timeZone)
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "In-person meeting on \(formatter.string(from: date))"
    }

    /// One italic line at the top of a new meeting note saying where it was
    /// recorded ("iPhone" / "iPad").
    nonisolated static func recordedOnLine(deviceName: String) -> String {
        let device = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = device.isEmpty ? "on iPhone or iPad" : "on \(device)"
        return "*Recorded \(place) — \(MobileRecordingDefaults.captureModeLabel).*"
    }

    /// "12:34" / "1:02:03" for an elapsed duration.
    nonisolated static func elapsedLabel(seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds)) : 0
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}
