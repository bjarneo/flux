import Foundation

/// How long a pairing request from this device waits for an answer.
let outgoingPairTimeout: TimeInterval = 30
/// How long an incoming pairing request stays open.
let incomingPairTimeout: TimeInterval = 25
/// The largest clock difference that a pairing request may have.
let maxTimestampDifference: Int64 = 1800
/// How long a host waits before its next pairing request counts, after its
/// incoming request ended without a pairing.
let pairCooldownSeconds: TimeInterval = 30

/// The computers and addresses whose incoming pairing request ended without
/// a pairing, for example after a reject or a timeout. Their next requests
/// end at once for `seconds`, so that a host on the network cannot hold the
/// only open request or show a new request each time.
struct PairCooldown {
    var seconds = pairCooldownSeconds
    /// The time of each end, in `ProcessInfo.systemUptime`, by device ID and by address.
    private var ended: [String: TimeInterval] = [:]

    mutating func add(id: String, ip: String, at now: TimeInterval) {
        ended = ended.filter { now - $0.value < seconds }
        for key in Self.keys(id: id, ip: ip) { ended[key] = now }
    }

    func blocks(id: String, ip: String, at now: TimeInterval) -> Bool {
        Self.keys(id: id, ip: ip).contains { key in ended[key].map { now - $0 < seconds } ?? false }
    }

    private static func keys(id: String, ip: String) -> [String] {
        ip.isEmpty ? ["id " + id] : ["id " + id, "ip " + ip]
    }
}

/// The pairing state of one device.
public enum PairState: String, Sendable {
    case none, requested, incoming, paired
}

/// One remote device. The core holds one object per device ID. All fields
/// are guarded by the core lock.
public final class Device: @unchecked Sendable {
    unowned let core: FluxCore
    public internal(set) var identity: Identity
    public internal(set) var link: Link? {
        didSet { link?.setPaired(paired) }
    }
    public internal(set) var certificate: [UInt8]?
    public internal(set) var lastIp = ""

    public internal(set) var pairState = PairState.none {
        didSet {
            link?.setPaired(paired)
            // An incoming request that ends without a pairing makes its
            // host wait, see `PairCooldown`.
            if oldValue == .incoming, pairState == .none { core.incomingPairEnded(self) }
        }
    }
    var pairTimestamp: Int64 = 0
    public internal(set) var pairKey = ""
    private var pairTimer: DispatchWorkItem?

    /// The certificate that `pairKey` comes from. A pairing pins only this
    /// certificate, the one behind the key that the user compared.
    var pairCertificate: [UInt8]?

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
        computeKey()
        send(Packet(PacketType.pair, ["pair": true, "timestamp": pairTimestamp]))
        armTimer(outgoingPairTimeout)
    }

    /// The user accepted an incoming request.
    func acceptPair() {
        guard pairState == .incoming else { return }
        // pairingDone refuses a changed certificate and answers pair false.
        if keyCertificateHolds { send(Packet(PacketType.pair, ["pair": true])) }
        pairingDone()
    }

    /// True when the link still shows the certificate behind the key.
    private var keyCertificateHolds: Bool {
        Self.keyHolds(pairCertificate: pairCertificate, certificate: certificate, linkCertificate: link?.peerCertificate)
    }

    /// Reports whether the device and its link still show the certificate
    /// behind the key, `pairCertificate`. Without a key or a link it is false.
    static func keyHolds(pairCertificate: [UInt8]?, certificate: [UInt8]?, linkCertificate: [UInt8]?) -> Bool {
        guard let cert = pairCertificate else { return false }
        return certificate == cert && linkCertificate == cert
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

    /// The message after a new link ends a pairing. After an incoming
    /// request, the computer waits `pairCooldownSeconds` before its next
    /// request counts, so the message names the path that works.
    static func pairStoppedText(computer: String, incoming: Bool, platform: FluxPlatform = .current) -> String {
        incoming
            ? "The pairing with \(computer) stopped. Pair again from \(platform.deviceNoun), or wait \(Int(pairCooldownSeconds)) seconds"
            : "The pairing with \(computer) stopped. Try again"
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
            // Forget the old trust, end the sessions of the pairing, and
            // show the request again.
            core.trust.remove(id)
            pairState = .none
            core.didUnpair(self)
            incoming(p)
        case .none:
            incoming(p)
        }
    }

    /// Reports whether a pairing timestamp is within the allowed clock
    /// difference. `now` is small, so the bounds cannot overflow, and any
    /// timestamp from a peer is safe.
    static func timestampFresh(_ ts: Int64, now: Int64) -> Bool {
        ts >= now - maxTimestampDifference && ts <= now + maxTimestampDifference
    }

    private func incoming(_ p: Packet) {
        // A host whose last request ended without a pairing waits. The
        // refusal shows no notification.
        guard !core.pairCooldownBlocks(self) else {
            FluxLog.core.info("refused a pairing request from \(self.name, privacy: .public): a request from this computer or address ended less than \(Int(pairCooldownSeconds)) seconds ago")
            send(Packet(PacketType.pair, ["pair": false]))
            return
        }
        let now = Int64(Date().timeIntervalSince1970)
        guard let ts = p.long("timestamp"), Self.timestampFresh(ts, now: now) else {
            send(Packet(PacketType.pair, ["pair": false]))
            core.toast(p.long("timestamp") == nil ? "Pairing refused: \(name) sent no timestamp" : "Pairing refused: the clock of \(name) is wrong")
            return
        }
        // 1 request at a time, so that other devices cannot bury it.
        guard !core.hasIncomingPair(except: id) else {
            FluxLog.core.info("refused a pairing request from \(self.name, privacy: .public): another request is open")
            send(Packet(PacketType.pair, ["pair": false]))
            return
        }
        pairTimestamp = ts
        computeKey()
        pairState = .incoming
        armTimer(core.incomingPairSeconds)
        core.notifyPairRequest(self)
    }

    /// Pins the certificate behind the key. A link that changed its
    /// certificate after the key was shown ends the pairing instead.
    private func pairingDone() {
        pairTimer?.cancel()
        guard keyCertificateHolds, let cert = pairCertificate else {
            FluxLog.core.error("pairing with \(self.name, privacy: .public) refused: the certificate changed after the key was shown")
            send(Packet(PacketType.pair, ["pair": false]))
            core.toast("Pairing with \(name) failed. Try again")
            resetPair()
            return
        }
        pairState = .paired
        let saved = core.trust.put(TrustedDevice(
            id: id,
            name: identity.deviceName,
            type: identity.deviceType,
            certificate: Data(cert).base64EncodedString(),
            lastIp: link?.address ?? "",
            isFlux: identity.isFlux
        ))
        core.toast(saved ? "Paired with \(name)" : "Paired with \(name), but Flux cannot save the pairing. Pair again after Flux restarts")
        core.onPaired(self)
    }

    /// Ends an open pairing on this side and sends nothing.
    func resetPair() {
        pairTimer?.cancel()
        pairState = .none
        pairKey = ""
        pairCertificate = nil
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

    /// Sets the key for the current certificate and remembers that certificate.
    private func computeKey() {
        pairCertificate = certificate
        guard let peer = certificate else {
            pairKey = ""
            return
        }
        pairKey = verificationKey(ownCertificate: core.local.certificateDER, peerCertificate: peer, timestamp: pairTimestamp)
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
