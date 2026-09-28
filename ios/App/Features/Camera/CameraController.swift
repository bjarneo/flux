import AVFoundation
import CoreImage
import FluxKit
import Observation
import UIKit

/// What a camera mode needs from the camera now.
enum CameraUse: Equatable {
    case off
    /// The live preview, for photos and signatures.
    case preview
    /// The live preview with Vision on the frames.
    case scan(VisionScan.Target)
}

/// The camera of the camera screen: the access, the back and front cameras,
/// the torch, the running session, and the outlines that Vision finds on
/// live frames.
@MainActor
@Observable
final class CameraController {
    let still = StillCamera()
    private(set) var access = CameraAccess.current
    private(set) var cameras: [CameraChoice] = StillCamera.cameras()
    private(set) var current: CameraChoice?
    private(set) var running = false
    private(set) var error: String?
    private(set) var hasTorch = false
    private(set) var torchOn = false
    /// The outlines of the codes, text, or page that Vision sees, in
    /// normalized frame coordinates with the origin at the top left corner.
    private(set) var outlines: [[CGPoint]] = []
    /// The size of the frames that the outlines belong to.
    private(set) var frameSize = CGSize.zero
    /// Receives the codes with a value in a live frame, and the frame.
    @ObservationIgnored var onCodes: (([ScannedCode], CGImage?) -> Void)?
    /// Shows a short message on the screen.
    @ObservationIgnored var onMessage: ((String) -> Void)?

    @ObservationIgnored private var use = CameraUse.off
    @ObservationIgnored private let analyzer = LiveAnalyzer()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var generation = 0

    /// The camera that the camera modes use. The webcam keeps its own choice.
    private static let cameraKey = "cameraModesDevice"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        analyzer.deliver = { [weak self] target, scan, frame in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(target, scan, frame) } }
        }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.camerasChanged() }
            })
        }
        // The user can change the access in Settings while Flux is away.
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccess() }
        })
    }

    /// Switches between the back and the front camera.
    func switchCamera() {
        guard cameras.count > 1 else { return }
        let index = cameras.firstIndex { $0.id == (current?.id ?? defaults.string(forKey: Self.cameraKey)) } ?? 0
        let next = cameras[(index + 1) % cameras.count]
        defaults.set(next.id, forKey: Self.cameraKey)
        current = next
        torchOn = false
        apply()
    }

    func toggleTorch() {
        let on = !torchOn
        Task {
            do {
                try await still.setTorch(on)
                torchOn = on
            } catch {
                // For example while the iPhone is too warm.
                torchOn = false
                onMessage?(error.localizedDescription)
            }
        }
    }

    /// Starts, changes, or stops the camera for what the mode needs.
    func set(_ use: CameraUse) {
        guard use != self.use else { return }
        self.use = use
        outlines = []
        if case .scan(let target) = use { analyzer.setTarget(target) } else { analyzer.setTarget(nil) }
        apply()
    }

    func requestAccess() async {
        access = await CameraAccess.request()
        apply()
    }

    /// Starts the camera again after an error.
    func retry() {
        error = nil
        apply()
    }

    func capturePhoto() async throws -> Data {
        try await still.capturePhoto()
    }

    /// Stops the camera for good when the screen closes.
    func shutdown() {
        set(.off)
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        onCodes = nil
        onMessage = nil
    }

    private func refreshAccess() {
        let now = CameraAccess.current
        guard now != access else { return }
        access = now
        apply()
    }

    private func apply() {
        generation += 1
        let gen = generation
        guard use != .off, access == .authorized, !cameras.isEmpty else {
            still.setFrameHandler(nil)
            still.stop()
            running = false
            torchOn = false
            return
        }
        let analyzer = analyzer
        still.setFrameHandler { analyzer.handle($0) }
        let id = defaults.string(forKey: Self.cameraKey)
        Task {
            do {
                let choice = try await still.start(id)
                guard gen == generation else { return }
                current = choice
                running = true
                hasTorch = still.hasTorch
                error = nil
            } catch {
                guard gen == generation else { return }
                running = false
                self.error = error.localizedDescription
            }
        }
    }

    private func camerasChanged() {
        cameras = StillCamera.cameras()
        // A camera that is gone falls back to the first camera.
        if let current, !cameras.contains(current) { self.current = nil }
        if use != .off { apply() }
    }

    private func receive(_ target: VisionScan.Target, _ scan: LiveScan, _ frame: CGImage?) {
        guard case .scan(let wanted) = use, wanted == target else { return }
        outlines = scan.outlines
        frameSize = scan.frameSize
        if target == .codes, !scan.codes.isEmpty { onCodes?(scan.codes, frame) }
    }
}

/// Runs Vision on live frames. It runs on the frame queue, so the camera
/// drops the frames that arrive while Vision works.
final class LiveAnalyzer: @unchecked Sendable {
    private let lock = NSLock()
    private var target: VisionScan.Target?
    private var last: CFAbsoluteTime = 0
    private let context = CIContext()
    var deliver: (@Sendable (VisionScan.Target, LiveScan, CGImage?) -> Void)?

    func setTarget(_ target: VisionScan.Target?) {
        lock.withLock {
            self.target = target
            last = 0
        }
    }

    func handle(_ frame: CVPixelBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        guard let target = lock.withLock({ () -> VisionScan.Target? in
            guard let target, now - last >= Self.interval(target) else { return nil }
            last = now
            return target
        }) else { return }
        guard let scan = try? VisionScan.live(target, frame: frame) else { return }
        var image: CGImage?
        if target == .codes, !scan.codes.isEmpty {
            let ci = CIImage(cvPixelBuffer: frame)
            image = context.createCGImage(ci, from: ci.extent)
        }
        deliver?(target, scan, image)
    }

    /// Codes pause the camera as soon as they show, so they get more frames.
    private static func interval(_ target: VisionScan.Target) -> CFAbsoluteTime {
        switch target {
        case .codes: 0.1
        case .text: 0.4
        case .document: 0.25
        }
    }
}
