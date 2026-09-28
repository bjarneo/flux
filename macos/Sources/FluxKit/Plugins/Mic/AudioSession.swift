#if os(iOS)
import AVFoundation

/// The audio session of the iPhone. iOS gives an app the microphone only
/// while its session is active in a category that records.
enum AudioSession {
    /// Activates the session. With `forRecording`, the session only records,
    /// in measurement mode without voice processing, for dictation. Else it
    /// plays and records for the microphone stream, and keeps the speaker
    /// and Bluetooth headsets.
    static func activate(forRecording: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        if forRecording {
            try session.setCategory(.record, mode: .measurement)
        } else {
            try setStreamCategory(session)
        }
        try session.setActive(true)
    }

    private static func setStreamCategory(_ session: AVAudioSession) throws {
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
    }

    /// The inputs that the microphone stream can record from: the built-in
    /// microphone, a wired headset, or a Bluetooth headset. iOS lists them
    /// for a category that records, so this sets the category of the stream
    /// when the category does not record. It keeps the category of a
    /// dictation, and it does not activate the session, so other apps keep
    /// playing.
    static func inputs() -> [MicInput] {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord && session.category != .record {
            do {
                try setStreamCategory(session)
            } catch {
                FluxLog.plugin.info("the audio session has no inputs: \(String(describing: error), privacy: .public)")
                return []
            }
        }
        return (session.availableInputs ?? []).map { MicInput(id: $0.uid, name: $0.portName) }
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

    /// Deactivates the session, so that other apps play again.
    static func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            FluxLog.plugin.info("the audio session did not stop: \(String(describing: error), privacy: .public)")
        }
    }
}
#endif
