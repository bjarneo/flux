import Foundation
import Dispatch
import FluxProto
import FluxNet
import FluxApprove
#if canImport(Security)
import Security
#endif

/// App-layer link owner (D6/D7): TCP listener + mDNS publish + `LinkRunner`.
///
/// Mirrors `FluxTestPeer.run` minus the harness flags: persisted identity,
/// first-free TCP port, one `LinkRunner` per inbound connection, events
/// forwarded for the UI/log. Discovery is mDNS-only on the free tier (no
/// UDP broadcast without the multicast entitlement); the desktop dials the
/// published TCP port (architecture: the desktop always opens connections).
///
/// Lifecycle: the app calls `start()` on launch + foreground and `stop()`
/// on background (iOS suspends the link anyway; the banner stays honest).
/// Pairing prompts are held in `pairApproval` for the UI (`PairView`
/// resolves them; unanswered prompts expire silently like an incoming
/// expiry). Approval prompts flow through `ApproveFlow` the same way
/// (`ApprovePromptScreen` + biometric signing).
public final class LinkService: @unchecked Sendable {
    /// Coarse state for the UI presence mapping (`LinkPresence` stays in
    /// `FluxUI`; this module must not import it).
    public enum State: Sendable, Equatable {
        case stopped
        case listening(port: Int)
        case connected(device: String)
    }

    public var onEvent: (@Sendable (LinkRunner.Event) -> Void)?
    public var onState: (@Sendable (State) -> Void)?

    /// Manual Accept path for `PairView` (stage B): the session thread
    /// blocks in `decide` until the UI calls `resolve(peerId:accept:)`.
    public let pairApproval = PairApproval()

    private let deviceName: String
    private let batteryProvider: (@Sendable () -> BatteryState?)?
    private let nowPlayingProvider: (@Sendable () -> MprisState?)?
    private let approveDecider: ((ApproveRequest) -> Packet?)?
    private let lock = NSLock()
    private nonisolated(unsafe) var tcpFD: Int32 = -1
    private nonisolated(unsafe) var running = false
    /// Live sessions for app-originated packets (D23). Weak: each runner
    /// is held strongly by its own session thread and dies with it; the
    /// registry only fans `send` out. Swept on every send + stop.
    private nonisolated(unsafe) var liveRunners: [WeakRunner] = []
    private var advertiser: NetService?
    private var advertiserDelegate: AdvertiserDelegate?
    private var browser: NetServiceBrowser?
    private var browserDelegate: BrowseDelegate?

    public init(
        deviceName: String,
        batteryProvider: (@Sendable () -> BatteryState?)? = nil,
        nowPlayingProvider: (@Sendable () -> MprisState?)? = nil,
        approveDecider: ((ApproveRequest) -> Packet?)? = nil
    ) {
        self.deviceName = deviceName
        self.batteryProvider = batteryProvider
        self.nowPlayingProvider = nowPlayingProvider
        self.approveDecider = approveDecider
    }

    public var state: State {
        lock.withLock { _state }
    }

    private var _state: State = .stopped

    private func setState(_ s: State) {
        lock.withLock { _state = s }
        onState?(s)
    }

