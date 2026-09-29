import Foundation
import FluxProto
import FluxCamera
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Webcam live producer (D16): bridges the camera drain into the
/// `AsyncStream` chunks a `LiveOffer` serves. Ports Android
/// `webcam/WebcamController.kt` (camera side) + `CameraSource.kt` (device
/// choice + controls) to `AVCaptureSession` + the shared `H264VideoEncoder`.
///
/// What runs where:
/// - Device choice: back/front wide-angle camera from `WebcamConfig.camera`
///   (Android `CameraSource.choose`); switching cameras re-seats the input
///   without restarting the stream or the encoder.
/// - Frame size: the session preset matches the config's short side
///   (720p/1080p, both native on modern iPhones); non-16:9 aspects are
///   center-cropped to the announced size, because the desktop fixes its
///   virtual camera to the `start` dimensions.
/// - Encoder: `H264VideoEncoder` at the announced size + `bitrateFor`, with
///   a keyframe on connect (Android `onConnected` parity).
/// - Live controls: zoom, exposure bias, white balance, and the mirror flag
///   apply without a restart; a frame-size change needs one (the app
///   restarts via `restartsStream`, Android `apply` parity).
///
/// Color-matrix keys (`brightness`/`contrast`/`saturation`/`warmth`) are
/// stored and reported in the `config` packet but have no `AVCapture`
/// control in v1 — Android applies them in its GL renderer, which iOS does
/// not port. A desktop `set` of those keys is kept (not rejected) and shows
/// on the PHONE CAMERA card; the image is unchanged.
///
/// The capture throws honestly without hardware/permission
/// (`WebcamCaptureError.noCamera`); the app asks permission first
/// (`CameraAccess`) so the error names the fix. The chunk source is
/// injectable for tests (the session + encoder are hardware): production
/// passes the drain, tests a stub.
#if canImport(AVFoundation)
/// Chunk source contract: the production `WebcamCapture` drain or a test stub.
public protocol WebcamChunkSource: AnyObject {
    var onChunk: ((Data) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func start(config: WebcamConfig) throws
    func stop()
    /// Applies image/camera changes without restarting the stream.
    /// Geometry changes are ignored here (the caller restarts instead).
    func applyLive(_ config: WebcamConfig)
    /// What the current camera supports (feeds the `config` packet caps).
    func currentCaps() -> WebcamCaps
}

/// Camera access gate: the system permission prompt (iOS). Everywhere else
/// the capture start fails honestly on its own (no macOS prompt API;
/// simulators have no camera).
public enum CameraAccess {
    public static func request() async -> Bool {
        #if os(iOS)
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .video) { granted in
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
/// ends the drain and finishes the stream. One session at a time — a second
/// `start` stops the first (Android `WebcamSession.start` parity).
///
/// `start` blocks briefly (`startRunning`), so the app calls it off-main;
/// every other method runs on the main thread. Cross-thread callbacks (the
/// drain, the encoder) only touch the `AsyncStream` continuation (Sendable)
/// and the main-hopped `onError`, never this object's state.
public final class WebcamProducer: @unchecked Sendable {
    /// Fatal capture/encoder failures mid-stream (the app ends the session
    /// with an announced stop, Android encoder-error parity).
    public var onError: ((String) -> Void)?

    private let makeSource: () -> WebcamChunkSource
    private var source: WebcamChunkSource?
    private var continuation: AsyncStream<Data>.Continuation?

    public init(makeSource: @escaping () -> WebcamChunkSource = { WebcamCapture() }) {
        self.makeSource = makeSource
    }

    /// Starts the drain and returns the chunk stream. Throws
    /// `WebcamCaptureError` (or the stub's error) with nothing held.
    /// Call off the main thread (`startRunning` blocks briefly).
    public func start(config: WebcamConfig) throws -> AsyncStream<Data> {
        stop()
        let source = makeSource()
        let (stream, cont) = AsyncStream<Data>.makeStream()
        source.onChunk = { cont.yield($0) }
        source.onError = { [weak self] message in self?.onError?(message) }
        do {
            try source.start(config: config)
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

    /// Ends the drain and finishes the stream. Safe before any start.
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

    /// Applies image/camera changes to the running drain, if any.
    public func applyLive(_ config: WebcamConfig) {
        source?.applyLive(config)
    }

    /// Caps for the `config` packet (`.loose` when idle).
    public func currentCaps() -> WebcamCaps {
        source?.currentCaps() ?? .loose
    }
}

/// Drains `AVCaptureVideoDataOutput` BGRA frames through the shared
/// `H264VideoEncoder` into Annex-B chunks. One instance per `start` (a
/// fresh session each time, so a camera switch never inherits stale
/// inputs); `stop` tears everything down.
public final class WebcamCapture: NSObject, WebcamChunkSource, @unchecked Sendable {
    public var onChunk: ((Data) -> Void)?
    public var onError: ((String) -> Void)?

    private let lock = NSLock()
    private var session: AVCaptureSession?
    private var device: AVCaptureDevice?
    private var encoder: H264VideoEncoder?
    private var config = WebcamConfig()
    private let videoQueue = DispatchQueue(label: "org.omarchy.flux.webcam-drain")

    public override init() {}

    public func start(config: WebcamConfig) throws {
        stop()
        guard let device = WebcamCapture.device(front: config.camera == "front") else {
            throw WebcamCaptureError.noCamera("This phone has no usable camera")
        }
        let session = AVCaptureSession()
        session.beginConfiguration()
        let preset: AVCaptureSession.Preset = config.resolution >= 1080 ? .hd1920x1080 : .hd1280x720
        guard session.canSetSessionPreset(preset) else {
            session.commitConfiguration()
            throw WebcamCaptureError.noCamera("This camera cannot stream \(config.width)×\(config.height)")
        }
        session.sessionPreset = preset
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw WebcamCaptureError.noCamera("This camera cannot stream \(config.width)×\(config.height)")
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw WebcamCaptureError.noCamera("This camera cannot stream \(config.width)×\(config.height)")
        }
        session.addOutput(output)
        session.commitConfiguration()
        applyControls(device: device, config: config, connection: output.connection(with: .video))
        let encoder = H264VideoEncoder()
        encoder.onFrame = { [weak self] bytes, _ in self?.onChunk?(bytes) }
        encoder.onError = { [weak self] message in self?.onError?(message) }
        try encoder.configure(width: config.width, height: config.height, bitrate: config.bitrate)
        encoder.requestKeyFrame()
        lock.withLock {
            self.session = session
            self.device = device
            self.encoder = encoder
            self.config = config
        }
        session.startRunning()
    }

    public func stop() {
        let (session, encoder): (AVCaptureSession?, H264VideoEncoder?) = lock.withLock {
            let r = (self.session, self.encoder)
            self.session = nil
            self.device = nil
            self.encoder = nil
            return r
        }
        if let session, session.isRunning { session.stopRunning() }
        encoder?.invalidate()
    }

    public func applyLive(_ config: WebcamConfig) {
        let (session, device, connection): (AVCaptureSession?, AVCaptureDevice?, AVCaptureConnection?) = lock.withLock {
            self.config = config
            let output = self.session?.outputs.compactMap { $0 as? AVCaptureVideoDataOutput }.first
            return (self.session, self.device, output?.connection(with: .video))
        }
        guard let session, let device else { return }
        if (config.camera == "front") != (device.position == .front),
           let next = WebcamCapture.device(front: config.camera == "front")
        {
            session.beginConfiguration()
            if let old = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first {
                session.removeInput(old)
            }
            if let input = try? AVCaptureDeviceInput(device: next), session.canAddInput(input) {
                session.addInput(input)
                lock.withLock { self.device = next }
                applyControls(device: next, config: config, connection: connection)
            } else if let old = try? AVCaptureDeviceInput(device: device), session.canAddInput(old) {
                session.addInput(old)
            }
            session.commitConfiguration()
        } else {
            applyControls(device: device, config: config, connection: connection)
        }
    }

    public func currentCaps() -> WebcamCaps {
        let devices = WebcamCapture.cameras()
        let cameras = devices.map { $0.position == .front ? "front" : "back" }
        var caps = WebcamCaps.loose
        caps.cameras = cameras.isEmpty ? ["back"] : cameras
        if let device = lock.withLock({ self.device }) {
            #if os(iOS)
            caps.zoomMax = max(1, Float(device.maxAvailableVideoZoomFactor))
            caps.exposureMin = device.minExposureTargetBias
            caps.exposureMax = device.maxExposureTargetBias
            #endif
            var wb = ["auto"]
            if device.isWhiteBalanceModeSupported(.locked) { wb += ["locked"] }
            caps.whiteBalance = wb
        }
        return caps
    }

    // MARK: - Devices

    private static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video, position: .unspecified
        ).devices
    }

    private static func device(front: Bool) -> AVCaptureDevice? {
        cameras().first { ($0.position == .front) == front }
    }

    // MARK: - Controls

    /// Applies the live subset (zoom/exposure/WB/mirror/focus). Geometry is
    /// the caller's job (restart). Best-effort: unsupported locks fail
    /// silently, the stored config still round-trips to the desktop.
    private func applyControls(device: AVCaptureDevice, config: WebcamConfig, connection: AVCaptureConnection?) {        if let connection, connection.isVideoMirroringSupported {
            connection.isVideoMirrored = config.mirror
        }
        do {
            try device.lockForConfiguration()
        } catch {
            return
        }
        defer { device.unlockForConfiguration() }
        #if os(iOS)
        let zoomMax = max(1, device.maxAvailableVideoZoomFactor)
        let want = min(max(CGFloat(config.zoom), 1), zoomMax)
        if device.videoZoomFactor != want { device.videoZoomFactor = want }
        #endif
        if config.exposure == 0 {
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        } else if device.isExposureModeSupported(.locked) {
            #if os(iOS)
            let lo = min(device.minExposureTargetBias, device.maxExposureTargetBias)
            let hi = max(device.minExposureTargetBias, device.maxExposureTargetBias)
            device.setExposureTargetBias(config.exposure.clamped(to: lo...hi), completionHandler: nil)
            #endif
            device.exposureMode = .locked
        }
        if config.whiteBalance == "auto" {
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        } else if device.isWhiteBalanceModeSupported(.locked) {
            device.whiteBalanceMode = .locked
        }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
    }
}

extension WebcamCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let (encoder, config): (H264VideoEncoder?, WebcamConfig) = lock.withLock { (self.encoder, self.config) }
        guard let encoder else { return }
        let buffer = WebcamCapture.frameForEncode(pixelBuffer, config: config) ?? pixelBuffer
        try? encoder.encode(buffer, presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}

extension WebcamCapture {
    /// Returns the buffer to encode: the camera frame when it already
    /// matches the announced size, else a center crop to it. The desktop
    /// fixes its virtual camera to the `start` dimensions, so anything else
    /// would corrupt its pipeline.
    static func frameForEncode(_ pixelBuffer: CVPixelBuffer, config: WebcamConfig) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        if w == config.width, h == config.height { return pixelBuffer }
        guard config.width <= w, config.height <= h,
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA
        else { return nil }
        return cropCenter(pixelBuffer, toWidth: config.width, toHeight: config.height)
    }

    /// Center-crops a BGRA buffer with plain row copies (no Accelerate
    /// dependency for a path that runs at most once per stream start per
    /// frame — a 720p copy is sub-millisecond).
    static func cropCenter(_ src: CVPixelBuffer, toWidth w: Int, toHeight h: Int) -> CVPixelBuffer? {
        let srcW = CVPixelBufferGetWidth(src)
        let srcH = CVPixelBufferGetHeight(src)
        guard w <= srcW, h <= srcH, w > 0, h > 0 else { return nil }
        let ox = ((srcW - w) / 2) & ~1
        let oy = ((srcH - h) / 2) & ~1
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
        let srcRow = CVPixelBufferGetBytesPerRow(src)
        let dstRow = CVPixelBufferGetBytesPerRow(dst)
        let copyBytes = w * 4
        for row in 0..<h {
            let from = s.advanced(by: (oy + row) * srcRow + ox * 4)
            let to = d.advanced(by: row * dstRow)
            to.copyMemory(from: from, byteCount: copyBytes)
        }
        return dst
    }
}

public enum WebcamCaptureError: Error, Equatable {
    case noCamera(String)
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
#endif
