import AVFoundation
import XCTest
@testable import FluxKit

final class MicConvertTests: XCTestCase {
    /// A 44.1 kHz stereo float buffer with a 440 Hz sine of amplitude 0.5 on both channels.
    private func sine(frames: Int, rate: Double = 44_100, channels: AVAudioChannelCount = 2, start: Int = 0) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try XCTUnwrap(buffer.floatChannelData)
        for c in 0..<Int(channels) {
            for i in 0..<frames { data[c][i] = 0.5 * sin(2 * .pi * 440 * Float(start + i) / Float(rate)) }
        }
        return buffer
    }

    private func samples(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    func testStereo44kBecomesMono48k() throws {
        var converter: AVAudioConverter?
        var out: [Int16] = []
        let chunk = 4410
        for n in 0..<10 {
            out += samples(try MicConvert.s16Mono48k(try sine(frames: chunk, start: n * chunk), converter: &converter))
        }
        // 1 second at 44.1 kHz gives about 1 second at 48 kHz. The resampler holds back a few frames.
        XCTAssertEqual(Double(out.count), 48_000, accuracy: 48_000 * 0.01)
        let peak = out.map { abs(Int($0)) }.max() ?? 0
        XCTAssertEqual(Double(peak), 0.5 * 32_767, accuracy: 0.05 * 32_767, "both channels mix into 1 at the same level")
        XCTAssertEqual(converter?.outputFormat.sampleRate, 48_000)
        XCTAssertEqual(converter?.outputFormat.channelCount, 1)
    }

    func testFormatChangeRebuildsTheConverter() throws {
        var converter: AVAudioConverter?
        _ = try MicConvert.s16Mono48k(try sine(frames: 4410), converter: &converter)
        let first = try XCTUnwrap(converter)
        _ = try MicConvert.s16Mono48k(try sine(frames: 4410), converter: &converter)
        XCTAssertTrue(first === converter, "the same format keeps the converter")
        var out: [Int16] = []
        for n in 0..<10 {
            out += samples(try MicConvert.s16Mono48k(try sine(frames: 4800, rate: 48_000, channels: 1, start: n * 4800), converter: &converter))
        }
        XCTAssertFalse(first === converter, "a new format builds a new converter")
        XCTAssertEqual(converter?.inputFormat.sampleRate, 48_000)
        XCTAssertEqual(Double(out.count), 48_000, accuracy: 48_000 * 0.01)
    }
}
