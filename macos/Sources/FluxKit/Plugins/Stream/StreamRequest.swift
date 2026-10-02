import Foundation

/// A request of a computer to start the webcam or the microphone of this
/// device. `flux-cli webcam start` and `flux-cli mic start` send it as
/// flux.stream.request. The request only asks. The stream starts only
/// after a tap of the user on this device.
public struct StreamRequest: Sendable, Equatable, Identifiable {
    /// The stream that the computer asks for.
    public enum Kind: String, Sendable, CaseIterable {
        case webcam, mic

        /// The kind of a flux.stream.request packet. It is nil for another
        /// packet type and for another kind. Other fields of the body do
        /// not change the result.
        public static func parse(_ packet: Packet) -> Kind? {
            guard packet.type == PacketType.fluxStreamRequest else { return nil }
            return packet.string("kind").flatMap(Kind.init(rawValue:))
        }

        /// The title of the prompt and of the notification.
        public func title(computer: String) -> String {
            switch self {
            case .webcam: return "\(computer) asks for the webcam"
            case .mic: return "\(computer) asks for the mic"
            }
        }

        /// The label of the button and of the notification action that
        /// start the stream.
        public var startLabel: String {
            switch self {
            case .webcam: return "Start webcam"
            case .mic: return "Start the mic"
            }
        }

        /// The text of the notification. An iPhone asks for a tap, and a
        /// Mac asks for a click.
        public func notificationText(platform: FluxPlatform = .current) -> String {
            let verb = platform == .mac ? "Click" : "Tap"
            switch self {
            case .webcam: return "\(verb) to start the webcam."
            case .mic: return "\(verb) to start the mic."
            }
        }

        /// The text under the title of the prompt.
        public func detail(computer: String, platform: FluxPlatform = .current) -> String {
            switch self {
            case .webcam:
                return "Apps on \(computer) see \(platform.deviceNoun) as Flux Camera. The camera stays off until you select \(startLabel)."
            case .mic:
                return "Apps on \(computer) see \(platform.deviceNoun) as Flux Microphone. The microphone stays off until you select \(startLabel)."
            }
        }

        /// The notification category. Each kind has its own category,
        /// because the start action of each kind has its own label.
        public var notificationCategory: String { "stream.\(rawValue)" }
    }

    /// The label of the button that closes the prompt and starts nothing.
    public static let notNowLabel = "Not now"

    /// The shortest time between 2 requests of the same kind from the same
    /// computer. This device ignores a request that comes sooner after the
    /// last request, also when it ignored that last request.
    public static let minInterval: Duration = .seconds(3)
    /// The time after which an open request ends without an answer. The
    /// notification goes away then.
    public static let lifetime: Duration = .seconds(60)

    public var computerId: String
    public var computerName: String
    public var kind: Kind
    /// The time when this device took the request.
    public var received: ContinuousClock.Instant

    public init(computerId: String, computerName: String, kind: Kind, received: ContinuousClock.Instant) {
        self.computerId = computerId
        self.computerName = computerName
        self.kind = kind
        self.received = received
    }

    /// Each computer has at most 1 open request of each kind, so the ID
    /// comes from the kind and the computer. The notification has the same ID.
    public var id: String { Self.id(kind, computerId) }

    static func id(_ kind: Kind, _ computerId: String) -> String { "stream.\(kind.rawValue).\(computerId)" }

    /// The title of the prompt and of the notification.
    public var title: String { kind.title(computer: computerName) }
}

/// The open stream requests of all computers, with the time limits. It
/// holds no timer. The caller gives the time of each change. The clock
/// also counts while the device sleeps.
struct StreamRequestBook: Equatable {
    /// What `receive` did with a request.
    enum Outcome: Equatable {
        /// The request is open. It replaced the open request of the same
        /// computer and kind.
        case opened(StreamRequest)
        /// The request came less than `StreamRequest.minInterval` after the last
        /// request of the same computer and kind.
        case tooSoon
        /// A stream of the same kind already runs to the computer.
        case streaming
    }

