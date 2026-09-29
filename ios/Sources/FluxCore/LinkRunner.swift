import Foundation
import FluxProto
import FluxNet
import FluxApprove
#if canImport(Security)
import Security

/// One inbound device connection: plaintext identity → TLS client handshake
/// → TLS identity → pairing + packets.
///
/// Mirrors Go `provider.go accept()` + `finish()` and Android `LanBackend`
/// link setup + `Device.onPairPacket` (M1b subset: ping/pair only; feature
/// plugins live in `FeatureRouter`, M2 messaging through M5 streams).
///
/// Threading: blocking I/O on the caller's thread (one thread per
/// connection, like Android `Link` reader/writer threads). Actor-bound
/// collaborators (`TrustStore`, `PairingSession`) are reached through a
/// semaphore bridge — safe because this never runs on the cooperative pool.
///
/// Each instance is confined to a single thread (`@unchecked Sendable`);
/// `Configuration.onEvent` is invoked on that thread and must be
/// thread-safe (logging is enough for the M1b harness).
public final class LinkRunner: @unchecked Sendable {
    public struct Configuration {
        public var ownId: String
        public var deviceName: String
        public var identity: SecIdentity
        public var ownSPKI: Data
        public var trust: any TrustStore
        /// Test-harness mode: accept incoming pair requests immediately
        /// (like tapping Accept with a matching key). Production UI drives
        /// acceptance through `PairView` + `pairApproval` (nil = log only).
        public var autoAccept: Bool
        /// Manual Accept path: the session thread blocks in `decide` until
        /// the UI resolves it. Ignored when `autoAccept` is true.
        public var pairApproval: PairApproval?
        /// Answers `kdeconnect.battery.request`. Nil = log only (the harness
        /// and the app inject their provider; `UIDevice` on device).
        public var batteryProvider: (@Sendable () -> BatteryState?)?
        /// Answers desktop player queries (`requestPlayerList`,
        /// `requestNowPlaying`). Nil = answer an empty list / log only
        /// (the harness injects a stub; the app reads
        /// `MPNowPlayingInfoCenter` through `NowPlayingBridge`).
        public var nowPlayingProvider: (@Sendable () -> MprisState?)?
        /// Packets sent once the link is ready (paired). The harness uses
        /// these for M2 phone→desktop verification; the app sends battery
        /// + `clipboard.connect` on connect (Android `Plugins.onConnected`).
        public var welcomePackets: (@Sendable () -> [Packet])?
        /// Clipboard sync setting (`auto_clipboard`, false on iOS).
        public var clipboardSync: Bool
        /// Local files uploaded once the link is ready (phone→desktop,
        /// always classic payload — the harness `--send-file` path).
        public var pendingUploads: [URL]
        /// Camera captures uploaded once the link is ready (same classic
        /// path with `scan`/`photo`/`screenshot` flags — the harness
        /// `--exercise-m5` path; the app uploads through `sendCaptures`).
        public var pendingCaptures: [TransferEngine.CaptureUpload]
        /// Streams served once the link is ready (phone→desktop webcam/mic/
        /// screen — the harness `--exercise-m5` path; the app serves
        /// through `StreamSession` + `StreamEngine` explicitly).
        public var m5Streams: [StreamOffer]
        /// Answers approval prompts (M6). Nil = hold for the UI (the app
        /// resolves through its own prompt flow); the harness injects a
        /// test-mode decider that signs with a non-biometric key and logs
        /// "TEST MODE (no biometric)". Runs off the session thread and may
        /// block (a real prompt waits on the user); return the reply packet
        /// to send, or nil to keep waiting. Late answers for closed prompts
        /// are dropped by id, never sent.
        public var approveDecider: ((ApproveRequest) -> Packet?)?
        /// Receive folder override. Nil = `Application Support/Downloads/`.
        public var downloadsDirectory: URL?
        public var onEvent: (Event) -> Void

        public init(
            ownId: String,
            deviceName: String,
            identity: SecIdentity,
            ownSPKI: Data,
            trust: any TrustStore,
            autoAccept: Bool,
            pairApproval: PairApproval? = nil,
            batteryProvider: (@Sendable () -> BatteryState?)? = nil,
            nowPlayingProvider: (@Sendable () -> MprisState?)? = nil,
            welcomePackets: (@Sendable () -> [Packet])? = nil,
            clipboardSync: Bool = false,
            pendingUploads: [URL] = [],
            pendingCaptures: [TransferEngine.CaptureUpload] = [],
            m5Streams: [StreamOffer] = [],
            approveDecider: ((ApproveRequest) -> Packet?)? = nil,
            downloadsDirectory: URL? = nil,
            onEvent: @escaping (Event) -> Void
        ) {
            self.ownId = ownId
            self.deviceName = deviceName
            self.identity = identity
            self.ownSPKI = ownSPKI
            self.trust = trust
            self.autoAccept = autoAccept
            self.pairApproval = pairApproval
            self.batteryProvider = batteryProvider
            self.nowPlayingProvider = nowPlayingProvider
            self.welcomePackets = welcomePackets
            self.clipboardSync = clipboardSync
            self.pendingUploads = pendingUploads
            self.pendingCaptures = pendingCaptures
            self.m5Streams = m5Streams
            self.approveDecider = approveDecider
            self.downloadsDirectory = downloadsDirectory
            self.onEvent = onEvent
        }
    }

