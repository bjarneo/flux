import Foundation
import FluxProto
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Vision)
import Vision
#endif

/// One-shot camera capture sessions for the text/QR/photo tabs (D15).
/// Ports of Android `camera/` modes (`TextMode`, `QrMode`, `PhotoMode`)
/// to `AVFoundation` + `Vision`.
///
/// Shape: each session owns its `AVCaptureSession`, runs once
/// (`scan()`/`capture()`), and stops itself on result, timeout (30 s), or
/// `stop()`. The running session is exposed as `previewSession` so the UI
/// can show a live preview while scanning — a blind shutter is not
/// shippable, and the preview is the same session, never a second drain.
/// Permission stays with the caller (`CameraAccess.request()`, the
/// mic/webcam pattern); a denied camera surfaces as `noCamera` here.
///
/// Mapping helpers (`TextRecognition`, `CodeDetection`,
/// `LiveCodeDetection`, `PhotoCapture`, `Codes`) stay in
/// `CapturePipelines.swift` and are unit-tested there; the live drains
/// below need hardware (like every `AVCapture` session in this module).
/// Pure seams for tests: `usableText(_:)` (result gate) and `isLink(_:)`
/// (QR URL gate, `CodeDetection` parity).

/// One-shot session failures. Every case lands on the status line, never
/// silent (the D16 mic/webcam contract).
public enum CaptureSessionError: Error, Sendable, Equatable {
    case noCamera
    case setupFailed(String)
    case timedOut
    case cancelled
    case captureFailed(String)
}

#if canImport(AVFoundation)
/// Lock-guarded one-shot continuation box: resume-once across the capture
/// queue, the timeout, and `stop()` (any order).
final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    private var done = false

    func set(_ c: CheckedContinuation<T, Error>) {
        lock.withLock { cont = c }
    }

    /// Resumes exactly once; late results are dropped.
    func resume(with result: Result<T, Error>) {
        let c = lock.withLock { () -> CheckedContinuation<T, Error>? in
            guard !done else { return nil }
            done = true
            let c = cont
            cont = nil
            return c
        }
        switch result {
        case .success(let v): c?.resume(returning: v)
        case .failure(let e): c?.resume(throwing: e)
        }
    }

    var finished: Bool { lock.withLock { done } }
}

/// Shared drain base: back-camera session + preview exposure + timeout.
/// Not a session itself — the three modes below own their outputs.
///
/// `@unchecked Sendable`: all mutable state is lock-guarded (`session`,
/// `timeoutWork`), queue-confined (delegates), or `nonisolated(unsafe)`
/// with single-writer discipline (`onStarted`, set before `scan()`).
public class CaptureDrain: NSObject, @unchecked Sendable {
    let lock = NSLock()
    nonisolated(unsafe) var session: AVCaptureSession?
    private nonisolated(unsafe) var timeoutWork: DispatchWorkItem?

    /// Fires on the session queue once the drain runs (the UI publishes
    /// `previewSession` from this — polling-free preview binding).
    public nonisolated(unsafe) var onStarted: (() -> Void)?

    /// The live session while running (nil when idle) — the UI binds its
    /// preview layer to this, never to a second session.
    public var previewSession: AVCaptureSession? {
        lock.withLock { session }
    }

    public var isRunning: Bool {
        lock.withLock { session != nil }
    }

