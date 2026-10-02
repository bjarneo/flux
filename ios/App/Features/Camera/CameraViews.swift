import AVFoundation
import FluxKit
import PhotosUI
import SwiftUI

/// Opens the camera modes for a computer: text, codes, photos, documents,
/// signatures, and the webcam.
struct CameraTile: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if device.accepts(PacketType.share) {
            let live = model.core.plugin(WebcamPlugin.self)?.model.status.active(for: device.id) == true
            FeatureTile("Camera", systemImage: live ? "web.camera.fill" : "camera", tint: .cyan,
                        subtitle: live ? "Webcam live" : "Text, codes, photos, and pages") {
                model.path.append(.feature(.camera(device.id)))
            }
            .disabled(!device.online && !live)
        }
    }
}

/// The camera screen: 1 camera with a mode bar at the bottom, like the
/// Camera screen of Flux for Android. The camera stops when the screen closes.
struct CameraScreen: View {
    @Environment(AppModel.self) private var model
    let deviceId: String
    /// The mode at the start. Send and Control open the screen in a mode.
    var mode: CameraMode = .text
    @State private var screen: CameraScreenModel?

    var body: some View {
        Group {
            if let screen {
                CameraContent(model: screen)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Camera")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if screen == nil { screen = CameraScreenModel(deviceId: deviceId, app: model, mode: mode) }
        }
        .onDisappear {
            screen?.close()
            screen = nil
        }
    }
}

private struct CameraContent: View {
    @Bindable var model: CameraScreenModel

    var body: some View {
        VStack(spacing: 0) {
            Label(model.mode.hint, systemImage: model.mode.systemImage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 6)
            Group {
                switch model.mode {
                case .text: TextModeView(scan: model.text, screen: model)
                case .qr: CodeModeView(scan: model.codes, screen: model)
                case .photo: PhotoModeView(shots: model.photo, screen: model)
                case .document: DocumentModeView(pages: model.document, screen: model)
                case .signature: SignatureModeView(capture: model.signature, screen: model)
                case .webcam: WebcamPanel(deviceId: model.output.deviceId)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if model.webcamStreams && model.mode != .webcam {
                    Label("The webcam uses the camera. Stop it to use the camera here.", systemImage: "web.camera.fill")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(24)
                }
            }
            ModeBar(mode: $model.mode)
        }
        .overlay(alignment: .top) {
            if let message = model.message {
                ToastBanner(message: message)
                    .padding(.top, 60)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.message)
        .onChange(of: model.cameraUse, initial: true) { _, use in model.camera.set(use) }
        .task {
            if model.camera.access == .notDetermined { await model.camera.requestAccess() }
        }
    }
}

/// The modes side by side at the bottom of the screen.
private struct ModeBar: View {
    @Binding var mode: CameraMode

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CameraMode.allCases) { m in
                let on = m == mode
                Button { mode = m } label: {
                    VStack(spacing: 4) {
                        Image(systemName: m.systemImage)
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 28)
                            .background(Capsule().fill(on ? Color.accentColor.opacity(0.18) : .clear))
                        Text(m.label)
                            .font(.caption2.weight(on ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(on ? Color.accentColor : .secondary)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(m.label)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// The area of a mode: the live preview, a still image, or a message.
struct CameraStage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Color.black
            content
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The live preview with outlines, or the reason it cannot show.
struct LiveCamera<Overlay: View>: View {
    let camera: CameraController
    let what: String
    var outlines = false
    @ViewBuilder var overlay: Overlay

    var body: some View {
        switch camera.access {
        case .denied:
            CameraNotice("Flux cannot use the camera", systemImage: "video.slash",
                         detail: "Allow the camera for Flux in Settings to \(what). You can also pick a photo.") {
                Button("Open Settings") { AppSettings.open() }
                    .buttonStyle(.borderedProminent)
            }
        case .notDetermined:
            CameraNotice("Flux needs the camera", systemImage: "video", detail: "Allow the camera to \(what).") {
                Button("Allow Camera") { Task { await camera.requestAccess() } }
                    .buttonStyle(.borderedProminent)
            }
        case .authorized:
            if camera.cameras.isEmpty {
                CameraNotice("No camera", systemImage: "video.slash",
                             detail: "This iPhone has no camera that Flux can use. Pick a photo or paste an image instead.") { EmptyView() }
            } else if let error = camera.error {
                CameraNotice("The camera does not start", systemImage: "exclamationmark.triangle", detail: error) {
                    Button("Try Again", action: camera.retry)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                CameraPreview(layer: camera.still.previewLayer)
                    .overlay {
                        if outlines {
                            Outlines(outlines: camera.outlines, frame: camera.frameSize,
                                     mirrored: camera.still.previewLayer.connection?.isVideoMirrored ?? false)
                        }
                    }
                    .overlay { overlay }
                    .overlay(alignment: .topTrailing) { CameraButtons(camera: camera) }
            }
        }
    }
}

/// The torch and the switch between the back and the front camera.
private struct CameraButtons: View {
    let camera: CameraController

    var body: some View {
        HStack(spacing: 10) {
            if camera.hasTorch {
                round(camera.torchOn ? "flashlight.on.fill" : "flashlight.off.fill", label: camera.torchOn ? "Torch off" : "Torch on",
                      action: camera.toggleTorch)
            }
            if camera.cameras.count > 1 {
                round("arrow.triangle.2.circlepath.camera", label: "Switch camera", action: camera.switchCamera)
            }
        }
        .padding(12)
    }

    private func round(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(Circle().fill(.black.opacity(0.45)))
        }
        .accessibilityLabel(label)
    }
}

/// A message on the stage, with actions.
struct CameraNotice<Actions: View>: View {
    let title: String
    let systemImage: String
    let detail: String
    @ViewBuilder let actions: Actions

    init(_ title: String, systemImage: String, detail: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.systemImage = systemImage
        self.detail = detail
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.largeTitle)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.75))
            actions
        }
        .foregroundStyle(.white)
        .padding(28)
        .frame(maxWidth: 440)
    }
}

/// Opens the settings of Flux in the Settings app.
enum AppSettings {
    @MainActor
    static func open() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

/// Hosts the preview layer of the camera.
private struct CameraPreview: UIViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> PreviewView { PreviewView(preview: layer) }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        private let preview: AVCaptureVideoPreviewLayer

        init(preview: AVCaptureVideoPreviewLayer) {
            self.preview = preview
            super.init(frame: .zero)
            backgroundColor = .black
            layer.addSublayer(preview)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            preview.frame = bounds
            CATransaction.commit()
        }
    }
}

/// Draws outlines from normalized frame coordinates over a preview that
/// fills its bounds with the frame and cuts off the overflow.
private struct Outlines: View {
    let outlines: [[CGPoint]]
    let frame: CGSize
    let mirrored: Bool

