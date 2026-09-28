@preconcurrency import AVFoundation
import CoreMedia

/// Converts microphone audio to the stream format: 48 kHz mono s16le.
/// macOS converts in the capture output. iOS has no output settings for
/// audio, so each buffer converts here.
enum MicConvert {
    /// Converts 1 buffer. The converter carries the resampler state from
    /// buffer to buffer, and a buffer in a new format builds a new one.
    static func s16Mono48k(_ buffer: AVAudioPCMBuffer, converter: inout AVAudioConverter?) throws -> Data {
        let c: AVAudioConverter
        if let existing = converter, existing.inputFormat == buffer.format {
            c = existing
        } else {
            guard let out = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(MicPackets.rate),
                                          channels: AVAudioChannelCount(MicPackets.channels), interleaved: true),
                  let made = AVAudioConverter(from: buffer.format, to: out) else {
                throw FluxError("Flux cannot convert \(Int(buffer.format.sampleRate)) Hz audio with \(buffer.format.channelCount) channels")
            }
            // Mix all channels into 1, instead of taking the first channel.
            made.downmix = true
            c = made
            converter = made
        }
        let ratio = c.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: c.outputFormat, frameCapacity: capacity) else {
            throw FluxError("Flux cannot make an audio buffer of \(capacity) frames")
        }
        var given = false
        var error: NSError?
        let status = c.convert(to: output, error: &error) { _, inputStatus in
            // The stream goes on, so the converter keeps the frames that it
            // cannot resample yet for the next buffer.
            guard !given else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            given = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error { throw error ?? FluxError("the audio conversion failed") }
        guard let samples = output.int16ChannelData else { throw FluxError("the converted audio has no samples") }
        return Data(bytes: samples[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }

    /// Copies the samples of a capture buffer into a PCM buffer in the same format.
    static func pcmBuffer(_ sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let description = sample.formatDescription else { throw FluxError("the audio has no format") }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw FluxError("Flux cannot read \(Int(format.sampleRate)) Hz audio with \(format.channelCount) channels")
        }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { throw FluxError("Flux cannot read the audio (\(status))") }
        return buffer
    }
}
