import Foundation
import Observation
import UserNotifications

/// The open stream requests of the computers, for the UI.
/// `StreamRequestPlugin` changes it on the main actor.
@MainActor
@Observable
public final class StreamRequestModel {
    /// The open requests, the oldest first.
    public internal(set) var requests: [StreamRequest] = []

    /// The request that the prompt shows: the newest one.
    public var current: StreamRequest? { requests.last }

    /// True while the app is on the screen. The app sets it. Without it,
    /// each new request shows a notification.
    @ObservationIgnored public var isAppActive: (@MainActor () -> Bool)?
    /// Shows the prompt for a new request while the app is on the screen.
    /// The app sets it.
    @ObservationIgnored public var present: (@MainActor () -> Void)?
    /// Opens the webcam or the microphone page of the computer and starts
    /// the stream with the start code of that feature. The plugin calls it
    /// only after a tap of the user on start. The app sets it.
    @ObservationIgnored public var open: (@MainActor (StreamRequest) -> Void)?
    /// Opens the webcam or the microphone page of the computer and starts
    /// nothing. The plugin calls it after a tap on a notification whose
    /// request ended or is too old. The user then starts the stream on the
    /// page. The app sets it, and opens only the page of a paired computer.
    @ObservationIgnored public var openPage: (@MainActor (_ computerId: String, _ kind: StreamRequest.Kind) -> Void)?

    init() {}
}

/// flux.stream.request from a computer: `flux-cli webcam start` or
/// `flux-cli mic start` asks this device to start its webcam or its
/// microphone. The packet never starts a stream. While the app is on the
/// screen, the app shows a prompt. Otherwise a notification shows the
/// request. Only a tap of the user on start starts the stream. A request
/// ends after 60 seconds. docs/ios.md and docs/macos.md describe the prompt.
public final class StreamRequestPlugin: FluxPlugin, @unchecked Sendable {
    /// The identifier of the start action of the notification.
    static let startAction = "start"

    public let outgoing: [String] = []
    public let model: StreamRequestModel
    private weak var core: FluxCore?
    @MainActor private var book = StreamRequestBook()
    /// The timer that ends each open request, by request ID.
    @MainActor private var expiries: [String: Task<Void, Never>] = [:]

    /// `lifetime` is the time after which an open request ends. A test
    /// sets a shorter time.
    @MainActor
    public init(lifetime: Duration = StreamRequest.lifetime) {
        model = StreamRequestModel()
        book.lifetime = lifetime
    }

    /// This device lists flux.stream.request only when it can stream both
    /// kinds: the core has the webcam and the microphone.
    public var incoming: [String] {
        guard let core, Self.streamsBoth(core) else { return [] }
        return [PacketType.fluxStreamRequest]
    }

    public var handledTypes: [String] { [PacketType.fluxStreamRequest] }

    static func streamsBoth(_ core: FluxCore) -> Bool {
        core.plugin(WebcamPlugin.self) != nil && core.plugin(MicPlugin.self) != nil
    }

