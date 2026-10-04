import AVFoundation
import Foundation

/// Plays a bounded queue of stereo PCM frames. Audio never delays the video decoder.
final class DesktopAudio: @unchecked Sendable {
    private let queue = DispatchQueue(label: "flux.desktop.audio")
    private let lock = NSLock()
    private var pending = 0
    private var generation = 0
    private var volume: Float = 1
    // The queue owns the engine and the player.
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var failed = false
    private var session = false

    func setVolume(_ value: Float) {
        guard value.isFinite else { return }
        lock.withLock { volume = min(1, max(0, value)) }
    }

    func feed(_ bytes: [UInt8]) {
        guard bytes.count > 0, bytes.count <= 3840, bytes.count % 4 == 0 else { return }
        let token: Int? = lock.withLock {
            guard pending < 8 else { return nil }
            pending += 1
            return generation
        }
        guard let token else { return }
        queue.async { [self] in
            guard lock.withLock({ generation == token }), !failed else { release(token); return }
            do {
                let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
                if engine == nil {
                    #if os(iOS)
                    try AudioSession.activate(.desktop)
                    session = true
                    #endif
                    let next = AVAudioEngine(), node = AVAudioPlayerNode()
                    next.attach(node)
                    next.connect(node, to: next.mainMixerNode, format: format)
                    next.prepare()
                    try next.start()
                    node.play()
                    engine = next
                    player = node
                }
                let count = bytes.count / 4
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                      let channels = buffer.floatChannelData, let player else { release(token); return }
                buffer.frameLength = AVAudioFrameCount(count)
                for i in 0..<count {
                    for channel in 0..<2 {
                        let at = i * 4 + channel * 2
                        let word = UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
                        channels[channel][i] = Float(Int16(bitPattern: word)) / 32768
                    }
                }
                player.volume = lock.withLock { volume }
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in self?.release(token) }
            } catch {
                failed = true
                release(token)
                FluxLog.plugin.error("desktop audio failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func release(_ token: Int) {
        lock.withLock { if token == generation { pending = max(0, pending - 1) } }
    }

    func stop() {
        lock.withLock { generation += 1; pending = 0 }
        queue.async { [self] in
            player?.stop()
            engine?.stop()
            player = nil
            engine = nil
            failed = false
            #if os(iOS)
            if session { AudioSession.deactivate(.desktop) }
            #endif
            session = false
        }
    }
}
