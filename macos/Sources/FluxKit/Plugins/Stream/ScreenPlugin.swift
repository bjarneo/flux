import CoreGraphics
import CoreVideo
import Foundation
import NIOCore
import Observation

/// The UI state of the screen mirror.
@MainActor
@Observable
public final class ScreenModel {
    public internal(set) var status = StreamStatus()
    public internal(set) var displays: [DisplayInfo] = []
    /// The display to mirror.
    public internal(set) var display: CGDirectDisplayID?
    /// False when macOS does not let Flux record the screen.
    public internal(set) var hasAccess = true

    init() {}
}

/// flux.screen: a display of this Mac in a window on the computer, with the
/// protocol of the Android app. This Mac listens, announces the port and the
/// frame size with "start", and writes H.264 to the computer that connects.
/// A change of the display resolution gives a new encoder on the same stream,
/// and the computer reads the new size from the next key frame.
public final class ScreenPlugin: FluxPlugin, @unchecked Sendable {
    /// How long this Mac waits for the computer to connect.
    private static let connectTimeout: Int64 = 10
    private static let displayKey = "screen.display"

    public let incoming = [PacketType.fluxScreen]
    public let outgoing = [PacketType.fluxScreen]
    public let model: ScreenModel

    private weak var core: FluxCore?

    private struct Session {
        let deviceId: String
        let display: CGDirectDisplayID
        var server: PayloadServer?
        var sink: VideoSink?
        var capture: ScreenCapture?
        var encoder: H264Encoder?
        var watch: DispatchSourceTimer?
    }

    private let lock = NSLock()
    private var session: Session?
    private var attempt = 0
    private var status = StreamStatus()
    private var display: CGDirectDisplayID?

    @MainActor
    public init() {
        model = ScreenModel()
    }

    public func attach(core: FluxCore) {
        self.core = core
        let saved = core.defaults.object(forKey: Self.displayKey) as? Int
        display = saved.map { CGDirectDisplayID(truncatingIfNeeded: $0) }
    }

    // MARK: Actions

    /// Reads the displays and the permission again.
    @MainActor
    public func refresh() {
        let displays = ScreenCapture.displays()
        model.displays = displays
        model.hasAccess = ScreenCapture.hasAccess
        let chosen = lock.withLock { display }
        model.display = displays.first { $0.id == chosen }?.id ?? displays.first?.id
    }

    /// Picks the display to mirror. It applies to the next mirror.
    @MainActor
    public func select(_ id: CGDirectDisplayID) {
        lock.withLock { display = id }
        core?.defaults.set(Int(id), forKey: Self.displayKey)
        model.display = id
    }

    /// Mirrors the chosen display to the computer. A running mirror stops first.
    public func start(_ deviceId: String) {
        guard let core else { return }
        stop(notify: true, status: StreamStatus())
        let chosen = lock.withLock { display }
        let target = chosen.flatMap { ScreenCapture.pixelSize($0) == nil ? nil : $0 } ?? CGMainDisplayID()
        let id = lock.withLock { () -> Int in
            attempt += 1
            session = Session(deviceId: deviceId, display: target)
            return attempt
        }
        let name = core.device(deviceId)?.name ?? "the computer"
        setStatus(StreamStatus(.connecting, "Waiting for \(name)…", deviceId: deviceId))
        Task { await self.run(core: core, deviceId: deviceId, name: name, display: target, id: id) }
    }

    /// Stops the mirror and tells the computer.
    public func stop() {
        stop(notify: true, status: StreamStatus(.idle, "Stopped on this Mac", deviceId: lock.withLock { status.deviceId }))
    }

    // MARK: Packets

    public func handle(_ packet: Packet, from device: Device) {
        guard let reply = ScreenReply.parse(packet) else { return }
        guard lock.withLock({ session?.deviceId == device.id }) else { return }
        let name = device.name
        let deviceId = device.id
        switch reply {
        case .live:
            let live = lock.withLock { () -> Bool in
                guard status.active else { return false }
                status = StreamStatus(.live, "Mirrors to \(name)", deviceId: deviceId)
                return true
            }
            if live { publishStatus() }
        case .failed(let message):
            Task { self.stop(notify: false, status: StreamStatus(.error, message, deviceId: deviceId)) }
        case .stop:
            Task { self.stop(notify: false, status: StreamStatus(.idle, "Stopped on \(name)", deviceId: deviceId)) }
        }
    }

    public func onDisconnected(_ device: Device) {
        guard lock.withLock({ session?.deviceId == device.id }) else { return }
        let deviceId = device.id
        Task { self.stop(notify: false, status: StreamStatus(.error, "The connection to the computer closed", deviceId: deviceId)) }
    }

    // MARK: Session

