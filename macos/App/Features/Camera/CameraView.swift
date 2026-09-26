import AppKit
import AVFoundation
import FluxKit
import SwiftUI

/// The camera window: the mode bar, the camera picker, and the mode.
struct CameraView: View {
    @Bindable var model: CameraWindowModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(CameraMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                CameraPicker(camera: model.camera)
            }
            .padding([.horizontal, .top], 16)
            Label(model.mode.hint, systemImage: model.mode.systemImage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            Group {
                switch model.mode {
                case .text: TextModeView(scan: model.text, window: model)
                case .qr: CodeModeView(scan: model.codes, window: model)
                case .photo: PhotoModeView(shots: model.photo, window: model)
                case .document: DocumentModeView(pages: model.document, window: model)
                case .signature: SignatureModeView(capture: model.signature, window: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 560)
        .overlay(alignment: .top) {
            if let message = model.message {
                Text(message)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 100)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.message)
        .onChange(of: model.cameraUse, initial: true) { _, use in model.camera.set(use) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.camera.refreshAccess()
        }
        .task {
            if model.camera.access == .notDetermined { await model.camera.requestAccess() }
        }
    }
}

/// Picks the camera: built in, Continuity Camera, or external.
private struct CameraPicker: View {
    let camera: CameraController

    var body: some View {
        if camera.cameras.count > 1 {
            Picker("Camera", selection: Binding(get: { camera.current?.id ?? camera.selectedID ?? "" }, set: { camera.select($0) })) {
                ForEach(camera.cameras) { Text($0.name).tag($0.id) }
            }
            .fixedSize()
        } else if let only = camera.cameras.first {
            Label(only.name, systemImage: "camera")
                .foregroundStyle(.secondary)
        }
    }
}

/// The area of a mode: the live preview, a still image, or a message. It
/// takes dropped images when the mode reads images.
struct CameraStage<Content: View>: View {
    let window: CameraWindowModel
    @ViewBuilder let content: Content
    @State private var dropping = false

    var body: some View {
        ZStack {
            Color.black
            content
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onDrop(of: ImageInput.dropTypes, isTargeted: $dropping) { providers in
            guard window.acceptsImages else { return false }
            Task { window.use(await ImageInput.load(providers)) }
            return true
        }
    }
}

/// The live preview with outlines, or the reason it cannot show.
struct LiveCamera<Overlay: View>: View {
    let camera: CameraController
    let what: String
    var outlines = false
    @ViewBuilder var overlay: Overlay

    private var privacySettings: URL { URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")! }

    var body: some View {
        switch camera.access {
        case .denied:
            notice("Flux cannot use the camera", systemImage: "video.slash",
                   detail: "Allow Flux in System Settings > Privacy & Security > Camera to \(what). You can also open an image.") {
                Button("Open Privacy Settings") { NSWorkspace.shared.open(privacySettings) }
            }
        case .notDetermined:
            notice("Flux needs the camera", systemImage: "video", detail: "Allow the camera to \(what).") {
                Button("Allow Camera") { Task { await camera.requestAccess() } }
            }
        case .authorized:
            if camera.cameras.isEmpty {
                notice("No camera found", systemImage: "video.slash",
                       detail: "Connect a camera or bring an iPhone near for Continuity Camera. You can also open an image.") { EmptyView() }
            } else if let error = camera.error {
                notice("The camera does not start", systemImage: "exclamationmark.triangle", detail: error) {
                    Button("Try Again", action: camera.retry)
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
            }
        }
    }

    private func notice<Actions: View>(_ title: String, systemImage: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.largeTitle)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).multilineTextAlignment(.center).foregroundStyle(.secondary)
            actions()
        }
        .foregroundStyle(.white)
        .padding(32)
        .frame(maxWidth: 440)
    }
}

/// Hosts the preview layer of the camera.
private struct CameraPreview: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> PreviewView { PreviewView(preview: layer) }

    func updateNSView(_ view: PreviewView, context: Context) {}

    final class PreviewView: NSView {
        private let preview: AVCaptureVideoPreviewLayer

        init(preview: AVCaptureVideoPreviewLayer) {
            self.preview = preview
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(preview)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
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
            ProgressView().controlSize(.small)
            Text(text)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
    }
}

/// The shutter button: a filled circle inside a ring. Space presses it.
struct Shutter: View {
    let label: String
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(Color.primary.opacity(0.8), lineWidth: 3).frame(width: 58, height: 58)
                Circle().fill(Color.primary.opacity(busy ? 0.3 : 0.85)).frame(width: 46, height: 46)
                if busy { ProgressView().controlSize(.small) }
            }
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .keyboardShortcut(.space, modifiers: [])
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Open Image, Screen Region, and Paste, for the modes that read images.
/// Command-V pastes an image too.
struct ImageSources: View {
    let window: CameraWindowModel
    var multiple = false

    var body: some View {
        Menu {
            Button(multiple ? "Open Images…" : "Open Image…") {
                window.use(ImageInput.open(multiple: multiple, prompt: "Open"))
            }
            Button("Screen Region…") {
                Task { if let image = await ImageInput.screenRegion() { window.use([image]) } }
            }
            Button("Paste Image", action: paste)
        } label: {
            Label("From Image", systemImage: "photo")
        }
        .fixedSize()
        .help("Open an image, select a region of the screen, or paste an image. You can also drop an image on the camera.")
        .background {
            Button("Paste Image", action: paste)
                .keyboardShortcut("v")
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private func paste() {
        if let image = ImageInput.paste() { window.use([image]) } else { window.show("The clipboard has no image") }
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
        .padding(.bottom, 16)
        .frame(minHeight: 72)
    }
}
