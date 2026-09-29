import SwiftUI
import FluxCore
import FluxProto
import FluxCamera
import FluxStream
import AVFoundation

/// M1 host + reverse-direction remote screens (#1 commands, #2 media).
/// The Devices list shows connected computers (from `.paired`, minus
/// `.closed`); each computer opens its Media + Run-commands screens, fed
/// from `RemoteScreensState` (state + closure views, no backend). Opening
/// a screen requests the fresh list/state over the link; tapping a
/// command or media control sends it over the D23 app-originated path.
/// `status` surfaces the last link log line on-device (device debugging
/// without Xcode attached shows where `start()` dies).
public struct ContentView: View {
    public var presence: LinkPresence
    public var status: String?
    public var remote: RemoteScreensState
    public var onRequestCommands: (String) -> Void
    public var onRunCommand: (String, RemoteCommand) -> Void
    public var onBrowseOpen: (String) -> Void
    public var onBrowseList: (String, String) -> Void
    public var onBrowseDownload: (String, BrowseEntry) -> Void
    public var onBrowseClose: (String) -> Void
    public var onRequestPlayers: (String) -> Void
    public var onSelectPlayer: (String, String) -> Void
    public var onMediaAction: (String, String, String) -> Void
    public var onMediaSeek: (String, String, Int64) -> Void
    public var micLevel: Float
    public var micWithWebcam: Bool
    public var onMicStart: (String) -> Void
    public var onMicStop: () -> Void
    public var onMicWithWebcam: (Bool) -> Void
    public var webcamConfig: WebcamConfig
    public var onWebcamStart: (String) -> Void
    public var onWebcamStop: () -> Void
    public var onMirrorStart: (String) -> Void
    public var onMirrorStop: () -> Void
    public var onSendText: (String, String) -> Void
    public var onCodeAction: (String, CodeAction) -> Void
    public var onTakePhoto: (String) -> Void
    public var onScanDocument: (String) -> Void
    /// One-shot scan results per device (D15): the app fills these as the
    /// text/QR drains report; the tabs render + send from them.
    public var captureTexts: [String: String]
    public var captureCodes: [String: CodeSheet]
    /// Devices with a live capture drain (preview + spinner).
    public var captureScanning: [String: Bool]
    public var onScanText: (String) -> Void
    public var onScanCode: (String) -> Void
    /// Library auto-upload switches (global, not per device).
    public var screenshotsOn: Bool
    public var photosOn: Bool
    public var onCaptureToggle: (CaptureAutoKind, Bool) -> Void
    /// The running drain's session for the preview (one scan at a time).
    public var capturePreview: AVCaptureSession?
    /// Received files on this iPhone (device-global, not per computer).
    public var downloads: [DownloadedFile]
    public var onRefreshDownloads: () -> Void
    public var onDeleteDownload: (DownloadedFile) -> Void
    @State private var cameraModes: [String: CameraMode] = [:]