    /// Builds + starts a back-camera session. Throws `noCamera` with no
    /// device (denied permission, simulator without a camera) or
    /// `setupFailed` when the input cannot attach.
    func startSession(preset: AVCaptureSession.Preset = .hd1280x720) throws -> AVCaptureSession {
        let s = AVCaptureSession()
        s.beginConfiguration()
        s.sessionPreset = preset
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video)
        else {
            throw CaptureSessionError.noCamera
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CaptureSessionError.setupFailed(String(describing: error))
        }
        guard s.canAddInput(input) else {
            throw CaptureSessionError.setupFailed("cannot add camera input")
        }
        s.addInput(input)
        s.commitConfiguration()
        lock.withLock { session = s }
        s.startRunning()
        onStarted?()
        return s
    }

    /// Schedules the 30 s one-shot timeout on the session queue.
    func armTimeout(queue: DispatchQueue, _ fire: @escaping () -> Void) {
        let work = DispatchWorkItem(block: fire)
        lock.withLock { timeoutWork = work }
        queue.asyncAfter(deadline: .now() + 30, execute: work)
    }

    /// Tears the session down (idempotent; `startRunning`/`stopRunning`
    /// block briefly, so never call on main).
    func teardown() {
        let (s, work) = lock.withLock { () -> (AVCaptureSession?, DispatchWorkItem?) in
            let s = session
            let w = timeoutWork
            session = nil
            timeoutWork = nil
            return (s, w)
        }
        work?.cancel()
        s?.stopRunning()
    }
}

/// Result gate: ignores empty/short fragments (a 1–2 char Vision line is
/// almost always a partial read, not the label the user framed).
public func usableText(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
}

/// URL gate for metadata codes (`CodeDetection` parity: raw links classify
/// `.url`, everything else keeps its raw value for `Codes.kind`).
public func codeIsLink(_ raw: String) -> Bool {
    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*://\\S+$", options: .regularExpression) != nil
}
#endif

#if canImport(AVFoundation) && canImport(Vision)
/// One-shot text scan: video frames → `VNRecognizeTextRequest` →
/// `TextAssembly` → first usable string. Frames are throttled (one Vision
/// request in flight, ≥500 ms apart) so a sustained scan doesn't queue
/// stale reads.
public final class TextCaptureSession: CaptureDrain, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "org.omarchy.flux.capture.text")
    private let shot = OneShot<String>()
    private nonisolated(unsafe) var inFlight = false
    private nonisolated(unsafe) var lastRequest = Date.distantPast

    public override init() { super.init() }

    /// Scans until usable text, the timeout, or `stop()`.
    public func scan() async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            shot.set(cont)
            queue.async { [weak self] in
                guard let self else { return }
                do {
                    let s = try self.startSession()
                    let out = AVCaptureVideoDataOutput()
                    out.alwaysDiscardsLateVideoFrames = true
                    out.setSampleBufferDelegate(self, queue: self.queue)
                    guard s.canAddOutput(out) else {
                        self.finish(.failure(CaptureSessionError.setupFailed("cannot add video output")))
                        return
                    }
                    s.addOutput(out)
                    self.armTimeout(queue: self.queue) { [weak self] in
                        self?.finish(.failure(CaptureSessionError.timedOut))
                    }
                } catch {
                    self.finish(.failure(error))
                }
            }
        }
    }

    /// Cancels the scan (the awaiter gets `cancelled`).
    public func stop() {
        queue.async { [weak self] in
            self?.finish(.failure(CaptureSessionError.cancelled))
        }
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !shot.finished else { return }
        let now = Date()
        guard !inFlight, now.timeIntervalSince(lastRequest) >= 0.5,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        inFlight = true
        lastRequest = now
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let req = TextRecognition.request(imageWidth: width, imageHeight: height) { [weak self] text in
            guard let self else { return }
            self.queue.async {
                self.inFlight = false
                if usableText(text) { self.finish(.success(text)) }
            }
        }
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixels, options: [:]).perform([req])
        } catch {
            queue.async { [weak self] in self?.inFlight = false }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        teardown()
        shot.resume(with: result)
    }
}

/// One-shot code scan: live metadata objects → first `ScannedCode`.
public final class CodeCaptureSession: CaptureDrain, @unchecked Sendable, AVCaptureMetadataOutputObjectsDelegate {
    private let queue = DispatchQueue(label: "org.omarchy.flux.capture.code")
    private let shot = OneShot<ScannedCode>()

    /// Metadata types this session recognizes (the
    /// `VNDetectBarcodesRequest` union from `LiveCodeDetection`).
    static var wantedTypes: [AVMetadataObject.ObjectType] {
        [.qr, .aztec, .pdf417, .dataMatrix, .ean13, .ean8, .upce,
         .code128, .code39, .code93, .codabar, .itf14]
    }

