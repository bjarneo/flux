import SwiftUI
import FluxUI
import FluxCore
import FluxProto
import FluxCamera
import FluxFeatures
import FluxApprove
import FluxStream
import AVFoundation
import Photos
#if os(iOS)
import VisionKit
#endif
#if canImport(Darwin)
import Darwin
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Flux for iOS entry point. The link runs in the foreground (M1): start
/// on launch + foreground, stop on background with the honest
/// "Background suspended" banner (plan §3.2). Incoming pair prompts
/// present `PairView` (compare the key on both screens, then Accept);
/// unanswered prompts expire silently (incoming 25 s expiry, M2 contract).
/// Desktop packets render through the M2 bridges (notification banner,
/// ring overlay, clipboard apply); every event also hits the console +
/// status line so device runs are observable without Xcode.
@main
struct FluxApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var presence: LinkPresence = .offline
    @State private var pairPrompt: PairPrompt?
    @State private var status: String?
    /// Reverse-direction remote screens (#1 commands, #2 media): fed by
    /// the `LinkRunner` media/command events below, sent back over
    /// `LinkService.send` (D23 path) through the `ContentView` closures.
    @State private var remoteScreens = RemoteScreensState()
    /// Received files on this iPhone (browse downloads + desktop sends):
    /// refreshed whenever a transfer lands so the Downloads screen (the
    /// only way to reach the sandboxed files) stays current.
    @State private var downloads: [DownloadedFile] = []
    /// Browse-file sessions (D1): one SSH session per device over a taken
    /// browse tunnel (`BrowseSession` actor) + the stashed offer creds per
    /// device (the runner auto-opens the tunnel on the offer; the app
    /// takes it on `browseTunnelReady`). Store state drives `BrowseScreen`.
    @State private var browseSessions: [String: BrowseSession] = [:]
    @State private var browseOffers: [String: SftpOffer] = [:]
    /// Microphone live session (D16): `StreamSession` status drives
    /// `MicScreen`, the tap feeds a `LiveOffer` through `offerStream`.
    /// Packets go over `link` (never `session.send`, so no double stop);
    /// the session is status only.
    private let micSession = StreamSession(kind: .mic)
    private let micProducer = MicProducer()
    @State private var micLevel: Float = 0
    @State private var micWithWebcam = MicPreferences.load().withWebcam
    /// Mic stream generation: recorded on every Start, bumped by every
    /// session stop. Events from older generations (a replaced stream's
    /// desktop error arriving after a re-tap) are stale and ignored —
    /// they must not tear down the current stream.
    @State private var micGeneration = 0
    /// When the user last stopped the mic: a desktop error arriving
    /// within the window is the RST echo of our own close (bytes were in
    /// flight), so it shows the idle screen, not the error screen.
    @State private var lastMicStop: Date?
    /// Webcam live session (D16): same shape as the mic — `StreamSession`
    /// status drives the `CameraScreen` webcam tab, the camera drain feeds
    /// a `LiveOffer` through `offerStream`. Packets go over `link` (never
    /// `session.send`, so no double stop); the session is status only.
    /// The persisted settings (`WebcamPreferences`) seed the announced
    /// frame size; a desktop `config` merges into them (Android
    /// `WebcamSettings.applyRemote` parity) and restarts the stream on a
    /// frame-size change.
    private let webcamSession = StreamSession(kind: .webcam)
    private let webcamProducer = WebcamProducer()
    @State private var webcamConfig = WebcamPreferences.load().config
    /// Webcam stream generation: same stale-event guard as the mic (a
    /// replaced stream's desktop error must not tear down its replacement).
    @State private var webcamGeneration = 0
    /// RST-echo grace for the webcam (same 3 s window as the mic).
    @State private var lastWebcamStop: Date?
    /// The mic runs because the webcam is live with the withWebcam flag
    /// (Android `WebcamPanel` mic-by-webcam parity): the webcam stops it
    /// when the webcam stops. A mic the user started themselves is never
    /// touched (only a non-active mic is auto-started).
    @State private var micByWebcam = false
    /// Screen-mirror live session: same shape as mic/webcam —
    /// `StreamSession` status drives `MirrorScreen`, the in-app
    /// `RPScreenRecorder` drain feeds a `LiveOffer` through `offerStream`.
    /// Packets go over `link` (never `session.send`, so no double stop);
    /// the session is status only. Foreground-only (the recorder needs
    /// it); backgrounding tears down via `.closed` like the rest.
    private let screenSession = StreamSession(kind: .screen)
    private let screenProducer = ScreenProducer()
    /// Screen stream generation: same stale-event guard as mic/webcam.
    @State private var screenGeneration = 0
    /// RST-echo grace for the mirror (same 3 s window as mic/webcam).
    @State private var lastScreenStop: Date?
    /// Camera captures (D15/D18): one-shot text/QR/photo drains, the
    /// VisionKit document scanner, and the photo-library auto-upload
    /// watch. Results feed the CameraScreen tabs per device; file captures
    /// stage to tmp + queue in the outbox (link-waiting, never dropped —
    /// a capture tap racing a dead link uploads on the next `.paired`).
    private let textSession = TextCaptureSession()
    private let codeSession = CodeCaptureSession()
    private let photoSession = PhotoCaptureSession()
    #if os(iOS)
    private let docScanner = DocumentScanner()
    #endif
    private let libraryWatch = PhotoLibraryWatch()
    @State private var captureOutbox = CaptureOutbox.restored()
    /// Staged paths with a send in flight (delivery-tracked outbox): items
    /// leave the queue only on `transferCompleted`, so a link-death
    /// mid-transfer retries instead of losing the capture. Cleared on
    /// `.closed` (outcomes unknown — the queue still holds the files, so
    /// the next flush retries; at-least-once, the host renames dups).
    @State private var inflightCaptures: Set<String> = []
    @State private var captureTexts: [String: String] = [:]
    @State private var captureCodes: [String: CodeSheet] = [:]
    @State private var captureScanning: [String: Bool] = [:]
    @State private var capturePreview: AVCaptureSession?
    @State private var screenshotsOn = CapturePrefs.screenshotsOn
    @State private var photosOn = CapturePrefs.photosOn
    /// The device a pending document scan uploads to (the scanner reports
    /// data without context — the tap's device is remembered here).
    @State private var docScanDevice: String?
    @State private var ringingFrom: String?
    @State private var shownNotifications: [String: [String]] = [:]
    /// Kept alive: the center holds its delegate weakly.
    private let foregroundNotifications = ForegroundNotificationDelegate()
    /// Main-thread-fed battery readings for the link provider.
    private let batteryCache = BatteryCache()
    @State private var batteryObserving = false
    /// Production approve decider (biometric signing, UI-mediated).
    private let approveFlow = ApproveFlow()
    @State private var approveItem: ApproveItem?
    @State private var approvePhase: ApprovePhase = .ask(working: false)
    /// Media/command bridges (M4 read path): desktop `flux media *`
    /// drives the command center; Focus changes go back on the link.
    private let nowPlaying: NowPlayingBridge
    private let focus = FocusBridge()
    private let calls = CallBridge()
#if canImport(UIKit)
    /// Foreground Focus poll (M4 hardware round, 2026-09-27): iOS
    /// offers no Focus-change callback, and one foreground read misses
    /// toggles made while open — worse, single reads made a stuck-`false`
    /// undiagnosable. A 3 s main-runloop poll while active closes both
    /// gaps; `DndGuard` keeps sends change-only and each tick is one
    /// locked property read (no battery cost to speak of). Stopped on
    /// background: a suspended app sends nothing anyway.
    @State private var focusTimer: Timer?
#if canImport(UIKit)
    /// Background grace for an open approval prompt (D22): if the user
    /// backgrounds mid-prompt, the app gets ~30 s to finish signing +
    /// sending the answer instead of suspending instantly.
    @State private var approveBackgroundTask: UIBackgroundTaskIdentifier = .invalid
