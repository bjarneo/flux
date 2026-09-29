import Foundation

/// How long a pairing request from this device waits for an answer.
let outgoingPairTimeout: TimeInterval = 30
/// How long an incoming pairing request stays open.
let incomingPairTimeout: TimeInterval = 25
/// The largest clock difference that a pairing request may have.
let maxTimestampDifference: Int64 = 1800

/// The pairing state of one device.
public enum PairState: String, Sendable {
    case none, requested, incoming, paired
}

/// One remote device. The core holds one object per device ID. All fields
/// are guarded by the core lock.
public final class Device: @unchecked Sendable {
    unowned let core: FluxCore
    public internal(set) var identity: Identity
    public internal(set) var link: Link?
    public internal(set) var certificate: [UInt8]?
    public internal(set) var lastIp = ""

    public internal(set) var pairState = PairState.none
    var pairTimestamp: Int64 = 0
    public internal(set) var pairKey = ""
    private var pairTimer: DispatchWorkItem?

    init(core: FluxCore, identity: Identity) {
        self.core = core
        self.identity = identity
    }

    public var id: String { identity.deviceId }
    public var name: String { identity.deviceName }
    public var online: Bool { link?.isOpen == true }
    public var paired: Bool { pairState == .paired }

    /// Sends a packet. It returns false when the device is not paired or has
    /// no open link. A peer that gets a plugin packet before pairing answers
    /// with an unpair, so only pair packets go to an unpaired device.
    @discardableResult
    public func send(_ p: Packet) -> Bool {
        if !paired && p.type != PacketType.pair { return false }
        guard let l = link, l.isOpen else { return false }
        l.send(p)
        return true
    }

    /// True when the peer accepts packets of the type.
    public func accepts(_ type: String) -> Bool { identity.incoming.contains(type) }

    func snapshot() -> DeviceSnapshot {
        DeviceSnapshot(
            id: id,
            name: identity.deviceName,
            type: identity.deviceType,
            ip: link?.address ?? lastIp,
            isFlux: identity.isFlux,
            paired: paired,
            online: online,
            pairState: pairState,
            pairKey: pairKey,
            incoming: identity.incoming,
            outgoing: identity.outgoing
        )
    }

    // MARK: Pairing

    /// Returns the key that a request with the timestamp shows, before it is sent.
    func previewKey(timestamp: Int64) -> String {
        guard let peer = certificate else { return "" }
        return verificationKey(ownCertificate: core.local.certificateDER, peerCertificate: peer, timestamp: timestamp)
    }

    /// Sends a pairing request with the timestamp that the dialog showed.
    func requestPair(timestamp: Int64) {
        guard online, !paired else { return }
        pairTimestamp = timestamp
        pairState = .requested
        pairKey = computeKey()
        send(Packet(PacketType.pair, ["pair": true, "timestamp": pairTimestamp]))
        armTimer(outgoingPairTimeout)
    }

    /// The user accepted an incoming request.
    func acceptPair() {
        guard pairState == .incoming else { return }
        send(Packet(PacketType.pair, ["pair": true]))
        pairingDone()
    }

    /// The user canceled a request or rejected an incoming request.
    func cancelPair() {
        guard pairState == .requested || pairState == .incoming else { return }
        send(Packet(PacketType.pair, ["pair": false]))
        resetPair()
    }

    func unpair() {
        send(Packet(PacketType.pair, ["pair": false]))
        core.trust.remove(id)
        resetPair()
    }

    /// The message after a computer ends the pairing.
    static func unpairedText(computer: String, platform: FluxPlatform = .current) -> String {
        "\(computer) unpaired \(platform.deviceNoun)"
    }

    /// Handles a flux.pair packet.
    func onPairPacket(_ p: Packet) {
        let wants = p.bool("pair") ?? false
        if !wants {
            let wasPaired = paired
            if wasPaired { core.trust.remove(id) }
            if pairState == .requested {
                core.toast("\(name) rejected the pairing")
            } else if wasPaired {
                core.toast(Self.unpairedText(computer: name))
            }
            resetPair()
            if wasPaired { core.didUnpair(self) }
            return
        }
        switch pairState {
        case .requested:
            pairingDone()
        case .incoming:
            break
        case .paired:
            // The peer lost the pairing, for example after a reinstall.
            // Forget the old trust and show the request again.
            core.trust.remove(id)
            pairState = .none
            incoming(p)
        case .none:
            incoming(p)
        }
    }

    private func incoming(_ p: Packet) {
        let now = Int64(Date().timeIntervalSince1970)
        guard let ts = p.long("timestamp"), abs(now - ts) <= maxTimestampDifference else {
            send(Packet(PacketType.pair, ["pair": false]))
            core.toast(p.long("timestamp") == nil ? "Pairing refused: \(name) sent no timestamp" : "Pairing refused: the clock of \(name) is wrong")
            return
        }
        pairTimestamp = ts
        pairKey = computeKey()
        pairState = .incoming
        armTimer(incomingPairTimeout)
        core.notifyPairRequest(self)
    }

    private func pairingDone() {
        pairTimer?.cancel()
        guard let cert = certificate else { return }
        pairState = .paired
        core.trust.put(TrustedDevice(
            id: id,
            name: identity.deviceName,
            type: identity.deviceType,
            certificate: Data(cert).base64EncodedString(),
            lastIp: link?.address ?? "",
            isFlux: identity.isFlux
        ))
        core.toast("Paired with \(name)")
        core.onPaired(self)
    }

    private func resetPair() {
        pairTimer?.cancel()
        pairState = .none
        pairKey = ""
    }

    private func armTimer(_ seconds: TimeInterval) {
        pairTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.core.locked {
                if self.pairState == .requested {
                    self.send(Packet(PacketType.pair, ["pair": false]))
                    self.core.toast("Pairing with \(self.name) timed out")
                }
                if self.pairState == .requested || self.pairState == .incoming { self.resetPair() }
            }
        }
        pairTimer = item
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func computeKey() -> String {
        guard let peer = certificate else { return "" }
        return verificationKey(ownCertificate: core.local.certificateDER, peerCertificate: peer, timestamp: pairTimestamp)
    }
}

/// A snapshot of one device for the UI.
public struct DeviceSnapshot: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var type: String
    public var ip: String
    public var isFlux: Bool
    public var paired: Bool
    public var online: Bool
    public var pairState: PairState
    public var pairKey: String
    public var incoming: [String]
    public var outgoing: [String]

    /// The apps build sample devices with it, for example for the demo of
    /// the iOS app.
    public init(id: String, name: String, type: String, ip: String, isFlux: Bool, paired: Bool, online: Bool,
                pairState: PairState, pairKey: String, incoming: [String], outgoing: [String]) {
        self.id = id
        self.name = name
        self.type = type
        self.ip = ip
        self.isFlux = isFlux
        self.paired = paired
        self.online = online
        self.pairState = pairState
        self.pairKey = pairKey
        self.incoming = incoming
        self.outgoing = outgoing
    }

    /// True when the peer accepts packets of the type.
    public func accepts(_ type: String) -> Bool { incoming.contains(type) }
}
