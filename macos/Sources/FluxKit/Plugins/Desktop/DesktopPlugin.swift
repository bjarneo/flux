import Foundation
import NIOCore
import Observation

/// How long this Mac waits for the computer to connect.
private let connectTimeout: TimeAmount = .seconds(15)

/// The UI state of the remote desktop and the Omarchy panel.
@MainActor
@Observable
public final class DesktopModel {
    public enum Phase: Sendable {
        case idle, connecting, live, error
    }

    public struct Status: Equatable, Sendable {
        public var phase = Phase.idle
        public var message = ""
        public var deviceId: String?
        public var monitor = ""
        public var monitors: [String] = []
        /// The size of the video, or 0 before the computer tells it.
        public var width = 0
        public var height = 0

        public init(_ phase: Phase = .idle, _ message: String = "", deviceId: String? = nil, monitor: String = "") {
            self.phase = phase
            self.message = message
            self.deviceId = deviceId
            self.monitor = monitor
        }

        public var active: Bool { phase == .connecting || phase == .live }
    }

    public internal(set) var status = Status()
    /// The key bindings and the workspaces of each computer.
    public internal(set) var shortcuts: [String: ShortcutsState] = [:]
    /// The descriptions of the shortcuts that the Omarchy panel pins.
    public var pins = DesktopShortcuts.defaultPins {
        didSet { defaults?.set(pins, forKey: DesktopPlugin.pinsKey) }
    }

    @ObservationIgnored private var defaults: UserDefaults?

    init() {}

    func load(_ defaults: UserDefaults) {
        pins = defaults.stringArray(forKey: DesktopPlugin.pinsKey) ?? DesktopShortcuts.defaultPins
        self.defaults = defaults
    }

    /// Pins the shortcut to the panel, or unpins it.
    public func togglePin(_ s: Shortcut) {
        if let i = pins.firstIndex(of: s.description) {
            pins.remove(at: i)
        } else {
            pins.append(s.description)
        }
    }
}

/// flux.desktop and flux.shortcuts: the screen of a computer in a window on
/// this Mac, 1 stream at a time. This Mac opens a TLS listener, the
/// computer connects and streams 1 monitor, and `video` shows the frames.
/// The computer shows its screen only while remote_desktop is on. The mouse
/// and the keys go through `RemoteInputPlugin`. The Omarchy panel sends
/// flux.shortcuts, and the answers go to the model.
public final class DesktopPlugin: FluxPlugin, @unchecked Sendable {
    static let pinsKey = "desktop.pinnedShortcuts"

    public let incoming = [PacketType.fluxDesktop, PacketType.fluxShortcuts]
    public let outgoing = [PacketType.fluxDesktop, PacketType.fluxShortcuts]
    public let model: DesktopModel
    public let video = DesktopVideo()

    private weak var core: FluxCore?
    private let lock = NSLock()
    // Guarded by lock. Each start and each end moves attempt forward, so that
    // the work of an old stream does nothing.
    private var attempt = 0
    private var deviceId: String?
    private var server: PayloadServer?
    private var stream: TLSStream?

    @MainActor
    public init() { model = DesktopModel() }

    public func attach(core: FluxCore) {
        self.core = core
        let defaults = core.defaults
        let model = model
        DispatchQueue.main.async { MainActor.assumeIsolated { model.load(defaults) } }
    }

    /// True when the computer can stream its screen to this Mac.
    public static func supported(_ device: DeviceSnapshot) -> Bool { device.accepts(PacketType.fluxDesktop) }

    /// True when the computer runs the actions of the Omarchy panel.
    public static func shortcutsSupported(_ device: DeviceSnapshot) -> Bool { device.accepts(PacketType.fluxShortcuts) }

    // MARK: Actions

    /// Starts the stream from the computer. A running stream stops first.
    /// `monitor` selects a monitor of the computer, and `maxSize` is the
    /// longest side of the stream in pixels.
    public func start(_ deviceId: String, monitor: String? = nil, maxSize: Int = DesktopPackets.defaultSize) {
        guard let core else { return }
        stop()
        let name = core.locked { core.device(deviceId)?.name } ?? "the computer"
        let id = lock.withLock {
            self.deviceId = deviceId
            attempt += 1
            show(.init(.connecting, "Waiting for \(name)…", deviceId: deviceId, monitor: monitor ?? ""))
            return attempt
        }
        video.reset()
        FluxLog.plugin.info("remote desktop: asking \(name, privacy: .public) for \(monitor ?? "the focused monitor", privacy: .public), max \(maxSize) px")
        Task { await run(core, deviceId, name, monitor, maxSize, id) }
    }

    /// Stops the stream and tells the computer. `status` shows after the stop.
    public func stop(status: DesktopModel.Status = .init()) {
        end(status, notify: true, attempt: lock.withLock { attempt })
    }

    /// Sends a flux.shortcuts packet. It returns false when the computer is offline.
    @discardableResult
    public func send(_ packet: Packet, to deviceId: String) -> Bool { core?.send(packet, to: deviceId) ?? false }

    // MARK: Packets

