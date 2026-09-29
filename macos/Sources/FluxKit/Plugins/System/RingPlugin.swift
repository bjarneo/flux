import Foundation
import Observation
import UserNotifications

/// The ring state that the UI shows.
@MainActor
@Observable
public final class RingModel {
    /// The name of the computer that rings this device, or nil.
    public internal(set) var ringing: String?

    init() {}
}

/// Find my phone: flux.findmyphone.request from the computer, which
/// `flux-cli ring` sends. The device rings until the user stops it, for 2
/// minutes at most, like Flux for Android. A second request while it rings
/// stops it, so the computer can stop a ring that nobody reaches. The app
/// plays the sound and shows the ring while `model.ringing` is set. Only the
/// iOS app registers it: a Mac does not get lost.
public final class RingPlugin: FluxPlugin, @unchecked Sendable {
    public let model: RingModel
    private let maxDuration: Duration
    @MainActor private var timeout: Task<Void, Never>?

    public static let defaultDuration = Duration.seconds(120)
    static let category = "ring"
    static let notificationId = "ring"

    @MainActor
    public init(maxDuration: Duration = RingPlugin.defaultDuration) {
        model = RingModel()
        self.maxDuration = maxDuration
    }

    public let incoming = [PacketType.findMyPhone]
    public let outgoing: [String] = []

    public func attach(core: FluxCore) {
        Notifier.shared.register(category: Self.category, actions: [
            UNNotificationAction(identifier: "stop", title: "I Found It", options: [.destructive]),
        ]) { [weak self] action, _, _ in
            // A tap opens Flux, which shows the ring with its Stop button.
            guard action == "stop" else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.stop() } }
        }
    }

    public func handle(_ packet: Packet, from device: Device) {
        let name = device.name
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated { ring(from: name) } }
    }

    /// Starts a ring, or stops the ring that runs.
    @MainActor
    public func ring(from name: String) {
        guard model.ringing == nil else {
            stop()
            return
        }
        FluxLog.plugin.info("\(name, privacy: .public) rings \(FluxPlatform.current.deviceNoun, privacy: .public)")
        model.ringing = name
        Notifier.shared.post(id: Self.notificationId, category: Self.category, title: "Ringing from \(name)",
                             body: "Tap to stop")
        let limit = maxDuration
        timeout = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    /// Stops the ring.
    @MainActor
    public func stop() {
        timeout?.cancel()
        timeout = nil
        guard model.ringing != nil else { return }
        model.ringing = nil
        Notifier.shared.remove(id: Self.notificationId)
    }
}

/// The sound of a ring: three short high beeps and a pause, which loops.
public enum RingTone {
    static let sampleRate = 44_100
    /// The length of 1 loop in seconds.
    static let duration = 1.2

    /// The tone as a 16-bit mono PCM WAVE file.
    public static func wav() -> Data {
        let count = Int(duration * Double(sampleRate))
        var pcm = Data(capacity: count * 2)
        let beep = 0.14, gap = 0.08, fade = 0.005
        for i in 0..<count {
            let t = Double(i) / Double(sampleRate)
            var value = 0.0
            let slot = Int(t / (beep + gap))
            let inSlot = t - Double(slot) * (beep + gap)
            if slot < 3, inSlot < beep {
                let frequency = slot == 1 ? 1760.0 : 1320.0
                // Short ramps at both ends keep the beeps from clicking.
                let envelope = min(1, inSlot / fade, (beep - inSlot) / fade)
                value = 0.9 * envelope * sin(2 * .pi * frequency * inSlot)
            }
            let sample = Int16((value * Double(Int16.max)).rounded())
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var wav = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8))
        u32(UInt32(36 + pcm.count))
        wav.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16)
        u16(1)
        u16(1)
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))
        u16(2)
        u16(16)
        wav.append(contentsOf: Array("data".utf8))
        u32(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}
