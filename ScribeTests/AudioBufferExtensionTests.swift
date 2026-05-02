import XCTest
import AVFoundation
@testable import Scribe

/// Tests for the `AVAudioPCMBuffer.floatArray` extension and other audio helpers.
final class AudioBufferExtensionTests: XCTestCase {

    func testFloatArrayExtractsFirstChannelSamples() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let frameCapacity: AVAudioFrameCount = 4
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity))
        buffer.frameLength = frameCapacity
        let channel = try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<Int(frameCapacity) {
            channel[0][i] = Float(i) * 0.25
        }

        XCTAssertEqual(buffer.floatArray, [0.0, 0.25, 0.5, 0.75])
    }

    func testFloatArrayEmptyForZeroFrameLength() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100))
        buffer.frameLength = 0
        XCTAssertTrue(buffer.floatArray.isEmpty)
    }

    func testISO8601StringRoundTripsThroughDate() throws {
        let date = Date(timeIntervalSince1970: 1_715_000_000)
        let iso = date.iso8601String
        XCTAssertTrue(iso.contains("2024"))
        XCTAssertTrue(iso.contains("Z"))

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = try XCTUnwrap(formatter.date(from: iso))
        XCTAssertEqual(parsed.timeIntervalSince1970, 1_715_000_000, accuracy: 0.01)
    }
}
