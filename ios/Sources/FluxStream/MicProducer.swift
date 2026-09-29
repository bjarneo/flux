import Foundation
import FluxProto
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Microphone live producer (D16): bridges the `MicCapture` tap into the
/// `AsyncStream` chunks a `LiveOffer` serves, plus a level callback for
/// `MicScreen`. The capture throws honestly without hardware/permission
/// (`MicCaptureError.noInput`); the app asks permission first
/// (`MicAccess`) so the error names the fix.
///
/// The chunk source is injectable for tests (`MicCapture` is hardware):
/// production passes the tap, tests a stub.
#if canImport(AVFoundation)
/// Chunk source contract: the production `MicCapture` tap or a test stub.
public protocol MicChunkSource: AnyObject {
    var onChunk: ((Data, Float) -> Void)? { get set }
    func start() throws
    func stop()
}

extension MicCapture: MicChunkSource {}

/// Microphone access gate: the system permission prompt (iOS). Everywhere
/// else the engine start fails honestly on its own (no macOS prompt API
/// for the tap; simulators have no input).
public enum MicAccess {
    public static func request() async -> Bool {
        #if os(iOS)
        await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
        #else
        return true
        #endif
    }
}

/// Owns one capture session: `start` returns the live chunk stream (and
/// throws the capture's error when hardware/permission fails), `stop`
/// ends the tap and finishes the stream. One session at a time — a second
/// `start` stops the first (Android `MicSession.start` parity).
public final class MicProducer {
    /// Level meter 0…1 for `MicScreen` (off the tap thread — the app hops
    /// to main before touching view state).
    public var onLevel: ((Float) -> Void)?

    private let makeCapture: () -> MicChunkSource
    private var capture: MicChunkSource?
    private var continuation: AsyncStream<Data>.Continuation?

    public init(makeCapture: @escaping () -> MicChunkSource = { MicCapture() }) {
        self.makeCapture = makeCapture
    }

    /// Starts the tap and returns the chunk stream. Throws
    /// `MicCaptureError` (or the stub's error) with nothing held.
    public func start() throws -> AsyncStream<Data> {
        stop()
        let capture = makeCapture()
        let (stream, cont) = AsyncStream<Data>.makeStream()
        capture.onChunk = { [weak self] bytes, level in
            cont.yield(bytes)
            if level >= 0 { self?.onLevel?(level) }
        }
        do {
            try capture.start()
        } catch {
            capture.onChunk = nil
            cont.finish()
            throw error
        }
        self.capture = capture
        self.continuation = cont
        return stream
    }

    /// Ends the tap and finishes the stream. Safe before any start.
    public func stop() {
        let capture = capture
        let cont = continuation
        self.capture = nil
        self.continuation = nil
        capture?.onChunk = nil
        capture?.stop()
        cont?.finish()
    }
}
#endif