    public override init() { super.init() }

    /// Scans until the first code, the timeout, or `stop()`.
    public func scan() async throws -> ScannedCode {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ScannedCode, Error>) in
            shot.set(cont)
            queue.async { [weak self] in
                guard let self else { return }
                do {
                    let s = try self.startSession()
                    let out = AVCaptureMetadataOutput()
                    guard s.canAddOutput(out) else {
                        self.finish(.failure(CaptureSessionError.setupFailed("cannot add metadata output")))
                        return
                    }
                    s.addOutput(out)
                    let types = Self.wantedTypes.filter { out.availableMetadataObjectTypes.contains($0) }
                    guard !types.isEmpty else {
                        self.finish(.failure(CaptureSessionError.setupFailed("no barcode types available")))
                        return
                    }
                    out.metadataObjectTypes = types
                    out.setMetadataObjectsDelegate(self, queue: self.queue)
                    self.armTimeout(queue: self.queue) { [weak self] in
                        self?.finish(.failure(CaptureSessionError.timedOut))
                    }
                } catch {
                    self.finish(.failure(error))
                }
            }
        }
    }

    /// Cancels the scan (the awaiter gets `cancelled`).
    public func stop() {
        queue.async { [weak self] in
            self?.finish(.failure(CaptureSessionError.cancelled))
        }
    }

    public func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !shot.finished else { return }
        for obj in metadataObjects {
            guard let code = obj as? AVMetadataMachineReadableCodeObject,
                  let raw = code.stringValue, !raw.isEmpty
            else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            finish(.success(ScannedCode(
                format: LiveCodeDetection.format(of: code.type), raw: raw,
                url: codeIsLink(raw) ? trimmed : nil)))
            return
        }
    }

    private func finish(_ result: Result<ScannedCode, Error>) {
        teardown()
        shot.resume(with: result)
    }
}

/// One-shot still photo: `AVCapturePhotoOutput` → file data + name.
/// JPEG always (compat note in `PhotoCapture`: the desktop routes by the
/// `photo` flag, and every desktop reads JPEG; HEIC needs a HEIF viewer).
public final class PhotoCaptureSession: CaptureDrain, @unchecked Sendable, AVCapturePhotoCaptureDelegate {
    private let queue = DispatchQueue(label: "org.omarchy.flux.capture.photo")
    private let shot = OneShot<(Data, String)>()

    public override init() { super.init() }

    /// Captures one still photo. Returns the file data + `IMG_…` name.
    public func capture() async throws -> (data: Data, name: String) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, String), Error>) in
            shot.set(cont)
            queue.async { [weak self] in
                guard let self else { return }
                do {
                    let s = try self.startSession(preset: .photo)
                    let out = AVCapturePhotoOutput()
                    guard s.canAddOutput(out) else {
                        self.finish(.failure(CaptureSessionError.setupFailed("cannot add photo output")))
                        return
                    }
                    s.addOutput(out)
                    self.armTimeout(queue: self.queue) { [weak self] in
                        self?.finish(.failure(CaptureSessionError.timedOut))
                    }
                    out.capturePhoto(with: PhotoCapture.settings(preferHEIC: false, hevcSupported: false), delegate: self)
                } catch {
                    self.finish(.failure(error))
                }
            }
        }
    }

    /// Cancels the capture (the awaiter gets `cancelled`).
    public func stop() {
        queue.async { [weak self] in
            self?.finish(.failure(CaptureSessionError.cancelled))
        }
    }

    public func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            finish(.failure(CaptureSessionError.captureFailed(String(describing: error))))
            return
        }
        guard let data = photo.fileDataRepresentation(), !data.isEmpty else {
            finish(.failure(CaptureSessionError.captureFailed("empty photo data")))
            return
        }
        let now = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: Date())
        finish(.success((data, CaptureNames.photo(now))))
    }

    private func finish(_ result: Result<(Data, String), Error>) {
        teardown()
        shot.resume(with: result)
    }
}
#endif
