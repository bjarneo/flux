import Foundation
import CoreVideo
import CoreMedia
#if canImport(VideoToolbox)
import VideoToolbox
#endif
#if canImport(Accelerate)
import Accelerate
#endif
#if os(iOS) && canImport(ReplayKit)
import ReplayKit
#endif
#if os(iOS) && canImport(UIKit)
import UIKit
#endif

/// Screen-mirror live producer (app side): bridges the in-app
/// `RPScreenRecorder` capture into the `AsyncStream` chunks a `LiveOffer`
/// serves. Ports Android `screen/ScreenMirrorService.kt` (capture side) to
/// `RPScreenRecorder.startCapture` + the shared `H264VideoEncoder`.
///
/// What runs where:
/// - Capture: `RPScreenRecorder.startCapture` (in-app, foreground-only,
///   free-tier compatible — no broadcast extension needed). Video buffers
///   only; app/mic audio buffers are dropped (the screen protocol carries
///   H.264 video, no audio track).
/// - Frame size: `MirrorScreenSize` fits the screen to `MirrorSize.fit`
///   (long side ≤1080, 16-aligned, so H.264-safe); mismatched frames are
///   vImage-scaled to the announced size, because the desktop fixes its
///   window to the `start` dimensions. Scaling (not cropping) also absorbs
///   a mid-stream rotation.
/// - Encoder: `H264VideoEncoder` at the announced size +
///   `MirrorSize.bitrate`, with a keyframe on connect (Android
///   `onConnected` parity).
/// - Backgrounding ends the stream: the app tears the session down on
///   `.closed` like mic/webcam (background links suspend by design).
///
/// The capture throws honestly without a usable recorder
/// (`ScreenCaptureError.unavailable` on simulator/macOS, where
/// `isAvailable` is false); the app surfaces the message on `MirrorScreen`.
/// The chunk source is injectable for tests (the recorder + encoder are
/// hardware): production passes the drain, tests a stub. Device proof is
/// open (like the D16 webcam arc was before hardware).
public enum MirrorScreenSize {
    /// The announced encoder size for a native screen of
    /// `nativeWidth` × `nativeHeight` pixels (`MirrorSize.fit`: same shape,
    /// long side ≤1080, 16-aligned).
    public static func announce(nativeWidth: Int, nativeHeight: Int) -> (Int, Int) {
        MirrorSize.fit(width: nativeWidth, height: nativeHeight)
    }

    /// The bitrate for an announced size (screen text needs more bits than
    /// a camera image).
    public static func bitrate(width: Int, height: Int) -> Int {
        MirrorSize.bitrate(width: width, height: height)
    }

    /// The announced size for this phone's screen. MainActor (reads
    /// `UIScreen.main`, which is main-actor-isolated on the iOS SDK);
    /// off-iOS a fixed fallback (the producer throws `unsupported` there
    /// before the size matters).
    @MainActor
    public static func current() -> (Int, Int) {
        #if os(iOS) && canImport(UIKit)
        let bounds = UIScreen.main.nativeBounds
        return announce(nativeWidth: Int(bounds.width), nativeHeight: Int(bounds.height))
        #else
        return announce(nativeWidth: 1280, nativeHeight: 720)
        #endif
    }
}

/// Chunk source contract: the production `ScreenCapture` drain or a test stub.
public protocol ScreenChunkSource: AnyObject {
    var onChunk: ((Data) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func start(width: Int, height: Int, bitrate: Int) throws
    func stop()
}

/// Owns one capture session: `start` returns the live chunk stream (and
/// throws the capture's error when the recorder is unavailable), `stop`
/// ends the capture and finishes the stream. One session at a time — a
/// second `start` stops the first (Android session `start` parity).
///
/// `start` blocks briefly (it waits for the recorder's completion, at most
/// a few seconds), so the app calls it off-main; every other method runs on
/// the main thread. Cross-thread callbacks (the capture handler, the
/// encoder) only touch the `AsyncStream` continuation (Sendable) and the
/// main-hopped `onError`, never this object's state.
public final class ScreenProducer: @unchecked Sendable {
    /// Fatal capture/encoder failures mid-stream (the app ends the session
    /// with an announced stop, Android encoder-error parity).
    public var onError: ((String) -> Void)?