    public func attach(core: FluxCore) {
        self.core = core
        for kind in StreamRequest.Kind.allCases {
            Notifier.shared.register(category: kind.notificationCategory,
                                     actions: Self.notificationActions(kind, platform: .current)) { [weak self] action, info, _ in
                guard StreamRequestPlugin.startsStream(action), let id = info["id"] as? String, let self else { return }
                // The category gives the kind. The computer must match the ID.
                let computerId = (info["computer"] as? String).flatMap { StreamRequest.id(kind, $0) == id ? $0 : nil }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.startFromNotification(id, kind: kind, computerId: computerId) }
                }
            }
        }
    }

    /// The action of the notification. It opens Flux. On an iPhone, it also
    /// needs the iPhone unlocked.
    static func notificationActions(_ kind: StreamRequest.Kind, platform: FluxPlatform) -> [UNNotificationAction] {
        let options: UNNotificationActionOptions = platform == .phone ? [.foreground, .authenticationRequired] : [.foreground]
        return [UNNotificationAction(identifier: startAction, title: kind.startLabel, options: options)]
    }

    /// True for the start action and for a tap or a click on the
    /// notification itself, whose text asks for it. A dismissal starts
    /// nothing.
    static func startsStream(_ action: String) -> Bool {
        action == startAction || action == UNNotificationDefaultActionIdentifier
    }

    /// The core lock is held. The main queue keeps the order of the packets.
    public func handle(_ packet: Packet, from device: Device) {
        guard let kind = StreamRequest.Kind.parse(packet) else { return }
        let id = device.id
        let name = device.name
        DispatchQueue.main.async { MainActor.assumeIsolated { self.receive(kind, computerId: id, computerName: name) } }
    }

    /// An unpair from either side ends the requests of the computer. A link
    /// that only drops keeps them, so that a tap after a reconnect still
    /// works. The core lock is held.
    public func onDisconnected(_ device: Device) {
        guard !device.paired else { return }
        let id = device.id
        DispatchQueue.main.async { MainActor.assumeIsolated { self.forget(id) } }
    }

    // MARK: Requests

    /// Takes a request from a computer. A new request shows the prompt
    /// while the app is on the screen, else a notification.
    @MainActor
    func receive(_ kind: StreamRequest.Kind, computerId: String, computerName: String, at now: ContinuousClock.Instant = .now) {
        switch book.receive(kind, computerId: computerId, computerName: computerName, streaming: streams(kind, to: computerId), at: now) {
        case .tooSoon:
            FluxLog.plugin.info("stream request: ignored a \(kind.rawValue, privacy: .public) request from \(computerName, privacy: .public) that came less than 3 seconds after the last one")
        case .streaming:
            FluxLog.plugin.info("stream request: ignored a \(kind.rawValue, privacy: .public) request from \(computerName, privacy: .public), because the stream runs")
        case .opened(let r):
            publish()
            arm(r)
            if model.isAppActive?() == true {
                Notifier.shared.remove(id: r.id)
                model.present?()
            } else {
                Notifier.shared.post(id: r.id, category: kind.notificationCategory, title: r.title, body: kind.notificationText(),
                                     userInfo: ["id": r.id, "computer": r.computerId])
            }
        }
    }

    /// Starts the stream of an open request after a tap of the user on
    /// start in the prompt. The request ends. A request that ended or is
    /// too old starts nothing. When a stream of the kind already runs to
    /// the computer, the request does nothing. A tap on the notification
    /// goes to `startFromNotification`.
    @MainActor
    public func start(_ id: String, at now: ContinuousClock.Instant = .now) {
        take(id, at: now)
    }

    /// Starts the stream of a request after a tap on its notification.
    /// When the request ended or is too old, it only opens the page of the
    /// computer, and the user starts the stream there. An example is a tap
    /// near the end of the 60 seconds and a slow unlock of the iPhone.
    /// `computerId` is nil when the notification does not name the
    /// computer. Then a request that ended opens nothing.
    @MainActor
    func startFromNotification(_ id: String, kind: StreamRequest.Kind, computerId: String?,
                               at now: ContinuousClock.Instant = .now) {
        guard !take(id, at: now), let computerId else { return }
        model.openPage?(computerId, kind)
    }

    /// Ends an open request and opens its stream, unless a stream of the
    /// kind already runs to the computer. It returns false when the
    /// request ended or is too old.
    @MainActor
    @discardableResult
    private func take(_ id: String, at now: ContinuousClock.Instant) -> Bool {
        guard let r = book.remove(id) else { return false }
        end([r])
        guard book.fresh(r, at: now) else {
            FluxLog.plugin.info("stream request: the \(r.kind.rawValue, privacy: .public) request of \(r.computerName, privacy: .public) is too old")
            return false
        }
        if !streams(r.kind, to: r.computerId) { model.open?(r) }
        return true
    }

    /// Ends an open request without a stream: "Not now".
    @MainActor
    public func dismiss(_ id: String) {
        guard let r = book.remove(id) else { return }
        end([r])
    }

    /// Ends the requests that are too old. The timer of each request does
    /// it too, but a suspended iOS app runs no timer, so the app also
    /// calls it when it comes on the screen.
    @MainActor
    public func expire(at now: ContinuousClock.Instant = .now) {
        let old = book.expire(at: now)
        if !old.isEmpty { end(old) }
    }

    /// True while a stream of the kind runs or starts to the computer.
    @MainActor
    public func streams(_ kind: StreamRequest.Kind, to computerId: String) -> Bool {
        switch kind {
        case .webcam:
            return Self.streams(webcam: core?.plugin(WebcamPlugin.self)?.model.status, to: computerId)
        case .mic:
            return Self.streams(mic: core?.plugin(MicPlugin.self)?.model.status, to: computerId)
        }
    }

    static func streams(webcam status: StreamStatus?, to computerId: String) -> Bool {
        status?.active(for: computerId) == true
    }

    static func streams(mic status: MicModel.Status?, to computerId: String) -> Bool {
        guard let status else { return false }
        return status.active && status.deviceId == computerId
    }

    /// Ends the requests of a computer that is no longer paired.
    @MainActor
    func forget(_ computerId: String) {
        let gone = book.forget(computerId)
        if !gone.isEmpty { end(gone) }
    }

    /// Removes the timers and the notifications of the ended requests, and
    /// shows the open requests.
    @MainActor
    private func end(_ ended: [StreamRequest]) {
        for r in ended {
            expiries.removeValue(forKey: r.id)?.cancel()
            Notifier.shared.remove(id: r.id)
        }
        publish()
    }

    /// Ends the request after its lifetime. A new request of the same
    /// computer and kind replaces the timer.
    @MainActor
    private func arm(_ r: StreamRequest) {
        expiries[r.id]?.cancel()
        let deadline = r.received + book.lifetime
        expiries[r.id] = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.expire()
        }
    }

    @MainActor
    private func publish() {
        if model.requests != book.requests { model.requests = book.requests }
    }
}
