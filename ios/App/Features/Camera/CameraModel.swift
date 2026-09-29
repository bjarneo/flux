import FluxKit
import Observation
import SwiftUI

/// The modes of the camera screen, in the order of the mode bar, like the
/// Camera screen of Flux for Android.
enum CameraMode: String, CaseIterable, Identifiable {
    case text, qr, photo, document, signature, webcam

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: "Text"
        case .qr: "QR"
        case .photo: "Photo"
        case .document: "Document"
        case .signature: "Signature"
        case .webcam: "Webcam"
        }
    }

    var systemImage: String {
        switch self {
        case .text: "text.viewfinder"
        case .qr: "qrcode.viewfinder"
        case .photo: "camera"
        case .document: "doc.viewfinder"
        case .signature: "signature"
        case .webcam: "web.camera"
        }
    }

    var hint: String {
        switch self {
        case .text: "Scan text and send it"
        case .qr: "Read a QR code or barcode"
        case .photo: "Take a photo for the computer"
        case .document: "Scan pages to a PDF"
        case .signature: "Sign on paper or draw, paste on the computer"
        case .webcam: "Use this iPhone as a webcam"
        }
    }
}

/// Runs slow image work off the main thread.
func offMain<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { c in
        DispatchQueue.global(qos: .userInitiated).async { c.resume(with: Result { try work() }) }
    }
}

/// The state of the camera screen: the mode, the camera, and each mode.
@MainActor
@Observable
final class CameraScreenModel {
    let output: CameraOutput
    let camera: CameraController
    var mode: CameraMode
    let text: TextScan
    let codes: CodeScan
    let photo: PhotoShots
    let document: DocumentPages
    let signature: SignatureCapture
    private(set) var message: String?
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private let webcam: WebcamPlugin?

    /// `mode` is the first mode, but while the webcam streams the screen
    /// opens on the webcam.
    init(deviceId: String, app: AppModel, mode: CameraMode) {
        let webcam = app.core.plugin(WebcamPlugin.self)
        self.webcam = webcam
        let output = CameraOutput(deviceId: deviceId, app: app)
        let camera = CameraController(defaults: app.core.defaults)
        self.output = output
        self.camera = camera
        self.mode = webcam?.model.status.active == true ? .webcam : mode
        text = TextScan(camera: camera, output: output)
        codes = CodeScan(output: output)
        photo = PhotoShots(camera: camera, output: output)
        document = DocumentPages(camera: camera, output: output)
        signature = SignatureCapture(camera: camera, output: output)
        output.onMessage = { [weak self] in self?.show($0) }
        camera.onMessage = { [weak self] in self?.show($0) }
        camera.onCodes = { [weak self] codes, frame in self?.codes.found(frame, codes, live: true) }
    }

    var deviceName: String { output.name }

    /// True while the webcam streams. It holds the camera, so the other
    /// modes leave it off.
    var webcamStreams: Bool { webcam?.model.status.active == true }

    /// What the mode needs from the camera now.
    var cameraUse: CameraUse {
        if webcamStreams { return .off }
        return switch mode {
        case .text: text.isLive ? .scan(.text) : .off
        case .qr: codes.isLive ? .scan(.codes) : .off
        case .photo: .preview
        case .document: document.sending ? .off : .scan(.document)
        case .signature: signature.isLive ? .preview : .off
        // The webcam runs its own camera.
        case .webcam: .off
        }
    }

    /// Runs the mode on images from outside the camera: photos from the
    /// library or pasted images. Photo mode sends the first image as a
    /// photo, because an iPhone without a camera, such as the simulator,
    /// has no other way to send one.
    func use(_ images: [Data]) {
        guard let first = images.first else {
            show("Cannot open the image")
            return
        }
        if mode == .photo {
            photo.send(picked: first)
            return
        }
        let mode = mode
        Task {
            do {
                let decoded = try await offMain { try images.map { try CameraImages.decode($0) } }
                guard let image = decoded.first else { return }
                switch mode {
                case .text: text.read(image)
                case .qr: codes.read(image)
                case .document: document.add(decoded)
                case .signature: signature.cut(image, crop: nil)
                case .photo, .webcam: break
                }
            } catch {
                show("Cannot open the image")
            }
        }
    }

    func show(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.message = nil }
        }
    }

    func close() {
        messageTask?.cancel()
        camera.shutdown()
    }
}