    var body: some View {
        Canvas { context, size in
            guard frame.width > 0, frame.height > 0 else { return }
            let scale = max(size.width / frame.width, size.height / frame.height)
            let dx = (size.width - frame.width * scale) / 2
            let dy = (size.height - frame.height * scale) / 2
            for outline in outlines where outline.count > 1 {
                var path = Path()
                path.addLines(outline.map { p in
                    let x = dx + p.x * frame.width * scale
                    return CGPoint(x: mirrored ? size.width - x : x, y: dy + p.y * frame.height * scale)
                })
                path.closeSubpath()
                context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 3, lineJoin: .round))
            }
        }
        .allowsHitTesting(false)
    }
}

/// A still image that fits the stage.
struct StillImage: View {
    let image: CGImage?

    var body: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
        }
    }
}

/// A short status over a still, such as "Reading text".
struct BusyBadge: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
    }
}

/// The shutter button: a filled circle inside a ring.
struct Shutter: View {
    let label: String
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(Color.accentColor, lineWidth: 4).frame(width: 70, height: 70)
                Circle().fill(Color.accentColor.opacity(busy ? 0.35 : 1)).frame(width: 54, height: 54)
                if busy { ProgressView().tint(.white) }
            }
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(label)
    }
}

/// Photos and Paste, for the modes that also take images. The simulator
/// has no camera, so these are the only way to use a mode there.
struct ImageSources: View {
    let screen: CameraScreenModel
    var multiple = false
    @State private var items: [PhotosPickerItem] = []

    var body: some View {
        HStack(spacing: 8) {
            PhotosPicker(selection: $items, maxSelectionCount: multiple ? DocumentPages.maxPages : 1, matching: .images) {
                Label("Photos", systemImage: "photo.on.rectangle")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color(.tertiarySystemFill)))
            }
            .accessibilityLabel(multiple ? "Pick photos" : "Pick a photo")
            PasteButton(supportedContentTypes: ImageInput.pasteTypes) { providers in
                Task { @MainActor in screen.use(await ImageInput.load(providers)) }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
        }
        .onChange(of: items) { _, picked in
            guard !picked.isEmpty else { return }
            items = []
            Task { screen.use(await ImageInput.load(picked)) }
        }
    }
}

/// The row of controls under the stage.
struct ControlBar<Leading: View, Center: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var center: Center
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            HStack { leading }.frame(maxWidth: .infinity, alignment: .leading)
            center
            HStack { trailing }.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .frame(minHeight: 86)
    }
}
