import Foundation
import FluxProto

/// Pairing state for one device. Mirrors Android `core/Model.kt PairState`
/// (`None`, `Requested`, `Incoming`, `Paired`) with the key + timestamp
/// carried alongside, like Go's `pairState`/`pairKey`/`pairTime`.
public enum PairState: Sendable, Equatable {
    case none
    case requested(timestamp: Int64, key: String)
    case incoming(timestamp: Int64, key: String)
    case paired
}

/// What the UI / trust layer should do after a pairing input.
public enum PairingEvent: Sendable, Equatable {
    /// Show the incoming request (key compare + Accept/Decline).
    case showRequest(key: String)
    /// Outgoing request was accepted; persist trust for `certificateDER`.
    case accepted
    /// Request was rejected, cancelled, unpaired, or timed out.
    case closed(reason: PairingCloseReason)
    /// The peer re-requested while paired (it lost its trust, e.g. after a
    /// reinstall). Local trust was dropped; confirm the key again.
    case trustReset(key: String)
    /// The peer re-requested while paired but invalidly (no timestamp /
    /// clock skew on v8). Local trust was dropped and a refusal was sent;
    /// do not show a dialog.
    case trustResetRefused(reason: PairingRefuseReason)
    /// Incoming packet was refused (no timestamp / clock skew on v8).
    /// The session already answered `{"pair": false}`.
    case refused(reason: PairingRefuseReason)
}

public enum PairingCloseReason: Sendable, Equatable {
    case rejectedByPeer
    case rejectedLocally
    case unpairedByPeer
    case unpairedLocally
    case timedOut
    case cancelled
}

public enum PairingRefuseReason: Sendable, Equatable {
    case missingTimestamp
    case clockSkew
}

