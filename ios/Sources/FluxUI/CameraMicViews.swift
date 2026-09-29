import SwiftUI
import FluxProto
import FluxCamera
import FluxStream
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

/// M5 local screens: microphone, camera (text/QR/photo/document/webcam),
/// and screen mirror. Ports Android `mic/MicScreen.kt`,
/// `camera/CameraScreen.kt`, and the mirror entry: the phone streams to the
/// desktop (`StreamSession` + `StreamEngine`) — never the reverse. Screens
/// take state + action closures (no backend); the app feeds them from
/// session statuses, and the actions drive `StreamSession` + capture
/// pipelines.
///
/// Demo fixtures mirror the `FLUX_DEMO=1` pages; release builds ignore the
/// extras.

// MARK: - Microphone

/// Microphone screen: level meter, Start/Stop, and the "also send with
/// webcam" flag (`MicPreferences.withWebcam`).
public struct MicScreen: View {
    public var computer: String
    public var online: Bool
    public var status: StreamStatus
    public var level: Float
    public var withWebcam: Bool
    public var onStart: () -> Void
    public var onStop: () -> Void
    public var onWithWebcam: @Sendable (Bool) -> Void

    public init(
        computer: String, online: Bool = true,
        status: StreamStatus = StreamStatus(),
        level: Float = 0, withWebcam: Bool = false,
        onStart: @escaping () -> Void = {}, onStop: @escaping () -> Void = {},
        onWithWebcam: @Sendable @escaping (Bool) -> Void = { _ in }
    ) {
        self.computer = computer
        self.online = online
        self.status = status
        self.level = level
        self.withWebcam = withWebcam
        self.onStart = onStart
        self.onStop = onStop
        self.onWithWebcam = onWithWebcam
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("On \(computer)").foregroundStyle(.secondary)
                // A live tap outlives presence (restart/background
                // windows, wifi drops): Stop is local-first and never
                // gated on the link — an active session with no Stop is
                // a trap (seen on the Mirror screen 2026-09-28).
                if status.active {
                    ProgressView(value: max(0, level))
                        .accessibilityLabel("Input level")
                    Text(status.message).foregroundStyle(.secondary)
                    Button("Stop", action: onStop).buttonStyle(.borderedProminent)
                } else if !online {
                    Text("The microphone needs a connection.").foregroundStyle(.secondary)
                } else if status.phase == .error {
                    Text(status.message).foregroundStyle(.red)
                    Button("Try again", action: onStart).buttonStyle(.borderedProminent)
                } else {
                    Text(status.message.isEmpty ? "Desktop apps hear this phone as Flux Microphone." : status.message)
                        .foregroundStyle(.secondary)
                    Button("Start", action: onStart).buttonStyle(.borderedProminent)
                }
                Toggle("Also send the microphone with the webcam", isOn: Binding(
                    get: { withWebcam }, set: onWithWebcam))
                .tint(.accentColor)
            }.padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Microphone")
    }
}

// MARK: - Camera

/// Live preview for a running capture session (D15). Binds the session
/// the drain already runs — never a second drain. iOS + macOS shapes;
/// nothing renders with no session.
#if os(iOS)
/// View hosting the preview layer. The layer tracks the view bounds in
/// `layoutSubviews`: sizing it once in `makeUIView` leaves it zero-sized
/// (bounds are still zero pre-layout and no later update resizes it),
/// which rendered the scan tabs blank on hardware (2026-09-28 — spinner
/// and hint only, no camera image).
/// Host view for `CameraPreview` (public only because the representable
/// vends it; treat as an implementation detail).
public final class PreviewHostView: UIView {
    public let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override public func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}

public struct CameraPreview: UIViewRepresentable {
    public var session: AVCaptureSession?

    public init(session: AVCaptureSession?) {
        self.session = session
    }

    public func makeUIView(context: Context) -> PreviewHostView {
        PreviewHostView()
    }

    public func updateUIView(_ view: PreviewHostView, context: Context) {
        view.previewLayer.session = session
    }
}
#elseif os(macOS)
/// Same layout-driven sizing as the iOS host (a layer assigned as
/// `view.layer` never resizes with the view on its own).
/// Host view for `CameraPreview` (public only because the representable
/// vends it; treat as an implementation detail).
public final class PreviewHostView: NSView {
    public let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
        wantsLayer = true
        layer?.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override public func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

public struct CameraPreview: NSViewRepresentable {
    public var session: AVCaptureSession?

    public init(session: AVCaptureSession?) {
        self.session = session
    }