    private let makeSource: () -> ScreenChunkSource
    private var source: ScreenChunkSource?
    private var continuation: AsyncStream<Data>.Continuation?

    public init(makeSource: @escaping () -> ScreenChunkSource = { ScreenProducer.defaultSource() }) {
        self.makeSource = makeSource
    }

    /// The production source per platform (a throwing stub where
    /// `RPScreenRecorder` does not exist).
    public static func defaultSource() -> ScreenChunkSource {
        #if os(iOS) && canImport(ReplayKit)
        return ScreenCapture()
        #else
        return UnsupportedScreenCapture()
        #endif
    }

    /// Starts the capture and returns the chunk stream. Throws
    /// `ScreenCaptureError` (or the stub's error) with nothing held.
    /// Call off the main thread (it waits for the recorder to answer).
    public func start(width: Int, height: Int, bitrate: Int) throws -> AsyncStream<Data> {
        stop()
        let source = makeSource()
        let (stream, cont) = AsyncStream<Data>.makeStream()
        source.onChunk = { cont.yield($0) }
        source.onError = { [weak self] message in self?.onError?(message) }
        do {
            try source.start(width: width, height: height, bitrate: bitrate)
        } catch {
            source.onChunk = nil
            source.onError = nil
            cont.finish()
            throw error
        }
        self.source = source
        self.continuation = cont
        return stream
    }

    /// Ends the capture and finishes the stream. Safe before any start.
    public func stop() {
        let source = source
        let cont = continuation
        self.source = nil
        self.continuation = nil
        source?.onChunk = nil
        source?.onError = nil
        source?.stop()
        cont?.finish()
    }
}

/// Honest errors from the screen capture path.
public enum ScreenCaptureError: Error, Equatable {
    /// No usable recorder (simulator/macOS, or a phone that reports
    /// unavailable). The message names the fix.
    case unavailable(String)
    /// The recorder refused to start, or died mid-stream.
    case failed(String)
    /// This platform has no `RPScreenRecorder` at all.
    case unsupported(String)
}

#if os(iOS) && canImport(ReplayKit)
/// Drains `RPScreenRecorder` video buffers through the shared
/// `H264VideoEncoder` into Annex-B chunks. One instance per `start`;
/// `stop` tears everything down.
public final class ScreenCapture: NSObject, ScreenChunkSource, @unchecked Sendable {
    public var onChunk: ((Data) -> Void)?
    public var onError: ((String) -> Void)?

    private let lock = NSLock()
    private var recorder: RPScreenRecorder?
    private var encoder: H264VideoEncoder?
    private var width = 0
    private var height = 0
    private var stopped = false

    public override init() {}

    public func start(width: Int, height: Int, bitrate: Int) throws {
        stop()
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            throw ScreenCaptureError.unavailable("Screen mirror is not available on this phone right now.")
        }
        recorder.isMicrophoneEnabled = false
        let encoder = H264VideoEncoder()
        encoder.onFrame = { [weak self] bytes, _ in self?.onChunk?(bytes) }
        encoder.onError = { [weak self] message in self?.onError?(message) }
        do {
            try encoder.configure(width: width, height: height, bitrate: bitrate)
        } catch {
            encoder.invalidate()
            throw ScreenCaptureError.failed("The video encoder did not start (\(error)).")
        }
        encoder.requestKeyFrame()
        lock.withLock {
            self.recorder = recorder
            self.encoder = encoder
            self.width = width
            self.height = height
            self.stopped = false
        }
        // The recorder answers async; wait for it (bounded) so a refusal
        // throws here instead of starting a stream that immediately dies.
        // `start` runs off-main (the producer contract), so this wait
        // never blocks the UI.
        let done = DispatchSemaphore(value: 0)
        var startError: Error?
        recorder.startCapture(
            handler: { [weak self] sample, type, error in
                self?.receive(sample: sample, type: type, error: error)
            },
            completionHandler: { error in
                startError = error
                done.signal()
            })
        _ = done.wait(timeout: .now() + 5)
        if let startError {
            stop()
            throw ScreenCaptureError.failed("Screen mirror could not start (\(startError)).")
        }
    }