    public enum Event {
        case log(String)
        case pairRequested(peerId: String, deviceName: String, key: String)
        /// A ready session with a trusted peer: fresh pairs carry the key,
        /// pinned reconnects carry `""` (same precedent as the
        /// simultaneous-accept path). The app maps this to its connected
        /// presence — without it every reconnect works fully while the
        /// banner insists otherwise (M4 hardware round, 2026-09-27).
        case paired(deviceName: String, key: String)
        case closed(deviceName: String)
        case pingReceived(deviceName: String, message: String)
        case batteryReceived(deviceName: String, level: Int?, charging: Bool)
        case clipboardReceived(deviceName: String, content: String)
        case shareTextReceived(deviceName: String, text: String)
        case shareURLReceived(deviceName: String, url: String)
        case shareFileQueued(deviceName: String, filename: String, size: Int64)
        case ringStarted(deviceName: String)
        case ringStopped(deviceName: String)
        case notificationReceived(deviceName: String, title: String, text: String)
        case notificationCancelled(deviceName: String, key: String)
        case transferProgress(deviceName: String, filename: String, done: Int64, size: Int64)
        case transferCompleted(deviceName: String, filename: String, path: String, bytes: Int64)
        case transferFailed(deviceName: String, filename: String, error: String)
        /// A `flux.tunnel` packet arrived. iOS never solicits tunnels, so
        /// these are only ever logged (see `Transfers.swift`).
        case tunnelObserved(deviceName: String, token: String, port: Int, error: String?)
        case sftpOfferReceived(deviceName: String, offer: SftpOffer)
        case sftpErrorReceived(deviceName: String, message: String)
        case sftpServeRequested(deviceName: String)
        case browseTunnelReady(deviceName: String, tunnel: String)
        case browseTunnelFailed(deviceName: String, error: String)
        /// Desktop player list / now-playing state (Media screen input).
        /// The state carries the full `MprisState` (not display fields)
        /// so `MediaScreen` gets position/length/seek + caps unchanged.
        case mediaPlayersReceived(deviceName: String, players: [String])
        case mediaStateReceived(deviceName: String, state: MprisState)
        /// Desktop control of this phone's playback (`flux media *`). The
        /// app drives `NowPlayingBridge` from these; the harness logs them.
        case mediaActionReceived(deviceName: String, player: String, action: String)
        case mediaSeekReceived(deviceName: String, player: String, positionMs: Int64)
        case mediaVolumeReceived(deviceName: String, player: String, volume: Int)
        /// Desktop command list (Commands screen input). The full list
        /// rides along (not just the count) so `CommandsScreen` renders
        /// names + commands in desktop config order; `count` is
        /// `commands.count`.
        case commandListReceived(deviceName: String, commands: [RemoteCommand], canAddCommand: Bool)
        /// Desktop Do Not Disturb (banner only; never sets Focus).
        case dndReceived(deviceName: String, on: Bool)
        /// Desktop stream answers (M5). The app drives `StreamSession`
        /// from these; the harness logs them.
        case webcamLiveReceived(deviceName: String, device: String, label: String)
        case webcamErrorReceived(deviceName: String, message: String)
        case webcamStopReceived(deviceName: String)
        case webcamConfigReceived(deviceName: String, reset: Bool, partial: [String: JSONValue]?)
        case micLiveReceived(deviceName: String, source: String)
        case micErrorReceived(deviceName: String, message: String)
        case micStopReceived(deviceName: String)
        case screenLiveReceived(deviceName: String, player: String)
        case screenErrorReceived(deviceName: String, message: String)
        case screenStopReceived(deviceName: String)
        /// Stream serving progress (M5 harness + Streams UI input).
        case streamStarted(deviceName: String, kind: String, port: Int)
        case streamProgress(deviceName: String, kind: String, done: Int64, size: Int64)
        case streamDone(deviceName: String, kind: String, bytes: Int64, sha256: String)
        case streamFailed(deviceName: String, kind: String, error: String)
        /// An approval/enrollment prompt to show (M6). The app shows its
        /// full-screen prompt + time-sensitive notification; the harness
        /// answers through `approveDecider`.
        case approvePromptReceived(deviceName: String, kind: String, id: String, host: String, user: String, service: String)
        /// An approval request settled: `approved`, `enrolled`, `denied`,
        /// `failed`, `cancelled`, or `expired` (local timeout, no packet).
        case approveAnswered(deviceName: String, id: String, result: String)
    }

    private let config: Configuration
    private let linkState = LinkState()