    public func makeNSView(context: Context) -> PreviewHostView {
        PreviewHostView()
    }

    public func updateNSView(_ view: PreviewHostView, context: Context) {
        view.previewLayer.session = session
    }
}
#endif

/// Camera screen: the five modes (`CameraMode`) + per-mode content. Capture
/// actions hand data to the app, which shares it (`scan` text, `photo` /
/// `scan` file flags); the webcam subpage drives `StreamSession`.
public struct CameraScreen: View {
    public var computer: String
    public var online: Bool
    public var mode: CameraMode
    public var recognizedText: String
    public var code: CodeSheet?
    public var webcam: StreamStatus
    public var webcamConfig: WebcamConfig
    public var onMode: (CameraMode) -> Void
    public var onSendText: (String) -> Void
    public var onCodeAction: (CodeAction) -> Void
    public var onTakePhoto: () -> Void
    public var onScanDocument: () -> Void
    public var onWebcamStart: () -> Void
    public var onWebcamStop: () -> Void
    /// One-shot scan state (D15): true while the app runs the drain for
    /// the current tab; the preview binds while true.
    public var scanning: Bool
    public var onScanText: () -> Void
    public var onScanCode: () -> Void
    /// Auto-upload switches for the photo tab (library watch).
    public var screenshotsOn: Bool
    public var photosOn: Bool
    public var onCaptureToggle: (CaptureAutoKind, Bool) -> Void
    public var previewSession: AVCaptureSession?

    public init(
        computer: String, online: Bool = true, mode: CameraMode = .webcam,
        recognizedText: String = "", code: CodeSheet? = nil,
        webcam: StreamStatus = StreamStatus(), webcamConfig: WebcamConfig = WebcamConfig(),
        onMode: @escaping (CameraMode) -> Void = { _ in },
        onSendText: @escaping (String) -> Void = { _ in },
        onCodeAction: @escaping (CodeAction) -> Void = { _ in },
        onTakePhoto: @escaping () -> Void = {}, onScanDocument: @escaping () -> Void = {},
        onWebcamStart: @escaping () -> Void = {}, onWebcamStop: @escaping () -> Void = {},
        scanning: Bool = false,
        onScanText: @escaping () -> Void = {}, onScanCode: @escaping () -> Void = {},
        screenshotsOn: Bool = false, photosOn: Bool = false,
        onCaptureToggle: @escaping (CaptureAutoKind, Bool) -> Void = { _, _ in },
        previewSession: AVCaptureSession? = nil
    ) {
        self.computer = computer
        self.online = online
        self.mode = mode
        self.recognizedText = recognizedText
        self.code = code
        self.webcam = webcam
        self.webcamConfig = webcamConfig
        self.onMode = onMode
        self.onSendText = onSendText
        self.onCodeAction = onCodeAction
        self.onTakePhoto = onTakePhoto
        self.onScanDocument = onScanDocument
        self.onWebcamStart = onWebcamStart
        self.onWebcamStop = onWebcamStop
        self.scanning = scanning
        self.onScanText = onScanText
        self.onScanCode = onScanCode
        self.screenshotsOn = screenshotsOn
        self.photosOn = photosOn
        self.onCaptureToggle = onCaptureToggle
        self.previewSession = previewSession
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("On \(computer)").foregroundStyle(.secondary)
                Picker("Mode", selection: Binding(get: { mode }, set: onMode)) {
                    ForEach(CameraMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }.pickerStyle(.segmented)
                switch mode {
                case .text:
                    textTab
                case .qr:
                    qrTab
                case .photo:
                    photoTab
                case .document:
                    Text("Scans land in scan_dir on \(computer).").foregroundStyle(.secondary)
                    Button("Scan document", action: onScanDocument).buttonStyle(.borderedProminent)
                case .webcam:
                    if webcam.active {
                        Text(webcam.message).foregroundStyle(.secondary)
                        Button("Stop", action: onWebcamStop).buttonStyle(.borderedProminent)
                    } else if !online {
                        // Same honest-offline hint as Mic/Mirror: a disabled
                        // Start with no reason reads as a dead button (seen
                        // on-device 2026-09-27 — the tap landed in a
                        // reconnect window and nothing explained it).
                        Text("The webcam needs a connection.").foregroundStyle(.secondary)
                    } else {
                        if webcam.phase == .error {
                            Text(webcam.message).foregroundStyle(.red)
                        }
                        Text("\(webcamConfig.width)×\(webcamConfig.height) · \(webcamConfig.camera) camera")
                            .foregroundStyle(.secondary)
                        Button("Start", action: onWebcamStart)
                            .buttonStyle(.borderedProminent).disabled(!online)
                    }
                }
            }.padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Camera")
    }

