import AVFoundation
import NIOCore

/// How long this Mac waits for the computer to connect.
private let connectTimeout: TimeAmount = .seconds(10)
/// The time between 2 level updates, about 15 per second, in nanoseconds.
private let levelInterval: UInt64 = 66_000_000
/// The audio chunks that wait for the network. A chunk holds 10 to 35 ms, so
/// this is 1 to 3.5 seconds. Older chunks drop when the connection is slower
/// than the microphone.
private let maxQueuedChunks = 100

/// flux.mic: this Mac as a microphone for the computer, 1 stream at a time.
/// The Mac records 48 kHz mono PCM and writes it to the computer, which plays
/// it into the source Flux Microphone.
public final class MicPlugin: FluxPlugin, @unchecked Sendable {
    public let incoming = [PacketType.fluxMic]
    public let outgoing = [PacketType.fluxMic]
    public let model: MicModel

    /// The defaults key of the chosen input ID.
    private static let inputKey = "mic.input"

    private weak var core: FluxCore?
    private var observers: [NSObjectProtocol] = []
    private let lock = NSLock()
    // Guarded by lock. Each start and each end moves attempt forward, so that
    // the work of an old stream does nothing.
    private var attempt = 0
    private var deviceId: String?
    private var server: PayloadServer?
    private var stream: TLSStream?
    private var capture: MicCapture?