    /// App-originated packet path (D23): published once the TLS session is
    /// up, cleared when it ends. The app sends phone→desktop packets that
    /// no inbound packet triggers — telephony events (`CallBridge`),
    /// Focus changes (`FocusBridge`), runcommand requests — through
    /// `LinkService.send`, which fans out over live runners. Writes reuse
    /// the session's `LinkSender`, so they stay lock-serialized with the
    /// session + transfer threads. False when no session is up (the caller
    /// drops or queues; nothing is ever silently half-sent).
    public let liveSend = LiveSendBox()

    /// Live-stream inlet for app-originated streams (D16). Published with
    /// the session engine once the TLS session is up, detached when it
    /// ends; `LinkService` fans `offerStream`/`stopStream` out over live
    /// runners. Pre-attach offers are held per kind and served on attach.
    public let liveStreams = LiveStreamBox()

    /// Upload inlet for app-originated files/captures (D15/D18).
    /// Published with the session transfer engine once the TLS session is
    /// up, detached when it ends; `LinkService` fans `sendFiles`/
    /// `sendCaptures` out over live runners. Pre-attach batches are held
    /// and served on attach.
    public let liveUploads = LiveUploadBox()

    /// Session transfer engine for the browse take path (D1). Set on
    /// session setup, cleared on teardown; the engine's `BrowseTunnels`
    /// store is locked, so `takeBrowseTunnel` is safe off the session
    /// thread (the SSH session layer takes from the app/peer thread).
    private let browseLock = NSLock()
    private nonisolated(unsafe) var browseEngine: TransferEngine?

    /// Takes an established browse tunnel for the SSH session layer (nil
    /// when the desktop never dialed or the session ended). The caller
    /// owns the connection.
    public func takeBrowseTunnel(_ id: String) -> TLSConnection? {
        browseLock.withLock { browseEngine?.takeBrowseTunnel(id) }
    }

    public init(config: Configuration) {
        self.config = config
    }

    /// The session socket while `run` owns it (-1 otherwise). Cross-thread
    /// shutdown only (see `close`); every teardown close stays on the
    /// session thread.
    private let sessionLock = NSLock()
    private nonisolated(unsafe) var sessionFD: Int32 = -1

