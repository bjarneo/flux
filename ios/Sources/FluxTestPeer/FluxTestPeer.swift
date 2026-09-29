// FluxTestPeer: runnable iOS-side peer for M1b wire interop.
//
// Listens like the phone app (TCP first-free 1716–1764 + UDP broadcasts),
// runs each inbound connection through LinkRunner, and auto-accepts pairing
// (test mode only). Talks to ios/tools/test_peer.py (desktop role) or a
// real fluxd on the LAN:
//
//   swift run FluxTestPeer --name "iPhone"            # ephemeral identity
//   python3 ios/tools/test_peer.py --listen           # discovers + pairs
//
// Flags:
//   --name            device name (default: SwiftPhone)
//   --tcp-port        fixed TCP port (default: 0 = first free 1716–1764)
//   --udp-port        discovery port (default: 1716)
//   --persist         keep device ID + trust in the Keychain (default is
//                     ephemeral: fresh ID each run, i.e. re-pair every run)
//   --forget          delete persisted identity + trust, then exit
//                     (fresh-install path: next launch re-pairs everywhere)
//   --dump-cert       write our certificate DER to PATH (for key audits)
//   --no-auto-accept  show requests without accepting (logs the key)
//   --exercise-m2     after pairing, send M2 phone→desktop samples (ping,
//                     battery, clipboard, share text, Flux-internal
//                     notification) and answer battery.request
//   --battery LEVEL   answer battery.request with LEVEL (implies a provider;
//                     --exercise-m2 defaults to 82)
//   --clipboard-sync  accept desktop clipboard/share-text (auto_clipboard on)
//   --downloads DIR   receive folder for desktop→phone files (default: a fresh
//                     mkdtemp dir, printed at startup)
//   --send-file PATH  upload PATH to the desktop once the link is ready
//                     (phone→desktop classic payload; repeatable per connection)
//   --browse          send kdeconnect.sftp.request on ready (Browse PC probe;
//                     the desktop answers an offer or an errorMessage)
//   --exercise-browse drive a full D1 browse after the offer (connect +
//                     list + download through the production BrowseSession;
//                     pair with test_peer.py --browse-ssh)
//   --exercise-m4     after pairing, send M4 phone→desktop samples (an
//                     mpris.request player-list query, a runcommand.request
//                     list query, a ringing→talking→hung-up call sequence,
//                     and flux.dnd on) and answer desktop player queries +
//                     mpris.request actions via a stub now-playing provider
//   --now-playing TITLE
//                     answer desktop player queries with TITLE playing
//                     (implies a stub provider; --exercise-m4 defaults to
//                     "Test Tone")
//   --exercise-m5     after pairing, serve M5 phone→desktop streams (webcam
//                     H.264 + config, mic PCM, screen H.264) with pinned-TLS
//                     listeners the desktop dials into, send scanned text +
//                     a scan PDF + a photo (photo_dir/scan_dir flags), and
//                     log desktop live/config/stop replies
//   --exercise-m5-live
//                     same bytes as --exercise-m5 but through the live
//                     producer seam (`LiveOffer` chunks posted to the
//                     runner's `liveStreams` box — the app Start path),
//                     proving the incremental serve + digest + stop
//   --exercise-m6     answer M6 approval/enrollment prompts (enroll +
//                     approve) with TEST-MODE signatures (non-biometric keys;
//                     every reply logs "TEST MODE (no biometric)"). Pair with
//                     test_peer.py --m6/--expect-m6, which verifies each
//                     signature with openssl against the enrolled pubkey.
//   --approve-deny    deny M6 approval prompts instead of signing them
//                     (enrollments are still approved)
//   --approve-delay N wait N seconds before answering M6 prompts (TEST MODE),
//                     so the desktop can cancel/timeout them first; answers
//                     for closed prompts are dropped by id, never sent

import Foundation
import Darwin
import CryptoKit
import FluxProto
import FluxNet
import FluxCore
import FluxCamera
import FluxStream
import FluxApprove
#if canImport(Security)
import Security
#endif

