import Foundation
import FluxProto
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Microphone capture. Ports Android `mic/MicSession.kt` (`openRecorder`,
/// `record`) to `AVAudioEngine`: voice-processing tap → 48 kHz mono s16le
/// chunks with the same framing (`Pcm`), ~10 ms writes, level ~15 Hz.
///
/// Needs hardware + the microphone permission (needs hardware runs are
/// gated in `ios/README.md` M5; the framing is unit-tested via `Pcm` and
/// the bytes are E2E-held through `StreamEngine`).

#if canImport(AVFoundation)
/// Records 48 kHz mono PCM and delivers little-endian chunks.
public final class MicCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var lastLevel = Date.distantPast

    /// Chunk bytes (s16le mono 48 kHz) + peak level 0…1.
    public var onChunk: ((Data, Float) -> Void)?

    public init() {}

    /// Starts the tap with voice processing, as a call app does
    /// (Android `VOICE_COMMUNICATION` parity; falls back to the plain
    /// input when the device has no voice path).
    public func start() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
        try session.setActive(true)
        #endif
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.channelCount > 0 else {
            throw MicCaptureError.noInput("This device cannot record audio")
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true) else {
            throw MicCaptureError.noInput("This device cannot record 48 kHz audio")
        }
        converter = AVAudioConverter(from: hardware, to: target)
        input.installTap(onBus: 0, bufferSize: 4800, format: hardware) { [weak self] buffer, _ in
            self?.convert(buffer, to: target)
        }
        engine.prepare()
        try engine.start()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) {
        guard let converter else { return }
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4800) else { return }
        var error: NSError?
        converter.convert(to: out, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0,
              let ptr = out.int16ChannelData?[0]
        else { return }
        let n = Int(out.frameLength)
        let samples = Array(UnsafeBufferPointer(start: ptr, count: n))
        let bytes = Pcm.toLittleEndian(samples, count: n)
        let now = Date()
        if now.timeIntervalSince(lastLevel) >= 0.066 {
            lastLevel = now
            onChunk?(bytes, Pcm.peak(samples, count: n))
        } else {
            onChunk?(bytes, -1)
        }
    }
}

public enum MicCaptureError: Error, Equatable {
    case noInput(String)
}
#endif
