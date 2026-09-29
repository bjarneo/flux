import FluxKit
import Observation
import SwiftUI

/// Signature mode: photographs a signature on paper, or takes one drawn
/// with a finger, cuts out the ink, and sends it as a transparent PNG. The
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
