import Foundation
import AVFoundation

// MARK: - TimeInterval

extension TimeInterval {

    /// Formats the interval as a human-readable duration string.
    ///
    /// Returns `"MM:SS"` when the duration is less than one hour,
    /// or `"HH:MM:SS"` otherwise.
    var formattedDuration: String {
        let totalSeconds = Int(self)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

// MARK: - Int (Milliseconds / Seconds)

extension Int {

    /// Formats the receiver (interpreted as milliseconds) as a bracketed timestamp.
    ///
    /// Example: `3_723_000.formattedTimestamp` returns `"[01:02:03]"`.
    var formattedTimestamp: String {
        let totalSeconds = self / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "[%02d:%02d:%02d]", hours, minutes, seconds)
    }

    /// Formats the receiver (interpreted as seconds) as a natural-language duration.
    ///
    /// Examples:
    /// - `90.formattedDurationFromSeconds` returns `"1 minute"`
    /// - `7500.formattedDurationFromSeconds` returns `"2 hours 5 minutes"`
    /// - `0.formattedDurationFromSeconds` returns `"0 minutes"`
    var formattedDurationFromSeconds: String {
        let hours = self / 3600
        let minutes = (self % 3600) / 60

        if hours > 0 && minutes > 0 {
            let hourWord = hours == 1 ? "hour" : "hours"
            let minuteWord = minutes == 1 ? "minute" : "minutes"
            return "\(hours) \(hourWord) \(minutes) \(minuteWord)"
        } else if hours > 0 {
            let hourWord = hours == 1 ? "hour" : "hours"
            return "\(hours) \(hourWord)"
        } else {
            let minuteWord = minutes == 1 ? "minute" : "minutes"
            return "\(minutes) \(minuteWord)"
        }
    }
}

// MARK: - AVAudioPCMBuffer

extension AVAudioPCMBuffer {

    /// Extracts the first channel of Float32 PCM data as a plain `[Float]` array.
    ///
    /// Returns an empty array if the buffer contains no float channel data.
    var floatArray: [Float] {
        guard let channelData = floatChannelData else { return [] }
        let frameCount = Int(frameLength)
        let samples = channelData[0]
        return Array(UnsafeBufferPointer(start: samples, count: frameCount))
    }
}

// MARK: - Date

extension Date {

    /// Formats the date as an ISO 8601 string with fractional seconds and UTC time zone.
    ///
    /// Example: `"2024-06-15T14:30:00.000Z"`.
    var iso8601String: String {
        Self.iso8601Formatter.string(from: self)
    }

    // `ISO8601DateFormatter` is documented as thread-safe for reads after its
    // options are configured, so sharing a single instance is safe.
    nonisolated(unsafe) private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
