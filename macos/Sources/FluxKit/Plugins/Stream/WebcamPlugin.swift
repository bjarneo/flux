import AVFoundation
import CoreGraphics
import Foundation
import NIOCore
import Observation

/// The UI state of the webcam.
@MainActor
@Observable
public final class WebcamModel {
    public internal(set) var status = StreamStatus()
    public internal(set) var config = WebcamConfig()
    public internal(set) var caps = WebcamCaps()
    public internal(set) var cameras: [CameraInfo] = []
    /// A problem with the camera itself, or nil.
    public internal(set) var cameraError: String?
    /// A small copy of the frames while the camera runs.
    public internal(set) var preview: CGImage?
    /// "Also send the microphone": the microphone streams to the computer
    /// while the webcam is live.
    public internal(set) var sendsMicrophone = false

    init() {}
}

/// flux.webcam: the camera of this Mac as a virtual camera on the computer,
/// with the protocol of the Android app. This Mac listens, announces the port
/// with "start", and writes H.264 to the computer that connects. 1 stream
/// runs at a time.
public final class WebcamPlugin: FluxPlugin, @unchecked Sendable {
    /// The largest digital zoom.
    static let zoomMax = 4.0
    /// The digital exposure range, in EV, and its step.
    static let exposureLimit = 2.0
    static let exposureStep = 0.1
    /// How long this Mac waits for the computer to connect.
    private static let connectTimeout: Int64 = 10
    /// The shortest time between 2 config messages to the computer, while a
    /// slider moves.
    private static let configInterval = 0.12
    private static let microphoneKey = "webcam.withMicrophone"

    public let incoming = [PacketType.fluxWebcam]
    public let outgoing = [PacketType.fluxWebcam]
    public let model: WebcamModel

    private weak var core: FluxCore?
    private var settings: WebcamSettings!
    private var pipeline: WebcamPipeline!

    private struct Session {
        let deviceId: String
        var server: PayloadServer?
        var sink: VideoSink?
        /// True after the computer got "start", so it can take "config".
        var announced = false
    }

    private let lock = NSLock()
    private var session: Session?
    private var attempt = 0
    private var status = StreamStatus()
    private var applied = WebcamConfig()
    private var sendPending = false
    /// True while the webcam runs a microphone stream that it started. Only
    /// the main thread uses it.
    private var microphoneByWebcam = false

    @MainActor
    public init() {
        model = WebcamModel()
    }