#endif
#endif
    private let link: LinkService

    init() {
        // A write to a dead peer raises SIGPIPE, which terminates the
        // process by default (seen on-device as a mic-Stop crash,
        // 2026-09-27: our stop packet races our own in-flight write —
        // the desktop closes on the stop, the pending write hits the
        // closed socket). Ignored process-wide, it surfaces as a normal
        // write error on the existing failure paths instead.
        #if canImport(Darwin)
        signal(SIGPIPE, SIG_IGN)
        #endif
#if canImport(UIKit)
        // App init runs on the main thread.
        let name = UIDevice.current.name
#else
        let name = "iPhone"
#endif
        let nowPlaying = NowPlayingBridge()
        self.nowPlaying = nowPlaying
        link = LinkService(
            deviceName: name,
            batteryProvider: batteryCache.provider(),
            nowPlayingProvider: { nowPlaying.current() },
            approveDecider: approveFlow.decide)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                presence: presence,
                status: status,
                remote: remoteScreens,
                onRequestCommands: { requestCommands(device: $0) },
                onRunCommand: { runCommand(device: $0, command: $1) },
                onBrowseOpen: { browseOpen(device: $0) },
                onBrowseList: { browseList(device: $0, path: $1) },
                onBrowseDownload: { browseDownload(device: $0, entry: $1) },
                onBrowseClose: { browseClose(device: $0) },
                onRequestPlayers: { requestPlayers(device: $0) },
                onSelectPlayer: { selectPlayer(device: $0, player: $1) },
                onMediaAction: { mediaAction(device: $0, player: $1, action: $2) },
                onMediaSeek: { mediaSeek(device: $0, player: $1, positionMs: $2) },
                micLevel: micLevel,
                micWithWebcam: micWithWebcam,
                onMicStart: { startMic(device: $0) },
                onMicStop: { stopMic() },
                onMicWithWebcam: { setMicWithWebcam($0) },
                webcamConfig: webcamConfig,
                onWebcamStart: { startWebcam(device: $0) },
                onWebcamStop: { stopWebcam() },
                onMirrorStart: { startMirror(device: $0) },
                onMirrorStop: { stopMirror() },
                onSendText: { sendScannedText(device: $0, text: $1) },
                onCodeAction: { codeAction(device: $0, action: $1) },
                onTakePhoto: { takePhoto(device: $0) },
                onScanDocument: { scanDocument(device: $0) },
                captureTexts: captureTexts,
                captureCodes: captureCodes,
                captureScanning: captureScanning,
                onScanText: { scanText(device: $0) },
                onScanCode: { scanCode(device: $0) },
                screenshotsOn: screenshotsOn,
                photosOn: photosOn,
                onCaptureToggle: { setCaptureAuto(kind: $0, on: $1) },
                capturePreview: capturePreview,
                downloads: downloads,
                onRefreshDownloads: { downloads = DownloadsStore.list() },
                onDeleteDownload: {
                    if DownloadsStore.remove($0) { downloads = DownloadsStore.list() }
                }
            )
                .task { startLink() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        print("flux: scene foreground")
                        startLink()
                        focusTimer?.invalidate()
                        let bridge = focus
                        focusTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
                            bridge.refresh()
                        }
                    } else if phase == .background {
                        print("flux: scene background (prompt open=\(approveItem != nil))")
                        focusTimer?.invalidate()
                        focusTimer = nil
                        // D22: an open prompt gets background grace so the
                        // user can still answer from the lock-screen
                        // notification; the hold ends on the answer. No
                        // re-post here: with `.list` the foreground post
                        // already owns a proper NC entry, and re-posting
                        // would just double-ping (second banner + sound).
                        if approveItem != nil { beginApproveBackgroundHold() }
                        // End live captures BEFORE the link stops (the
                        // announces go out over the live runners):
                        // backgrounding kills sessions by design, and a
                        // surviving socket leaves a zombie the UI can't
                        // stop — presence drops while bytes still flow
                        // (seen on the mirror 2026-09-28: live mpv, no
                        // Stop button, uploads refusing with "no link").
                        // Each stop is a no-op when its session is idle.
                        // Approvals are untouched (D22 grace lives on).
                        stopMic()
                        stopWebcam()
                        stopMirror()
                        // Orderly FIN so the desktop notices at once (its
                        // link gate clears → fast redial on republish).
                        // Skipped only with an open approve/pair prompt
                        // (the D22 answer and the handshake still need
                        // their session).
                        if approveItem == nil && pairPrompt == nil {
                            link.closeSessions()
                        }
                        link.stop()
                        presence = .suspended
                    }
                }
                .sheet(item: $pairPrompt) { prompt in
                    PairView(
                        deviceName: prompt.deviceName,
                        verificationKey: prompt.key,
                        onAccept: { answerPair(prompt: prompt, accept: true) },
                        onDecline: { answerPair(prompt: prompt, accept: false) }
                    )
                }
                .sheet(item: $approveItem) { item in
                    ApprovePromptScreen(
                        request: item.request,
                        computerName: item.peerName,
                        phase: approvePhase,
                        onApprove: {
                            approvePhase = .ask(working: true)
                            approveFlow.resolve(id: item.id, accept: true)
                        },
                        onDeny: {
                            approveFlow.resolve(id: item.id, accept: false)
                            ApproveNotifications.dismiss(id: item.id)
                            endApproveBackgroundHold()
                            approveItem = nil
                            approvePhase = .ask(working: false)
                        },
                        onClose: {
                            // Swipe-away without answering: fail closed.
                            // (Only while still asking — after an answer the
                            // verdict is already consumed or stale-safe.)
                            if case .ask = approvePhase {
                                approveFlow.resolve(id: item.id, accept: false)
                            }
                            ApproveNotifications.dismiss(id: item.id)
                            endApproveBackgroundHold()
                            approveItem = nil
                            approvePhase = .ask(working: false)
                        }
                    )
                }
                .sheet(isPresented: Binding(
                    get: { ringingFrom != nil },
                    set: { if !$0 { ringingFrom = nil } }
                )) {
                    RingView(from: ringingFrom ?? "", onStop: { ringingFrom = nil })
                }
        }
    }

    private func startLink() {
        // Never restart under a live capture: `link.start()` stops the
        // listener first, which clears the runner registry while live
        // sockets survive — the session orphans (presence drops to
        // reconnecting, sends refuse, the UI loses its Stop). Only
        // `.background` tears sessions down, but `.active` also fires on
        // `.inactive` blips (notification shade, switcher) with no
        // background in between — seen 2026-09-28: the mirror kept
        // streaming across two foreground reprints with no background
        // line. Idle only: relaunch + background return + recovery are
        // unaffected (teardown idles every session first).
        guard !micSession.current.active, !webcamSession.current.active,
              !screenSession.current.active
        else {
            print("flux: link restart skipped (live session)")
            return
        }
#if canImport(UserNotifications)
        // One system prompt (desktop→phone banners need it). Detached +
        // await: the completion-handler form traps when created in this
        // async context and invoked on the framework queue
        // (`dispatch_assert_queue_fail`, first-device crash 2026-09-27).
        Task.detached {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        }
        // Approval prompt category (D21 Approve/Deny lock-screen actions).
        ApproveNotifications.registerCategories()
        // Foreground banners need the delegate (set on main; weak-held).
        // Lock-screen Approve/Deny resolves the held prompt (D21); the
        // biometric gate still runs before any signature leaves the phone.
        let foreground = foregroundNotifications
        let flow = approveFlow
        foreground.onApproveAction = { promptId, approve in
            if approve {
                Task { @MainActor in approvePhase = .ask(working: true) }
            } else {
                Task { @MainActor in
                    approveItem = nil
                    approvePhase = .ask(working: false)
                }
                ApproveNotifications.dismiss(id: promptId)
            }
            flow.resolve(id: promptId, accept: approve)
        }
        DispatchQueue.main.async {
            UNUserNotificationCenter.current().delegate = foreground
        }
#endif
        // Approval diagnostics (D20): auth/sign error codes hit the
        // console + status line; the wire message stays user-actionable.
        // This is how a misread is told apart from an invalidated key.
        approveFlow.onLog = { message in
            print("flux: approve \(message)")
            Task { @MainActor in status = "approve \(message)" }
        }
        // Media/command bridges (M4): remote-command handlers drive the
        // (currently silent) player closures; Focus access is asked once
        // and refreshed every foreground — no background polling.
        nowPlaying.start()
        focus.requestAccess()
        focus.onLog = { message in
            // Console-only, like link logs: the screen keeps user
            // state, diagnostics go to Xcode.
            print("flux: \(message)")
        }
        focus.onChange = { [link] on in
            _ = link.send(DndMessage.packet(on: on))
        }
        // After onChange: the first foreground's change used to be
        // swallowed by the nil handler (M4 hardware round, 2026-09-27).
        focus.refresh()
        calls.onPacket = { [link] packet in
            // No number ever reaches the desktop (D14): `CallBridge` only
            // builds "Unknown caller" packets. False with no link up (a
            // transition observed while suspended is lost — the tracker
            // already moved on; the proof run foregrounds mid-ring so
            // each leg fires on a live link).
            let event = packet.string("event") ?? "call"
            let end = CallPackets.isCancel(packet) ? " (end)" : ""
            let sent = link.send(packet)
            print("flux: call \(event)\(end) sent=\(sent)")
        }
        calls.start()
        // Camera captures (D15/D18): the library watch resolves assets
        // through the production loader (HEIC→JPEG) and hands staged
        // files to the outbox; the document scanner uploads to the
        // remembered device. All three flush through `sendCaptures`.
        libraryWatch.dataForAsset = { id in
            CaptureAssetLoader.fetchSync(localIdentifier: id)
        }
        libraryWatch.log = { print("flux: \($0)") }
        libraryWatch.onCapture = { data, name, flags in
            Task { @MainActor in
                var scan = false, photo = false, screenshot = false
                for (k, v) in flags {
                    guard (v as? Bool) == true else { continue }
                    if k == "scan" { scan = true }
                    if k == "photo" { photo = true }
                    if k == "screenshot" { screenshot = true }
                }
                do {
                    let url = try CaptureAssetLoader.stageTempFile(data: data, name: name)
                    print("flux: library capture staged \(name) (\(data.count) B)")
                    captureOutbox.enqueue(CaptureOutbox.Item(
                        url: url, scan: scan, photo: photo, screenshot: screenshot))
                    captureOutbox.persist()
                    flushCaptures()
                } catch {
                    print("flux: library capture stage failed \(name): \(error)")
                    status = "Could not save \(name)."
                }
            }
        }
        if screenshotsOn { libraryWatch.setKind(.screenshot, on: true) }
        if photosOn { libraryWatch.setKind(.photo, on: true) }
        libraryWatch.refresh()
        #if os(iOS)
        docScanner.onScan = { data, name in
            Task { @MainActor in
                guard let device = docScanDevice else { return }
                docScanDevice = nil
                do {
                    let url = try CaptureAssetLoader.stageTempFile(data: data, name: name)
                    print("flux: document scan staged \(name) (\(data.count) B)")
                    captureOutbox.enqueue(CaptureOutbox.Item(url: url, scan: true))
                    captureOutbox.persist()
                    status = "Scan staged — sending to \(device)…"
                    flushCaptures()
                } catch {
                    print("flux: document stage failed \(name): \(error)")
                    status = "Could not save \(name)."
                }
            }
        }
        docScanner.onCancel = {
            Task { @MainActor in
                docScanDevice = nil
                status = "Scan cancelled."
            }
        }
        #endif
        // Mic session status → MicScreen store (D16). Fires on
        // session/engine threads; hops to main. Device-less statuses
        // (plain idle resets) cannot be attributed — every app stop
        // passes its device explicitly, so those never occur here.
        micSession.onStatus = { status in
            guard let device = status.deviceId else { return }
            Task { @MainActor in
                remoteScreens.applyMicStatus(device: device, status: status)
            }
        }
        // Webcam session status → CameraScreen webcam tab (same hop as the
        // mic; device-less resets never occur — every app stop passes its
        // device explicitly).
        webcamSession.onStatus = { status in
            guard let device = status.deviceId else { return }
            Task { @MainActor in
                remoteScreens.applyWebcamStatus(device: device, status: status)
            }
        }
        // Encoder/drain death mid-stream (Android encoder-error parity):
        // the desktop is still reading, so the end is announced — the
        // desktop stops its virtual camera instead of timing out on EOF.
        webcamProducer.onError = { message in
            Task { @MainActor in
                guard let device = webcamSession.current.deviceId else { return }
                webcamTeardown(device: device, message: message, phase: .error, announce: true)
            }
        }
        // Mirror session status → MirrorScreen store (same hop as mic/
        // webcam; device-less resets never occur — every app stop passes
        // its device explicitly).
        screenSession.onStatus = { status in
            guard let device = status.deviceId else { return }
            Task { @MainActor in
                remoteScreens.applyScreenStatus(device: device, status: status)
            }
        }
        // Recorder/encoder death mid-mirror: the desktop is still
        // watching, so the end is announced — the desktop closes its
        // window instead of timing out on EOF.
        screenProducer.onError = { message in
            Task { @MainActor in
                guard let device = screenSession.current.deviceId else { return }
                mirrorTeardown(device: device, message: message, phase: .error, announce: true)
            }
        }
#if canImport(UIKit)
        // Feed the battery cache on the main thread (once for the
        // observers; every start for the reading itself).
        Task { @MainActor in
            BatteryBridge.refresh(batteryCache)
            if !batteryObserving {
                batteryObserving = true
                let center = NotificationCenter.default
                center.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { [batteryCache] _ in
                    Task { @MainActor in BatteryBridge.refresh(batteryCache) }
                }
                center.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { [batteryCache] _ in
                    Task { @MainActor in BatteryBridge.refresh(batteryCache) }
                }
            }
        }
#endif
        link.onEvent = { [link] event in
            print("flux: \(event)")
            switch event {
            case .log:
                // Console-only (M4 hardware round, 2026-09-27): the
                // status line is user-facing state, not a debug channel —
                // everything already hits the Xcode console via the print
                // above, and real failures set `status` directly at their
                // own sites (`link start failed`, approve/media/transfer
                // states below).
                break
            case .pairRequested(let peerId, let deviceName, let key):
                let prompt = PairPrompt(peerId: peerId, deviceName: deviceName, key: key)
                Task { @MainActor in
                    pairPrompt = prompt
                    // Auto-dismiss at the incoming expiry: a resolve after
                    // dismiss is impossible, so no stale verdict can
                    // pre-answer a future prompt (Android dialog-race
                    // parity; see PairApproval).
                    DispatchQueue.main.asyncAfter(deadline: .now() + Pairing.incomingTimeout) {
                        if pairPrompt == prompt { pairPrompt = nil }
                    }
                }
            case .paired(let deviceName, _):
                Task { @MainActor in
                    pairPrompt = nil
                    remoteScreens.notePaired(deviceName)
                    // A link is up: queued captures (offline taps, library
                    // auto-upload) go now (D18 queue-waits-for-link).
                    flushCaptures()
                }
            case .closed(let deviceName):
                // In-flight capture outcomes are unknown once the link
                // dies: forget them (the queue still holds the files, so
                // the next flush retries — at-least-once delivery).
                Task { @MainActor in
                    inflightCaptures.removeAll()
                }
                // MainActor hop (this closure runs on session threads;
                // teardown touches MainActor app state like the rest).
                Task { @MainActor in
                    micTeardown(device: deviceName, message: "Disconnected.", phase: .idle)
                }
                Task { @MainActor in
                    webcamTeardown(device: deviceName, message: "Disconnected.", phase: .idle)
                }
                Task { @MainActor in
                    mirrorTeardown(device: deviceName, message: "Disconnected.", phase: .idle)
                }
                Task { @MainActor in
                    pairPrompt = nil
                    remoteScreens.noteClosed(deviceName)
                }
                Task { @MainActor in browseTeardown(device: deviceName) }
            case .approvePromptReceived(_, _, let id, _, _, _):
                // The full request lands in the flow a breath after the
                // event (decider thread); fetch it off-main, then present.
                Task.detached { [approveFlow] in
                    guard let request = approveFlow.pendingRequest(id: id) else { return }
                    let item = ApproveItem(id: id, request: request, peerName: request.computerName)
                    // Lock-screen path (D21): the time-sensitive prompt
                    // notification survives suspension, so a backgrounded
                    // app still shows the request on the lock screen.
                    ApproveNotifications.show(request)
                    await MainActor.run {
                        approvePhase = .ask(working: false)
                        approveItem = item
                        // Auto-dismiss at the request timeout (same
                        // stale-verdict reasoning as the pair sheet).
                        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(request.timeoutSeconds)) {
                            if approveItem == item {
                                approveItem = nil
                                ApproveNotifications.dismiss(id: id)
                                endApproveBackgroundHold()
                            }
                        }
                    }
                }
            case .approveAnswered(_, let id, let result):
                // Dismissing is thread-safe from the session thread; the
                // background hold + sheet state hop to main below.
                ApproveNotifications.dismiss(id: id)
                Task { @MainActor in
                    endApproveBackgroundHold()
                    guard let item = approveItem, item.id == id else { return }
                    switch result {
                    case "enrolled":
                        approvePhase = .enrolled(
                            code: approveFlow.enrolledCode(computerId: item.request.computerId) ?? "—")
                    case "approved":
                        status = "approved \(item.request.service) on \(item.peerName)"
                        approveItem = nil
                        approvePhase = .ask(working: false)
                    case "denied", "expired", "cancelled":
                        approveItem = nil
                        approvePhase = .ask(working: false)
                    case "failed":
                        // Stay open on the failure (D20): the message
                        // names the fix — usually re-enrollment after a
                        // biometric change. Close fails closed (deny).
                        approvePhase = .failed(
                            message: approveFlow.failureMessage(id: id)
                                ?? ApproveMessage.signProblem)
                    default: // answered
                        status = "approval \(result): \(item.request.service)"
                        approveItem = nil
                        approvePhase = .ask(working: false)
                    }
                }
            case .pingReceived(let device, let message):
                Task { @MainActor in status = "ping from \(device): \(message)" }
            case .notificationReceived(let device, let title, let text):
                Task { @MainActor in
                    status = "notification: \(title)"
                    showNotification(device: device, title: title, text: text)
                }
            case .notificationCancelled(let device, _):
                Task { @MainActor in dismissNotifications(device: device) }
            case .ringStarted(let device):
                Task { @MainActor in
                    status = "ringing"
                    ringingFrom = device
                    RingerBridge.alertOnce()
                }
            case .ringStopped:
                Task { @MainActor in ringingFrom = nil }
            case .clipboardReceived(let device, let content):
                Task { @MainActor in status = "clipboard from \(device)" }
                ClipboardBridge.write(content)
            case .shareTextReceived(let device, let text):
                Task { @MainActor in status = "shared text from \(device): \(text)" }
            case .shareURLReceived(let device, let url):
                Task { @MainActor in status = "shared link from \(device): \(url)" }
            case .shareFileQueued(let device, let filename, let size):
                Task { @MainActor in status = "receiving \(filename) (\(size) B) from \(device)" }
            case .transferProgress(let device, let filename, let done, let size):
                Task { @MainActor in status = "\(filename) \(done)/\(size) B from \(device)" }
            case .transferCompleted(let device, let filename, let path, let bytes):
                Task { @MainActor in
                    if inflightCaptures.remove(path) != nil {
                        // Our upload landed: drop it from the queue and
                        // delete the staged tmp file (path matches the
                        // staged file exactly — inbound Downloads paths
                        // never qualify).
                        captureOutbox.drop(paths: [path])
                        captureOutbox.persist()
                        CaptureAssetLoader.deleteStaged(path: path)
                        print("flux: capture \(filename) delivered (\(bytes) B), dropped from outbox")
                        status = "sent \(filename) (\(bytes) B) to \(device)"
                    } else {
                        status = "saved \(filename) (\(bytes) B) from \(device) — see Downloads"
                        downloads = DownloadsStore.list()
                    }
                }
            case .transferFailed(let device, let filename, let error):
                Task { @MainActor in
                    if let path = inflightCaptures.first(where: {
                        URL(fileURLWithPath: $0).lastPathComponent == filename
                    }) {
                        // Our upload died mid-flight: it stays queued (the
                        // staged file is untouched) and retries on the next
                        // flush — never silently lost.
                        inflightCaptures.remove(path)
                        print("flux: capture \(filename) failed, stays queued (\(error))")
                        status = "\(filename) failed — will retry when connected."
                    } else {
                        status = "transfer \(filename) failed: \(error)"
                    }
                }
            case .batteryReceived(let device, let level, let charging):
                Task { @MainActor in
                    if let level {
                        status = "battery \(device): \(level)%\(charging ? " charging" : "")"
                    } else {
                        status = "battery \(device): unknown"
                    }
                }
            case .mediaPlayersReceived(let device, let players):
                Task { @MainActor in
                    remoteScreens.applyPlayers(device: device, players: players)
                    status = "players on \(device): \(players.joined(separator: ", "))"
                }
            case .mediaStateReceived(let device, let state):
                Task { @MainActor in
                    remoteScreens.applyMediaState(device: device, state: state)
                    status = "\(state.player) on \(device): \(state.playing ? "▶" : "⏸") \(state.title) — \(state.artist)"
                }
            case .mediaActionReceived(let device, let player, let action):
                Task { @MainActor in status = "media \(action) on \(player) (\(device))" }
                _ = nowPlaying.handle(player: player, action: action)
            case .mediaSeekReceived(_, let player, let positionMs):
                _ = nowPlaying.handleSeek(player: player, positionMs: positionMs)
            case .mediaVolumeReceived(let device, let player, _):
                // No remote volume API for third parties (M4): logged only.
                Task { @MainActor in status = "volume for \(player) ignored (\(device))" }
            case .commandListReceived(let device, let commands, _):
                Task { @MainActor in
                    remoteScreens.applyCommands(device: device, commands: commands)
                    status = "\(commands.count) commands on \(device)"
                }
            case .sftpOfferReceived(let device, let offer):
                // The runner auto-opens the tunnel; stash the creds for
                // the take on `browseTunnelReady` (the one-time password
                // travels in-memory only, never to logs or status).
                Task { @MainActor in
                    if offer.tunnel != nil { browseOffers[device] = offer }
                }
            case .sftpErrorReceived(let device, let message):
                // Desktop refusal (notably share_home off — the message
                // itself is user-ready, shown verbatim like Android).
                Task { @MainActor in
                    remoteScreens.applyBrowse(
                        device: device,
                        state: BrowseViewState(loading: false, error: message))
                    status = "browse on \(device): \(message)"
                    print("flux: browse error on \(device): \(message)")
                }
            case .browseTunnelReady(let device, let tunnel):
                Task { @MainActor in startBrowseSession(device: device, tunnel: tunnel) }
            case .browseTunnelFailed(let device, let error):
                Task { @MainActor in
                    remoteScreens.applyBrowse(
                        device: device,
                        state: BrowseViewState(loading: false, error: error))
                    status = "browse on \(device): \(error)"
                    print("flux: browse tunnel on \(device): \(error)")
                }
            case .dndReceived(let device, let on):
                focus.noteRemote(on: on)
                DesktopDndBridge.show(computer: device, on: on)
                Task { @MainActor in status = "DND \(on ? "on" : "off") on \(device)" }
            case .webcamLiveReceived(let device, _, let label):
                Task { @MainActor in
                    if webcamCurrent(device: device) {
                        webcamSession.markLive(deviceId: device, message: "Live on \(device) as \(label)")
                        // "Also send the microphone": the mic streams while
                        // the webcam is live (Android `WebcamPanel` parity).
                        if micWithWebcam, !micSession.current.active {
                            startMic(device: device)
                            micByWebcam = true
                        }
                    }
                }
                Task { @MainActor in status = "webcam live on \(device) (\(label))" }
            case .webcamErrorReceived(let device, let message):
                Task { @MainActor in
                    // RST echo of our own user Stop (same 3 s window as the
                    // mic): the stop already landed, show the idle screen.
                    if let stopped = lastWebcamStop,
                       Date().timeIntervalSince(stopped) < 3.0
                    {
                        webcamTeardown(device: device, message: "Webcam off.", phase: .idle)
                    } else {
                        webcamTeardown(device: device, message: message, phase: .error)
                    }
                }
                Task { @MainActor in status = "webcam error on \(device): \(message)" }
            case .webcamStopReceived(let device):
                Task { @MainActor in
                    webcamTeardown(device: device, message: "Stopped on \(device).", phase: .idle)
                }
                Task { @MainActor in status = "webcam stopped on \(device)" }
            case .webcamConfigReceived(let device, let reset, let partial):
                Task { @MainActor in
                    applyDesktopWebcamConfig(device: device, reset: reset, partial: partial)
                }
                Task { @MainActor in status = "webcam config\(reset ? " reset" : "") on \(device)" }
            case .micLiveReceived(let device, let source):
                Task { @MainActor in
                    if micCurrent(device: device) {
                        micSession.markLive(deviceId: device, message: "Live on \(device) as \(source)")
                    }
                }
                Task { @MainActor in status = "mic live on \(device) (\(source))" }
            case .micErrorReceived(let device, let message):
                Task { @MainActor in
                    // RST echo of our own user Stop (see `lastMicStop`):
                    // the stop already landed, show the idle screen.
                    if let stopped = lastMicStop,
                       Date().timeIntervalSince(stopped) < 3.0
                    {
                        micTeardown(device: device, message: "Microphone off.", phase: .idle)
                    } else {
                        micTeardown(device: device, message: message, phase: .error)
                    }
                }
                Task { @MainActor in status = "mic error on \(device): \(message)" }
            case .micStopReceived(let device):
                Task { @MainActor in
                    micTeardown(device: device, message: "Stopped on \(device).", phase: .idle)
                }
                Task { @MainActor in status = "mic stopped on \(device)" }
            case .screenLiveReceived(let device, let player):
                Task { @MainActor in
                    if mirrorCurrent(device: device) {
                        screenSession.markLive(deviceId: device, message: "Mirrors to \(device) (\(player))")
                    }
                }
                Task { @MainActor in status = "screen live on \(device) (\(player))" }
            case .screenErrorReceived(let device, let message):
                Task { @MainActor in
                    // RST echo of our own user Stop (same 3 s window as
                    // mic/webcam): the stop already landed, show idle.
                    if let stopped = lastScreenStop,
                       Date().timeIntervalSince(stopped) < 3.0
                    {
                        mirrorTeardown(device: device, message: "Mirror off.", phase: .idle)
                    } else {
                        mirrorTeardown(device: device, message: message, phase: .error)
                    }
                }
                Task { @MainActor in status = "screen error on \(device): \(message)" }
            case .screenStopReceived(let device):
                Task { @MainActor in
                    mirrorTeardown(device: device, message: "Stopped on \(device).", phase: .idle)
                }
                Task { @MainActor in status = "screen stopped on \(device)" }
            case .streamStarted(let device, let kind, let port):
                if kind == StreamKind.mic.rawValue {
                    Task { @MainActor in
                        if micCurrent(device: device) {
                            micSession.connected(message: "Streaming to \(device)…")
                        }
                    }
                }
                if kind == StreamKind.webcam.rawValue {
                    Task { @MainActor in
                        if webcamCurrent(device: device) {
                            webcamSession.connected(message: "Streaming to \(device)…")
                        }
                    }
                }
                if kind == StreamKind.screen.rawValue {
                    Task { @MainActor in
                        if mirrorCurrent(device: device) {
                            screenSession.connected(message: "Streaming to \(device)…")
                        }
                    }
                }
                Task { @MainActor in status = "serving \(kind) to \(device) (port \(port))" }
            case .streamProgress(let device, let kind, let done, let size):
                Task { @MainActor in
                    // Live streams report `size: -1` (total unknown):
                    // show bytes-so-far instead of a fraction.
                    status = size < 0
                        ? "streaming \(kind) \(done) B to \(device)"
                        : "streaming \(kind) \(done)/\(size) B to \(device)"
                }
            case .streamDone(let device, let kind, let bytes, _):
                if kind == StreamKind.mic.rawValue {
                    Task { @MainActor in
                        micTeardown(device: device, message: "Finished on \(device).", phase: .idle)
                    }
                }
                if kind == StreamKind.webcam.rawValue {
                    Task { @MainActor in
                        webcamTeardown(device: device, message: "Finished on \(device).", phase: .idle)
                    }
                }
                if kind == StreamKind.screen.rawValue {
                    Task { @MainActor in
                        mirrorTeardown(device: device, message: "Finished on \(device).", phase: .idle)
                    }
                }
                Task { @MainActor in status = "streamed \(kind) (\(bytes) B) to \(device)" }
            case .streamFailed(let device, let kind, let error):
                if kind == StreamKind.mic.rawValue {
                    Task { @MainActor in
                        micTeardown(device: device, message: error, phase: .error)
                    }
                }
                if kind == StreamKind.webcam.rawValue {
                    Task { @MainActor in
                        webcamTeardown(device: device, message: error, phase: .error)
                    }
                }
                if kind == StreamKind.screen.rawValue {
                    Task { @MainActor in
                        mirrorTeardown(device: device, message: error, phase: .error)
                    }
                }
                Task { @MainActor in status = "stream \(kind) failed: \(error)" }
            default:
                break
            }
        }
        link.onState = { state in
            Task { @MainActor in
                switch state {
                case .stopped: presence = .offline
                case .listening: presence = .reconnecting
                case .connected: presence = .connected
                }
            }
        }
        do {
            try link.start()
        } catch {
            print("flux: link start failed: \(error)")
            status = "link start failed: \(error)"
            presence = .offline
        }
    }

    /// Begins background grace for an open approval prompt (D22). Call on
    /// the main thread (the scenePhase background handler is main). Ends
    /// on the answer, the local expiry, or the sheet close — every path
    /// calls `endApproveBackgroundHold`. Best-effort by platform design:
    /// past the grace (or the request timeout) the desktop falls back to
    /// the password, which is the honest failure mode.
    private func beginApproveBackgroundHold() {
#if canImport(UIKit)
        guard approveBackgroundTask == .invalid else { return }
        print("flux: approve background hold began")
        approveBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "flux-approve") {
            print("flux: approve background hold expired by the system")
            DispatchQueue.main.async { endApproveBackgroundHold() }
        }