    /// The time after which an open request ends. A test sets a shorter time.
    var lifetime = StreamRequest.lifetime
    /// The open requests, the oldest first.
    private(set) var requests: [StreamRequest] = []
    /// The time of the last request, by request ID. An ignored request
    /// counts too.
    private var last: [String: ContinuousClock.Instant] = [:]

    /// Takes a request, or ignores it. `streaming` is true when a stream of
    /// the kind already runs to the computer. An ignored request also moves
    /// the time of the last request, so that a computer that repeats a
    /// request faster than `StreamRequest.minInterval` shows 1 request only.
    /// Android counts the requests in the same way.
    mutating func receive(_ kind: StreamRequest.Kind, computerId: String, computerName: String, streaming: Bool,
                          at now: ContinuousClock.Instant) -> Outcome {
        let id = StreamRequest.id(kind, computerId)
        let previous = last[id]
        last = last.filter { now - $0.value < StreamRequest.minInterval }
        last[id] = now
        if let previous, now - previous < StreamRequest.minInterval { return .tooSoon }
        if streaming { return .streaming }
        let request = StreamRequest(computerId: computerId, computerName: computerName, kind: kind, received: now)
        requests.removeAll { $0.id == id }
        requests.append(request)
        return .opened(request)
    }

    /// True while the request is younger than `lifetime`.
    func fresh(_ request: StreamRequest, at now: ContinuousClock.Instant) -> Bool {
        now - request.received < lifetime
    }

    /// Ends the request with the ID and returns it, or nil when it is not open.
    @discardableResult
    mutating func remove(_ id: String) -> StreamRequest? {
        guard let i = requests.firstIndex(where: { $0.id == id }) else { return nil }
        return requests.remove(at: i)
    }

    /// Ends the requests that are `lifetime` old or older, and returns them.
    mutating func expire(at now: ContinuousClock.Instant) -> [StreamRequest] {
        // A local copy, because the closure of removeAll cannot read self.
        let limit = lifetime
        let old = requests.filter { now - $0.received >= limit }
        requests.removeAll { now - $0.received >= limit }
        return old
    }

    /// Ends the requests of a computer, and returns them.
    mutating func forget(_ computerId: String) -> [StreamRequest] {
        let gone = requests.filter { $0.computerId == computerId }
        requests.removeAll { $0.computerId == computerId }
        let ids = Set(StreamRequest.Kind.allCases.map { StreamRequest.id($0, computerId) })
        last = last.filter { !ids.contains($0.key) }
        return gone
    }
}

/// A start that waits after a tap or a click on start. Both streams need
/// the link to the computer, and the webcam of an iPhone also needs Flux on
/// the screen. A tap on the notification opens Flux, and the link can come
/// back a moment later. The iPhone app and the Mac app use it.
public struct PendingStart: Equatable, Sendable {
    /// How long a start waits for Flux on the screen and for the link.
    public static let wait: Duration = .seconds(15)

    public let kind: StreamRequest.Kind
    public let computerId: String
    public let computerName: String
    public let deadline: ContinuousClock.Instant

    public init(kind: StreamRequest.Kind, computerId: String, computerName: String, deadline: ContinuousClock.Instant) {
        self.kind = kind
        self.computerId = computerId
        self.computerName = computerName
        self.deadline = deadline
    }

    /// The start of the request, with the deadline `wait` after `now`.
    public init(_ request: StreamRequest, now: ContinuousClock.Instant) {
        self.init(kind: request.kind, computerId: request.computerId, computerName: request.computerName, deadline: now + Self.wait)
    }

    public enum Step: Equatable, Sendable {
        case wait
        case start
        /// The link did not come back before the deadline.
        case giveUp
    }

    /// The next step of the start. A Mac gives true for `active`, because
    /// its camera also works while Flux is not the active app.
    public func step(active: Bool, online: Bool, now: ContinuousClock.Instant) -> Step {
        if active && online { return .start }
        return now < deadline ? .wait : .giveUp
    }

    /// The message when the stream did not start.
    public var failedText: String {
        switch kind {
        case .webcam: return "The webcam did not start, because \(computerName) is not connected."
        case .mic: return "The microphone did not start, because \(computerName) is not connected."
        }
    }
}
