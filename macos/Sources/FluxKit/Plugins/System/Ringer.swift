import AVFoundation

/// Plays an alarm in a loop at full player volume. The phone raises its
/// separate alarm stream; a Mac has no such stream, so the ring follows the
/// system output volume and never changes it.
@MainActor
final class Ringer {
    /// The sounds that the ringer tries, in order.
    private static let sounds = [
        "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones/Alarm.m4r",
        "/System/Library/Sounds/Sosumi.aiff",
    ]

    private var player: AVAudioPlayer?

    func start() {
        guard player == nil else { return }
        for path in Self.sounds where FileManager.default.fileExists(atPath: path) {
            guard let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else { continue }
            p.numberOfLoops = -1
            p.volume = 1
            if p.play() {
                FluxLog.plugin.info("ring sound \(path, privacy: .public) playing")
                player = p
                return
            }
        }
        FluxLog.plugin.error("no ring sound can play")
    }

    func stop() {
        player?.stop()
        player = nil
    }
}
