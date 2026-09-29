import Foundation

/// Stream stubs. `AVAudioEngine` mic + ReplayKit broadcast extension land in M5.
public enum FluxStream {
    /// Mic framing matches Android `mic/MicSession.kt`: PCM 48 kHz mono.
    public static let micSampleRate = 48_000
    public static let micChannels = 1
}