    public init(
        presence: LinkPresence = .offline,
        status: String? = nil,
        remote: RemoteScreensState = RemoteScreensState(),
        onRequestCommands: @escaping (String) -> Void = { _ in },
        onRunCommand: @escaping (String, RemoteCommand) -> Void = { _, _ in },
        onBrowseOpen: @escaping (String) -> Void = { _ in },
        onBrowseList: @escaping (String, String) -> Void = { _, _ in },
        onBrowseDownload: @escaping (String, BrowseEntry) -> Void = { _, _ in },
        onBrowseClose: @escaping (String) -> Void = { _ in },
        onRequestPlayers: @escaping (String) -> Void = { _ in },
        onSelectPlayer: @escaping (String, String) -> Void = { _, _ in },
        onMediaAction: @escaping (String, String, String) -> Void = { _, _, _ in },
        onMediaSeek: @escaping (String, String, Int64) -> Void = { _, _, _ in },
        micLevel: Float = 0,
        micWithWebcam: Bool = false,
        onMicStart: @escaping (String) -> Void = { _ in },
        onMicStop: @escaping () -> Void = {},
        onMicWithWebcam: @escaping (Bool) -> Void = { _ in },
        webcamConfig: WebcamConfig = WebcamConfig(),
        onWebcamStart: @escaping (String) -> Void = { _ in },
        onWebcamStop: @escaping () -> Void = {},
        onMirrorStart: @escaping (String) -> Void = { _ in },
        onMirrorStop: @escaping () -> Void = {},
        onSendText: @escaping (String, String) -> Void = { _, _ in },
        onCodeAction: @escaping (String, CodeAction) -> Void = { _, _ in },
        onTakePhoto: @escaping (String) -> Void = { _ in },
        onScanDocument: @escaping (String) -> Void = { _ in },
        captureTexts: [String: String] = [:],
        captureCodes: [String: CodeSheet] = [:],
        captureScanning: [String: Bool] = [:],
        onScanText: @escaping (String) -> Void = { _ in },
        onScanCode: @escaping (String) -> Void = { _ in },
        screenshotsOn: Bool = false,
        photosOn: Bool = false,
        onCaptureToggle: @escaping (CaptureAutoKind, Bool) -> Void = { _, _ in },
        capturePreview: AVCaptureSession? = nil,
        downloads: [DownloadedFile] = [],
        onRefreshDownloads: @escaping () -> Void = {},
        onDeleteDownload: @escaping (DownloadedFile) -> Void = { _ in }
    ) {
        self.presence = presence
        self.status = status
        self.remote = remote
        self.onRequestCommands = onRequestCommands
        self.onRunCommand = onRunCommand
        self.onBrowseOpen = onBrowseOpen
        self.onBrowseList = onBrowseList
        self.onBrowseDownload = onBrowseDownload
        self.onBrowseClose = onBrowseClose
        self.onRequestPlayers = onRequestPlayers
        self.onSelectPlayer = onSelectPlayer
        self.onMediaAction = onMediaAction
        self.onMediaSeek = onMediaSeek
        self.micLevel = micLevel
        self.micWithWebcam = micWithWebcam
        self.onMicStart = onMicStart
        self.onMicStop = onMicStop
        self.onMicWithWebcam = onMicWithWebcam
        self.webcamConfig = webcamConfig
        self.onWebcamStart = onWebcamStart
        self.onWebcamStop = onWebcamStop
        self.onMirrorStart = onMirrorStart
        self.onMirrorStop = onMirrorStop
        self.onSendText = onSendText
        self.onCodeAction = onCodeAction
        self.onTakePhoto = onTakePhoto
        self.onScanDocument = onScanDocument
        self.captureTexts = captureTexts
        self.captureCodes = captureCodes
        self.captureScanning = captureScanning
        self.onScanText = onScanText
        self.onScanCode = onScanCode
        self.screenshotsOn = screenshotsOn
        self.photosOn = photosOn
        self.onCaptureToggle = onCaptureToggle
        self.capturePreview = capturePreview
        self.downloads = downloads
        self.onRefreshDownloads = onRefreshDownloads
        self.onDeleteDownload = onDeleteDownload
    }

