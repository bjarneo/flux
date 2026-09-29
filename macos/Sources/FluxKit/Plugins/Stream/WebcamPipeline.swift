import CoreImage
import Foundation

/// Connects the camera, the renderer, and the encoder for the webcam. All
/// frame work runs on 1 queue. While no encoder runs, the frames only feed
/// the preview. The preview renders only while a view shows it.
final class WebcamPipeline: @unchecked Sendable {
    /// Every 5th frame goes to the preview: 6 images per second.
    private static let previewEvery = 5

    private let frames = DispatchQueue(label: "org.omarchy.flux.webcam.frames", qos: .userInteractive)
    private let renderer = FrameRenderer()
    private let onPreview: @Sendable (CGImage) -> Void
    private var camera: CameraSource!

    private let lock = NSLock()
    private var look = FrameRenderer.Look()
    private var width = 1280
    private var height = 720
    private var encoder: H264Encoder?
    private var sink: VideoSink?
    /// The number of views that show the preview.
    private var previewViews = 0

    /// Owned by the frame queue.
    private var frameCount = 0

    init(onPreview: @escaping @Sendable (CGImage) -> Void, onCameraError: @escaping @Sendable (String) -> Void) {
        self.onPreview = onPreview
        camera = CameraSource(frames: frames, onFrame: { [unowned self] buffer, rotation in
            frame(buffer, rotation: rotation)
        }, onError: onCameraError)
    }

    #if os(iOS)
    /// Runs when the camera runs again after an interruption.
    func onCameraResume(_ body: @escaping @Sendable () -> Void) {
        camera.onResume = body
    }
    #endif

    /// Applies the image settings at once. The frame size applies to the
    /// preview at once and to the stream with the next encoder.
    func apply(_ config: WebcamConfig) {
        lock.withLock {
            look = FrameRenderer.Look(
                mirror: config.mirror, zoom: config.zoom, exposure: config.exposure,
                color: ColorAdjust(brightness: config.brightness, contrast: config.contrast, saturation: config.saturation, warmth: config.warmth)
            )
            width = config.width
            height = config.height
        }
    }

    var isCameraOpen: Bool { camera.isOpen }

    /// Opens camera for the stream attempt owner.
    func openCamera(_ info: CameraInfo, shortSide: Int, owner: Int) async throws {
        try await camera.open(info, shortSide: shortSide, owner: owner)
    }

    /// Switches the open camera to info. It does nothing when no camera is open.
    func switchCamera(_ info: CameraInfo, shortSide: Int) async throws {
        try await camera.switchTo(info, shortSide: shortSide)
    }

    /// Stops the camera when the stream attempt owner opened it last.
    func closeCamera(owner: Int) {
        camera.close(owner: owner)
    }

    /// Starts to encode frames of width x height into sink.
    func startEncoder(width: Int, height: Int, bitrate: Int, sink: VideoSink, onError: @escaping @Sendable (String) -> Void) throws {
        let encoder = try H264Encoder(
            width: width, height: height, bitrate: bitrate, backlogged: { [sink] in sink.backlogged },
            output: { [sink] bytes in sink.push(bytes) }, onError: onError
        )
        let old = lock.withLock { () -> H264Encoder? in
            defer { self.encoder = encoder; self.sink = sink }
            return self.encoder
        }
        old?.release()
    }

    func stopEncoder() {
        let old = lock.withLock { () -> H264Encoder? in
            defer { encoder = nil; sink = nil }
            return encoder
        }
        old?.release()
    }

    /// Asks for an IDR frame now, for example after a camera switch.
    func requestKeyFrame() {
        lock.withLock { encoder }?.requestKeyFrame()
    }

    /// Counts the views that show the preview. A count keeps the preview on
    /// when a new view appears before the old view disappears.
    func setPreviewShown(_ shown: Bool) {
        lock.withLock { previewViews = max(0, previewViews + (shown ? 1 : -1)) }
    }

    private func frame(_ buffer: CVPixelBuffer, rotation: Int) {
        let (look, width, height, encoder, sink, previewWanted) = lock.withLock { () -> (FrameRenderer.Look, Int, Int, H264Encoder?, VideoSink?, Bool) in
            (self.look, self.width, self.height, self.encoder, self.sink, self.previewViews > 0)
        }
        frameCount += 1
        let wantsPreview = previewWanted && frameCount % Self.previewEvery == 0
        let sending = encoder != nil && sink?.backlogged == false
        guard sending || wantsPreview else { return }
        // The encoder keeps its size until the next stream, so the stream
        // never changes size in the middle.
        let w = encoder?.width ?? width
        let h = encoder?.height ?? height
        let image = renderer.image(buffer, width: w, height: h, rotation: rotation, look: look)
        if sending, let encoder, let out = renderer.render(image, width: w, height: h) {
            encoder.encode(out)
        }
        if wantsPreview, let preview = renderer.preview(image, maxWidth: 480) {
            onPreview(preview)
        }
    }
}
