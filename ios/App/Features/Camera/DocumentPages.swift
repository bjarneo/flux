import FluxKit
import ImageIO
import Observation
import SwiftUI

/// Document mode: finds the page edges in photos or images, flattens the
/// pages, and sends them to the computer as 1 PDF. A document has at most
/// `maxPages` pages. Each page keeps its images as JPEG and a small image
/// for the list, so that many pages fit in the memory of the iPhone.
@MainActor
@Observable
final class DocumentPages {
    struct Page: Identifiable {
        let id = UUID()
        /// The whole image as JPEG.
        let original: Data
        /// The page cut out along its edges as JPEG, or nil when no edges were found.
        let flat: Data?
        /// The small images of `original` and `flat` for the list.
        let originalThumb: CGImage
        let flatThumb: CGImage?
        /// Uses the whole image instead of the page that was found.
        var whole = false

        /// The JPEG that goes into the PDF.
        var jpeg: Data { whole ? original : flat ?? original }
        var thumb: CGImage { whole ? originalThumb : flatThumb ?? originalThumb }

        /// The largest side of the small images.
        static let thumbSide = 240
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
    /// The most pages of 1 document.
    static let maxPages = 30

    static let fullText = "A document has at most \(maxPages) pages. Send the PDF, then start the next one."

    func capture() {
        guard !busy, !sending else { return }
        guard pages.count < Self.maxPages else {
            status = Self.fullText
            return
        }
        busy = true
        Task {
            do {
                let data = try await camera.capturePhoto()
                let page = try await offMain { try Self.page(CameraImages.decode(data, maxSide: Self.maxSide)) }
                pages.append(page)
                status = nil
            } catch {
                output.say("Cannot take the photo")
            }
            busy = false
        }
    }

    /// Adds picked or pasted images as pages. It decodes and flattens 1
    /// image at a time and stops at `maxPages`.
    func add(_ images: [Data]) {
        guard !sending, !images.isEmpty else { return }
        busy = true
        Task {
            status = nil
            for data in images {
                guard pages.count < Self.maxPages else {
                    status = Self.fullText
                    break
                }
                do {
                    let page = try await offMain { try Self.page(CameraImages.decode(data)) }
                    pages.append(page)
                } catch {
                    output.say("Cannot open the image")
                }
            }
            busy = false
        }
    }

    /// Finds and flattens the page in an image, and keeps both images as JPEG.
    nonisolated private static func page(_ image: CGImage) throws -> Page {
        let quad: DocumentQuad? = try? VisionScan.document(in: image)
        let flat = quad.flatMap { CameraImages.flatten(image, quad: $0) }
        guard let original = CameraImages.jpeg(image, quality: 0.9),
              let originalThumb = CameraImages.crop(image, to: nil, maxSide: Page.thumbSide) else { throw FluxError("Cannot read the image") }
        let flatJPEG = flat.flatMap { CameraImages.jpeg($0, quality: 0.9) }
        let flatThumb = flatJPEG == nil ? nil : flat.flatMap { CameraImages.crop($0, to: nil, maxSide: Page.thumbSide) }
        return Page(original: original, flat: flatJPEG, originalThumb: originalThumb, flatThumb: flatThumb)
    }

    /// Returns an image that decodes its JPEG only when the PDF draws it and
    /// keeps no decoded copy, so that 1 page at a time is in memory.
    nonisolated private static func lazyImage(_ jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    func remove(_ id: UUID) { pages.removeAll { $0.id == id } }

    func toggleWhole(_ id: UUID) {
        if let i = pages.firstIndex(where: { $0.id == id }) { pages[i].whole.toggle() }
    }

    func send() {
        guard !pages.isEmpty, !sending, !busy else { return }
        let name = CaptureNames.document()
        let jpegs = pages.map(\.jpeg)
        let label = Self.label(jpegs.count)
        sending = true
        status = "Sending \(name), \(label)…"
        Task {
            do {
                let data = try await offMain {
                    let images = jpegs.compactMap(Self.lazyImage)
                    guard images.count == jpegs.count, let pdf = CameraImages.pdf(images) else { throw FluxError("Cannot make the PDF") }
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