#endif
    }

    /// Ends the approval background hold, if any. Main thread (all call
    /// sites are main: the answered handler hops, the timers are main,
    /// the expiry handler hops above).
    private func endApproveBackgroundHold() {
#if canImport(UIKit)
        let task = approveBackgroundTask
        approveBackgroundTask = .invalid
        if task != .invalid {
            print("flux: approve background hold ended")
            UIApplication.shared.endBackgroundTask(task)
        }
#endif
    }

    // MARK: - Microphone live session (D16)

    /// Starts the tap and offers the live stream. Every failure lands in
    /// the session status (permission → Settings hint, no input → device
    /// message, no link → offline) — never silent, never half-sent.
    private func startMic(device: String) {
        lastMicStop = nil
        micSession.start(deviceId: device, waiting: "Starting microphone…")
        micGeneration = micSession.generation
        Task {
            guard await MicAccess.request() else {
                micSession.stop(notify: false, status: StreamStatus(
                    phase: .error, message: "Microphone access is off. Allow it in Settings → Flux.",
                    deviceId: device))
                return
            }
            let chunks: AsyncStream<Data>
            do {
                micProducer.onLevel = { level in
                    Task { @MainActor in micLevel = max(0, level) }
                }
                chunks = try micProducer.start()
            } catch {
                micSession.stop(notify: false, status: StreamStatus(
                    phase: .error, message: "The microphone could not start (\(error)).",
                    deviceId: device))
                return
            }
            // A Stop tap while permission/the tap was spinning up wins:
            // the session no longer targets this device, so drop the
            // fresh stream instead of serving into a closed screen.
            guard micSession.current.deviceId == device else {
                micProducer.stop()
                return
            }
            let offer = LiveOffer(
                kind: .mic,
                buildStart: { MicPackets.start(port: $0) },
                chunks: chunks, announceStop: true)
            guard link.offerStream(offer) else {
                micProducer.stop()
                micSession.stop(notify: false, status: StreamStatus(
                    phase: .idle, message: "Offline — open Flux to stay connected.",
                    deviceId: device))
                return
            }
        }
    }

    /// User Stop: ends the tap, announces it (the desktop stops
    /// listening), and idles the session. `session.send` stays nil, so
    /// the stop packet goes out exactly once, via `link`.
    private func stopMic() {
        guard let device = micSession.current.deviceId else { return }
        lastMicStop = Date()
        micProducer.stop()
        link.stopStream(kind: .mic, announce: true)
        micSession.stop(notify: false, status: StreamStatus(
            phase: .idle, message: "Microphone off.", deviceId: device))
    }

    /// This device's current mic stream, for event attribution: stale
    /// events (older generation, other computer) never touch the session.
    private func micCurrent(device: String) -> Bool {
        micSession.current.deviceId == device
            && micSession.generation == micGeneration
    }

    /// Desktop-side or transport-side end (error/stop/failed/done/link
    /// closed): ends the tap and idles/errors the session without
    /// announcing — the desktop already knows or is gone.
    private func micTeardown(device: String, message: String, phase: StreamPhase) {
        guard micCurrent(device: device) else { return }
        micProducer.stop()
        link.stopStream(kind: .mic, announce: false)
        micSession.stop(notify: false, status: StreamStatus(
            phase: phase, message: message, deviceId: device))
    }

    private func setMicWithWebcam(_ on: Bool) {
        MicPreferences(withWebcam: on).save()
        Task { @MainActor in micWithWebcam = on }
    }

    // MARK: - Webcam live session (D16)

    /// Starts the camera drain and offers the live stream. Same shape as
    /// the mic: every failure lands in the session status (permission →
    /// Settings hint, no camera → device message, no link → offline) —
    /// never silent, never half-sent. The announced frame size + the
    /// follow-up `config` packet come from the persisted settings
    /// (Android `goLive` + send-config-after-`start` parity).
    private func startWebcam(device: String) {
        lastWebcamStop = nil
        webcamSession.start(deviceId: device, waiting: "Starting webcam…")
        webcamGeneration = webcamSession.generation
        let config = webcamConfig
        Task {
            guard await CameraAccess.request() else {
                webcamSession.stop(notify: false, status: StreamStatus(
                    phase: .error, message: "Camera access is off. Allow it in Settings → Flux.",
                    deviceId: device))
                return
            }
            let chunks: AsyncStream<Data>
            do {
                // Off-main: `startRunning` blocks briefly.
                chunks = try await Task.detached(priority: .userInitiated) {
                    try webcamProducer.start(config: config)
                }.value
            } catch {
                webcamSession.stop(notify: false, status: StreamStatus(
                    phase: .error, message: "The webcam could not start (\(error)).",
                    deviceId: device))
                return
            }
            // A Stop tap while permission/the drain was spinning up wins:
            // the session no longer targets this device, so drop the
            // fresh stream instead of serving into a closed screen.
            guard webcamSession.current.deviceId == device else {
                webcamProducer.stop()
                return
            }
            let caps = webcamProducer.currentCaps()
            let offer = LiveOffer(
                kind: .webcam,
                buildStart: { WebcamPackets.start(port: $0, width: config.width, height: config.height) },
                followUp: WebcamPackets.config(config: config.jsonObject(), caps: caps.jsonObject()),
                chunks: chunks, announceStop: true)
            guard link.offerStream(offer) else {
                webcamProducer.stop()
                webcamSession.stop(notify: false, status: StreamStatus(
                    phase: .idle, message: "Offline — open Flux to stay connected.",
                    deviceId: device))
                return
            }
        }
    }

    /// User Stop: ends the drain, announces it (the desktop stops its
    /// virtual camera), and idles the session. `session.send` stays nil, so
    /// the stop packet goes out exactly once, via `link`. A companion mic
    /// started for the webcam stops too; a user-started mic never does.
    private func stopWebcam() {
        guard let device = webcamSession.current.deviceId else { return }
        lastWebcamStop = Date()
        webcamProducer.stop()
        link.stopStream(kind: .webcam, announce: true)
        webcamSession.stop(notify: false, status: StreamStatus(
            phase: .idle, message: "Webcam off.", deviceId: device))
        stopCompanionMic()
    }

    /// This device's current webcam stream, for event attribution: stale
    /// events (older generation, other computer) never touch the session.
    private func webcamCurrent(device: String) -> Bool {
        webcamSession.current.deviceId == device
            && webcamSession.generation == webcamGeneration
    }

    /// Desktop-side or transport-side end (error/stop/done/failed/link
    /// closed): ends the drain and idles/errors the session. `announce`
    /// sends the kind's stop (phone-initiated ends like encoder death);
    /// pass false for desktop-initiated stops (the desktop already knows
    /// or is gone — replying stop would ping-pong).
    private func webcamTeardown(device: String, message: String, phase: StreamPhase, announce: Bool = false) {
        guard webcamCurrent(device: device) else { return }
        webcamProducer.stop()
        link.stopStream(kind: .webcam, announce: announce)
        webcamSession.stop(notify: false, status: StreamStatus(
            phase: phase, message: message, deviceId: device))
        stopCompanionMic()
    }

    /// Stops a mic the webcam started, if any (never a user-started mic).
    private func stopCompanionMic() {
        if micByWebcam {
            micByWebcam = false
            stopMic()
        }
    }

    /// Applies a desktop `config` (`flux webcam set` / `reset`): reset
    /// restores the neutral image values first, then the partial merges —
    /// clamped to the live camera caps and saved (Android
    /// `WebcamSettings.applyRemote` parity). A frame-size change restarts
    /// the stream with the new size (`stop` + fresh `start`, Android
    /// `restart` parity); anything else applies live to the running drain.
    private func applyDesktopWebcamConfig(device: String, reset: Bool, partial: [String: JSONValue]?) {
        let base = reset ? webcamConfig.reset() : webcamConfig
        let next = base.merged(partial).clamped(webcamProducer.currentCaps())
        let restarts = webcamConfig.restartsStream(next)
        if next != webcamConfig {
            webcamConfig = next
            WebcamPreferences(config: next).save()
        }
        guard webcamCurrent(device: device), webcamSession.current.active else { return }
        if restarts {
            webcamProducer.stop()
            link.stopStream(kind: .webcam, announce: true)
            startWebcam(device: device)
        } else {
            webcamProducer.applyLive(next)
        }
    }

    // MARK: - Screen mirror live session (app side)

    /// Starts the in-app screen capture and offers the live stream. Same
    /// shape as mic/webcam: every failure lands in the session status
    /// (unavailable recorder → device message, no link → offline) —
    /// never silent, never half-sent. The announced frame size fits this
    /// phone's screen (`MirrorScreenSize`); the desktop shows it in its
    /// window and sends no input back (same as Android). MainActor: the
    /// announced size reads `UIScreen.main` (`MirrorScreenSize.current`).
    @MainActor
    private func startMirror(device: String) {
        lastScreenStop = nil
        screenSession.start(deviceId: device, waiting: "Starting mirror…")
        screenGeneration = screenSession.generation
        let (width, height) = MirrorScreenSize.current()
        let bitrate = MirrorScreenSize.bitrate(width: width, height: height)
        Task {
            let chunks: AsyncStream<Data>
            do {
                // Off-main: `start` waits for the recorder to answer.
                chunks = try await Task.detached(priority: .userInitiated) {
                    try screenProducer.start(width: width, height: height, bitrate: bitrate)
                }.value
            } catch {
                screenSession.stop(notify: false, status: StreamStatus(
                    phase: .error, message: mirrorStartMessage(error),
                    deviceId: device))
                return
            }
            // A Stop tap while the recorder was spinning up wins: the
            // session no longer targets this device, so drop the fresh
            // stream instead of serving into a closed screen.
            guard screenSession.current.deviceId == device else {
                screenProducer.stop()
                return
            }
            let offer = LiveOffer(
                kind: .screen,
                buildStart: { ScreenPackets.start(port: $0, width: width, height: height) },
                chunks: chunks, announceStop: true)
            guard link.offerStream(offer) else {
                screenProducer.stop()
                screenSession.stop(notify: false, status: StreamStatus(
                    phase: .idle, message: "Offline — open Flux to stay connected.",
                    deviceId: device))
                return
            }
        }
    }

    /// User Stop: ends the capture, announces it (the desktop closes its
    /// window), and idles the session. `session.send` stays nil, so the
    /// stop packet goes out exactly once, via `link`.
    private func stopMirror() {
        guard let device = screenSession.current.deviceId else { return }
        lastScreenStop = Date()
        screenProducer.stop()
        link.stopStream(kind: .screen, announce: true)
        screenSession.stop(notify: false, status: StreamStatus(
            phase: .idle, message: "Mirror off.", deviceId: device))
    }

    /// This device's current mirror stream, for event attribution: stale
    /// events (older generation, other computer) never touch the session.
    private func mirrorCurrent(device: String) -> Bool {
        screenSession.current.deviceId == device
            && screenSession.generation == screenGeneration
    }

    /// Desktop-side or transport-side end (error/stop/done/failed/link
    /// closed): ends the capture and idles/errors the session. `announce`
    /// sends the kind's stop (phone-initiated ends like recorder death);
    /// pass false for desktop-initiated stops (the desktop already knows
    /// or is gone — replying stop would ping-pong).
    private func mirrorTeardown(device: String, message: String, phase: StreamPhase, announce: Bool = false) {
        guard mirrorCurrent(device: device) else { return }
        screenProducer.stop()
        link.stopStream(kind: .screen, announce: announce)
        screenSession.stop(notify: false, status: StreamStatus(
            phase: phase, message: message, deviceId: device))
    }

    /// Honest start-failure text for `MirrorScreen` (unavailable recorder
    /// vs. a refused start).
    private func mirrorStartMessage(_ error: Error) -> String {
        switch error as? ScreenCaptureError {
        case .unsupported, .unavailable:
            return "Screen mirror needs an iPhone with screen recording available."
        case .failed, nil:
            return "The mirror could not start (\(error))."
        }
    }

    // MARK: - Camera captures (D15/D18)

    /// Sends the outbox batch over the live link (the D23 fan-out for
    /// uploads: `LinkService.sendCaptures` over live runners, false with
    /// no link up). Peek-only: items stay queued until `transferCompleted`
    /// drops them, so a transfer dying mid-flight retries on the next
    /// flush instead of vanishing (the old take-then-send lost two
    /// screenshots into a churning link on-device 2026-09-28). In-flight
    /// paths are skipped (no double-send while an outcome is pending).
    /// MainActor: the outbox is UI state.
    private func flushCaptures() {
        let batch = captureOutbox.peek().filter { !inflightCaptures.contains($0.url.path) }
        guard !batch.isEmpty else { return }
        let uploads = batch.map {
            TransferEngine.CaptureUpload(
                url: $0.url, scan: $0.scan, photo: $0.photo,
                screenshot: $0.screenshot)
        }
        print("flux: flushing \(uploads.count) capture(s)")
        if link.sendCaptures(uploads) {
            inflightCaptures.formUnion(batch.map(\.url.path))
        } else {
            print("flux: no link — \(batch.count) capture(s) stay queued")
            Task { @MainActor in status = "Offline — captures send when connected." }
        }
    }

    /// Sends reviewed text as a scanned-text share (desktop `saveScan`
    /// lands it in `scan_dir`, like Android text mode).
    private func sendScannedText(device: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if link.send(ShareMessage.textPacket(trimmed, scan: true)) {
            print("flux: scanned text sent to \(device) (\(trimmed.count) chars)")
            Task { @MainActor in status = "Text sent to \(device)." }
        } else {
            print("flux: scanned text kept for \(device) (no link)")
            Task { @MainActor in status = "Offline — text kept, Send when connected." }
        }
    }

    /// Sends a QR-sheet action (open on the computer / copy on the
    /// computer / save-as-scan, `Codes.sheet` parity with Android).
    private func codeAction(device: String, action: CodeAction) {
        let packet: Packet
        switch action.body {
        case .openURL(let url):
            packet = ShareMessage.urlPacket(url)
        case .copy(let text):
            packet = ShareMessage.textPacket(text)
        case .save(let text):
            packet = ShareMessage.textPacket(text, scan: true)
        }
        if link.send(packet) {
            print("flux: code action '\(action.verb)' sent to \(device)")
            Task { @MainActor in status = "\(action.verb) — sent." }
        } else {
            print("flux: code action kept for \(device) (no link)")
            Task { @MainActor in status = "Offline — action kept, retry when connected." }
        }
    }

    /// One-shot text scan: permission → drain with preview → first usable
    /// text into the tab (Send ships it via `sendScannedText`).
    private func scanText(device: String) {
        captureScanning[device] = true
        Task {
            guard await CameraAccess.request() else {
                Task { @MainActor in
                    captureScanning[device] = false
                    capturePreview = nil
                    status = "Camera access is off. Allow it in Settings → Flux."
                }
                return
            }
            textSession.onStarted = {
                Task { @MainActor in capturePreview = textSession.previewSession }
            }
            do {
                let text = try await textSession.scan()
                print("flux: text scanned (\(text.count) chars)")
                Task { @MainActor in
                    captureTexts[device] = text
                    captureScanning[device] = false
                    capturePreview = nil
                    status = "Scanned — review and Send to \(device)."
                }
            } catch {
                print("flux: text scan ended: \(error)")
                Task { @MainActor in
                    captureScanning[device] = false
                    capturePreview = nil
                    status = scanStatus(error)
                }
            }
        }
    }

    /// One-shot code scan: permission → metadata drain with preview →
    /// first code into the tab's sheet (actions ship via `codeAction`).
    private func scanCode(device: String) {
        captureScanning[device] = true
        Task {
            guard await CameraAccess.request() else {
                Task { @MainActor in
                    captureScanning[device] = false
                    capturePreview = nil
                    status = "Camera access is off. Allow it in Settings → Flux."
                }
                return
            }
            codeSession.onStarted = {
                Task { @MainActor in capturePreview = codeSession.previewSession }
            }
            do {
                let code = try await codeSession.scan()
                let sheet = Codes.sheet(code, pc: device)
                print("flux: code scanned (\(code.format), \(sheet.kind))")
                Task { @MainActor in
                    captureCodes[device] = sheet
                    captureScanning[device] = false
                    capturePreview = nil
                    status = "Code scanned — pick an action for \(device)."
                }
            } catch {
                print("flux: code scan ended: \(error)")
                Task { @MainActor in
                    captureScanning[device] = false
                    capturePreview = nil
                    status = scanStatus(error)
                }
            }
        }
    }

    /// One-shot still photo: permission → capture → stage → outbox → send
    /// with the `photo` flag (desktop `photo_dir`). The moment matters, so
    /// the photo is taken even offline — the outbox waits for the link.
    private func takePhoto(device: String) {
        Task {
            guard await CameraAccess.request() else {
                Task { @MainActor in
                    status = "Camera access is off. Allow it in Settings → Flux."
                }
                return
            }
            do {
                let (data, name) = try await photoSession.capture()
                print("flux: photo captured \(name) (\(data.count) B)")
                Task { @MainActor in
                    do {
                        let url = try CaptureAssetLoader.stageTempFile(data: data, name: name)
                        captureOutbox.enqueue(CaptureOutbox.Item(url: url, photo: true))
                        captureOutbox.persist()
                        status = "Photo staged — sending to \(device)…"
                        flushCaptures()
                    } catch {
                        print("flux: photo stage failed: \(error)")
                        status = "Could not save the photo."
                    }
                }
            } catch {
                print("flux: photo capture ended: \(error)")
                Task { @MainActor in status = scanStatus(error) }
            }
        }
    }

    /// Document scan: the VisionKit sheet (iOS only) → staged PDF → outbox
    /// → send with the `scan` flag (desktop `scan_dir`).
    private func scanDocument(device: String) {
        #if os(iOS)
        Task { @MainActor in
            guard VNDocumentCameraViewController.isSupported else {
                status = "Document scan is not supported on this phone."
                return
            }
            guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
                let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
            else {
                status = "Could not open the scanner."
                return
            }
            docScanDevice = device
            status = "Scan the document…"
            root.present(docScanner.viewController(), animated: true)
        }
        #else
        Task { @MainActor in status = "Document scan needs an iPhone." }
        #endif
    }

    /// Library auto-upload switch (photo tab): full access enables (the
    /// baseline seeds at now, so the past never uploads —
    /// `PhotoLibraryWatch.setKind` parity); anything less keeps manual
    /// only, honestly.
    private func setCaptureAuto(kind: CaptureAutoKind, on: Bool) {
        Task {
            if on {
                let granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                Task { @MainActor in
                    guard granted == .authorized else {
                        print("flux: photo access \(granted) — manual picker only")
                        status = granted == .limited
                            ? "Limited access — pick manually, or set Full Access in Settings → Apps → Flux → Photos."
                            : "Photo access is off. Allow it in Settings → Flux."
                        return
                    }
                    CapturePrefs.set(kind, on: true)
                    if kind == .screenshot {
                        screenshotsOn = true
                        libraryWatch.setKind(.screenshot, on: true)
                    } else {
                        photosOn = true
                        libraryWatch.setKind(.photo, on: true)
                    }
                    status = "Auto-upload on — new \(kind == .screenshot ? "screenshots" : "photos") send automatically."
                }
            } else {
                Task { @MainActor in
                    CapturePrefs.set(kind, on: false)
                    if kind == .screenshot {
                        screenshotsOn = false
                        libraryWatch.setKind(.screenshot, on: false)
                    } else {
                        photosOn = false
                        libraryWatch.setKind(.photo, on: false)
                    }
                    status = "Auto-upload off."
                }
            }
        }
    }

    /// Honest one-shot outcome text (permission/timeout/cancel shapes).
    private func scanStatus(_ error: Error) -> String {
        switch error as? CaptureSessionError {
        case .timedOut:
            return "Nothing found — try again."
        case .cancelled:
            return "Scan cancelled."
        case .noCamera:
            return "No camera on this phone."
        case .setupFailed, .captureFailed, nil:
            return "The capture failed — try again."
        }
    }

    // MARK: - Reverse-direction sends (#1 commands, #2 media)

    /// Phone→desktop sends over the D23 app-originated path
    /// (`LinkService.send` fans out over live runners; false with no link
    /// up — the status line says so, presence is never faked).

    private func requestCommands(device: String) {
        if link.send(RunCommandMessage.requestList()) {
            Task { @MainActor in status = "loading commands on \(device)…" }
        } else {
            Task { @MainActor in status = "offline — open Flux to stay connected" }
        }
    }

    private func runCommand(device: String, command: RemoteCommand) {
        guard let packet = RunCommandMessage.run(key: command.key) else { return }
        if link.send(packet) {
            Task { @MainActor in status = "running \(command.name) on \(device)" }
        } else {
            Task { @MainActor in status = "offline — could not run \(command.name)" }
        }
    }

    private func requestPlayers(device: String) {
        if link.send(MprisMessage.requestPlayerList()) {
            Task { @MainActor in status = "loading players on \(device)…" }
        } else {
            Task { @MainActor in status = "offline — open Flux to stay connected" }
        }
    }

    private func selectPlayer(device: String, player: String) {
        if link.send(MprisMessage.requestNowPlaying(player: player)) {
            Task { @MainActor in status = "loading \(player) on \(device)…" }
        } else {
            Task { @MainActor in status = "offline — open Flux to stay connected" }
        }
    }

    private func mediaAction(device: String, player: String, action: String) {
        // `MediaScreen` sends `MediaAction` raw values ("Play"/"Pause"/
        // "Next"/…); anything else builds nothing and is dropped.
        guard let packet = MprisMessage.action(player: player, action: action) else { return }
        if link.send(packet) {
            Task { @MainActor in status = "media \(action) on \(player) (\(device))" }
        } else {
            Task { @MainActor in status = "offline — could not send media \(action)" }
        }
    }

    private func mediaSeek(device: String, player: String, positionMs: Int64) {
        if !link.send(MprisMessage.seek(player: player, positionMs: positionMs)) {
            Task { @MainActor in status = "offline — could not seek \(player) (\(device))" }
        }
    }

    // MARK: - Browse files (D1)

    /// Asks the desktop for an SFTP session (Android `Browse.start`
    /// parity): the offer auto-opens the tunnel, `browseTunnelReady`
    /// takes it and lists the first root.
    private func browseOpen(device: String) {
        guard link.send(SftpPackets.requestPacket()) else {
            Task { @MainActor in status = "offline — open Flux to stay connected" }
            return
        }
        Task { @MainActor in
            remoteScreens.applyBrowse(device: device, state: BrowseViewState())
            status = "loading files on \(device)…"
            print("flux: browse requesting \(device)")
        }
        // No-answer timeout (Android parity: 10 s): the desktop never
        // heard the request or never answered — say so, don't spin.
        Task {
            try? await Task.sleep(for: .seconds(10))
            await MainActor.run {
                let current = remoteScreens.browseState(for: device)
                if current.loading, current.entries.isEmpty, current.error == nil {
                    remoteScreens.applyBrowse(
                        device: device,
                        state: BrowseViewState(
                            loading: false,
                            error: "\(device) did not answer. Browse needs fluxd."))
                    status = "browse on \(device): no answer"
                }
            }
        }
    }

    /// Takes an established browse tunnel and opens the SSH session over
    /// it (Android `onCredentials` + first `list` parity). Runs on the
    /// MainActor hop (the event already hopped); session I/O rides a
    /// child task, store/status hop back after.
    private func startBrowseSession(device: String, tunnel: String) {
        guard let offer = browseOffers.removeValue(forKey: device), offer.tunnel == tunnel else { return }
        guard let conn = link.takeBrowseTunnel(tunnel) else {
            remoteScreens.applyBrowse(
                device: device,
                state: BrowseViewState(loading: false, error: "\(device) never opened the tunnel. Try again."))
            status = "browse on \(device): no tunnel"
            return
        }
        if let old = browseSessions[device] {
            Task { await old.close() }
        }
        let session = BrowseSession(onLog: { print("flux: browse \($0)") })
        browseSessions[device] = session
        Task {
            do {
                try await session.connect(tunnel: conn, user: offer.user, password: offer.password)
                let roots = offer.roots.map { BrowseRoot(name: $0.0, path: $0.1) }
                let first = offer.roots.first?.1 ?? offer.path
                let entries = try await session.list(path: first)
                await MainActor.run {
                    remoteScreens.applyBrowse(
                        device: device,
                        state: BrowseViewState(loading: false, roots: roots, path: first, entries: entries))
                    status = "browsing \(device): \(first) (\(entries.count) entries)"
                    print("flux: browse \(device) \(first): \(entries.count) entries")
                }
            } catch {
                await MainActor.run {
                    remoteScreens.applyBrowse(
                        device: device,
                        state: BrowseViewState(
                            loading: false,
                            error: "Cannot open files on \(device): \(error)"))
                    status = "browse on \(device): \(error)"
                    print("flux: browse \(device) failed: \(error)")
                }
            }
        }
    }

    /// Lists a folder (roots chips, dir taps, up-row).
    private func browseList(device: String, path: String) {
        guard let session = browseSessions[device] else {
            // Dead session (a failed download ends it): reopen Browse
            // files for a fresh one — never a silent tap.
            Task { @MainActor in status = "browse session ended — reopen Browse files" }
            return
        }
        Task { @MainActor in
            var current = remoteScreens.browseState(for: device)
            current.loading = true
            current.error = nil
            remoteScreens.applyBrowse(device: device, state: current)
        }
        Task {
            do {
                let entries = try await session.list(path: path)
                await MainActor.run {
                    var current = remoteScreens.browseState(for: device)
                    current.loading = false
                    current.path = path
                    current.entries = entries
                    remoteScreens.applyBrowse(device: device, state: current)
                    status = "browsing \(device): \(path) (\(entries.count) entries)"
                }
            } catch {
                await MainActor.run {
                    var current = remoteScreens.browseState(for: device)
                    current.loading = false
                    current.error = "Cannot open \(path): \(error)"
                    remoteScreens.applyBrowse(device: device, state: current)
                    status = "browse on \(device): \(error)"
                    // A dead channel ends the session: drop it so the next
                    // tap says reopen instead of refailing on the corpse.
                    if (error as? BrowseError)?.isSessionDead == true {
                        browseSessions.removeValue(forKey: device)
                        status = "browse session ended — reopen Browse files"
                        print("flux: browse session for \(device) dropped (\(error))")
                    }
                }
            }
        }
    }

    /// Downloads one file into Downloads (Android `Browse.download`
    /// parity: non-clobbering name, completion status line). A closed
    /// channel ends the session: the next open asks for a new one, so a
    /// retry is always one screen-reopen away.
    private func browseDownload(device: String, entry: BrowseEntry) {
        guard let session = browseSessions[device] else {
            Task { @MainActor in status = "browse session ended — reopen Browse files" }
            return
        }
        Task { @MainActor in status = "downloading \(entry.name) from \(device)…" }
        Task {
            do {
                let dir = TransferEngine.defaultDownloadsDirectory()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = TransferEngine.uniqueDestination(
                    directory: dir, filename: ShareMessage.sanitize(entry.name))
                let bytes = try await session.download(remotePath: entry.path, to: dest)
                await MainActor.run {
                    status = "saved \(entry.name) (\(bytes) B) from \(device) — see Downloads"
                    downloads = DownloadsStore.list()
                    print("flux: browse downloaded \(entry.name) (\(bytes) B) from \(device)")
                }
            } catch {
                await MainActor.run {
                    status = "could not save \(entry.name): \(error)"
                    print("flux: browse download \(entry.name) failed: \(error)")
                    // A dead channel ends the session: drop it so the next
                    // tap says reopen instead of refailing on the corpse.
                    if (error as? BrowseError)?.isSessionDead == true {
                        browseSessions.removeValue(forKey: device)
                        status = "browse session ended — reopen Browse files"
                        print("flux: browse session for \(device) dropped (\(error))")
                    }
                }
            }
        }
    }

    /// Ends the SSH session and drops browse state (screen closed or link
    /// lost — Android `Browse.close` parity: a tunnel carries one session,
    /// so the next open asks the desktop for a new one).
    private func browseClose(device: String) {
        if let session = browseSessions.removeValue(forKey: device) {
            Task { await session.close() }
        }
        browseOffers.removeValue(forKey: device)
        remoteScreens.dropBrowse(device: device)
    }

    /// Link-closed teardown: same as screen close, silent (the disconnect
    /// status belongs to the link/streams, not the file list).
    private func browseTeardown(device: String) {
        browseClose(device: device)
    }

    private func answerPair(prompt: PairPrompt, accept: Bool) {
        // Resolve synchronously in the tap handler, before dismiss: the
        // verdict reaches the waiting session (or a just-timed-out one,
        // whose window is the tap-vs-expiry race, same as Android).
        link.pairApproval.resolve(peerId: prompt.peerId, accept: accept)
        if pairPrompt == prompt { pairPrompt = nil }
    }

    /// Renders a desktop notification through the M2 bridge (display-only;
    /// the desktop accepts no replies). Tracks the identifier per device
    /// so a desktop cancel clears what we showed.
    private func showNotification(device: String, title: String, text: String) {
        let id = "\(device):\(title)"
        shownNotifications[device, default: []].append(id)
        DesktopNotificationBridge.show(ComputerNotification(
            key: id, subText: device, title: title, text: text,
            timeMs: Int64(Date().timeIntervalSince1970 * 1000),
            clearable: true, cancel: false))
    }

    private func dismissNotifications(device: String) {
        for id in shownNotifications[device] ?? [] {
            DesktopNotificationBridge.dismiss(key: id)
        }
        shownNotifications[device] = nil
    }
}

/// One incoming pair prompt (sheet item). Equality is by peer + key so a
/// re-request replaces the sheet instead of stacking it.
private struct PairPrompt: Identifiable, Equatable {
    let peerId: String
    let deviceName: String
    let key: String
    var id: String { peerId + key }
}

/// One held approval prompt (sheet item). The full request rides along
/// (the prompt event only carries display fields).
private struct ApproveItem: Identifiable, Equatable {
    let id: String
    let request: ApproveRequest
    let peerName: String
}
