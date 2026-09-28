import AppKit
import FluxKit
import Observation

/// The modes of the camera window, in the order of the mode bar. Webcam
/// streaming is a feature of its own.
enum CameraMode: String, CaseIterable, Identifiable {
    case text, qr, photo, document, signature

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: "Text"
        case .qr: "QR"
        case .photo: "Photo"
        case .document: "Document"
        case .signature: "Signature"
        }
    }

    var systemImage: String {
        switch self {
        case .text: "text.viewfinder"
        case .qr: "qrcode.viewfinder"
        case .photo: "camera"
        case .document: "doc.viewfinder"
        case .signature: "signature"
        }
    }

    var hint: String {
        switch self {
        case .text: "Scan text and send it"
        case .qr: "Read a QR code or barcode"
        case .photo: "Take a photo for the computer"
        case .document: "Scan pages to a PDF"
        case .signature: "Sign on paper or draw, paste on the computer"
        }
    }
}

/// Runs slow image work off the main thread.
func offMain<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { c in
        DispatchQueue.global(qos: .userInitiated).async { c.resume(with: Result { try work() }) }
    }
}

/// The state of 1 camera window: the mode, the camera, and each mode.
@MainActor
@Observable
final class CameraWindowModel {
    @ObservationIgnored let app: AppModel
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

    init(deviceId: String, app: AppModel, mode: CameraMode) {
        let output = CameraOutput(deviceId: deviceId, app: app)
        let camera = CameraController(defaults: app.core.defaults)
        self.app = app
        self.output = output
        self.camera = camera
        self.mode = mode
        text = TextScan(camera: camera, output: output)
        codes = CodeScan(output: output)
        photo = PhotoShots(camera: camera, output: output)
        document = DocumentPages(camera: camera, output: output)
        signature = SignatureCapture(camera: camera, output: output)
        output.onMessage = { [weak self] in self?.show($0) }
        camera.onCodes = { [weak self] codes, frame in self?.codes.found(frame, codes, live: true) }
    }

    var deviceName: String { output.name }

    /// What the mode needs from the camera now.
    var cameraUse: CameraUse {
        switch mode {
        case .text: text.isLive ? .scan(.text) : .off
        case .qr: codes.isLive ? .scan(.codes) : .off
        case .photo: .preview
        case .document: document.sending ? .off : .scan(.document)
        case .signature: signature.isLive ? .preview : .off
        }
    }

    /// Photo mode takes photos with the camera only, like on Android.
    var acceptsImages: Bool { mode != .photo }

