import Foundation

/// The webcam settings of this Mac. The Mac UI and the computer both change
/// them through update. Each change is saved, so the next stream starts with
/// the same settings.
final class WebcamSettings: @unchecked Sendable {
    private static let key = "webcam.config"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var _config: WebcamConfig
    private var _caps: WebcamCaps

    init(defaults: UserDefaults, caps: WebcamCaps) {
        self.defaults = defaults
        _caps = caps
        let saved = defaults.data(forKey: Self.key).flatMap { JSONValue.parse($0)?.object }
        _config = WebcamConfig().merged(saved).clamped(caps)
    }

    var config: WebcamConfig { lock.withLock { _config } }
    var caps: WebcamCaps { lock.withLock { _caps } }

    /// Changes the settings. The result is clamped to the caps and saved. It
    /// returns the new settings, or nil when nothing changed.
    func update(_ change: (WebcamConfig) -> WebcamConfig) -> WebcamConfig? {
        lock.withLock {
            let next = change(_config).clamped(_caps)
            guard next != _config else { return nil }
            _config = next
            defaults.set(JSONValue.object(next.json).serialized(), forKey: Self.key)
            return next
        }
    }

    /// Applies a "config" message from the computer.
    func applyRemote(reset: Bool, partial: [String: JSONValue]?) -> WebcamConfig? {
        update { c in (reset ? c.reset() : c).merged(partial) }
    }

    /// Sets what the current camera supports, and clamps the settings to it.
    func setCaps(_ caps: WebcamCaps) -> WebcamConfig? {
        lock.withLock { _caps = caps }
        return update { $0 }
    }
}
