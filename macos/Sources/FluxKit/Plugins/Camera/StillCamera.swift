import AVFoundation
import Foundation

/// The camera access of Flux.
public enum CameraAccess: Sendable {
    case notDetermined, denied, authorized

    public static var current: CameraAccess {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// Asks for the camera when macOS has not asked yet.
    public static func request() async -> CameraAccess {
        if current == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .video) }
        return current
    }
}

/// One camera of this Mac: built in, Continuity Camera, or external.
public struct CameraChoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
}

/// The camera of the camera modes. It shows a live preview, gives live frames
/// for Vision, and takes full-quality photos. A private queue owns the
/// capture session, so a slow camera never blocks the caller.
public final class StillCamera: NSObject, @unchecked Sendable {
    /// The cameras of this Mac, built-in cameras first.
    public static func cameras() -> [CameraChoice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external]
        // Without this Info.plist key, Continuity Camera reports itself as a
        // built-in camera and the first type finds it.
        if Bundle.main.object(forInfoDictionaryKey: "NSCameraUseContinuityCameraDeviceType") as? Bool == true {
            types.append(.continuityCamera)
        }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        func rank(_ d: AVCaptureDevice) -> Int { d.deviceType == .builtInWideAngleCamera && !d.isContinuityCamera ? 0 : 1 }
        return devices.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map { CameraChoice(id: $0.element.uniqueID, name: $0.element.localizedName) }
    }

    public let session = AVCaptureSession()
    /// The preview. It fills its bounds and cuts off the overflow.
    public let previewLayer: AVCaptureVideoPreviewLayer

    private let queue = DispatchQueue(label: "org.omarchy.flux.stillcamera")
    private let frameQueue = DispatchQueue(label: "org.omarchy.flux.stillcamera.frames")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()

    // Owned by the queue.
    private var input: AVCaptureDeviceInput?
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var observations: [NSKeyValueObservation] = []

    private let lock = NSLock()
    private var onFrame: (@Sendable (CVPixelBuffer) -> Void)?
    private var captures: Set<PhotoCapture> = []

    public override init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        super.init()
        session.beginConfiguration()
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        session.commitConfiguration()
    }

    /// Receives each live frame on a private queue. Nil stops the frames.
    public func setFrameHandler(_ handler: (@Sendable (CVPixelBuffer) -> Void)?) {
        lock.withLock { onFrame = handler }
        queue.async { [self] in updateFrames() }
    }

    /// Starts the camera with the ID, or the first camera when that camera
    /// is gone. It returns the camera that runs.
    @discardableResult
    public func start(_ id: String?) async throws -> CameraChoice {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<CameraChoice, Error>) in
            queue.async { [self] in c.resume(with: Result { try startNow(id) }) }
        }
    }

    /// Stops the camera. The camera light goes off.
    public func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Takes a photo and returns it as JPEG data with its metadata.
    public func capturePhoto() async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            queue.async { [self] in
                guard session.isRunning, photoOutput.connection(with: .video) != nil else {
                    return c.resume(throwing: FluxError("The camera is not running"))
                }
                let settings = photoOutput.availablePhotoCodecTypes.contains(.jpeg)
                    ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                    : AVCapturePhotoSettings()
                if photoOutput.maxPhotoDimensions.width > 0 { settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions }
                let capture = PhotoCapture { [weak self] capture, result in
                    self?.lock.withLock { _ = self?.captures.remove(capture) }
                    c.resume(with: result)
                }
                lock.withLock { _ = captures.insert(capture) }
                photoOutput.capturePhoto(with: settings, delegate: capture)
            }
        }
    }

    private func startNow(_ id: String?) throws -> CameraChoice {
        let choices = Self.cameras()
        guard let choice = choices.first(where: { $0.id == id }) ?? choices.first,
              let device = AVCaptureDevice(uniqueID: choice.id) else { throw FluxError("No camera found") }
        if input?.device.uniqueID != device.uniqueID {
            let newInput = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            if let input { session.removeInput(input) }
            session.sessionPreset = .high
            guard session.canAddInput(newInput) else {
                session.commitConfiguration()
                input = nil
                throw FluxError("Cannot open \(choice.name)")
            }
            session.addInput(newInput)
            if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
            input = newInput
            photoOutput.maxPhotoDimensions = device.activeFormat.supportedMaxPhotoDimensions
                .max { $0.width * $0.height < $1.width * $1.height } ?? photoOutput.maxPhotoDimensions
            session.commitConfiguration()
            followRotation(device)
            updateFrames()
        }
        if !session.isRunning { session.startRunning() }
        guard session.isRunning else { throw FluxError("Cannot start \(choice.name)") }
        return choice
    }

    /// Turns the video output on only while a frame handler is set. Without
    /// a handler, the camera converts no frames to BGRA. A new input gives a
    /// new connection, so it runs again after each camera change. It runs on
    /// the queue.
    private func updateFrames() {
        let wanted = lock.withLock { onFrame != nil }
        videoOutput.connection(with: .video)?.isEnabled = wanted
    }

    /// Keeps photos, frames, and the preview upright, for example when a
    /// Continuity Camera iPhone turns.
    private func followRotation(_ device: AVCaptureDevice) {
        observations.removeAll()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        self.coordinator = coordinator
        let apply = { [weak self] in
            guard let self, let coordinator = self.coordinator else { return }
            let capture = coordinator.videoRotationAngleForHorizonLevelCapture
            for connection in [photoOutput.connection(with: .video), videoOutput.connection(with: .video)].compactMap({ $0 })
            where connection.isVideoRotationAngleSupported(capture) {
                connection.videoRotationAngle = capture
            }
            let preview = coordinator.videoRotationAngleForHorizonLevelPreview
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(preview) {
                connection.videoRotationAngle = preview
            }
        }
        apply()
        observations = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture) { [weak self] _, _ in self?.queue.async(execute: apply) },
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview) { [weak self] _, _ in self?.queue.async(execute: apply) },
        ]
    }
}

extension StillCamera: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let handler = lock.withLock({ onFrame }), let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        handler(frame)
    }
}

/// The delegate of 1 photo. It reports the JPEG data or the error once.
private final class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let done: (PhotoCapture, Result<Data, Error>) -> Void

    init(done: @escaping (PhotoCapture, Result<Data, Error>) -> Void) {
        self.done = done
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            done(self, .failure(error))
        } else if let data = photo.fileDataRepresentation() {
            done(self, .success(data))
        } else {
            done(self, .failure(FluxError("The camera returned no photo")))
        }
    }
}
