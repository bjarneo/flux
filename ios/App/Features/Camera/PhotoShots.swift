import FluxKit
import Observation
import SwiftUI

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

    /// Sends a photo from the library or the clipboard as a JPEG file.
    func send(picked data: Data) {
        guard !busy else { return }
        let name = CaptureNames.photo()
        status = .saving
        Task {
            do {
                let jpeg = try await offMain { try CameraImages.jpegFile(data) }
                let thumb = try? await offMain { try CameraImages.decode(jpeg, maxSide: 256) }
                send(jpeg, name: name, thumb: thumb)
            } catch {
                status = .none
                output.say(error.localizedDescription)
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