    public func attach(core: FluxCore) {
        self.core = core
        let cameras = CameraSource.available()
        settings = WebcamSettings(defaults: core.defaults, caps: Self.caps(cameras))
        applied = settings.config
        pipeline = WebcamPipeline(
            onPreview: { [weak self] image in
                self?.ui { [weak self] m in if self?.pipeline.isCameraOpen == true { m.preview = image } }
            },
            onCameraError: { [weak self] message in self?.ui { $0.cameraError = message } }
        )
        #if os(iOS)
        pipeline.onCameraResume { [weak self] in self?.ui { $0.cameraError = nil } }
        #endif
        pipeline.apply(applied)
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.publishCameras(CameraSource.available())
            }
        }
        publishCameras(cameras)
        publishConfig()
        let sendsMicrophone = core.defaults.bool(forKey: Self.microphoneKey)
        ui { $0.sendsMicrophone = sendsMicrophone }
    }

    /// True when the user did not let Flux use the camera.
    public static var cameraAccessDenied: Bool { CameraSource.accessDenied }

    /// The caps of this Mac: the cameras, a digital zoom and exposure, and
    /// automatic white balance only, because macOS gives apps no white
    /// balance presets.
    static func caps(_ cameras: [CameraInfo]) -> WebcamCaps {
        var caps = WebcamCaps()
        caps.zoomMax = zoomMax
        caps.exposureMin = -exposureLimit
        caps.exposureMax = exposureLimit
        caps.exposureStep = exposureStep
        caps.cameras = cameras.map(\.id)
        return caps
    }

    // MARK: Actions

    /// Starts a stream to the computer. A running stream stops first.
    public func start(_ deviceId: String) {
        guard let core else { return }
        stop(notify: true, status: StreamStatus())
        let id = lock.withLock { () -> Int in
            attempt += 1
            session = Session(deviceId: deviceId)
            return attempt
        }
        let name = core.withDevice(deviceId) { $0.name } ?? "the computer"
        setStatus(StreamStatus(.connecting, "Waiting for \(name)…", deviceId: deviceId))
        ui { $0.cameraError = nil }
        Task { await self.run(core: core, deviceId: deviceId, name: name, id: id) }
    }

    /// Stops the stream and tells the computer.
    public func stop() {
        stop(notify: true, status: StreamStatus())
    }

    #if os(iOS)
    /// Stops a running stream because Flux left the screen, and tells the
    /// computer. iOS gives the camera only to the app on the screen.
    public func stopInBackground() {
        guard let deviceId = lock.withLock({ session?.deviceId }) else { return }
        stop(notify: true, status: StreamStatus(.idle, Self.backgroundText, deviceId: deviceId))
    }

    /// The status after the stream stopped in the background.
    static let backgroundText = "The webcam stopped when Flux left the screen. iOS gives the camera only to the app on the screen."
    #endif

    /// Changes the settings. The image changes at once, a new camera switches
    /// without a new stream, and a new frame size starts the stream again.
    public func update(_ change: (inout WebcamConfig) -> Void) {
        let next = settings.update { c in
            var c = c
            change(&c)
            return c
        }
        if let next { changed(next) }
    }

    /// Turns "Also send the microphone" on or off. Turning it on asks for the
    /// microphone permission when macOS has not asked yet, and stays off when
    /// the user denies it.
    public func setSendsMicrophone(_ on: Bool) {
        guard on else { return applySendsMicrophone(false) }
        Task {
            var granted = MicPermission.current == .granted
            if MicPermission.current == .undetermined { granted = await AVCaptureDevice.requestAccess(for: .audio) }
            if !granted { core?.toast("Allow the microphone for Flux to send it with the webcam") }
            applySendsMicrophone(granted)
        }
    }

    private func applySendsMicrophone(_ on: Bool) {
        core?.defaults.set(on, forKey: Self.microphoneKey)
        ui { [weak self] m in
            m.sendsMicrophone = on
            self?.syncMicrophone()
        }
    }

    /// Tells the webcam that a view shows the preview, or stopped to show
    /// it. Without a view, the frames make no preview images.
    public func setPreviewShown(_ shown: Bool) {
        pipeline.setPreviewShown(shown)
    }

    /// Sets the neutral image values. The shape, the quality, and the camera stay.
    public func reset() {
        if let next = settings.update({ $0.reset() }) { changed(next) }
    }

    // MARK: Packets

    public func handle(_ packet: Packet, from device: Device) {
        guard let reply = WebcamReply.parse(packet) else { return }
        guard lock.withLock({ session?.deviceId == device.id }) else { return }
        let name = device.name
        let deviceId = device.id
        switch reply {
        case .live(_, let label):
            let live = lock.withLock { () -> Bool in
                guard status.active else { return false }
                status = StreamStatus(.live, "Live on \(name) as \(label)", deviceId: deviceId)
                return true
            }
            if live { publishStatus() }
        case .failed(let message):
            Task { self.stop(notify: false, status: StreamStatus(.error, message, deviceId: deviceId)) }
        case .stop:
            Task { self.stop(notify: false, status: StreamStatus(.idle, "Stopped on \(name)", deviceId: deviceId)) }
        case .config(let partial, let reset):
            Task {
                if let next = self.settings.applyRemote(reset: reset, partial: partial) { self.changed(next) }
            }
        }
    }

    public func onDisconnected(_ device: Device) {
        guard lock.withLock({ session?.deviceId == device.id }) else { return }
        let name = device.name
        let deviceId = device.id
        Task { self.stop(notify: false, status: StreamStatus(.error, "The connection to \(name) closed", deviceId: deviceId)) }
    }

    // MARK: Texts

    /// The error when the computer's Flux has no webcam support.
    static func updateText(computer: String, platform: FluxPlatform = .current) -> String {
        "Update Flux on \(computer) to use \(platform.deviceNoun) as a webcam"
    }

    /// The error when no camera is available.
    static func noCameraText(platform: FluxPlatform = .current) -> String {
        "\(platform.deviceNounStart) has no usable camera"
    }

    // MARK: Session

    private func run(core: FluxCore, deviceId: String, name: String, id: Int) async {
        do {
            // The core lock guards the fields of the device.
            let peer = core.withDevice(deviceId) { (accepts: $0.accepts(PacketType.fluxWebcam), certificate: $0.certificate) }
            guard let peer else { throw FluxError("\(name) is not known") }
            guard peer.accepts else { throw FluxError(Self.updateText(computer: name)) }
            guard let certificate = peer.certificate else { throw FluxError("\(name) is not connected") }
            try await CameraSource.authorize()
            try await openCamera(id: id)
            let config = settings.config
            let server = try await PayloadServer.open(tls: core.tls, expected: certificate)
            guard change(id, { $0.server = server }) else {
                server.close()
                return
            }
            guard core.send(WebcamPackets.start(port: server.port, width: config.width, height: config.height), to: deviceId) else {
                throw FluxError("Not connected to \(name)")
            }
            _ = change(id) { $0.announced = true }
            _ = core.send(WebcamPackets.config(settings.config, settings.caps), to: deviceId)
            let waited = ContinuousClock.now
            let stream: TLSStream
            do {
                stream = try await server.accept(timeout: .seconds(Self.connectTimeout))
            } catch where ContinuousClock.now - waited >= .seconds(Self.connectTimeout) {
                throw FluxError("\(name) did not connect. Update Flux on the computer.")
            }
            let sink = VideoSink(stream: stream, bitrate: config.bitrate)
            guard change(id, { $0.server = nil; $0.sink = sink }) else {
                sink.close()
                return
            }
            setStatus(StreamStatus(.starting, "Starting Flux Camera on \(name)…", deviceId: deviceId))
            do {
                try pipeline.startEncoder(width: config.width, height: config.height, bitrate: config.bitrate, sink: sink) { [weak self] message in
                    Task { self?.end(notify: true, status: StreamStatus(.error, message, deviceId: deviceId), id: id) }
                }
            } catch {
                throw FluxError("The video encoder did not start: \(error)")
            }
            do {
                try await sink.run()
            } catch {
                end(notify: true, status: StreamStatus(.error, "The connection to the computer closed", deviceId: deviceId), id: id)
            }
        } catch {
            guard current(id) else { return }
            FluxLog.plugin.info("webcam start failed: \(String(describing: error), privacy: .public)")
            end(notify: true, status: StreamStatus(.error, String(describing: error), deviceId: deviceId), id: id)
        }
    }

    /// Opens the camera of the settings for attempt id, after the settings
    /// took the cameras that this Mac has now.
    private func openCamera(id: Int) async throws {
        let cameras = CameraSource.available()
        publishCameras(cameras)
        guard let first = cameras.first else { throw FluxError(Self.noCameraText()) }
        if let next = settings.setCaps(Self.caps(cameras)) { changed(next) }
        let config = settings.config
        let camera = cameras.first { $0.id == config.camera } ?? first
        guard current(id) else { return }
        try await pipeline.openCamera(camera, shortSide: config.resolution, owner: id)
        if !current(id) { pipeline.closeCamera(owner: id) }
    }

    /// Stops the current attempt.
    private func stop(notify: Bool, status: StreamStatus) {
        end(notify: notify, status: status, id: lock.withLock { attempt })
    }

    /// Ends attempt id once. With notify, the computer gets "stop" when it
    /// knew about the stream.
    private func end(notify: Bool, status: StreamStatus, id: Int) {
        let ended = lock.withLock { () -> Session?? in
            guard attempt == id else { return nil }
            attempt += 1
            defer { session = nil }
            return .some(session)
        }
        guard let ended else { return }
        pipeline.stopEncoder()
        pipeline.closeCamera(owner: id)
        ended?.server?.close()
        ended?.sink?.close()
        if notify, let s = ended, s.server != nil || s.sink != nil {
            _ = core?.send(WebcamPackets.stop(), to: s.deviceId)
        }
        setStatus(status)
    }

    private func current(_ id: Int) -> Bool { lock.withLock { attempt == id } }

    /// Changes the session of attempt id. It returns false when a later
    /// attempt replaced it.
    private func change(_ id: Int, _ body: (inout Session) -> Void) -> Bool {
        lock.withLock {
            guard attempt == id, var s = session else { return false }
            body(&s)
            session = s
            return true
        }
    }

    /// Applies new settings to the camera, the image, and the stream. The
    /// computer gets the full settings after each change.
    private func changed(_ next: WebcamConfig) {
        publishConfig()
        let (old, announcedTo) = lock.withLock { () -> (WebcamConfig, String?) in
            defer { applied = next }
            return (applied, session?.announced == true ? session?.deviceId : nil)
        }
        pipeline.apply(next)
        if old.camera != next.camera { switchCamera(next) }
        if old.restartsStream(next), let deviceId = announcedTo {
            // The new "start" carries the new size, and the config follows it.
            start(deviceId)
            return
        }
        scheduleConfig()
    }

    private func switchCamera(_ config: WebcamConfig) {
        guard pipeline.isCameraOpen else { return }
        Task {
            let cameras = CameraSource.available()
            publishCameras(cameras)
            guard let camera = cameras.first(where: { $0.id == config.camera }) ?? cameras.first else { return }
            do {
                try await pipeline.switchCamera(camera, shortSide: config.resolution)
                pipeline.requestKeyFrame()
                ui { $0.cameraError = nil }
            } catch {
                ui { $0.cameraError = String(describing: error) }
            }
        }
    }

    private func scheduleConfig() {
        let schedule = lock.withLock { () -> Bool in
            defer { sendPending = true }
            return !sendPending
        }
        guard schedule else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.configInterval) { [weak self] in
            self?.sendConfig()
        }
    }

    /// Sends the full settings to the computer, when a stream runs.
    private func sendConfig() {
        let target = lock.withLock { () -> String? in
            sendPending = false
            return session?.announced == true ? session?.deviceId : nil
        }
        guard let target else { return }
        _ = core?.send(WebcamPackets.config(settings.config, settings.caps), to: target)
    }

    // MARK: UI

    private func setStatus(_ s: StreamStatus) {
        lock.withLock { status = s }
        publishStatus()
    }

    private func publishStatus() {
        ui { [weak self] m in
            guard let self else { return }
            m.status = self.lock.withLock { self.status }
            if !m.status.active { m.preview = nil }
            self.syncMicrophone()
        }
    }

    /// Starts the microphone when the webcam goes live with "Also send the
    /// microphone" on, and stops the microphone that it started when the
    /// webcam stops or the option turns off.
    @MainActor
    private func syncMicrophone() {
        guard let mic = core?.plugin(MicPlugin.self) else { return }
        let status = model.status
        if status.phase == .live, model.sendsMicrophone, MicPermission.current == .granted,
           !mic.model.status.active, let deviceId = status.deviceId {
            mic.start(deviceId)
            microphoneByWebcam = true
        } else if (!status.active || !model.sendsMicrophone) && microphoneByWebcam {
            microphoneByWebcam = false
            if mic.model.status.active { mic.stop() }
        }
    }

    /// Sends the current settings to the model. The UI calls update on the
    /// main thread and sees the result at once.
    private func publishConfig() {
        let settings = settings!
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                model.config = settings.config
                model.caps = settings.caps
            }
        } else {
            ui { m in
                m.config = settings.config
                m.caps = settings.caps
            }
        }
    }

    private func publishCameras(_ cameras: [CameraInfo]) {
        ui { $0.cameras = cameras }
    }

    /// Runs change on the main queue, in order.
    private func ui(_ change: @escaping @MainActor (WebcamModel) -> Void) {
        let model = model
        DispatchQueue.main.async { MainActor.assumeIsolated { change(model) } }
    }
}