    private func run(core: FluxCore, deviceId: String, name: String, display: CGDirectDisplayID, id: Int) async {
        do {
            guard let d = core.device(deviceId) else { throw FluxError("\(name) is not known") }
            guard d.accepts(PacketType.fluxScreen) else { throw FluxError("Update Flux on \(name) to mirror this screen") }
            guard let certificate = d.certificate else { throw FluxError("\(name) is not connected") }
            guard let pixels = ScreenCapture.pixelSize(display), let size = MirrorSize.fit(width: pixels.width, height: pixels.height) else {
                throw FluxError("The display is not connected")
            }
            let capture = ScreenCapture(onFrame: { [weak self] buffer in self?.frame(buffer) }, onStop: { [weak self] message in
                Task { self?.end(notify: true, status: StreamStatus(.error, message, deviceId: deviceId), id: id) }
            })
            do {
                try await capture.prepare(display: display)
            } catch {
                publishAccess()
                throw error
            }
            let server = try await PayloadServer.open(tls: core.tls, expected: certificate)
            guard change(id, { $0.server = server }) else {
                server.close()
                return
            }
            guard core.send(ScreenPackets.start(port: server.port, width: size.width, height: size.height), to: deviceId) else {
                throw FluxError("Not connected to \(name)")
            }
            let waited = ContinuousClock.now
            let stream: TLSStream
            do {
                stream = try await server.accept(timeout: .seconds(Self.connectTimeout))
            } catch where ContinuousClock.now - waited >= .seconds(Self.connectTimeout) {
                throw FluxError("\(name) did not connect. Update Flux on the computer.")
            }
            let sink = VideoSink(stream: stream, bitrate: MirrorSize.bitrate(width: size.width, height: size.height))
            guard change(id, { $0.server = nil; $0.sink = sink }) else {
                sink.close()
                return
            }
            do {
                let encoder = try newEncoder(width: size.width, height: size.height, sink: sink, deviceId: deviceId, id: id)
                guard change(id, { $0.capture = capture; $0.encoder = encoder }) else {
                    encoder.release()
                    return
                }
                try await capture.start(width: size.width, height: size.height)
                watch(display: display, sink: sink, deviceId: deviceId, id: id)
            } catch {
                throw FluxError("The screen capture failed: \(error.localizedDescription)")
            }
            do {
                try await sink.run()
            } catch {
                end(notify: false, status: StreamStatus(.error, "The connection to the computer closed", deviceId: deviceId), id: id)
            }
        } catch {
            guard lock.withLock({ attempt == id }) else { return }
            FluxLog.plugin.info("mirror did not start: \(String(describing: error), privacy: .public)")
            end(notify: true, status: StreamStatus(.error, String(describing: error), deviceId: deviceId), id: id)
        }
    }

    private func newEncoder(width: Int, height: Int, sink: VideoSink, deviceId: String, id: Int) throws -> H264Encoder {
        try H264Encoder(width: width, height: height, bitrate: MirrorSize.bitrate(width: width, height: height), output: { [sink] bytes in
            sink.push(bytes)
        }, onError: { [weak self] message in
            Task { self?.end(notify: true, status: StreamStatus(.error, message, deviceId: deviceId), id: id) }
        })
    }

    private func frame(_ buffer: CVPixelBuffer) {
        guard let (encoder, sink) = lock.withLock({ session.flatMap { s in s.encoder.flatMap { e in s.sink.map { (e, $0) } } } }),
              !sink.backlogged,
              CVPixelBufferGetWidth(buffer) == encoder.width, CVPixelBufferGetHeight(buffer) == encoder.height else { return }
        encoder.encode(buffer)
    }

    /// Checks the display size every second. A new size gives a new encoder
    /// on the same stream: the old encoder writes its last frames before the
    /// new one starts with a key frame, so the stream stays valid.
    private func watch(display: CGDirectDisplayID, sink: VideoSink, deviceId: String, id: Int) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "org.omarchy.flux.screen.watch"))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, let pixels = ScreenCapture.pixelSize(display),
                  let next = MirrorSize.fit(width: pixels.width, height: pixels.height),
                  let current = self.lock.withLock({ self.session?.encoder }), current.width != next.width || current.height != next.height,
                  let capture = self.lock.withLock({ self.session?.capture }) else { return }
            do {
                let encoder = try newEncoder(width: next.width, height: next.height, sink: sink, deviceId: deviceId, id: id)
                guard change(id, { $0.encoder = encoder }) else {
                    encoder.release()
                    return
                }
                current.release()
                Task {
                    do {
                        try await capture.resize(width: next.width, height: next.height)
                    } catch {
                        self.end(notify: true, status: StreamStatus(.error, "The screen mirror stopped after the display changed", deviceId: deviceId), id: id)
                    }
                }
            } catch {
                end(notify: true, status: StreamStatus(.error, "The screen mirror stopped after the display changed", deviceId: deviceId), id: id)
            }
        }
        if change(id, { $0.watch = timer }) { timer.resume() }
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
        if let s = ended {
            s.watch?.cancel()
            s.capture?.stop()
            s.encoder?.release()
            s.server?.close()
            s.sink?.close()
            if notify, s.server != nil || s.sink != nil { _ = core?.send(ScreenPackets.stop(), to: s.deviceId) }
        }
        setStatus(status)
    }

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

    // MARK: UI

    private func setStatus(_ s: StreamStatus) {
        lock.withLock { status = s }
        publishStatus()
    }

    private func publishStatus() {
        ui { [weak self] m in
            guard let self else { return }
            m.status = self.lock.withLock { self.status }
        }
    }

    private func publishAccess() {
        ui { $0.hasAccess = ScreenCapture.hasAccess }
    }

    /// Runs change on the main queue, in order.
    private func ui(_ change: @escaping @MainActor (ScreenModel) -> Void) {
        let model = model
        DispatchQueue.main.async { MainActor.assumeIsolated { change(model) } }
    }
}