    /// Wakes a blocked session read with an orderly shutdown (the
    /// background-FIN path): the peer sees EOF at once and its link gate
    /// clears, so the next publish redials in seconds instead of a
    /// half-open stalemate neither keepalive kills (seen on-device
    /// 18:36–37: phone publishing, desktop silent, phone stuck
    /// Reconnecting for minutes).
    ///
    /// Never closes the fd itself — the session thread still owns it (a
    /// raw cross-thread close risks handing a recycled number to the
    /// teardown close; the LiveChannel lesson). `shutdown` only wakes the
    /// reader; teardown closes exactly once as before. Safe to call when
    /// idle (taken-and-cleared atomically; unknown numbers refused).
    public func close() {
        let fd: Int32 = sessionLock.withLock {
            let f = sessionFD
            sessionFD = -1
            return f
        }
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
        }
    }

    /// Runs the connection to completion on the current thread.
    public func run(fd: Int32) {
        sessionLock.withLock { sessionFD = fd }
        defer {
            sessionLock.withLock { sessionFD = -1 }
            liveSend.clear()
            liveStreams.detach()
            liveUploads.detach()
            // Unpublish the browse take path on every exit (normal and
            // error); the normal path also clears it before dropping
            // untaken tunnels.
            browseLock.withLock { browseEngine = nil }
        }
        do {
            try TLSConnection.setTimeout(fd: fd, seconds: 10)
            guard let rawLine = try Sockets.readRawLine(fd: fd, max: Lan.maxIdentitySize) else {
                Sockets.close(fd)
                return
            }
            guard let rawPacket = Packet.parse(rawLine),
                  let plain = FluxLink.validatesPreTLS(rawPacket, ownId: config.ownId)
            else {
                emit(.log("refusing: bad plaintext identity"))
                Sockets.close(fd)
                return
            }
            emit(.log("plaintext identity: \(plain.deviceName) (\(plain.deviceType))"))

            let pinned: Data? = sync { await self.config.trust.certificateDER(for: plain.deviceId) }
            var peerDER: Data?
            let conn = try TLSConnection.handshake(fd: fd, role: .client(identity: config.identity), timeout: 10) { cn, der in
                peerDER = der
                let result = TrustValidation.validate(
                    commonName: cn, peerDER: der,
                    expectedDeviceId: plain.deviceId,
                    deviceName: plain.deviceName,
                    pinnedDER: pinned
                )
                switch result {
                case .success:
                    return true
                case .failure(let failure):
                    self.emit(.log("trust refused: \(failure)"))
                    return false
                }
            }
            guard let peerDER else {
                emit(.log("refusing: peer sent no certificate"))
                conn.close()
                return
            }
            try TLSConnection.setTimeout(fd: fd, seconds: 30)

            // TLS-phase identity (must not carry tcpPort).
            let secure = Identity(
                deviceId: config.ownId,
                deviceName: cleanName(config.deviceName),
                deviceType: "phone"
            )
            let sender = LinkSender(conn)
            liveSend.publish { sender.send($0) }
            sender.send(secure.toPacket())
            let peerHost = Sockets.peerAddress(fd: fd) ?? "127.0.0.1"
            let reader = TLSLineReader(conn)
            guard let idLine = try reader.readLine(max: Lan.maxIdentitySize),
                  let idPacket = Packet.parse(idLine),
                  let securePeer = Identity.from(idPacket),
                  securePeer.deviceId == plain.deviceId,
                  securePeer.protocolVersion == plain.protocolVersion
            else {
                emit(.log("refusing: TLS identity does not match plaintext"))
                conn.close()
                return
            }
            emit(.log("TLS identity OK: \(securePeer.deviceName)"))

            let peerSPKI = Certificates.spkiFromCertificate(peerDER)
            if peerSPKI == nil {
                emit(.log("warning: cannot parse peer SPKI; pairing disabled"))
            }
            let pairing = PairingSession(
                peerId: plain.deviceId,
                peerProtocolVersion: plain.protocolVersion,
                ownSPKI: config.ownSPKI,
                peerSPKI: peerSPKI ?? Data()
            )
            let peerName = securePeer.deviceName
            let peerType = securePeer.deviceType
            let isFlux = securePeer.isFlux
            let engine = TransferEngine(
                identity: config.identity, peerDER: peerDER,
                send: { sender.send($0) },
                downloadsDir: config.downloadsDirectory ?? TransferEngine.defaultDownloadsDirectory()
            ) { [config] event in
                switch event {
                case .progress(let filename, let done, let size):
                    config.onEvent(.transferProgress(deviceName: peerName, filename: filename, done: done, size: size))
                case .completed(let filename, let path, let bytes):
                    config.onEvent(.transferCompleted(deviceName: peerName, filename: filename, path: path, bytes: bytes))
                case .failed(let filename, let error):
                    config.onEvent(.transferFailed(deviceName: peerName, filename: filename, error: error))
                case .browseReady(let tunnel):
                    config.onEvent(.browseTunnelReady(deviceName: peerName, tunnel: tunnel))
                case .browseFailed(let tunnel, let error):
                    config.onEvent(.browseTunnelFailed(deviceName: peerName, error: tunnel.map { "\($0): \(error)" } ?? error))
                }
            }
            let streams = StreamEngine(
                identity: config.identity, peerDER: peerDER,
                send: { sender.send($0) }
            ) { [config] event in
                switch event {
                case .started(let kind, let port):
                    config.onEvent(.streamStarted(deviceName: peerName, kind: kind.rawValue, port: port))
                case .progress(let kind, let done, let size):
                    config.onEvent(.streamProgress(deviceName: peerName, kind: kind.rawValue, done: done, size: size))
                case .done(let kind, let bytes, let sha):
                    config.onEvent(.streamDone(deviceName: peerName, kind: kind.rawValue, bytes: bytes, sha256: sha))
                case .failed(let kind, let error):
                    config.onEvent(.streamFailed(deviceName: peerName, kind: kind.rawValue, error: error))
                }
            }
            // Publish the live-stream inlet for the rest of the session
            // (app Start/Stop rides here; pre-attach offers serve now).
            liveStreams.attach(streams)
            // Publish the upload inlet for the rest of the session (app
            // captures + library auto-upload ride here; pre-attach
            // batches serve now).
            liveUploads.attach(engine)
            // Publish the transfer engine for the browse take path (D1;
            // the SSH session layer takes established tunnels off-thread).
            browseLock.withLock { browseEngine = engine }

            // A pinned certificate means the pair handshake already happened:
            // plugin packets flow immediately (Go `dev.Paired` survives).
            linkState.paired = pinned != nil
            if linkState.paired {
                sendWelcome(sender: sender)
                sendPendingUploads(engine: engine)
                sendPendingCaptures(engine: engine)
                sendPendingStreams(engine: streams)
                emit(.paired(deviceName: peerName, key: ""))
            }

            while true {
                guard let line = try reader.readLine(max: FluxProto.maxPacketSize) else { break }
                if line.isEmpty { continue }
                guard let packet = Packet.parse(line) else {
                    emit(.log("bad packet; skipped"))
                    continue
                }
                if packet.type == PacketType.pair {
                    handlePair(packet, pairing: pairing, sender: sender, engine: engine, streams: streams,
                               peerDER: peerDER,
                               peerName: peerName, peerType: peerType, isFlux: isFlux,
                               pairingEnabled: peerSPKI != nil)
                } else {
                    routeFeature(packet, sender: sender, engine: engine,
                                 peerId: plain.deviceId, peerName: peerName, peerHost: peerHost)
                }
                if let stopped = linkState.expireRing(nowMs: nowMs()) {
                    emit(.ringStopped(deviceName: stopped))
                }
            }
            if linkState.ringing {
                emit(.ringStopped(deviceName: peerName))
            }
            emit(.closed(deviceName: peerName))
            // Unpublish the browse take path first (a concurrent take gets
            // nil), then drop any untaken tunnels.
            browseLock.withLock { browseEngine = nil }
            engine.closeBrowseTunnels()
            conn.close()
        } catch {
            emit(.log("link error: \(error)"))
            Sockets.close(fd)
        }
    }

    // MARK: - Pairing

    private func handlePair(
        _ packet: Packet,
        pairing: PairingSession,
        sender: LinkSender,
        engine: TransferEngine,
        streams: StreamEngine,
        peerDER: Data,
        peerName: String,
        peerType: String,
        isFlux: Bool,
        pairingEnabled: Bool
    ) {
        if !pairingEnabled {
            emit(.log("refusing pair: no peer SPKI"))
            sender.send(Pairing.reject())
            return
        }
        let (event, send): (PairingEvent?, [Packet]) = sync {
            await pairing.receive(packet)
        }
        for p in send { sender.send(p) }
        guard let event else { return }
        switch event {
        case .showRequest(let key), .trustReset(let key):
            if case .trustReset = event {
                sync { await self.config.trust.remove(deviceId: pairing.peerId) }
            }
            emit(.pairRequested(peerId: pairing.peerId, deviceName: peerName, key: key))
            if config.autoAccept {
                acceptPairing(key: key, pairing: pairing, sender: sender, engine: engine, streams: streams,
                              peerDER: peerDER,
                              peerName: peerName, peerType: peerType, isFlux: isFlux)
            } else if let approval = config.pairApproval {
                // Manual path: PairView resolves this from onAccept/onDecline.
                // Blocks the session thread, never the cooperative pool.
                switch approval.decide(peerId: pairing.peerId, timeout: Pairing.incomingTimeout) {
                case true?:
                    acceptPairing(key: key, pairing: pairing, sender: sender, engine: engine, streams: streams,
                                  peerDER: peerDER,
                                  peerName: peerName, peerType: peerType, isFlux: isFlux)
                case false?:
                    let reject: Packet? = sync { await pairing.reject() }
                    if reject != nil { sender.send(Pairing.reject()) }
                    emit(.log("pair declined by user"))
                case nil:
                    emit(.log("pair request timed out"))
                }
            } else {
                emit(.log("pair request waiting (no approval handler)"))
            }
        case .accepted:
            // Inbound-only runner: reached via simultaneous requests.
            persistTrust(peerDER: peerDER, peerName: peerName, peerType: peerType, isFlux: isFlux, pairing: pairing)
            linkState.paired = true
            sendWelcome(sender: sender)
            sendPendingUploads(engine: engine)
            sendPendingCaptures(engine: engine)
            sendPendingStreams(engine: streams)
            emit(.paired(deviceName: peerName, key: ""))
        case .trustResetRefused:
            sync { await self.config.trust.remove(deviceId: pairing.peerId) }
            emit(.log("re-request refused; trust dropped"))
        case .refused(let reason):
            emit(.log("pair refused: \(reason)"))
        case .closed(let reason):
            if reason == .unpairedByPeer {
                sync { await self.config.trust.remove(deviceId: pairing.peerId) }
                linkState.paired = false
            }
            emit(.log("pair closed: \(reason)"))
        }
    }

    private func acceptPairing(
        key: String,
        pairing: PairingSession,
        sender: LinkSender,
        engine: TransferEngine,
        streams: StreamEngine,
        peerDER: Data,
        peerName: String,
        peerType: String,
        isFlux: Bool
    ) {
        let accept: Packet? = sync { await pairing.accept() }
        if accept != nil {
            persistTrust(peerDER: peerDER, peerName: peerName, peerType: peerType, isFlux: isFlux, pairing: pairing)
            sender.send(Pairing.accept())
            linkState.paired = true
            sendWelcome(sender: sender)
            sendPendingUploads(engine: engine)
            sendPendingCaptures(engine: engine)
            sendPendingStreams(engine: streams)
            emit(.paired(deviceName: peerName, key: key))
        }
    }

    private func persistTrust(peerDER: Data, peerName: String, peerType: String, isFlux: Bool, pairing: PairingSession) {
        let peerId = pairing.peerId
        sync {
            await self.config.trust.put(TrustedDevice(
                id: peerId, name: peerName, type: peerType,
                certificateDER: peerDER, isFlux: isFlux
            ))
        }
    }

    // MARK: - Feature packets (M2)

    private func routeFeature(_ packet: Packet, sender: LinkSender, engine: TransferEngine, peerId: String, peerName: String, peerHost: String) {
        var ctx = FeatureContext(
            peerId: peerId, peerName: peerName, paired: linkState.paired,
            clipboardSync: config.clipboardSync, nowMs: nowMs()
        )
        if packet.type == PacketType.fluxApprove {
            // Fresh per packet: a key enrolled between requests applies at once.
            ctx.hasApproveKey = ApproveKeys.has(computerId: peerId)
        }
        for action in linkState.route(packet, ctx: ctx) {
            switch action {
            case .send(let out):
                sender.send(out)
                emit(.log("-> \(out.type)"))
            case .event(let event):
                handleFeature(event, sender: sender, engine: engine, peerName: peerName, peerHost: peerHost)
            }
        }
    }

    private func handleFeature(_ event: FeatureEvent, sender: LinkSender, engine: TransferEngine, peerName: String, peerHost: String) {
        switch event {
        case .ping(let message):
            emit(.pingReceived(deviceName: peerName, message: message))
        case .battery(let state):
            emit(.batteryReceived(deviceName: peerName, level: state.level, charging: state.charging))
            if state.thresholdEvent == 1 {
                emit(.log("battery low: \(state.level ?? -1)%"))
            }
        case .batteryRequested:
            if let battery = config.batteryProvider?() {
                sender.send(battery.packet())
                emit(.log("-> \(PacketType.battery)"))
            } else {
                emit(.log("battery.request ignored (no provider)"))
            }
        case .clipboard(let content):
            emit(.clipboardReceived(deviceName: peerName, content: content))
        case .clipboardStale(let content):
            emit(.log("stale clipboard.connect stored (\(content.count) chars)"))
        case .shareText(let text, let scan):
            emit(.shareTextReceived(deviceName: peerName, text: scan ? "[scan] \(text)" : text))
        case .shareURL(let url):
            emit(.shareURLReceived(deviceName: peerName, url: url))
        case .shareFile(let file):
            // Fetched off-thread by the transfer engine (M3); the queue
            // event stays for the UI + the deferred-fetch store.
            engine.receive(file, host: peerHost)
            emit(.shareFileQueued(deviceName: peerName, filename: file.filename, size: file.payloadSize))
        case .shareUpdate(let n, let total):
            emit(.log("share update: \(n) files, \(total) bytes"))
        case .ringToggled(let ringing, let from):
            if ringing {
                emit(.ringStarted(deviceName: from))
                scheduleRingStop(peerName: from)
            } else {
                emit(.ringStopped(deviceName: from))
            }
        case .notification(let n):
            emit(.notificationReceived(deviceName: peerName, title: n.title, text: n.text))
        case .notificationCancelled(let key):
            emit(.notificationCancelled(deviceName: peerName, key: key))
        case .notificationSyncRequested:
            emit(.log("notification list requested (no mirror on iOS; nothing sent)"))
        case .notificationCancel(let id):
            emit(.log("notification cancel \(id) (no mirror on iOS; nothing to dismiss)"))
        case .notificationReplyDropped(let id, _):
            emit(.log("notification reply \(id) dropped (no mirror on iOS)"))
        case .notificationActionDropped(let key, let action):
            emit(.log("notification action \(key)/\(action) dropped (no mirror on iOS)"))
        case .tunnelReady(let token, let port):
            emit(.tunnelObserved(deviceName: peerName, token: token, port: port, error: nil))
            emit(.log("unsolicited flux.tunnel \(token) port \(port) (nothing waits on it)"))
        case .tunnelFailed(let token, let error):
            emit(.tunnelObserved(deviceName: peerName, token: token, port: 0, error: error))
            emit(.log("flux.tunnel \(token) failed: \(error)"))
        case .sftpOffer(let offer):
            // The SSH session layer (D1) takes the tunnel + creds from the
            // offer; the one-time password travels in-memory only, never
            // to logs.
            emit(.sftpOfferReceived(deviceName: peerName, offer: offer))
            if offer.viaTunnel {
                engine.openBrowseTunnel(offer)
            } else {
                emit(.log("classic sftp offer \(offer.ip ?? "?"):\(offer.port) (SSH dial is M4+)"))
            }
        case .sftpError(let message):
            emit(.sftpErrorReceived(deviceName: peerName, message: message))
        case .sftpServeRequested:
            // Serving iPhone files over SFTP is deferred (plan §4.7).
            emit(.sftpServeRequested(deviceName: peerName))
            emit(.log("sftp.request: serving is deferred (no offer sent)"))
        case .mediaPlayersChanged(let players):
            emit(.mediaPlayersReceived(deviceName: peerName, players: players))
        case .mediaState(let s):
            emit(.mediaStateReceived(deviceName: peerName, state: s))
        case .mediaPlayersRequested:
            // Answer like Go sendPlayerList: our players, or empty when
            // nothing plays (nil provider = nothing plays on the harness).
            let players = config.nowPlayingProvider?().map { [$0.player] } ?? []
            sender.send(MprisMessage.playerListPacket(players))
            emit(.log("-> \(PacketType.mpris) (\(players.count) player(s))"))
        case .mediaStateRequested(let player):
            if let now = config.nowPlayingProvider?(), now.player == player {
                sender.send(MprisMessage.statePacket(now))
                emit(.log("-> \(PacketType.mpris) (\(player))"))
            } else {
                emit(.log("now-playing for \(player) requested (nothing playing)"))
            }
        case .mediaActionRequested(let player, let action):
            emit(.mediaActionReceived(deviceName: peerName, player: player, action: action))
        case .mediaSeekRequested(let player, let positionMs):
            emit(.mediaSeekReceived(deviceName: peerName, player: player, positionMs: positionMs))
        case .mediaVolumeRequested(let player, let volume):
            emit(.mediaVolumeReceived(deviceName: peerName, player: player, volume: volume))
        case .mediaAlbumArtRequested(let player, let url):
            emit(.log("album art for \(player) \(url) deferred (no phone state published in v1)"))
        case .commandList(let commands, let canAdd):
            emit(.commandListReceived(deviceName: peerName, commands: commands, canAddCommand: canAdd))
        case .dndChanged(let on):
            emit(.dndReceived(deviceName: peerName, on: on))
        case .webcamLive(let device, let label):
            emit(.webcamLiveReceived(deviceName: peerName, device: device, label: label))
        case .webcamError(let message):
            emit(.webcamErrorReceived(deviceName: peerName, message: message))
        case .webcamStopped:
            emit(.webcamStopReceived(deviceName: peerName))
        case .webcamConfig(let reset, let partial):
            emit(.webcamConfigReceived(deviceName: peerName, reset: reset, partial: partial))
        case .micLive(let source):
            emit(.micLiveReceived(deviceName: peerName, source: source))
        case .micError(let message):
            emit(.micErrorReceived(deviceName: peerName, message: message))
        case .micStopped:
            emit(.micStopReceived(deviceName: peerName))
        case .screenLive(let player):
            emit(.screenLiveReceived(deviceName: peerName, player: player))
        case .screenError(let message):
            emit(.screenErrorReceived(deviceName: peerName, message: message))
        case .screenStopped:
            emit(.screenStopReceived(deviceName: peerName))
        case .approveRequested(let r):
            handleApprovePrompt(r, sender: sender, peerName: peerName)
        case .approveCancelled(let id):
            if linkState.approveClear(id: id) {
                emit(.approveAnswered(deviceName: peerName, id: id, result: "cancelled"))
            } else {
                emit(.log("approve cancel for unknown \(id)"))
            }
        case .ignored(let type, let reason):
            switch reason {
            case .unpaired:
                emit(.log("ignored \(type) from a device that is not paired"))
            case .unadvertised:
                emit(.log("ignored unadvertised \(type)"))
            case .unhandled:
                emit(.log("no handler for \(type)"))
            case .syncDisabled:
                emit(.log("ignored \(type) (clipboard sync off)"))
            }
        }
    }

    /// Holds an approval prompt: emits it for the UI/harness, runs the
    /// test-mode decider when present, and schedules the local timeout
    /// (Android `Approvals.receive` + `postDelayed clear`).
    ///
    /// The decider runs off the session thread (a real prompt waits on the
    /// user while packets keep flowing). A late answer for a prompt that
    /// already closed (cancel/timeout/answer) is dropped, never sent —
    /// `Approvals.clear` checks the id the same way.
    private func handleApprovePrompt(_ r: ApproveRequest, sender: LinkSender, peerName: String) {
        let kind = r.kind == .enroll ? "enroll" : "request"
        emit(.approvePromptReceived(
            deviceName: peerName, kind: kind, id: r.id,
            host: r.host, user: r.user, service: r.service))
        if let decide = config.approveDecider {
            Thread.detachNewThread { [self] in
                guard let reply = decide(r) else { return }
                guard self.linkState.approveCurrentId() == r.id else {
                    self.emit(.log("approve answer dropped (stale id=\(r.id))"))
                    return
                }
                let wasSent = sender.send(reply)
                self.emit(.log("-> \(PacketType.fluxApprove) (\(self.describeApproveReply(reply))) sent=\(wasSent)"))
                self.linkState.approveClear(id: r.id)
                self.emit(.approveAnswered(deviceName: peerName, id: r.id, result: self.describeApproveReply(reply)))
            }
        }
        scheduleApproveExpiry(r, peerName: peerName)
    }

    private func describeApproveReply(_ p: Packet) -> String {
        if p.string("kind") == "enrolled" { return "enrolled" }
        if p.bool("denied") == true { return "denied" }
        if p.string("error") != nil { return "failed" }
        if p.string("signature") != nil { return "approved" }
        return "answered"
    }

    /// Closes a prompt nobody answered after its timeout (Go
    /// `approveTimeout`, Android `postDelayed clear`). The phone sends no
    /// packet: `fluxd` already cancelled on its own timeout.
    private func scheduleApproveExpiry(_ r: ApproveRequest, peerName: String) {
        Thread.detachNewThread { [self] in
            Thread.sleep(forTimeInterval: TimeInterval(r.timeoutSeconds) + 1)
            if let expired = self.linkState.approveExpire() {
                self.emit(.approveAnswered(deviceName: peerName, id: expired.id, result: "expired"))
            }
        }
    }

    /// Sends the harness/app welcome packets once per link.
    private func sendWelcome(sender: LinkSender) {
        guard let packets = linkState.takeWelcome(config.welcomePackets?() ?? []) else { return }
        for p in packets {
            sender.send(p)
            emit(.log("-> \(p.type)"))
        }
    }

    /// Uploads harness/app files once per link (phone→desktop, classic).
    private func sendPendingUploads(engine: TransferEngine) {
        guard let paths = linkState.takeUploads(config.pendingUploads), !paths.isEmpty else { return }
        emit(.log("uploading \(paths.count) file(s)"))
        engine.sendFiles(paths)
    }

    /// Uploads harness/app captures once per link (classic + flags).
    private func sendPendingCaptures(engine: TransferEngine) {
        guard let items = linkState.takeCaptures(config.pendingCaptures), !items.isEmpty else { return }
        emit(.log("uploading \(items.count) capture(s)"))
        engine.sendCaptures(items)
    }

    /// Serves harness/app streams once per link (phone→desktop webcam/mic/
    /// screen listeners). Chunked through `LinkSender` for packets; the
    /// byte listeners run off-thread, so transfers keep their progress
    /// semantics while a stream flows.
    private func sendPendingStreams(engine: StreamEngine) {
        guard let offers = linkState.takeStreams(config.m5Streams), !offers.isEmpty else { return }
        emit(.log("serving \(offers.count) stream(s)"))
        engine.serve(offers)
    }

    /// Stops a ring nobody stopped after 2 minutes (Go `time.AfterFunc`,
    /// Android `handler.postDelayed`), even on an idle link.
    private func scheduleRingStop(peerName: String) {
        Thread.detachNewThread { [self] in
            Thread.sleep(forTimeInterval: TimeInterval(RingState.maxRingMs) / 1000 + 1)
            if let stopped = self.linkState.expireRing(nowMs: self.nowMs()) {
                self.emit(.ringStopped(deviceName: stopped))
            }
        }
    }

    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func emit(_ event: Event) {
        config.onEvent(event)
    }

    private func sync<T>(_ op: @escaping @Sendable () async -> T) -> T {
        let box = SyncBox<T>()
        let sem = DispatchSemaphore(value: 0)
        Task { box.value = await op(); sem.signal() }
        sem.wait()
        return box.value!
    }
}

