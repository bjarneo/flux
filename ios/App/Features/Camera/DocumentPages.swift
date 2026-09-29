import FluxKit
import Observation
import SwiftUI

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