    @ViewBuilder
    private var textTab: some View {
        if scanning {
            scanPreview(hint: "Point the camera at text.")
        } else if recognizedText.isEmpty {
            Text("Point the camera at text, then scan.").foregroundStyle(.secondary)
            Button("Scan text", action: onScanText).buttonStyle(.borderedProminent)
        } else {
            Text(recognizedText)
            HStack {
                Button("Send to \(computer)") { onSendText(recognizedText) }
                    .buttonStyle(.borderedProminent).disabled(!online)
                Button("Scan again", action: onScanText).buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var qrTab: some View {
        if scanning {
            scanPreview(hint: "Point the camera at a code.")
        } else if let sheet = code {
            Text(sheet.title).font(.headline)
            Text(sheet.value)
            ForEach(0 ..< sheet.actions.count, id: \.self) { i in
                Button(sheet.actions[i].verb) { onCodeAction(sheet.actions[i]) }
                    .buttonStyle(.bordered).disabled(!online)
            }
            Button("Scan again", action: onScanCode).buttonStyle(.bordered)
        } else {
            Text("Point the camera at a code, then scan.").foregroundStyle(.secondary)
            Button("Scan code", action: onScanCode).buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var photoTab: some View {
        Text("Photos land in photo_dir on \(computer).").foregroundStyle(.secondary)
        Button("Take photo", action: onTakePhoto).buttonStyle(.borderedProminent)
        Toggle("Auto-upload screenshots", isOn: Binding(
            get: { screenshotsOn }, set: { onCaptureToggle(.screenshot, $0) }))
            .tint(.accentColor)
        Toggle("Auto-upload camera photos", isOn: Binding(
            get: { photosOn }, set: { onCaptureToggle(.photo, $0) }))
            .tint(.accentColor)
        Text("Needs full photo-library access; Limited access keeps the manual buttons only.")
            .font(.footnote).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func scanPreview(hint: String) -> some View {
        #if os(iOS) || os(macOS)
        if let session = previewSession {
            CameraPreview(session: session)
                .frame(minHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        #endif
        Text(hint).foregroundStyle(.secondary)
        ProgressView().accessibilityLabel("Scanning")
    }
}

// MARK: - Screen mirror

/// Screen mirror: status + Start/Stop. The desktop window shows the screen
/// and sends no input back (same as Android).
public struct MirrorScreen: View {
    public var computer: String
    public var online: Bool
    public var status: StreamStatus
    public var onStart: () -> Void
    public var onStop: () -> Void

    public init(
        computer: String, online: Bool = true,
        status: StreamStatus = StreamStatus(),
        onStart: @escaping () -> Void = {}, onStop: @escaping () -> Void = {}
    ) {
        self.computer = computer
        self.online = online
        self.status = status
        self.onStart = onStart
        self.onStop = onStop
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("On \(computer)").foregroundStyle(.secondary)
                // Like Mic/Camera: a live capture outlives presence, so
                // Stop comes first and is never gated on the link.
                if status.active {
                    Text(status.message).foregroundStyle(.secondary)
                    Button("Stop", action: onStop).buttonStyle(.borderedProminent)
                } else if !online {
                    Text("The mirror needs a connection.").foregroundStyle(.secondary)
                } else {
                    if status.phase == .error {
                        Text(status.message).foregroundStyle(.red)
                    }
                    Text("The desktop window shows this screen. It cannot control it.")
                        .foregroundStyle(.secondary)
                    Button("Start", action: onStart).buttonStyle(.borderedProminent)
                }
            }.padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Mirror screen")
    }
}

// MARK: - Previews

#Preview("Mic idle") {
    MicScreen(computer: "omarchy-xps")
}

#Preview("Mic live") {
    MicScreen(
        computer: "omarchy-xps",
        status: StreamStatus(phase: .live, message: "Live as Flux Microphone", deviceId: "pc"),
        level: 0.4, withWebcam: true)
}

#Preview("Camera webcam") {
    CameraScreen(computer: "omarchy-xps")
}

#Preview("Camera QR result") {
    CameraScreen(
        computer: "omarchy-xps", mode: .qr,
        code: Codes.sheet(ScannedCode(format: .qrCode, raw: "https://omarchy.org/flux", url: "https://omarchy.org/flux"), pc: "omarchy-xps"))
}

#Preview("Mirror") {
    MirrorScreen(computer: "omarchy-xps")
}