/// One side of the `kdeconnect.pair` handshake.
///
/// Mirrors Android `core/Device.kt` pairing methods and Go
/// `internal/core/pairing.go` `handlePair`:
/// - Only pair packets flow before pairing (plugin packets to unpaired
///   devices are dropped by the caller; the peer answers with unpair).
/// - `pair:false` while paired removes trust and reports `unpairedByPeer`.
/// - `pair:true` while already paired means the peer lost its trust:
///   drop local trust and surface the request again.
/// - Timeouts are explicit (`expire(now:)`): outgoing 30 s, incoming 25 s.
///   The caller sends `Pairing.reject()` on timeout for outgoing requests,
///   like Android `armTimer`.
///
/// Key computation is injected (`keyForSPKI`) so tests run without a
/// Secure Enclave; production passes `Certificates.verificationKey` with
/// the local SPKI. The timestamp is protocol-gated (v8+ uses it, older
/// peers omit it), matching `previewKey`/`computeKey`/`keyLocked`.
public actor PairingSession {
    public let peerId: String
    public let peerProtocolVersion: Int
    public private(set) var state: PairState = .none

    private let ownSPKI: Data
    private let peerSPKI: Data
    private let keyForSPKI: @Sendable (Data, Data, Int64) -> String
    private let now: @Sendable () -> Date
    private var deadline: Date?

    public init(
        peerId: String,
        peerProtocolVersion: Int = FluxProto.protocolVersion,
        ownSPKI: Data,
        peerSPKI: Data,
        keyForSPKI: @Sendable @escaping (Data, Data, Int64) -> String = Certificates.verificationKey,
        now: @Sendable @escaping () -> Date = Date.init
    ) {
        self.peerId = peerId
        self.peerProtocolVersion = peerProtocolVersion
        self.ownSPKI = ownSPKI
        self.peerSPKI = peerSPKI
        self.keyForSPKI = keyForSPKI
        self.now = now
    }

    private func key(timestamp: Int64) -> String {
        keyForSPKI(ownSPKI, peerSPKI, Pairing.keyTimestamp(pairTimestamp: timestamp, protocolVersion: peerProtocolVersion))
    }

    // MARK: - Outgoing (this phone pairs to the desktop)

    /// Starts an outgoing request. Returns the packet to send plus the key
    /// the dialog must show (the key is fixed before sending, like Android
    /// `requestPair` / Go `RequestPair`).
    @discardableResult
    public func startOutgoing(timestamp: Int64? = nil) -> (packet: Packet, key: String)? {
        guard case .none = state else { return nil }
        let ts = timestamp ?? Int64(now().timeIntervalSince1970)
        let k = key(timestamp: ts)
        state = .requested(timestamp: ts, key: k)
        deadline = now().addingTimeInterval(Pairing.outgoingTimeout)
        return (Pairing.request(timestamp: ts), k)
    }

    // MARK: - Incoming (desktop pairs to this phone)

    /// Handles one received `kdeconnect.pair` packet.
    ///
    /// Returns the event plus zero or more packets to send (refusals and
    /// timeout-cancels answer `{"pair": false}` immediately).
    public func receive(_ packet: Packet) -> (event: PairingEvent?, send: [Packet]) {
        guard let msg = Pairing.parse(packet) else { return (nil, []) }
        switch msg {
        case .reject:
            return handleReject()
        case .accept:
            return handleAccept()
        case .request(let ts):
            return handleRequest(timestamp: ts)
        }
    }

    private func handleReject() -> (PairingEvent?, [Packet]) {
        switch state {
        case .none:
            return (nil, [])
        case .requested:
            state = .none
            deadline = nil
            return (.closed(reason: .rejectedByPeer), [])
        case .incoming:
            // Peer cancelled its own request.
            state = .none
            deadline = nil
            return (.closed(reason: .cancelled), [])
        case .paired:
            state = .none
            deadline = nil
            return (.closed(reason: .unpairedByPeer), [])
        }
    }

    private func handleAccept() -> (PairingEvent?, [Packet]) {
        switch state {
        case .requested:
            state = .paired
            deadline = nil
            return (.accepted, [])
        case .incoming:
            // Bare accept while incoming: peer confusion; keep waiting.
            return (nil, [])
        case .paired:
            // Unsolicited bare accept while paired: the peer re-asks. Before
            // protocol v8 there is no timestamp, so it is valid; on v8 it
            // is a request without a timestamp — drop trust and refuse.
            state = .none
            deadline = nil
            if peerProtocolVersion < 8 {
                let k = key(timestamp: 0)
                state = .incoming(timestamp: 0, key: k)
                deadline = now().addingTimeInterval(Pairing.incomingTimeout)
                return (.trustReset(key: k), [])
            }
            return (.trustResetRefused(reason: .missingTimestamp), [Pairing.reject()])
        case .none:
            // Unsolicited bare accept while idle: before v8 it is a valid
            // request (no timestamps exist); on v8 it is a request without
            // a timestamp — refuse it.
            if peerProtocolVersion < 8 {
                let k = key(timestamp: 0)
                state = .incoming(timestamp: 0, key: k)
                deadline = now().addingTimeInterval(Pairing.incomingTimeout)
                return (.showRequest(key: k), [])
            }
            return (.refused(reason: .missingTimestamp), [Pairing.reject()])
        }
    }

    private func handleRequest(timestamp: Int64?) -> (PairingEvent?, [Packet]) {
        switch state {
        case .requested:
            // Simultaneous request while we wait: the accept path resolves
            // it — treat like Android (`Requested -> pairingDone` on any
            // `pair:true`). Accept and finish.
            state = .paired
            deadline = nil
            return (.accepted, [])
        case .incoming:
            return (nil, [])
        case .paired:
            // The peer lost its trust (reinstall). Forget and ask again,
            // like Android + Go. Invalid requests still drop trust first.
            state = .none
            deadline = nil
            guard Pairing.validTimestamp(timestamp, protocolVersion: peerProtocolVersion, now: now()) else {
                return (.trustResetRefused(reason: timestamp == nil ? .missingTimestamp : .clockSkew), [Pairing.reject()])
            }
            let ts = timestamp ?? 0
            let k = key(timestamp: ts)
            state = .incoming(timestamp: ts, key: k)
            deadline = now().addingTimeInterval(Pairing.incomingTimeout)
            return (.trustReset(key: k), [])
        case .none:
            guard Pairing.validTimestamp(timestamp, protocolVersion: peerProtocolVersion, now: now()) else {
                return (.refused(reason: timestamp == nil ? .missingTimestamp : .clockSkew), [Pairing.reject()])
            }
            let ts = timestamp ?? 0
            let k = key(timestamp: ts)
            state = .incoming(timestamp: ts, key: k)
            deadline = now().addingTimeInterval(Pairing.incomingTimeout)
            return (.showRequest(key: k), [])
        }
    }

    // MARK: - Local actions

    /// Accepts the incoming request. Returns the accept packet to send.
    public func accept() -> Packet? {
        guard case .incoming = state else { return nil }
        state = .paired
        deadline = nil
        return Pairing.accept()
    }

    /// Rejects the incoming request (or cancels the outgoing one).
    /// Returns the reject packet to send.
    public func reject() -> Packet? {
        switch state {
        case .incoming:
            state = .none
            deadline = nil
            return Pairing.reject()
        case .requested:
            state = .none
            deadline = nil
            return Pairing.reject()
        case .paired, .none:
            return nil
        }
    }

    /// Unpairs. Returns the `{"pair": false}` packet to send; the caller
    /// removes trust.
    public func unpair() -> Packet? {
        switch state {
        case .paired, .requested, .incoming:
            state = .none
            deadline = nil
            return Pairing.reject()
        case .none:
            return nil
        }
    }

    /// Expires an open request past its deadline. Returns the close event
    /// plus the cancel packet for outgoing requests (Android `armTimer`
    /// sends `pair:false` on outgoing timeout only).
    public func expire(now date: Date? = nil) -> (event: PairingEvent?, send: [Packet]) {
        let at = date ?? now()
        guard let deadline, at >= deadline else { return (nil, []) }
        switch state {
        case .requested:
            state = .none
            self.deadline = nil
            return (.closed(reason: .timedOut), [Pairing.reject()])
        case .incoming:
            state = .none
            self.deadline = nil
            return (.closed(reason: .timedOut), [])
        case .paired, .none:
            self.deadline = nil
            return (nil, [])
        }
    }

    /// Marks the session paired after the trust was persisted (accept path).
    public var isPaired: Bool {
        if case .paired = state { return true }
        return false
    }
}