    /// Binds TCP, publishes `_kdeconnect._udp`, and starts the accept loop
    /// on a detached thread. Must be called on the main thread (the mDNS
    /// `NetService` needs a runloop for its delegate callbacks).
    /// Idempotent: a second start stops the first (launch `.task` +
    /// foreground `onChange` otherwise double-bind, seen on-device as
    /// `listening tcp=1716` + `listening tcp=1717`).
    public func start() throws {
        stop()
        // Device ID (Keychain-persisted; a cleared Keychain mints a new
        // ID: reinstall = re-pair, M1 contract).
        let keychain = KeychainClient.live()
        let deviceId: String
        if let loaded = keychain.load(DeviceID.service, DeviceID.account),
           let id = String(data: loaded, encoding: .utf8), validDeviceId(id)
        {
            deviceId = id
        } else {
            deviceId = DeviceID.make()
            keychain.save(DeviceID.service, DeviceID.account, Data(deviceId.utf8))
        }
        let name = cleanName(deviceName)

        // Identity key + self-signed certificate (persisted so restarts
        // keep the pin; Go `generateCert` profile).
        let key = try (IdentityKeys.loadOrCreate() as! SecKey)
        let certDER: Data
        if let saved = keychain.load(DeviceID.service, "device-cert"), !saved.isEmpty {
            certDER = saved
        } else {
            certDER = try SelfSignedCertificate.issue(key: key, deviceId: deviceId)
            keychain.save(DeviceID.service, "device-cert", certDER)
        }
        guard let secCert = SecCertificateCreateWithData(nil, certDER as CFData),
              let secIdentity = TLSIdentity.makeIdentity(certificate: secCert, label: IdentityKeys.applicationTag),
              let pub = SecKeyCopyPublicKey(key),
              let rep = SecKeyCopyExternalRepresentation(pub, nil) as Data?,
              let ownSPKI = Certificates.spkiFromUncompressedPoint(rep)
        else { throw SelfSignedCertificate.IssueError.signingFailed }

        // TCP listener (first free 1716–1764, the desktop dial range).
        let (fd, port) = try Sockets.listenTCP()
        lock.withLock {
            tcpFD = fd
            running = true
        }

        // mDNS publish: instance name = device ID, port = TCP port, TXT
        // carries id/name/type/protocol (Go `mdns.go` contract verbatim;
        // the desktop resolves IP + port from the SRV record).
        let txt = NetService.data(fromTXTRecord: [
            "id": Data(deviceId.utf8),
            "name": Data(name.utf8),
            "type": Data("phone".utf8),
            "protocol": Data(String(FluxProto.protocolVersion).utf8),
        ])
        let advertiser = NetService(domain: "local.", type: "_kdeconnect._udp.", name: deviceId, port: Int32(port))
        let delegate = AdvertiserDelegate { [weak self] message in
            self?.onEvent?(.log(message))
        }
        advertiser.delegate = delegate
        advertiser.setTXTRecord(txt)
        // NetService schedules on the CURRENT runloop: publish from the
        // main thread (or hop there). From a concurrency Task with no
        // runloop the publish silently never happens — first-device
        // finding (2026-09-27): TCP bound, no mDNS record, no Local
        // Network prompt. Publishing also triggers the prompt.
        // (Box: NetService is not Sendable; handoff to main is safe —
        // nothing else touches it until stop().)
        final class ServiceBox: @unchecked Sendable { let service: NetService; init(_ s: NetService) { service = s } }
        let box = ServiceBox(advertiser)
        onEvent?(.log("link: publishing _kdeconnect._udp as \(deviceId) port=\(port) (main=\(Thread.isMainThread))"))
        // D6 bring-up diagnostic: bounded self-browse. Finding Linux's
        // record proves RX works; finding our own proves the publish
        // landed locally (LAN visibility follows, modulo permission).
        // Browsing may itself trigger the Local Network prompt — that
        // outcome is data too.
        final class BrowseBox: @unchecked Sendable {
            let browser: NetServiceBrowser
            let delegate: BrowseDelegate
            init(_ b: NetServiceBrowser, _ d: BrowseDelegate) { browser = b; delegate = d }
        }
        let browseDelegate = BrowseDelegate { [weak self] message in
            self?.onEvent?(.log(message))
        }
        let browseBox = BrowseBox(NetServiceBrowser(), browseDelegate)
        let startDiscovery: @Sendable () -> Void = {
            browseBox.browser.delegate = browseBox.delegate
            browseBox.browser.searchForServices(ofType: "_kdeconnect._udp.", inDomain: "local.")
        }
        if Thread.isMainThread {
            advertiser.publish()
            startDiscovery()
        } else {
            DispatchQueue.main.sync {
                box.service.publish()
                startDiscovery()
            }
        }
        browser = browseBox.browser
        browserDelegate = browseDelegate
        // The browse is diagnostic only: stop it after 10 s (no polling,
        // no battery cost; permanent nearby-peer browsing is later UX).
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.browser?.stop()
            self?.browser = nil
            self?.browserDelegate = nil
        }
        self.advertiser = advertiser
        advertiserDelegate = delegate