    public func handle(_ packet: Packet, from device: Device) {
        if packet.type == PacketType.fluxShortcuts {
            let id = device.id
            let model = model
            DispatchQueue.main.async {
                MainActor.assumeIsolated { model.shortcuts[id] = DesktopShortcuts.merge(model.shortcuts[id], packet) }
            }
            return
        }
        guard let reply = DesktopReply.parse(packet), let id = attempt(for: device) else { return }
        let name = device.name
        let deviceId = device.id
        switch reply {
        case .live(let monitor, let monitors, let width, let height):
            FluxLog.plugin.info("remote desktop: \(name, privacy: .public) shows \(monitor, privacy: .public) at \(width)x\(height), monitors \(monitors.joined(separator: ","), privacy: .public)")
            lock.withLock {
                guard attempt == id else { return }
                let model = model
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        var s = model.status
                        guard s.active, s.deviceId == deviceId else { return }
                        s.phase = .live
                        s.message = "Shows \(name)"
                        s.monitor = monitor
                        s.monitors = monitors
                        // The size frame of the stream wins over the packet.
                        if s.width == 0 || s.height == 0 {
                            s.width = width
                            s.height = height
                        }
                        model.status = s
                    }
                }
            }
        case .failed(let message):
            FluxLog.plugin.info("remote desktop: \(name, privacy: .public) failed: \(message, privacy: .public)")
            end(.init(.error, message, deviceId: deviceId), notify: false, attempt: id)
        case .stop:
            end(.init(.idle, "Stopped on \(name)", deviceId: deviceId), notify: false, attempt: id)
        }
    }

    public func onDisconnected(_ device: Device) {
        guard let id = attempt(for: device) else { return }
        end(.init(.error, "The connection to \(device.name) closed", deviceId: device.id), notify: false, attempt: id)
    }

    /// The attempt of the stream from the device, or nil when no stream comes from there.
    private func attempt(for device: Device) -> Int? {
        lock.withLock { deviceId == device.id ? attempt : nil }
    }

    // MARK: Stream

    private func run(_ core: FluxCore, _ deviceId: String, _ name: String, _ monitor: String?, _ maxSize: Int, _ id: Int) async {
        do {
            let peer = core.locked { core.device(deviceId).map { (accepts: $0.accepts(PacketType.fluxDesktop), certificate: $0.certificate) } }
            guard let peer else { throw FluxError("\(name) is not known") }
            guard peer.accepts else { throw FluxError("Update Flux on \(name) to show its screen") }
            guard let certificate = peer.certificate else { throw FluxError("\(name) is not connected") }
            let stream = try await connect(core, deviceId, name, monitor, maxSize, certificate, id)
            let keep = lock.withLock {
                guard attempt == id else { return false }
                server = nil
                self.stream = stream
                return true
            }
            guard keep else {
                stream.channel.channel.close(promise: nil)
                return
            }
            try await read(stream, id)
            end(.init(.error, "\(name) stopped the stream", deviceId: deviceId), notify: false, attempt: id)
        } catch {
            guard lock.withLock({ attempt == id }) else { return }
            FluxLog.plugin.info("remote desktop ended: \(String(describing: error), privacy: .public)")
            let message = (error as? FluxError)?.description ?? "The connection to \(name) closed"
            end(.init(.error, message, deviceId: deviceId), notify: true, attempt: id)
        }
    }

    /// Opens a listener, sends flux.desktop "start" with its port, and waits
    /// for the computer. The computer connects out, as for the webcam, and
    /// must use the certificate of the paired computer.
    private func connect(_ core: FluxCore, _ deviceId: String, _ name: String, _ monitor: String?, _ maxSize: Int,
                         _ certificate: [UInt8], _ id: Int) async throws -> TLSStream {
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
        guard core.send(DesktopPackets.start(port: server.port, monitor: monitor, maxSize: maxSize), to: deviceId) else {
            server.close()
            throw FluxError("Not connected to \(name)")
        }
        let stream: TLSStream
        do {
            stream = try await server.accept(timeout: connectTimeout)
        } catch {
            // An error packet from the computer ends the attempt first, with its message.
            throw FluxError("\(name) did not connect. Update Flux on the computer.")
        }
        guard stream.peerCertificate == certificate else {
            stream.channel.channel.close(promise: nil)
            throw FluxError("The connection did not come from \(name)")
        }
        return stream
    }

    /// Reads the frames until the computer closes the stream, and shows them.
    private func read(_ stream: TLSStream, _ id: Int) async throws {
        try await stream.executeThenClose { inbound, _ in
            var reader = DesktopFrameReader()
            for try await buffer in inbound {
                guard lock.withLock({ attempt == id }) else { return }
                for frame in try reader.push(buffer.readableBytesView) {
                    if let size = frame.size {
                        showSize(size.width, size.height, id)
                    } else if frame.isConfig {
                        if let sets = DesktopH264.parameterSets(frame.data), !video.configure(sps: sets.sps, pps: sets.pps) {
                            throw FluxError("This Mac cannot show the stream")
                        }
                    } else {
                        video.show(frame.data, key: frame.isKey)
                    }
                }
            }
        }
    }

    /// Ends the stream of the attempt. With notify, the computer gets
    /// flux.desktop "stop" when it already got "start".
    private func end(_ status: DesktopModel.Status, notify: Bool, attempt id: Int) {
        let taken: (target: String?, server: PayloadServer?, stream: TLSStream?)? = lock.withLock {
            guard attempt == id else { return nil }
            attempt += 1
            defer {
                deviceId = nil
                server = nil
                stream = nil
            }
            show(status)
            return (deviceId, server, stream)
        }
        guard let taken else { return }
        taken.server?.close()
        taken.stream?.channel.channel.close(promise: nil)
        video.reset()
        if notify, let target = taken.target, taken.server != nil || taken.stream != nil {
            core?.send(DesktopPackets.stop(), to: target)
        }
    }

    // MARK: Model

    /// Shows a status. The lock is held, so the statuses reach the model in order.
    private func show(_ status: DesktopModel.Status) {
        let model = model
        DispatchQueue.main.async { MainActor.assumeIsolated { model.status = status } }
    }

    private func showSize(_ width: Int, _ height: Int, _ id: Int) {
        lock.withLock {
            guard attempt == id else { return }
            let model = model
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard model.status.active, model.status.width != width || model.status.height != height else { return }
                    model.status.width = width
                    model.status.height = height
                }
            }
        }
    }
}