    public func stop() {
        let (recorder, encoder): (RPScreenRecorder?, H264VideoEncoder?) = lock.withLock {
            self.stopped = true
            let r = (self.recorder, self.encoder)
            self.recorder = nil
            self.encoder = nil
            return r
        }
        if let recorder { recorder.stopCapture { _ in } }
        encoder?.invalidate()
    }

    private func receive(sample: CMSampleBuffer, type: RPSampleBufferType, error: Error?) {
        if let error {
            onError?("Screen mirror stopped (\(error)).")
            return
        }
        guard type == .video else { return }
        let (encoder, width, height, dead): (H264VideoEncoder?, Int, Int, Bool) = lock.withLock {
            (self.encoder, self.width, self.height, self.stopped)
        }
        guard let encoder, !dead else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let buffer = ScreenScaler.frameForEncode(pixelBuffer, width: width, height: height)
            ?? pixelBuffer
        // A frame the encoder rejects is dropped (like the webcam drain):
        // the stream stays alive, the desktop shows the next good frame.
        try? encoder.encode(buffer, presentationTime: CMSampleBufferGetPresentationTimeStamp(sample))
    }
}
#else
/// Stand-in where `RPScreenRecorder` does not exist (macOS, simulator
/// builds without ReplayKit): every start throws honestly.
public final class UnsupportedScreenCapture: ScreenChunkSource {
    public var onChunk: ((Data) -> Void)?
    public var onError: ((String) -> Void)?

    public init() {}

    public func start(width: Int, height: Int, bitrate: Int) throws {
        throw ScreenCaptureError.unsupported("Screen mirror needs an iPhone.")
    }

    public func stop() {}
}
#endif

/// Screen frame sizing (ungated so the math runs in tests on macOS:
/// the recorder itself is iOS-only, the buffers are not).
public enum ScreenScaler {
    /// Returns the buffer to encode: the screen frame when it already
    /// matches the announced size, else a scale to it. Unlike the camera
    /// crop (which drops smaller frames — the camera cannot upscale), the
    /// screen always scales: a rotation mid-stream swaps the frame shape,
    /// and the desktop window stays fixed at the announced size.
    public static func frameForEncode(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        if w == width, h == height { return pixelBuffer }
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        return scaled(pixelBuffer, toWidth: width, toHeight: height)
    }

    /// Scales a BGRA buffer to an exact size with vImage (channel order is
    /// irrelevant to the scale, so ARGB8888 covers BGRA).
    public static func scaled(_ src: CVPixelBuffer, toWidth w: Int, toHeight h: Int) -> CVPixelBuffer? {
        #if canImport(Accelerate)
        guard w > 0, h > 0 else { return nil }
        let srcW = CVPixelBufferGetWidth(src)
        let srcH = CVPixelBufferGetHeight(src)
        guard srcW > 0, srcH > 0 else { return nil }
        var dst: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, w, h,
            kCVPixelFormatType_32BGRA, nil, &dst) == kCVReturnSuccess,
            let dst
        else { return nil }
        CVPixelBufferLockBaseAddress(src, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
        CVPixelBufferLockBaseAddress(dst, [])
        defer { CVPixelBufferUnlockBaseAddress(dst, []) }
        guard let s = CVPixelBufferGetBaseAddress(src), let d = CVPixelBufferGetBaseAddress(dst) else { return nil }
        var srcBuf = vImage_Buffer(
            data: s, height: vImagePixelCount(srcH),
            width: vImagePixelCount(srcW),
            rowBytes: CVPixelBufferGetBytesPerRow(src))
        var dstBuf = vImage_Buffer(
            data: d, height: vImagePixelCount(h),
            width: vImagePixelCount(w),
            rowBytes: CVPixelBufferGetBytesPerRow(dst))
        guard vImageScale_ARGB8888(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            return nil
        }
        return dst
        #else
        return nil
        #endif
    }
}
