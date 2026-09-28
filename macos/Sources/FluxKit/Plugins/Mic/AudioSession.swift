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
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        }
        try session.setActive(true)
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