/// Lock-guarded per-link M2 state (the session thread + the ring auto-stop
/// thread both touch it).
private final class LinkState: @unchecked Sendable {
    private let lock = NSLock()
    private var router = FeatureRouter()
    private var _paired = false
    private var _welcomeSent = false
    private var _uploadsSent = false
    private var _capturesSent = false
    private var _streamsSent = false

    var paired: Bool {
        get { lock.withLock { _paired } }
        set { lock.withLock { _paired = newValue } }
    }

    var ringing: Bool {
        lock.withLock { router.ring.ringing }
    }

    func route(_ p: Packet, ctx: FeatureContext) -> [FeatureAction] {
        lock.withLock { router.route(p, ctx: ctxWithPaired(ctx)) }
    }

    func approveClear(id: String) -> Bool {
        lock.withLock { router.approveClear(id: id) }
    }

    /// The id of the open approval prompt, if any (stale-answer guard).
    func approveCurrentId() -> String? {
        lock.withLock { router.approvals.current?.id }
    }

    func approveExpire() -> ApproveRequest? {
        lock.withLock { router.approveExpire() }
    }

    func expireRing(nowMs: Int64) -> String? {
        lock.withLock { router.ring.expire(nowMs: nowMs) }
    }

    /// Returns the packets on first call, nil after (one welcome per link).
    func takeWelcome(_ packets: [Packet]) -> [Packet]? {
        lock.withLock {
            guard !_welcomeSent else { return nil }
            _welcomeSent = true
            return packets
        }
    }

    /// Returns the upload list on first call, nil after (one batch per link).
    func takeUploads(_ paths: [URL]) -> [URL]? {
        lock.withLock {
            guard !_uploadsSent else { return nil }
            _uploadsSent = true
            return paths
        }
    }

    /// Returns the capture list on first call, nil after (one batch per link).
    func takeCaptures(_ items: [TransferEngine.CaptureUpload]) -> [TransferEngine.CaptureUpload]? {
        lock.withLock {
            guard !_capturesSent else { return nil }
            _capturesSent = true
            return items
        }
    }

    /// Returns the stream offers on first call, nil after (one batch per link).
    func takeStreams(_ offers: [StreamOffer]) -> [StreamOffer]? {
        lock.withLock {
            guard !_streamsSent else { return nil }
            _streamsSent = true
            return offers
        }
    }

    private func ctxWithPaired(_ ctx: FeatureContext) -> FeatureContext {
        var ctx = ctx
        ctx.paired = _paired
        return ctx
    }
}

/// Unchecked `Sendable` cell for bridging actor calls onto a confined
/// blocking thread (`LinkRunner.sync`).
private final class SyncBox<T>: @unchecked Sendable {
    var value: T?
}
#endif
