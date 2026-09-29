import FluxKit
import Observation
import SwiftUI

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
            do {
                found(image, try await offMain { try VisionScan.codes(in: image) }, live: false)
            } catch {
                phase = .missing(image)
                output.say("Cannot read the image")
            }
        }
    }

    func run(_ action: CodeAction) {
        output.say(output.send(action.body) ? "Sent to \(output.name)" : "Not connected")
    }

    func again() { phase = .live }
}
