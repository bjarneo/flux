import AVFoundation

/// One camera of this Mac: built in, Continuity Camera, or external.
public struct CameraInfo: Sendable, Hashable, Identifiable {
    /// The camera in the protocol: its name in lower case. The computer
    /// lists it and sends it back in the "camera" setting.
    public let id: String
    public let uniqueID: String
    public let name: String
    public let isContinuity: Bool
}

/// Captures 1 camera with AVFoundation. Each frame goes to onFrame on the
/// frame queue, with the clockwise rotation that makes it upright. Callers
/// set the wanted camera, and a private queue brings the capture to the last
/// wanted state, so calls from different streams cannot leave the camera on
/// and a slow camera never blocks the caller.
final class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let frames: DispatchQueue
    private let control = DispatchQueue(label: "org.omarchy.flux.camera.control")
    private let onFrame: (CVPixelBuffer, Int) -> Void
    private let onError: @Sendable (String) -> Void

    // Owned by the control queue.
    private var session: AVCaptureSession?
    private var device: AVCaptureDevice?
    private var shortSide = 0
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var observers: [NSObjectProtocol] = []
    private var rotationObservation: NSKeyValueObservation?

    private struct Want {
        let camera: CameraInfo
        let shortSide: Int
        let owner: Int
    }

    private let lock = NSLock()
    private var desired: Want?
    private var rotation = 0

    init(frames: DispatchQueue, onFrame: @escaping (CVPixelBuffer, Int) -> Void, onError: @escaping @Sendable (String) -> Void) {
        self.frames = frames
        self.onFrame = onFrame
        self.onError = onError
    }

    /// The video devices that Flux can stream, built-in cameras first.
    static func available() -> [CameraInfo] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external]
        // Without this Info.plist key, Continuity Camera reports itself as a
        // built-in camera and the first type finds it.
        if Bundle.main.object(forInfoDictionaryKey: "NSCameraUseContinuityCameraDeviceType") as? Bool == true {
            types.append(.continuityCamera)
        }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        func rank(_ d: AVCaptureDevice) -> Int {
            if d.isContinuityCamera { return 1 }
            return d.deviceType == .builtInWideAngleCamera ? 0 : 2
        }
        var seen: [String: Int] = [:]
        return devices.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map { _, d in
                let name = d.localizedName.trimmingCharacters(in: .whitespaces)
                let key = name.lowercased()
                let n = (seen[key] ?? 0) + 1
                seen[key] = n
                let label = n == 1 ? name : "\(name) \(n)"
                return CameraInfo(id: label.lowercased(), uniqueID: d.uniqueID, name: label, isContinuity: d.isContinuityCamera)
            }
    }

    /// Asks for the camera permission when macOS has not asked yet.
    static func authorize() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .video) { return }
        default:
            break
        }
        throw FluxError(accessMessage)
    }

    static let accessMessage = "Flux has no access to the camera. Allow Flux in System Settings, Privacy & Security, Camera."

    static var accessDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return status == .denied || status == .restricted
    }

    /// Opens camera for owner, or switches to it, with a format that covers
    /// shortSide pixels on its short side at 30 frames per second. It returns
    /// when the camera runs, or when a later call replaced this one.
    func open(_ camera: CameraInfo, shortSide: Int, owner: Int) async throws {
        lock.withLock { desired = Want(camera: camera, shortSide: shortSide, owner: owner) }
        try await reconcile()
    }

    /// Switches the open camera to camera. It does nothing when no camera is open.
    func switchTo(_ camera: CameraInfo, shortSide: Int) async throws {
        let open = lock.withLock { () -> Bool in
            guard let owner = desired?.owner else { return false }
            desired = Want(camera: camera, shortSide: shortSide, owner: owner)
            return true
        }
        if open { try await reconcile() }
    }

    /// Stops the camera when owner opened it last.
    func close(owner: Int) {
        let closed = lock.withLock { () -> Bool in
            guard desired?.owner == owner else { return false }
            desired = nil
            return true
        }
        if closed { control.async { try? self.apply() } }
    }

    var isOpen: Bool { lock.withLock { desired != nil } }

    private func reconcile() async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            control.async {
                do {
                    try self.apply()
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    /// Brings the camera to the last wanted state. It runs on the control queue.
    private func apply() throws {
        guard let want = lock.withLock({ desired }) else {
            closeNow()
            return
        }
        do {
            try openNow(want.camera, shortSide: want.shortSide)
        } catch {
            closeNow()
            throw error
        }
    }

    private func openNow(_ camera: CameraInfo, shortSide: Int) throws {
        if device?.uniqueID == camera.uniqueID, self.shortSide == shortSide, session?.isRunning == true { return }
        closeNow()
        guard let device = AVCaptureDevice(uniqueID: camera.uniqueID) else { throw FluxError("\(camera.name) is not connected") }
        let session = AVCaptureSession()
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw FluxError("\(camera.name) cannot be used") }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frames)
        guard session.canAddOutput(output) else { throw FluxError("\(camera.name) cannot be used") }
        session.addOutput(output)
        if let format = Self.format(device, shortSide: shortSide) {
            try device.lockForConfiguration()
            device.activeFormat = format
            let fps = Double(WebcamPackets.fps)
            if format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }) {
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(WebcamPackets.fps))
            }
            device.unlockForConfiguration()
        }
        session.commitConfiguration()

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] c, _ in
            let r = FrameGeometry.snap(Int(c.videoRotationAngleForHorizonLevelCapture.rounded()))
            self?.lock.withLock { self?.rotation = r }
        }
        let name = camera.name
        observers = [
            NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [onError] _ in
                onError("\(name) was disconnected")
            },
            NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [onError] note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                onError("\(name) stopped: \(error?.localizedDescription ?? "unknown error")")
            },
        ]
        session.startRunning()
        let d = device.activeFormat.formatDescription.dimensions
        FluxLog.plugin.info("camera \(camera.name, privacy: .public) runs at \(d.width)x\(d.height)")
        self.session = session
        self.device = device
        self.shortSide = shortSide
        self.coordinator = coordinator
    }

    private func closeNow() {
        guard let session else { return }
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        rotationObservation = nil
        coordinator = nil
        session.stopRunning()
        self.session = nil
        device = nil
        FluxLog.plugin.info("camera stopped")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame(buffer, lock.withLock { rotation })
    }

    /// The smallest format with 30 frames per second that covers shortSide,
    /// else the largest one.
    private static func format(_ device: AVCaptureDevice, shortSide: Int) -> AVCaptureDevice.Format? {
        let fps = Double(WebcamPackets.fps)
        let usable = device.formats
            .filter { $0.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps - 0.5 } }
            .map { f -> (AVCaptureDevice.Format, Int32) in
                let d = f.formatDescription.dimensions
                return (f, min(d.width, d.height))
            }
        let covering = usable.filter { $0.1 >= Int32(shortSide) }
        return (covering.min { $0.1 < $1.1 } ?? usable.max { $0.1 < $1.1 })?.0
    }
}