    @MainActor
    public init() {
        model = MicModel()
        #if os(iOS)
        // A headset that comes or goes changes the route of the audio session.
        let names = [AVAudioSession.routeChangeNotification]
        #else
        let names = [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification]
        #endif
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.inputsChanged() }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    public func attach(core: FluxCore) {
        self.core = core
        let input = core.defaults.string(forKey: Self.inputKey) ?? ""
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                model.input = input
                inputsChanged()
            }
        }
    }

    // MARK: Actions

    /// Starts a stream to the device. A running stream stops first.
    public func start(_ deviceId: String) {
        guard let core else { return }
        stop()
        let name = core.locked { core.device(deviceId)?.name } ?? "the computer"
        let id = lock.withLock {
            self.deviceId = deviceId
            attempt += 1
            show(.init(.connecting, "Waiting for \(name)…", deviceId: deviceId))
            return attempt
        }
        Task { await run(core, deviceId, name, id) }
    }

    /// Stops the stream and tells the computer.
    public func stop() {
        end(.init(), notify: true, attempt: lock.withLock { attempt })
    }

    /// Records from the input with the ID from now on. Empty means the system
    /// default input. A running stream moves to the input without stopping.
    @MainActor
    public func selectInput(_ id: String) {
        model.input = id
        core?.defaults.set(id, forKey: Self.inputKey)
        switchCapture()
    }

    /// Reads the microphone permission again, for example after the user
    /// returns from System Settings.
    @MainActor
    public func refreshPermission() {
        model.permission = .current
    }

    // MARK: Packets

    public func handle(_ packet: Packet, from device: Device) {
        guard let reply = MicReply.parse(packet), let id = attempt(for: device) else { return }
        let name = device.name
        switch reply {
        case .live(let source):
            lock.withLock {
                if attempt == id { show(.init(.live, "Live on \(name) as \(source)", deviceId: device.id)) }
            }
        case .failed(let message):
            end(.init(.error, message, deviceId: device.id), notify: false, attempt: id)
        case .stop:
            end(.init(.idle, "Stopped on \(name)", deviceId: device.id), notify: false, attempt: id)
        }
    }

    public func onDisconnected(_ device: Device) {
        guard let id = attempt(for: device) else { return }
        end(.init(.error, "The connection to \(device.name) closed", deviceId: device.id), notify: false, attempt: id)
    }

    /// The attempt of the stream to the device, or nil when no stream goes there.
    private func attempt(for device: Device) -> Int? {
        lock.withLock { deviceId == device.id ? attempt : nil }
    }

    // MARK: Texts

    /// The error when the computer's Flux has no microphone support.
    static func updateText(computer: String, platform: FluxPlatform = .current) -> String {
        "Update Flux on \(computer) to use \(platform.deviceNoun) as a microphone"
    }

    /// The error when no microphone input exists.
    static func noMicrophoneText(platform: FluxPlatform = .current) -> String {
        "\(platform.deviceNounStart) has no microphone"
    }

    // MARK: Stream

    private func run(_ core: FluxCore, _ deviceId: String, _ name: String, _ id: Int) async {
        do {
            try await authorize()
            let peer = core.locked { core.device(deviceId).map { (accepts: $0.accepts(PacketType.fluxMic), certificate: $0.certificate) } }
            guard let peer else { throw FluxError("\(name) is not known") }
            guard peer.accepts else { throw FluxError(Self.updateText(computer: name)) }
            guard let certificate = peer.certificate else { throw FluxError("\(name) is not connected") }
            let stream = try await connect(core, deviceId, name, certificate, id)
            let keep = lock.withLock {
                guard attempt == id else { return false }
                server = nil
                self.stream = stream
                show(.init(.starting, "Starting Flux Microphone on \(name)…", deviceId: deviceId))
                return true
            }
            guard keep else {
                await stream.discard()
                return
            }
            try await record(stream, name, id)
        } catch {
            guard lock.withLock({ attempt == id }) else { return }
            FluxLog.plugin.info("microphone stopped: \(String(describing: error), privacy: .public)")
            let message = (error as? FluxError)?.description ?? "The connection to \(name) closed"
            end(.init(.error, message, deviceId: deviceId), notify: true, attempt: id)
        }
    }

    /// Asks for the microphone the first time. It throws when the user denied it.
    private func authorize() async throws {
        var granted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            granted = await AVCaptureDevice.requestAccess(for: .audio)
        }
        await MainActor.run { [model] in model.permission = .current }
        guard granted else { throw FluxError(Self.deniedText()) }
    }

    static func deniedText(platform: FluxPlatform = .current) -> String {
        "Allow the microphone for Flux in \(platform.settingsApp) > Privacy & Security > Microphone"
    }

    /// Opens a listener, sends flux.mic "start" with its port, and waits for
    /// the computer. The computer connects out, so the stream passes a
    /// firewall that blocks incoming traffic on the computer. The connection
    /// must use the certificate of the paired computer.
    private func connect(_ core: FluxCore, _ deviceId: String, _ name: String, _ certificate: [UInt8], _ id: Int) async throws -> TLSStream {
        let server = try await PayloadServer.open(tls: core.tls, expected: nil)
        let keep = lock.withLock {
            guard attempt == id else { return false }
            self.server = server
            return true
        }
        guard keep else {
            server.close()
            throw CancellationError()
        }
        guard core.send(MicPackets.start(port: server.port), to: deviceId) else {
            server.close()
            throw FluxError("Not connected to \(name)")
        }
        let stream: TLSStream
        do {
            stream = try await server.accept(timeout: connectTimeout)
        } catch {
            throw FluxError("\(name) did not connect. Update Flux on the computer.")
        }
        guard stream.peerCertificate == certificate else {
            await stream.discard()
            throw FluxError("The connection did not come from \(name)")
        }
        return stream
    }

    /// Records and writes the audio until the stream ends. It throws when the
    /// computer closes the connection.
    private func record(_ stream: TLSStream, _ name: String, _ id: Int) async throws {
        let (chunks, sink) = AsyncStream.makeStream(of: ByteBuffer.self, bufferingPolicy: .bufferingNewest(maxQueuedChunks))
        defer { sink.finish() }
        let allocator = ByteBufferAllocator()
        var lastLevel: UInt64 = 0
        let capture = MicCapture(onSamples: { [weak self] samples in
            let size = samples.count * 2
            var chunk = allocator.buffer(capacity: size)
            chunk.writeWithUnsafeMutableBytes(minimumWritableBytes: size) { out in
                Pcm.toLittleEndian(samples, into: out)
                return size
            }
            sink.yield(chunk)
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastLevel >= levelInterval {
                lastLevel = now
                self?.showLevel(Pcm.peak(samples), id)
            }
        }, onError: { [weak self] message in
            self?.fail(message, id)
        })
        let input = core?.defaults.string(forKey: Self.inputKey) ?? ""
        // The capture starts inside executeThenClose, so that a capture that
        // fails still closes the stream the way NIO requires.
        try await stream.executeThenClose { inbound, outbound in
            #if os(macOS)
            guard let device = MicCapture.device(for: input) else { throw FluxError(Self.noMicrophoneText()) }
            #endif
            let keep = lock.withLock {
                guard attempt == id else { return false }
                self.capture = capture
                return true
            }
            guard keep else { return }
            #if os(macOS)
            try await capture.start(device)
            #else
            try await capture.start(route: input)
            #endif
            try await withThrowingTaskGroup(of: Void.self) { group in
                // The computer sends nothing. The inbound side ends when it closes.
                group.addTask { for try await _ in inbound {} }
                group.addTask { for await chunk in chunks { try await outbound.write(chunk) } }
                try await group.next()
                group.cancelAll()
            }
        }
        throw FluxError("The connection to \(name) closed")
    }

    /// Moves a running capture to the chosen input.
    @MainActor
    private func switchCapture() {
        #if os(iOS)
        // The iPhone has 1 capture device. The route of the audio session picks the input.
        if lock.withLock({ capture }) != nil { AudioSession.prefer(model.input) }
        #else
        guard let capture = lock.withLock({ capture }), let device = MicCapture.device(for: model.input) else { return }
        capture.use(device)
        #endif
    }

    /// Reloads the inputs after a device came or went. A running capture on a
    /// device that went away moves to the system default input.
    @MainActor
    private func inputsChanged() {
        #if os(iOS)
        if let inputs = MicCapture.inputs() { model.inputs = inputs }
        #else
        model.inputs = MicCapture.inputs()
        #endif
        switchCapture()
    }

    private func fail(_ message: String, _ id: Int) {
        let target = lock.withLock { deviceId }
        end(.init(.error, message, deviceId: target), notify: true, attempt: id)
    }

    /// Ends the stream of the attempt. With notify, the computer gets
    /// flux.mic "stop" when it already got "start".
    private func end(_ status: MicModel.Status, notify: Bool, attempt id: Int) {
        let taken: (target: String?, server: PayloadServer?, stream: TLSStream?, capture: MicCapture?)? = lock.withLock {
            guard attempt == id else { return nil }
            attempt += 1
            defer {
                deviceId = nil
                server = nil
                stream = nil
                capture = nil
            }
            show(status)
            return (deviceId, server, stream, capture)
        }
        guard let taken else { return }
        taken.server?.close()
        taken.stream?.channel.channel.close(promise: nil)
        taken.capture?.stop()
        if notify, let target = taken.target, taken.server != nil || taken.stream != nil {
            core?.send(MicPackets.stop(), to: target)
        }
    }

    // MARK: Model

    /// Shows a status. The lock is held, so the statuses reach the model in order.
    private func show(_ status: MicModel.Status) {
        let model = model
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                model.status = status
                if status.phase != .live { model.level = 0 }
            }
        }
    }

    private func showLevel(_ level: Float, _ id: Int) {
        lock.withLock {
            guard attempt == id else { return }
            let model = model
            DispatchQueue.main.async { MainActor.assumeIsolated { model.level = level } }
        }
    }
}