#if canImport(Security)
@main
struct FluxTestPeer {
    static func main() {
        let args = CommandLine.arguments
        func flag(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let has = { args.contains($0) }
        let name = flag("--name") ?? "SwiftPhone"
        let tcpPort = Int(flag("--tcp-port") ?? "") ?? 0
        let udpPort = Int(flag("--udp-port") ?? "") ?? Lan.udpPort
        let persist = has("--persist")
        let autoAccept = !has("--no-auto-accept")
        let exerciseM2 = has("--exercise-m2")
        let batteryLevel: Int? = flag("--battery").flatMap(Int.init) ?? (exerciseM2 ? 82 : nil)
        let clipboardSync = has("--clipboard-sync") || exerciseM2
        let downloadsDir: URL = {
            if let d = flag("--downloads") { return URL(fileURLWithPath: d) }
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("flux-m3-\(UUID().uuidString)")
        }()
        let sendFile: URL? = flag("--send-file").map { URL(fileURLWithPath: $0) }
        let browse = has("--browse")
        let exerciseBrowse = has("--exercise-browse")
        let browseIdle = UInt64(flag("--browse-idle") ?? "") ?? 0
        let exerciseM4 = has("--exercise-m4")
        let nowPlayingTitle: String? = flag("--now-playing") ?? (exerciseM4 ? "Test Tone" : nil)
        let exerciseM5 = has("--exercise-m5")
        let exerciseM5Live = has("--exercise-m5-live")
        let exerciseM6 = has("--exercise-m6")
        let approveDeny = has("--approve-deny")
        let approveDelay = UInt32(flag("--approve-delay") ?? "") ?? 0

        if has("--forget") {
            let kc = KeychainClient.live()
            kc.delete(DeviceID.service, DeviceID.account)
            kc.delete(DeviceID.service, "device-cert")
            kc.delete("org.omarchy.flux.testpeer", TrustService.indexAccount)
            // Trust items are keyed by desktop device ID (test-peer state dir).
            if let desktopId = try? String(
                contentsOfFile: NSString(string: "~/.cache/flux-ios-test-peer/id").expandingTildeInPath,
                encoding: .utf8
            ) {
                kc.delete("org.omarchy.flux.testpeer", desktopId.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            IdentityKeys.delete()
            // Approve keys are Keychain items too: remove every enrolled
            // computer key (M6 `--persist` runs) + the index itself.
            let forgotApprove = ApproveKeys.deleteAllEnrolled()
            print("flux-test-peer: forgot persisted identity + trust (approve keys: \(forgotApprove))")
            return
        }

        do {
            try run(name: name, tcpPort: tcpPort, udpPort: udpPort, persist: persist,
                    autoAccept: autoAccept, dumpCert: flag("--dump-cert"),
                    batteryLevel: batteryLevel, clipboardSync: clipboardSync,
                    exerciseM2: exerciseM2, downloadsDir: downloadsDir,
                    sendFile: sendFile, browse: browse, exerciseBrowse: exerciseBrowse, browseIdle: browseIdle,
                    nowPlayingTitle: nowPlayingTitle, exerciseM4: exerciseM4,
                    exerciseM5: exerciseM5, exerciseM5Live: exerciseM5Live, exerciseM6: exerciseM6,
                    approveDeny: approveDeny, approveDelay: approveDelay)
        } catch {
            fputs("flux-test-peer: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run(name: String, tcpPort: Int, udpPort: Int, persist: Bool, autoAccept: Bool, dumpCert: String?, batteryLevel: Int?, clipboardSync: Bool, exerciseM2: Bool, downloadsDir: URL, sendFile: URL?, browse: Bool, exerciseBrowse: Bool, browseIdle: UInt64, nowPlayingTitle: String?, exerciseM4: Bool, exerciseM5: Bool, exerciseM5Live: Bool, exerciseM6: Bool, approveDeny: Bool, approveDelay: UInt32) throws {
        let keychain: KeychainClient = persist ? .live() : .inMemory()
        let idService = persist ? DeviceID.service : "org.omarchy.flux.testpeer ephemeral \(UUID().uuidString)"
        let certAccount = "device-cert"

        // Device ID.
        let deviceId: String
        if let loaded = keychain.load(idService, DeviceID.account),
           let id = String(data: loaded, encoding: .utf8), validDeviceId(id) {
            deviceId = id
        } else {
            deviceId = DeviceID.make()
            keychain.save(idService, DeviceID.account, Data(deviceId.utf8))
        }

        // Key: permanent Keychain entry (required for SecIdentity lookup).
        // Ephemeral mode uses a fixed tag, replaced every run and removed
        // on clean exit, so the login keychain does not accumulate orphans.
        let tag = persist ? IdentityKeys.applicationTag : "org.omarchy.flux.testpeer-ephemeral"
        if !persist { IdentityKeys.delete(tag: tag) }
        ephemeralCleanupTag = persist ? nil : tag
        installSignalHandlers()
        defer { if !persist { IdentityKeys.delete(tag: tag) } }
        let key = try (IdentityKeys.loadOrCreate(tag: tag) as! SecKey)

        // Certificate: persisted in --persist mode so restarts keep the pin
        // (a fresh cert every launch would force a re-pair every time).
        let certDER: Data
        if let saved = keychain.load(idService, certAccount), !saved.isEmpty {
            certDER = saved
        } else {
            certDER = try SelfSignedCertificate.issue(key: key, deviceId: deviceId)
            keychain.save(idService, certAccount, certDER)
        }
        if let dumpCert { try certDER.write(to: URL(fileURLWithPath: dumpCert)) }
        guard let secCert = SecCertificateCreateWithData(nil, certDER as CFData),
              let secIdentity = TLSIdentity.makeIdentity(certificate: secCert, label: tag),
              let pub = SecKeyCopyPublicKey(key),
              let rep = SecKeyCopyExternalRepresentation(pub, nil) as Data?,
              let ownSPKI = Certificates.spkiFromUncompressedPoint(rep)
        else { throw SelfSignedCertificate.IssueError.signingFailed }

        let trust: any TrustStore = persist
            ? KeychainTrustStore(keychain: keychain, service: "org.omarchy.flux.testpeer")
            : InMemoryTrustStore()

        // TCP listener.
        let (tcpFD, boundPort): (Int32, Int)
        if tcpPort > 0 {
            (tcpFD, boundPort) = try bindFixed(port: tcpPort)
        } else {
            (tcpFD, boundPort) = try Sockets.listenTCP()
        }
        print("flux-test-peer: id=\(deviceId) name=\(cleanName(name)) tcp=\(boundPort) persist=\(persist)", flush: true)

        // M5 capture files: a scan PDF + a photo with deterministic bytes
        // (byte-identical both sides; the flags route them to scan_dir +
        // photo_dir on a real fluxd).
        let m5Captures: [TransferEngine.CaptureUpload] = (exerciseM5 || exerciseM5Live) ? makeM5Captures() : []
        // M5 streams: webcam H.264 + config, mic PCM, screen H.264.
        let m5Streams: [StreamOffer] = exerciseM5 ? makeM5Streams() : []
        // M5-live streams ride the app path instead of config: posted to
        // the runner's `liveStreams` box on `.paired` (same bytes as the
        // fixed fixtures, chunked — checksums must match).
        let liveRef = LiveRunnerRef()
        if exerciseM5Live { liveRef.build = { makeM5LiveOffers() } }
        // D1 browse: stashes offers + the session runner; the offer's
        // tunnel is taken and driven once the desktop dials it in.
        let browseDriver = BrowseDriver()
        browseDriver.idleSeconds = browseIdle
        // M6 approvals: test-mode auto-answer (non-biometric keys, every
        // reply logged as TEST MODE). Nil = hold prompts for the UI.
        let approveDecider: ((ApproveRequest) -> Packet?)? = {
            guard exerciseM6 || approveDeny || approveDelay > 0 else { return nil }
            let signer = TestApproveSigner(stored: persist, deny: approveDeny, delaySeconds: approveDelay)
            return { signer.decide($0) }
        }()
        print("flux-test-peer: approve decider active=\(approveDecider != nil)", flush: true)

        // UDP discovery socket (receive desktop broadcasts + send our own).
        let udpFD = try Sockets.discoverySocket(port: udpPort)
        let identity = Identity(deviceId: deviceId, deviceName: cleanName(name), deviceType: "phone", tcpPort: boundPort)
        let broadcastLine = try identity.toPacket(withPort: true).serialize()

        Thread.detachNewThread {
            while true {
                for host in ["255.255.255.255", "127.255.255.255", "127.0.0.1"] {
                    try? Sockets.sendTo(fd: udpFD, data: broadcastLine, host: host, port: udpPort)
                }
                Thread.sleep(forTimeInterval: 5)
            }
        }
        Thread.detachNewThread {
            while true {
                guard let (data, ip) = try? Sockets.receiveFrom(fd: udpFD, timeout: 10) else { continue }
                guard let pkt = Packet.parse(data), pkt.type == PacketType.identity,
                      let seen = Identity.from(pkt), seen.deviceId != deviceId
                else { continue }
                print("flux-test-peer: broadcast from \(seen.deviceName) @ \(ip) tcp=\(seen.tcpPort)", flush: true)
            }
        }

        // Accept loop.
        while true {
            let fd: Int32
            do { fd = try Sockets.accept(fd: tcpFD, timeout: 60) } catch { continue }
            var provider: (@Sendable () -> BatteryState?)? = nil
            if let level = batteryLevel {
                let inner: @Sendable () -> BatteryState? = { BatteryState(level: level, charging: false) }
                provider = inner
            }
            var nowPlaying: (@Sendable () -> MprisState?)? = nil
            if let title = nowPlayingTitle {
                let inner: @Sendable () -> MprisState? = {
                    MprisState(player: "Music", title: title, artist: "Test Band", playing: true, length: 180_000, canSeek: true)
                }
                nowPlaying = inner
            }
            var welcome: (@Sendable () -> [Packet])? = nil
            if exerciseM2 || browse || exerciseBrowse || exerciseM4 || exerciseM5 || exerciseM5Live {
                let phone = cleanName(name)
                let atBattery = batteryLevel ?? 82
                let wantBrowse = browse || exerciseBrowse
                let wantM4 = exerciseM4
                let wantM5 = exerciseM5 || exerciseM5Live
                let packets: @Sendable () -> [Packet] = {
                    let now = Int64(Date().timeIntervalSince1970 * 1000)
                    var out = exerciseM2 ? [
                        BatteryState(level: atBattery, charging: true).packet(),
                        PingMessage.packet(message: "hello from \(phone)"),
                        ClipboardMessage(content: "hello clipboard from \(phone)").packet(),
                        ShareMessage.textPacket("shared text from \(phone)"),
                        NotificationPackets.outgoing(
                            id: "flux-ios-m2", appName: "Flux",
                            title: "Hello from \(phone)",
                            text: "M2 exercise", timeMs: now),
                    ] : []
                    if wantBrowse { out.append(SftpPackets.requestPacket()) }
                    if wantM4 {
                        // M4 phone→desktop samples: a desktop-player query, a
                        // command-list query, one incoming call answered and
                        // hung up, and Focus on. test_peer.py --expect-m4
                        // asserts all four types arrive.
                        out += [
                            MprisMessage.requestPlayerList(),
                            RunCommandMessage.requestList(),
                            CallPackets.packet(event: CallEvent("ringing"), phoneNumber: "+4712345678"),
                            CallPackets.packet(event: CallEvent("talking"), phoneNumber: "+4712345678"),
                            CallPackets.packet(event: CallEvent("talking", cancel: true), phoneNumber: "+4712345678"),
                            DndMessage.packet(on: true),
                        ]
                    }
                    if wantM5 {
                        // M5 phone→desktop capture sample: scanned text.
                        // test_peer.py --expect-m5 asserts it arrives; the
                        // scan PDF + photo ride the capture-upload path.
                        out.append(ShareMessage.textPacket(
                            "Scanned text from \(phone): Gate B14, Boarding 15:40", scan: true))
                    }
                    return out
                }
                welcome = packets
            }
            print("flux-test-peer: downloads=\(downloadsDir.path)", flush: true)
            let runner = LinkRunner(config: LinkRunner.Configuration(
                ownId: deviceId,
                deviceName: name,
                identity: secIdentity,
                ownSPKI: ownSPKI,
                trust: trust,
                autoAccept: autoAccept,
                batteryProvider: provider,
                nowPlayingProvider: nowPlaying,
                welcomePackets: welcome,
                clipboardSync: clipboardSync,
                pendingUploads: sendFile.map { [$0] } ?? [],
                pendingCaptures: m5Captures,
                m5Streams: m5Streams,
                approveDecider: approveDecider,
                downloadsDirectory: downloadsDir
            ) { event in
                switch event {
                case .log(let m):
                    print("flux-test-peer: \(m)", flush: true)
                case .pairRequested(_, _, let key):
                    print("flux-test-peer: PAIR REQUEST key=\(key) \(autoAccept ? "(auto-accept)" : "(waiting; restart with auto-accept)")", flush: true)
                case .paired(let device, let key):
                    print("flux-test-peer: PAIRED with \(device) key=\(key)", flush: true)
                    liveRef.postLive()
                case .closed(let device):
                    print("flux-test-peer: closed \(device)", flush: true)
                case .pingReceived(let device, let message):
                    print("flux-test-peer: PING from \(device): \(message)", flush: true)
                case .batteryReceived(let device, let level, let charging):
                    print("flux-test-peer: BATTERY from \(device): \(level.map(String.init) ?? "none") charging=\(charging)", flush: true)
                case .clipboardReceived(let device, let content):
                    print("flux-test-peer: CLIPBOARD from \(device): \(content)", flush: true)
                case .shareTextReceived(let device, let text):
                    print("flux-test-peer: SHARE TEXT from \(device): \(text)", flush: true)
                case .shareURLReceived(let device, let url):
                    print("flux-test-peer: SHARE URL from \(device): \(url)", flush: true)
                case .shareFileQueued(let device, let filename, let size):
                    print("flux-test-peer: SHARE FILE from \(device): \(filename) (\(size) bytes, M3 fetch)", flush: true)
                case .ringStarted(let device):
                    print("flux-test-peer: RING START from \(device)", flush: true)
                case .ringStopped(let device):
                    print("flux-test-peer: RING STOP from \(device)", flush: true)
                case .notificationReceived(let device, let title, let text):
                    print("flux-test-peer: NOTIFICATION from \(device): \(title) — \(text)", flush: true)
                case .notificationCancelled(let device, let key):
                    print("flux-test-peer: NOTIFICATION CANCEL from \(device): \(key)", flush: true)
                case .transferProgress(let device, let filename, let done, let size):
                    print("flux-test-peer: TRANSFER \(filename) \(done)/\(size) from \(device)", flush: true)
                case .transferCompleted(let device, let filename, let path, let bytes):
                    let sha: String = {
                        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return "unreadable" }
                        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    }()
                    print("flux-test-peer: TRANSFER DONE \(filename) (\(bytes) bytes) sha256=\(sha) from \(device)", flush: true)
                case .transferFailed(let device, let filename, let error):
                    print("flux-test-peer: TRANSFER FAILED \(filename) from \(device): \(error)", flush: true)
                case .tunnelObserved(let device, let token, let port, let error):
                    print("flux-test-peer: TUNNEL \(token) port=\(port) error=\(error ?? "none") from \(device)", flush: true)
                case .sftpOfferReceived(let device, let offer):
                    print("flux-test-peer: SFTP OFFER tunnel=\(offer.tunnel ?? "none") roots=\(offer.roots.map { $0.0 }.joined(separator: ",")) user=\(offer.user) from \(device)", flush: true)
                    if exerciseBrowse { browseDriver.noteOffer(offer) }
                case .sftpErrorReceived(let device, let message):
                    print("flux-test-peer: SFTP ERROR from \(device): \(message)", flush: true)
                case .sftpServeRequested(let device):
                    print("flux-test-peer: SFTP SERVE REQUEST from \(device) (deferred)", flush: true)
                case .browseTunnelReady(let device, let tunnel):
                    print("flux-test-peer: BROWSE TUNNEL \(tunnel) established with \(device)", flush: true)
                    if exerciseBrowse { browseDriver.driveIfReady(tunnel: tunnel) }
                case .browseTunnelFailed(let device, let error):
                    print("flux-test-peer: BROWSE TUNNEL FAILED with \(device): \(error)", flush: true)
                case .mediaPlayersReceived(let device, let players):
                    print("flux-test-peer: MEDIA PLAYERS from \(device): \(players.joined(separator: ","))", flush: true)
                case .mediaStateReceived(let device, let state):
                    print("flux-test-peer: MEDIA STATE from \(device): \(state.player) \(state.title) - \(state.artist) playing=\(state.playing)", flush: true)
                case .mediaActionReceived(let device, let player, let action):
                    print("flux-test-peer: MEDIA ACTION from \(device): \(player) \(action)", flush: true)
                case .mediaSeekReceived(let device, let player, let positionMs):
                    print("flux-test-peer: MEDIA SEEK from \(device): \(player) \(positionMs)ms", flush: true)
                case .mediaVolumeReceived(let device, let player, let volume):
                    print("flux-test-peer: MEDIA VOLUME from \(device): \(player) \(volume)", flush: true)
                case .commandListReceived(let device, let commands, let canAdd):
                    print("flux-test-peer: COMMANDS from \(device): \(commands.count) command(s) canAdd=\(canAdd)", flush: true)
                case .dndReceived(let device, let on):
                    print("flux-test-peer: DND from \(device): \(on ? "on" : "off")", flush: true)
                case .webcamLiveReceived(let device, let dev, let label):
                    print("flux-test-peer: WEBCAM LIVE from \(device): \(dev) as \(label)", flush: true)
                case .webcamErrorReceived(let device, let message):
                    print("flux-test-peer: WEBCAM ERROR from \(device): \(message)", flush: true)
                case .webcamStopReceived(let device):
                    print("flux-test-peer: WEBCAM STOP from \(device)", flush: true)
                case .webcamConfigReceived(let device, let reset, let partial):
                    print("flux-test-peer: WEBCAM CONFIG from \(device): reset=\(reset) partial=\(partial?.keys.sorted().joined(separator: ",") ?? "none")", flush: true)
                case .micLiveReceived(let device, let source):
                    print("flux-test-peer: MIC LIVE from \(device): \(source)", flush: true)
                case .micErrorReceived(let device, let message):
                    print("flux-test-peer: MIC ERROR from \(device): \(message)", flush: true)
                case .micStopReceived(let device):
                    print("flux-test-peer: MIC STOP from \(device)", flush: true)
                case .screenLiveReceived(let device, let player):
                    print("flux-test-peer: SCREEN LIVE from \(device): \(player)", flush: true)
                case .screenErrorReceived(let device, let message):
                    print("flux-test-peer: SCREEN ERROR from \(device): \(message)", flush: true)
                case .screenStopReceived(let device):
                    print("flux-test-peer: SCREEN STOP from \(device)", flush: true)
                case .streamStarted(let device, let kind, let port):
                    print("flux-test-peer: STREAM \(kind) started port=\(port) with \(device)", flush: true)
                case .streamProgress(let device, let kind, let done, let size):
                    print("flux-test-peer: STREAM \(kind) \(done)/\(size) to \(device)", flush: true)
                case .streamDone(let device, let kind, let bytes, let sha):
                    print("flux-test-peer: STREAM \(kind) SERVED \(bytes) bytes sha256=\(sha) to \(device)", flush: true)
                case .streamFailed(let device, let kind, let error):
                    print("flux-test-peer: STREAM \(kind) FAILED to \(device): \(error)", flush: true)
                case .approvePromptReceived(let device, let kind, let id, let host, let user, let service):
                    print("flux-test-peer: APPROVE PROMPT \(kind) id=\(id) host=\(host) user=\(user) service=\(service) from \(device)", flush: true)
                case .approveAnswered(let device, let id, let result):
                    print("flux-test-peer: APPROVE \(result.uppercased()) id=\(id) with \(device)", flush: true)
                }
            })
            liveRef.set(runner)
            if exerciseBrowse { browseDriver.set(runner) }
            Thread.detachNewThread { runner.run(fd: fd) }
        }
    }

    /// M5 capture fixtures: a scan PDF (`scan:true` → `scan_dir`) + a photo
    /// (`photo:true` → `photo_dir`) with deterministic bytes, so the desktop
    /// can prove byte-identity like any M3 upload.
    static func makeM5Captures() -> [TransferEngine.CaptureUpload] {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("flux-m5-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var pdf = Data("%PDF-1.4\n%Flux M5 scan fixture\n".utf8)
        for i in 0 ..< 2048 { pdf += Data("scan-line \(i): Gate B14, Boarding 15:40\n".utf8) }
        pdf += Data("%%EOF\n".utf8)
        var jpg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
        for i in 0 ..< 4096 {
            jpg.append(UInt8(i & 0xFF))
            jpg.append(UInt8((i >> 8) & 0xFF))
        }
        let pdfURL = dir.appendingPathComponent("scan-20260925-101500.pdf")
        let jpgURL = dir.appendingPathComponent("IMG_20260925_101500.jpg")
        try? pdf.write(to: pdfURL)
        try? jpg.write(to: jpgURL)
        return [
            TransferEngine.CaptureUpload(url: pdfURL, scan: true),
            TransferEngine.CaptureUpload(url: jpgURL, photo: true),
        ]
    }

    /// Shared M5 stream media: identical bytes back both the fixed
    /// `StreamOffer`s and the live `LiveOffer`s, so checksums match
    /// whichever seam serves them.
    struct M5Media {
        var webcamWidth: Int
        var webcamHeight: Int
        var webcamConfig: [String: JSONValue]
        var webcamCaps: [String: JSONValue]
        var webcamBytes: Data
        var micBytes: Data
        var screenWidth: Int
        var screenHeight: Int
        var screenBytes: Data
    }

    static func makeM5Media() -> M5Media {
        let cfg = WebcamConfig()
        let (screenWidth, screenHeight) = MirrorSize.fit(width: 1080, height: 2400)
        return M5Media(
            webcamWidth: cfg.width, webcamHeight: cfg.height,
            webcamConfig: cfg.jsonObject(), webcamCaps: WebcamCaps.loose.jsonObject(),
            webcamBytes: StreamFixtures.videoStream(idrCount: 64, pPerIdr: 15),
            micBytes: StreamFixtures.micStream(seconds: 2),
            screenWidth: screenWidth, screenHeight: screenHeight,
            screenBytes: StreamFixtures.videoStream(idrCount: 32, pPerIdr: 7))
    }

    /// M5 stream fixtures: webcam H.264 + full config, mic PCM, screen
    /// H.264 — all deterministic (`StreamFixtures`), all announced with a
    /// stop so the desktop sees the full session.
    static func makeM5Streams() -> [StreamOffer] {
        let m = makeM5Media()
        return [
            StreamOffer(
                kind: .webcam,
                buildStart: { WebcamPackets.start(port: $0, width: m.webcamWidth, height: m.webcamHeight) },
                followUp: WebcamPackets.config(config: m.webcamConfig, caps: m.webcamCaps),
                bytes: m.webcamBytes, announceStop: true),
            StreamOffer(
                kind: .mic,
                buildStart: { MicPackets.start(port: $0) },
                bytes: m.micBytes, announceStop: true),
            StreamOffer(
                kind: .screen,
                buildStart: { ScreenPackets.start(port: $0, width: m.screenWidth, height: m.screenHeight) },
                bytes: m.screenBytes, announceStop: true),
        ]
    }

    /// M5-live offers: the same starts + bytes as `makeM5Streams`, chunked
    /// through the `liveStreams` box (the app Start path). Fresh streams
    /// per build — an `AsyncStream` serves once, so every `.paired` (fresh
    /// + pinned reconnects) rebuilds.
    static func makeM5LiveOffers() -> [LiveOffer] {
        let m = makeM5Media()
        return [
            LiveOffer(
                kind: .webcam,
                buildStart: { WebcamPackets.start(port: $0, width: m.webcamWidth, height: m.webcamHeight) },
                followUp: WebcamPackets.config(config: m.webcamConfig, caps: m.webcamCaps),
                chunks: chunked(m.webcamBytes, parts: 8), announceStop: true),
            LiveOffer(
                kind: .mic,
                buildStart: { MicPackets.start(port: $0) },
                chunks: chunked(m.micBytes, parts: 8), announceStop: true),
            LiveOffer(
                kind: .screen,
                buildStart: { ScreenPackets.start(port: $0, width: m.screenWidth, height: m.screenHeight) },
                chunks: chunked(m.screenBytes, parts: 8), announceStop: true),
        ]
    }

    /// Splits deterministic bytes into `parts` chunks for the live seam.
    static func chunked(_ bytes: Data, parts: Int) -> AsyncStream<Data> {
        AsyncStream { cont in
            var off = 0
            let n = max(1, bytes.count / parts)
            while off < bytes.count {
                cont.yield(bytes.subdata(in: off..<min(off + n, bytes.count)))
                off += n
            }
            cont.finish()
        }
    }

    static func bindFixed(port: Int) throws -> (Int32, Int) {        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Sockets.SocketError.unavailable(errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let e = errno
            close(fd)
            throw Sockets.SocketError.unavailable(e)
        }
        listen(fd, 16)
        return (fd, port)
    }
}

/// Holds the session runner for `--exercise-m5-live`: the event closure
/// (built before the runner exists) posts live offers through it on
/// `.paired`, exactly like the app will post Start offers through
/// `LinkService`. Fresh offers per post (an `AsyncStream` serves once).
final class LiveRunnerRef: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var runner: LinkRunner?
    var build: (() -> [LiveOffer])?

    func set(_ r: LinkRunner) {
        lock.withLock { runner = r }
    }

    func postLive() {
        let (current, make): (LinkRunner?, (() -> [LiveOffer])?) = lock.withLock { (runner, build) }
        guard let current, let make else { return }
        for offer in make() { current.liveStreams.serve(offer) }
    }
}

/// Module-wide print with flush (stdout is block-buffered under pipes;
///
/// E2E transcripts rely on prompt output).
func print(_ s: String, flush: Bool) {
    Swift.print(s)
    fflush(stdout)
}

private nonisolated(unsafe) var ephemeralCleanupTag: String?

private func installSignalHandlers() {
    signal(SIGINT, signalHandler)
    signal(SIGTERM, signalHandler)
    // Writes to a dead peer raise SIGPIPE, which terminates by default
    // (crashed the app on mic Stop, 2026-09-27). Ignored, they surface
    // as normal write errors on the existing failure paths.
    signal(SIGPIPE, SIG_IGN)
}

private func signalHandler(_ sig: Int32) {
    if let tag = ephemeralCleanupTag {
        IdentityKeys.delete(tag: tag)
    }
    Darwin.exit(128 + sig)
}
#else
@main
struct FluxTestPeer {
    static func main() {
        fputs("flux-test-peer needs the Security framework (Apple platforms)\n", stderr)
        exit(1)
    }
}
#endif