    public var body: some View {
        NavigationStack {
            List {
                // Device-global rows live beside the per-computer
                // sections in the same list, so every destination
                // renders as the same plain row + chevron.
                Section("This iPhone") {
                    NavigationLink("Downloads") {
                        DownloadsScreen(
                            files: downloads,
                            onRefresh: onRefreshDownloads,
                            onDelete: onDeleteDownload
                        )
                    }
                }
                ForEach(remote.computers, id: \.self) { device in
                    Section(device) {
                        NavigationLink("Media") {
                            mediaScreen(for: device)
                        }
                        NavigationLink("Run commands") {
                            CommandsScreen(
                                computer: device,
                                online: presence == .connected,
                                loaded: remote.isCommandsLoaded(device: device),
                                commands: remote.commands(for: device),
                                onRun: { onRunCommand(device, $0) },
                                onRefresh: { onRequestCommands(device) }
                            )
                        }
                        NavigationLink("Browse files") {
                            BrowseScreen(
                                computer: device,
                                online: presence == .connected,
                                state: remote.browseState(for: device),
                                onOpen: { onBrowseOpen(device) },
                                onClose: { onBrowseClose(device) },
                                onBrowse: { onBrowseList(device, $0) },
                                onDownload: { onBrowseDownload(device, $0) }
                            )
                        }
                        NavigationLink("Microphone") {
                            MicScreen(
                                computer: device,
                                online: presence == .connected,
                                status: remote.micStatus(for: device),
                                level: micLevel,
                                withWebcam: micWithWebcam,
                                onStart: { onMicStart(device) },
                                onStop: onMicStop,
                                onWithWebcam: onMicWithWebcam
                            )
                        }
                        NavigationLink("Mirror screen") {
                            MirrorScreen(
                                computer: device,
                                online: presence == .connected,
                                status: remote.screenStatus(for: device),
                                onStart: { onMirrorStart(device) },
                                onStop: onMirrorStop
                            )
                        }
                        NavigationLink("Camera") {
                            CameraScreen(
                                computer: device,
                                online: presence == .connected,
                                mode: cameraModes[device] ?? .webcam,
                                recognizedText: captureTexts[device] ?? "",
                                code: captureCodes[device],
                                webcam: remote.webcamStatus(for: device),
                                webcamConfig: webcamConfig,
                                onMode: { cameraModes[device] = $0 },
                                onSendText: { onSendText(device, $0) },
                                onCodeAction: { onCodeAction(device, $0) },
                                onTakePhoto: { onTakePhoto(device) },
                                onScanDocument: { onScanDocument(device) },
                                onWebcamStart: { onWebcamStart(device) },
                                onWebcamStop: onWebcamStop,
                                scanning: captureScanning[device] ?? false,
                                onScanText: { onScanText(device) },
                                onScanCode: { onScanCode(device) },
                                screenshotsOn: screenshotsOn,
                                photosOn: photosOn,
                                onCaptureToggle: onCaptureToggle,
                                previewSession: capturePreview
                            )
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Devices")
            // The banner + debug status stay pinned above the list without
            // wrapping it in a VStack: a List nested in a VStack breaks the
            // navigation bar's scroll tracking (large title never collapses,
            // leaving the tall empty gap above it) and the bottom safe-area
            // inset (last row clips under the home indicator).
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 8) {
                    if presence.showsBanner {
                        ConnectionBanner(presence: presence)
                    }
                    if let status {
                        Text(status)
                            .font(.footnote)
                            .monospaced()
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if remote.computers.isEmpty {
                        Text("Flux for iOS (M1 pairing)")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, (presence.showsBanner || status != nil || remote.computers.isEmpty) ? 8 : 0)
            }
        }
    }

    /// Media destination (#2): the latest pushed state (nil = "Nothing is
    /// playing"), refreshed on open; player selects + controls fan out
    /// with the device attached.
    private func mediaScreen(for device: String) -> some View {
        let players = remote.players(for: device)
        let state = remote.mediaState(for: device)
        return MediaScreen(
            computer: device,
            online: presence == .connected,
            players: players,
            current: state?.player,
            state: state,
            onSelectPlayer: { onSelectPlayer(device, $0) },
            onAction: { action in
                if let player = state?.player ?? players.first {
                    onMediaAction(device, player, action)
                }
            },
            onSeek: { positionMs in
                if let player = state?.player ?? players.first {
                    onMediaSeek(device, player, positionMs)
                }
            }
        )
        .onAppear { onRequestPlayers(device) }
    }
}

public extension View {
    /// Demo fixture flag: `-FLUX_DEMO 1` renders sample computers with no
    /// backend, for App Review + screenshots. Release builds ignore extras.
    static var fluxDemo: Bool {
        CommandLine.arguments.contains("-FLUX_DEMO") || ProcessInfo.processInfo.arguments.contains("FLUX_DEMO=1")
    }
}