    /// Runs the mode on images from outside the camera: files, a screen region, the clipboard, or a drop.
    func use(_ images: [CGImage]) {
        guard let first = images.first else {
            show("Cannot open the image")
            return
        }
        switch mode {
        case .text: text.read(first)
        case .qr: codes.read(first)
        case .document: document.add(images)
        case .signature: signature.cut(first, crop: nil)
        case .photo: break
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

// MARK: Text

/// Text mode: reads text with the camera or from an image and sends it to the computer.
@MainActor
@Observable
final class TextScan {
    enum Phase {
        /// The camera preview runs and shows the text boxes.
        case live
        /// The image is frozen and recognition runs. The image is nil until the photo arrives.
        case reading(CGImage?)
        /// The recognized text is ready to edit and send.
        case result(CGImage)
    }

    private(set) var phase = Phase.live
    var text = ""
    @ObservationIgnored private let camera: CameraController
    @ObservationIgnored private let output: CameraOutput

    init(camera: CameraController, output: CameraOutput) {
        self.camera = camera
        self.output = output
    }

    var isLive: Bool { if case .live = phase { true } else { false } }

    func capture() {
        guard isLive else { return }
        phase = .reading(nil)
        Task {
            do {
                let data = try await camera.capturePhoto()
                read(try await offMain { try CameraImages.decode(data) })
            } catch {
                phase = .live
                output.say("Cannot take the photo")
            }
        }
    }

    func read(_ image: CGImage) {
        phase = .reading(image)
        Task {
            do {
                text = TextAssembly.assemble(try await offMain { try VisionScan.text(in: image) })
            } catch {
                text = ""
                output.say("Cannot read the image")
            }
            phase = .result(image)
        }
    }

    func retake() {
        text = ""
        phase = .live
    }

    func send() {
        if output.sendScan(text) {
            output.say("Sent to \(output.name)")
            retake()
        } else {
            output.say("Not connected")
        }
    }
}

// MARK: QR

/// QR mode: reads QR codes and barcodes and sends the value to the computer.
@MainActor
@Observable
final class CodeScan {
    enum Phase {
        case live
        case found(CGImage?, CodeSheet)
        case missing(CGImage?)
    }

    private(set) var phase = Phase.live
    @ObservationIgnored private let output: CameraOutput

    init(output: CameraOutput) {
        self.output = output
    }

    var isLive: Bool { if case .live = phase { true } else { false } }

    /// Shows the first code with a value. A live frame pauses the camera on
    /// the first code, like a camera app.
    func found(_ image: CGImage?, _ codes: [ScannedCode], live: Bool) {
        if live && !isLive { return }
        if let code = codes.first(where: { !$0.raw.isEmpty }) {
            phase = .found(image, Codes.sheet(code, pc: output.name))
        } else {
            phase = .missing(image)
        }
    }

    func read(_ image: CGImage) {
        Task {
            let codes = (try? await offMain { try VisionScan.codes(in: image) }) ?? []
            found(image, codes, live: false)
        }
    }

    func run(_ action: CodeAction) {
        output.say(output.send(action.body) ? "Sent to \(output.name)" : "Not connected")
    }

    func again() { phase = .live }
}

// MARK: Photo

/// Photo mode: takes a full-quality photo and sends it to the computer as a file.
@MainActor
@Observable
final class PhotoShots {
    /// The state of the last photo.
    enum Status {
        case none
        case saving
        case sending(CGImage?)
        case sent(CGImage?)
        case failed(CGImage?, Data, String, String)
    }

    private(set) var status = Status.none
    @ObservationIgnored private let camera: CameraController
    @ObservationIgnored private let output: CameraOutput

    init(camera: CameraController, output: CameraOutput) {
        self.camera = camera
        self.output = output
    }

    var busy: Bool {
        switch status {
        case .saving, .sending: true
        default: false
        }
    }

    func shoot() {
        guard !busy else { return }
        let name = CaptureNames.photo()
        status = .saving
        Task {
            do {
                let data = try await camera.capturePhoto()
                let thumb = try? await offMain { try CameraImages.decode(data, maxSide: 256) }
                send(data, name: name, thumb: thumb)
            } catch {
                status = .none
                output.say("Cannot take the photo")
            }
        }
    }

    /// Sends a photo that failed again.
    func retry() {
        if case .failed(let thumb, let data, let name, _) = status { send(data, name: name, thumb: thumb) }
    }

    private func send(_ data: Data, name: String, thumb: CGImage?) {
        status = .sending(thumb)
        Task {
            do {
                try await output.sendCapture(data, name: name, extra: ["photo": true])
                status = .sent(thumb)
                output.say("Sent to \(output.name)")
            } catch {
                let message = error.localizedDescription
                status = .failed(thumb, data, name, message)
                output.say(message)
            }
        }
    }
}

// MARK: Document

/// Document mode: finds the page edges in photos or images, flattens the
/// pages, and sends them to the computer as 1 PDF.
@MainActor
@Observable
final class DocumentPages {
    struct Page: Identifiable {
        let id = UUID()
        let original: CGImage
        /// The page cut out along its edges, or nil when no edges were found.
        let flat: CGImage?
        /// Uses the whole image instead of the page that was found.
        var whole = false

        var image: CGImage { whole ? original : flat ?? original }
    }

    private(set) var pages: [Page] = []
    private(set) var busy = false
    private(set) var sending = false
    private(set) var status: String?
    @ObservationIgnored private let camera: CameraController
    @ObservationIgnored private let output: CameraOutput

    init(camera: CameraController, output: CameraOutput) {
        self.camera = camera
        self.output = output
    }

    /// The largest side of a page photo.
    private static let maxSide = 3000

    func capture() {
        guard !busy, !sending else { return }
        busy = true
        Task {
            do {
                let data = try await camera.capturePhoto()
                let image = try await offMain { try CameraImages.decode(data, maxSide: Self.maxSide) }
                await addNow([image])
            } catch {
                output.say("Cannot take the photo")
            }
            busy = false
        }
    }

    func add(_ images: [CGImage]) {
        guard !sending else { return }
        busy = true
        Task {
            await addNow(images)
            busy = false
        }
    }

    private func addNow(_ images: [CGImage]) async {
        for image in images {
            let flat = try? await offMain { try VisionScan.document(in: image).flatMap { CameraImages.flatten(image, quad: $0) } }
            pages.append(Page(original: image, flat: flat ?? nil))
        }
        status = nil
    }

    func remove(_ id: UUID) { pages.removeAll { $0.id == id } }

    func toggleWhole(_ id: UUID) {
        if let i = pages.firstIndex(where: { $0.id == id }) { pages[i].whole.toggle() }
    }

    func send() {
        guard !pages.isEmpty, !sending, !busy else { return }
        let name = CaptureNames.document()
        let images = pages.map(\.image)
        let label = Self.label(images.count)
        sending = true
        status = "Sending \(name), \(label)…"
        Task {
            do {
                let data = try await offMain {
                    guard let pdf = CameraImages.pdf(images) else { throw FluxError("Cannot make the PDF") }
                    return pdf
                }
                try await output.sendCapture(data, name: name, extra: ["scan": true])
                pages.removeAll()
                status = "Sent \(name), \(label), to \(output.name)"
                output.say("Sent to \(output.name)")
            } catch {
                status = error.localizedDescription
            }
            sending = false
        }
    }

    static func label(_ n: Int) -> String { n == 1 ? "1 page" : "\(n) pages" }
}

// MARK: Signature

/// Signature mode: photographs a signature on paper, or takes one drawn on
/// the trackpad, cuts out the ink, and sends it as a transparent PNG. The
/// computer puts it on the clipboard.
@MainActor
@Observable
final class SignatureCapture {
    enum Source: String, CaseIterable, Identifiable {
        case camera, draw

        var id: String { rawValue }
        var label: String { self == .camera ? "Paper" : "Draw" }
    }

    enum Phase {
        /// The camera preview runs with the guide frame, or the drawing canvas shows.
        case live
        /// The ink is cut out.
        case working(CGImage?)
        /// The ink is ready to send. It is nil when the image has no ink.
        case result(SignatureInk?)
    }

    var source = Source.camera {
        didSet { if oldValue != source { retake() } }
    }
    private(set) var phase = Phase.live
    var color = InkColor.black
    var drawing = SignatureDrawing()
    private(set) var sending = false
    private(set) var failure: String?
    /// True when the result comes from the canvas, where the pen is black.
    private(set) var drawn = false
    @ObservationIgnored private let camera: CameraController
    @ObservationIgnored private let output: CameraOutput

    init(camera: CameraController, output: CameraOutput) {
        self.camera = camera
        self.output = output
    }

    var isLive: Bool {
        if case .live = phase { source == .camera } else { false }
    }

    /// Takes a photo and cuts out the ink inside the guide frame of a preview of the size.
    func capture(preview: CGSize) {
        guard isLive, preview.width > 0, preview.height > 0 else { return }
        phase = .working(nil)
        Task {
            do {
                let data = try await camera.capturePhoto()
                let image = try await offMain { try CameraImages.decode(data, maxSide: 2560) }
                let frame = SignatureCut.guideFrame(width: preview.width, height: preview.height)
                let crop = SignatureCut.frameInImage(
                    left: Float(frame.minX), top: Float(frame.minY), right: Float(frame.maxX), bottom: Float(frame.maxY),
                    viewWidth: Int(preview.width), viewHeight: Int(preview.height), imageWidth: image.width, imageHeight: image.height,
                    pad: 0.05
                )
                cut(image, crop: crop)
            } catch {
                phase = .live
                output.say("Cannot take the photo")
            }
        }
    }

    /// Crops the image, scales it down, and cuts out the ink.
    func cut(_ image: CGImage, crop: SignatureCrop?) {
        phase = .working(image)
        failure = nil
        drawn = false
        Task {
            let ink = try? await offMain { () -> SignatureInk? in
                guard let part = CameraImages.crop(image, to: crop, maxSide: SignatureCut.maxSide),
                      let px = CameraImages.argb(part) else { return nil }
                return SignatureCut.extract(px, width: part.width, height: part.height)
            }
            phase = .result(ink ?? nil)
        }
    }

    /// Cuts out the ink of the drawing on a canvas of the size.
    func finishDrawing(canvas: CGSize) {
        failure = nil
        drawn = true
        if color == .original { color = .black }
        phase = .result(drawing.ink(canvas: canvas))
    }

    func retake() {
        failure = nil
        phase = .live
    }

    func send(_ ink: SignatureInk) {
        guard !sending else { return }
        sending = true
        failure = nil
        let rgb = color.of(ink)
        let name = CaptureNames.signature()
        Task {
            do {
                let data = try await offMain {
                    guard let png = CameraImages.png(ink, rgb: rgb) else { throw FluxError("Cannot save the signature") }
                    return png
                }
                try await output.sendCapture(data, name: name, extra: ["signature": true])
                output.say("Copied to the clipboard on \(output.name)")
                drawing.clear()
                phase = .live
            } catch {
                failure = error.localizedDescription
            }
            sending = false
        }
    }
}
