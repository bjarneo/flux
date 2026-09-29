import FluxKit
import Observation
import SwiftUI

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
