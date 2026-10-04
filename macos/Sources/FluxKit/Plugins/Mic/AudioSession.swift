import Foundation

/// A part of Flux that needs the audio session of the iPhone.
public enum AudioUse: Sendable, Hashable {
    /// The microphone stream to a computer.
    case mic
    /// A dictation into a text field.
    case dictation
    /// The ring of a computer that looks for the iPhone.
    case ring
    /// The audio of a remote desktop.
    case desktop
}

/// The categories that Flux gives the audio session.
enum AudioCategory: Sendable, Equatable {
    /// Records only, in measurement mode without voice processing, for dictation.
    case record
    /// Plays and records, with the speaker and Bluetooth headsets.
    case playAndRecord
    /// Plays only, also with the silent switch on.
    case playback

    /// The category for the uses: the microphone stream plays and records,
    /// and so does a ring while a dictation records.
    static func needed(for uses: Set<AudioUse>) -> AudioCategory {
        if uses.contains(.mic) || (uses.contains(.dictation) && !uses.isDisjoint(with: [.ring, .desktop])) { return .playAndRecord }
        return uses.contains(.dictation) ? .record : .playback
    }

    /// Reports whether the category works for each of the uses.
    func serves(_ uses: Set<AudioUse>) -> Bool {
        switch self {
        case .playAndRecord: return true
        case .record: return uses.isSubset(of: [.dictation])
        case .playback: return uses.isSubset(of: [.ring, .desktop])
        }
    }
}

/// Who holds the audio session. The session is active while at least 1
/// user holds it, so that no user deactivates it under another, and its
/// category changes only when it does not work for a new user.
struct AudioUsers: Sendable, Equatable {
    private(set) var counts: [AudioUse: Int] = [:]
    /// The category of the session while users hold it.
    private(set) var category: AudioCategory?

    /// True while a user holds the session.
    var active: Bool { !counts.isEmpty }

    /// Adds a user. It returns the category that the session needs now, or
    /// nil when the category it has works.
    mutating func add(_ use: AudioUse) -> AudioCategory? {
        counts[use, default: 0] += 1
        let uses = Set(counts.keys)
        if let category, category.serves(uses) { return nil }
        let next = AudioCategory.needed(for: uses)
        category = next
        return next
    }

    /// Removes a user that holds the session. It returns true when that was
    /// the last user, so that the session deactivates.
    mutating func remove(_ use: AudioUse) -> Bool {
        guard let count = counts[use] else { return false }
        counts[use] = count > 1 ? count - 1 : nil
        guard counts.isEmpty else { return false }
        category = nil
        return true
    }
}

#if os(iOS)
import AVFoundation

/// The audio session of the iPhone. iOS gives an app the microphone only
/// while its session is active in a category that records. The microphone
/// stream, dictation, and the ring share it through `activate` and
/// `deactivate`, see `AudioUsers`.
public enum AudioSession {
    private static let lock = NSLock()
    /// Guarded by lock.
    private static var users = AudioUsers()

    /// Activates the session for the use, in a category that works for each
    /// use that holds it. Each activate needs 1 `deactivate`.
    public static func activate(_ use: AudioUse) throws {
        try lock.withLock {
            let before = users
            let category = users.add(use)
            do {
                let session = AVAudioSession.sharedInstance()
                if let category { try set(category, on: session) }
                try session.setActive(true)
            } catch {
                users = before
                throw error
            }
        }
    }

    /// Ends the use. The last use deactivates the session, so that other
    /// apps play again.
    public static func deactivate(_ use: AudioUse) {
        lock.withLock {
            guard users.remove(use) else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                FluxLog.plugin.info("the audio session did not stop: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static func set(_ category: AudioCategory, on session: AVAudioSession) throws {
        switch category {
        case .record: try session.setCategory(.record, mode: .measurement)
        case .playAndRecord: try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        case .playback: try session.setCategory(.playback, mode: .default)
        }
    }

    /// The inputs that the microphone stream can record from: the built-in
    /// microphone, a wired headset, or a Bluetooth headset. iOS lists them
    /// for a category that records. When the category does not record and
    /// no use holds the session, this sets the category of the stream,
    /// without activating the session, so other apps keep playing. When a
    /// use holds the session in a category that does not record, such as
    /// the ring, it returns nil, and the list stays as it was.
    static func inputs() -> [MicInput]? {
        lock.withLock {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playAndRecord && session.category != .record {
                guard !users.active else { return nil }
                do {
                    try set(.playAndRecord, on: session)
                } catch {
                    FluxLog.plugin.info("the audio session has no inputs: \(String(describing: error), privacy: .public)")
                    return []
                }
            }
            return (session.availableInputs ?? []).map { MicInput(id: $0.uid, name: $0.portName) }
        }
    }

    /// Records from the input with the ID. An empty ID or an input that is
    /// gone lets iOS pick the input. The session must be active.
    static func prefer(_ id: String) {
        let session = AVAudioSession.sharedInstance()
        let port = id.isEmpty ? nil : session.availableInputs?.first { $0.uid == id }
        // Each change of the input changes the route, and a route change
        // lists the inputs again, so an unchanged input sets nothing.
        guard session.preferredInput?.uid != port?.uid else { return }
        do {
            try session.setPreferredInput(port)
        } catch {
            FluxLog.plugin.info("the microphone input did not change: \(String(describing: error), privacy: .public)")
        }
    }
}
#endif