        // Downloads land in Application Support/Downloads/ (plan §4.7).
        let downloads = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Downloads", isDirectory: true)
        if let downloads { try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true) }

        let trust: any TrustStore = KeychainTrustStore()
        let approval = pairApproval
        // SecIdentity is not Sendable: box it for the accept thread
        // (immutable after creation; codebase `@unchecked Sendable` idiom).
        final class IdentityBox: @unchecked Sendable { let identity: SecIdentity; init(_ i: SecIdentity) { identity = i } }
        let identityBox = IdentityBox(secIdentity)
        let emit: @Sendable (LinkRunner.Event) -> Void = { [weak self] event in
            guard let self else { return }
            if case .paired(let device, _) = event { self.setState(.connected(device: device)) }
            if case .closed = event {
                if case .connected = self.state { self.setState(.listening(port: port)) }
            }
            self.onEvent?(event)
        }
        setState(.listening(port: port))
        onEvent?(.log("link: listening tcp=\(port) id=\(deviceId)"))

        // Local copies for the Sendable accept loop (no self capture).
        let provider = batteryProvider
        let nowPlaying = nowPlayingProvider
        let decider = approveDecider
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            while self.lock.withLock({ self.running }) {
                let fd: Int32
                do { fd = try Sockets.accept(fd: self.tcpFD, timeout: 5) } catch { continue }
                let runner = LinkRunner(config: LinkRunner.Configuration(
                    ownId: deviceId,
                    deviceName: name,
                    identity: secIdentity,
                    ownSPKI: ownSPKI,
                    trust: trust,
                    autoAccept: false,
                    pairApproval: approval,
                    batteryProvider: batteryProvider,
                    nowPlayingProvider: nowPlaying,
                    // Android `Plugins.onConnected` parity: battery state +
                    // clipboard.connect on every ready link (empty content
                    // is a safe no-op desktop-side; sync itself stays off
                    // on iOS).
                    welcomePackets: {
                        var out: [Packet] = []
                        if let battery = provider?() { out.append(battery.packet()) }
                        out.append(ClipboardMessage(
                            content: "",
                            timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
                            isConnect: true).packet())
                        return out
                    },
                    // First-device finding 2026-09-27: `false` drops every
                    // desktop clip (`ignored ... (clipboard sync off)`).
                    // `true` is correct here — the iOS restriction lives one
                    // layer down (`ClipboardBridge.write` applies only while
                    // foreground-active), so router-open + foreground-gated
                    // = foreground-only sync, the designed iOS posture.
                    clipboardSync: true,
                    pendingUploads: [],
                    pendingCaptures: [],
                    m5Streams: [],
                    approveDecider: decider,
                    downloadsDirectory: downloads
                ) { event in
                    emit(event)
                })
                self.remember(runner)
                Thread.detachNewThread { runner.run(fd: fd) }
            }
        }
    }

    /// Closes the listener and unpublishes mDNS. In-flight links keep
    /// running until iOS suspends the process (honest-suspension UX).
    public func stop() {
        lock.withLock { running = false }
        let fd = lock.withLock { () -> Int32 in
            let f = tcpFD
            tcpFD = -1
            return f
        }
        if fd >= 0 { close(fd) }
        lock.withLock { liveRunners.removeAll() }
        browser?.stop()
        browser = nil
        browserDelegate = nil
        advertiser?.stop()
        advertiser = nil
        advertiserDelegate = nil
        setState(.stopped)
    }

    // MARK: - App-originated packets (D23)

    /// Sends a phone→desktop packet on every live session (normally one):
    /// telephony events, Focus changes, runcommand requests. True when at
    /// least one session accepted it. False with no link up — the caller
    /// drops (presence state is offline/suspended, never faked).
    @discardableResult
    public func send(_ packet: Packet) -> Bool {
        var sent = false
        for runner in lock.withLock({ sweepLocked() }) {
            sent = runner.liveSend.send(packet) || sent
        }
        return sent
    }

    // MARK: - App-originated live streams (D16)

    /// Serves a live stream offer on every live session (normally one):
    /// mic/webcam/screen Start from the app. True when at least one
    /// session took it (pre-engine offers are held per kind and served on
    /// attach). False with no link up — the caller shows offline instead.
    @discardableResult
    public func offerStream(_ offer: LiveOffer) -> Bool {
        let runners = lock.withLock({ sweepLocked() })
        guard !runners.isEmpty else { return false }
        for runner in runners { runner.liveStreams.serve(offer) }
        return true
    }

    // MARK: - App-originated uploads (D15/D18)

    /// Sends local files on every live session (normally one): photo-library
    /// auto-upload retries, in-app file shares. True when at least one
    /// session took them (pre-engine batches are held and served on
    /// attach). False with no link up — the caller queues or shows
    /// offline instead; nothing is ever silently half-sent (each engine
    /// announces + serves its own batch like the harness `--send-file`
    /// path).
    @discardableResult
    public func sendFiles(_ paths: [URL]) -> Bool {
        let runners = lock.withLock({ sweepLocked() })
        guard !runners.isEmpty else { return false }
        for runner in runners { runner.liveUploads.sendFiles(paths) }
        return true
    }

    /// Sends camera captures on every live session (normally one): photo /
    /// document / library captures with their `scan`/`photo`/`screenshot`
    /// routing flags (same classic path + flags as the harness
    /// `--exercise-m5` captures). Presence contract like `sendFiles`.
    @discardableResult
    public func sendCaptures(_ items: [TransferEngine.CaptureUpload]) -> Bool {
        let runners = lock.withLock({ sweepLocked() })
        guard !runners.isEmpty else { return false }
        for runner in runners { runner.liveUploads.sendCaptures(items) }
        return true
    }

    /// Stops a live stream on every live session. `announce` sends the
    /// kind's `stop` (user stop); pass false for desktop-initiated stops
    /// (the desktop already stopped — replying stop would ping-pong).
    public func stopStream(kind: StreamKind, announce: Bool = true) {
        for runner in lock.withLock({ sweepLocked() }) {
            runner.liveStreams.stop(kind: kind, announce: announce)
        }
    }

    // MARK: - Browse take path (D1)

    /// Takes an established browse tunnel for the SSH session layer: the
    /// first live session holding it wins. Nil when no session has it
    /// (offline race, or the desktop never dialed — the caller shows
    /// offline/retry, never a phantom session).
    public func takeBrowseTunnel(_ id: String) -> TLSConnection? {
        for runner in lock.withLock({ sweepLocked() }) {
            if let conn = runner.takeBrowseTunnel(id) { return conn }
        }
        return nil
    }

    /// Orderly-FINs every live session socket (background path): the
    /// desktop sees EOF at once, clears its link gate, and redials on the
    /// next publish — instead of a half-open stalemate that neither
    /// keepalive kills. The app calls this on background with no open
    /// approve/pair prompt (the D22 answer and the pairing handshake still
    /// need their session); live streams are torn down first. Safe
    /// under idle sessions (runner `close` is a wakeup, teardown still
    /// closes exactly once).
    public func closeSessions() {
        let runners = lock.withLock { () -> [LinkRunner] in
            let r = sweepLocked()
            liveRunners.removeAll()
            return r
        }
        for runner in runners { runner.close() }
    }

    private func remember(_ runner: LinkRunner) {
        lock.withLock {
            _ = sweepLocked()
            liveRunners.append(WeakRunner(runner))
        }
    }

    /// Drops dead sessions. Must hold `lock`.
    private func sweepLocked() -> [LinkRunner] {
        liveRunners = liveRunners.filter { $0.runner != nil }
        return liveRunners.compactMap { $0.runner }
    }
}

/// Weak session handle for the `LinkService` live registry (D23).
private final class WeakRunner {
    weak var runner: LinkRunner?
    init(_ runner: LinkRunner) { self.runner = runner }
}

/// Forwards mDNS publish results to the link log (no UI surface: a failed
/// publish just means `flux discover` won't see us until the next start).
private final class AdvertiserDelegate: NSObject, NetServiceDelegate {
    private let log: (String) -> Void
    init(log: @escaping (String) -> Void) { self.log = log }
    func netServiceDidPublish(_ sender: NetService) {
        log("link: published _kdeconnect._udp as \(sender.name) port=\(sender.port)")
    }
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        log("link: mDNS publish failed \(errorDict[NetService.errorCode] ?? 0) (discover won't see us)")
    }
}

/// D6 bring-up browse diagnostic: logs every `_kdeconnect._udp` instance
/// seen (names only, no resolve). Runs 10 s per start, then stops.
private final class BrowseDelegate: NSObject, NetServiceBrowserDelegate {
    private let log: (String) -> Void
    init(log: @escaping (String) -> Void) { self.log = log }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        log("link: browse found \(service.name) (more=\(moreComing))")
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        log("link: browse failed \(errorDict[NetService.errorCode] ?? 0)")
    }
}
