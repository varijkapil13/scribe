// ScribeTests/AudioConversionTests.swift
import AVFoundation
import XCTest
@testable import Scribe

// MARK: - Converter feeding

/// The mic resampler used to answer `.haveData` with the same buffer on every
/// input-block call into a fixed 100 ms output buffer, so the converter
/// re-read each ~85 ms hardware buffer and duplicated audio.
final class AudioConversionTests: XCTestCase {

    func testOutputCapacityScalesWithRateAndAddsHeadroom() {
        let headroom = AudioConversion.outputHeadroomFrames
        // 4096 @ 48 kHz → 16 kHz is 1365.33 frames: rounded up.
        XCTAssertEqual(AudioConversion.outputCapacity(inputFrames: 4096, inputRate: 48_000, outputRate: 16_000),
                       1366 + headroom)
        XCTAssertEqual(AudioConversion.outputCapacity(inputFrames: 441, inputRate: 44_100, outputRate: 16_000),
                       160 + headroom)
        XCTAssertEqual(AudioConversion.outputCapacity(inputFrames: 160, inputRate: 16_000, outputRate: 16_000),
                       160 + headroom)
        // Upsampling grows the buffer.
        XCTAssertEqual(AudioConversion.outputCapacity(inputFrames: 100, inputRate: 8_000, outputRate: 16_000),
                       200 + headroom)
    }

    func testOutputCapacityFallsBackForInvalidRates() {
        let headroom = AudioConversion.outputHeadroomFrames
        XCTAssertEqual(AudioConversion.outputCapacity(inputFrames: 512, inputRate: 0, outputRate: 16_000), 512 + headroom)
        XCTAssertEqual(AudioConversion.outputCapacity(inputFrames: 512, inputRate: 48_000, outputRate: 0), 512 + headroom)
    }

    func testConverterDoesNotDuplicateInput() throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                                      channels: 1, interleaved: false))
        let outputFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                       channels: 1, interleaved: false))
        let converter = try XCTUnwrap(AVAudioConverter(from: inputFormat, to: outputFormat))

        let buffers = 10
        let framesPerBuffer: AVAudioFrameCount = 4096 // ~85 ms, shorter than the old 100 ms output
        var produced = 0
        for index in 0..<buffers {
            let input = try makeSine(format: inputFormat, frames: framesPerBuffer, phase: index * Int(framesPerBuffer))
            if let output = AudioConversion.convert(input, using: converter) {
                XCTAssertEqual(output.format.sampleRate, 16_000)
                produced += Int(output.frameLength)
            }
        }

        let expected = Double(buffers) * Double(framesPerBuffer) / 3 // 13 653
        // The resampler may hold a few frames back, but must never emit more
        // than the input accounts for (the old feed produced 16 000 here).
        XCTAssertLessThanOrEqual(Double(produced), expected + 2)
        XCTAssertGreaterThan(Double(produced), expected - 512)
    }

    private func makeSine(format: AVAudioFormat, frames: AVAudioFrameCount, phase: Int) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        let step: Float = 2 * Float.pi * 440 / Float(format.sampleRate)
        for i in 0..<Int(frames) {
            samples[i] = 0.5 * sinf(Float(phase + i) * step)
        }
        return buffer
    }
}
