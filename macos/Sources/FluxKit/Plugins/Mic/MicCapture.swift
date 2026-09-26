@preconcurrency import AVFoundation
import CoreMedia

/// One audio input of this Mac.
public struct MicInput: Identifiable, Hashable, Sendable {
    /// The unique ID of the capture device.
    public let id: String
    public let name: String
}

/// The microphone permission of Flux.
public enum MicPermission: Sendable {
    case granted, undetermined, denied

    public static var current: MicPermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .undetermined
        default: .denied
        }
    }
}

/// Records one audio input as 48 kHz mono s16le PCM. AVFoundation converts
/// the format of the device. Samples arrive on a private serial queue.
final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let samples = DispatchQueue(label: "org.omarchy.flux.mic.samples")
    /// Runs the blocking session calls in order.
    private let control = DispatchQueue(label: "org.omarchy.flux.mic.control")
    private let onSamples: (UnsafeBufferPointer<Int16>) -> Void
    private let onError: (String) -> Void
    // Guarded by control.
    private var input: AVCaptureDeviceInput?
    private var stopped = false
    private var observer: NSObjectProtocol?

    /// onSamples gets each buffer of samples. onError gets a message for the
    /// user when the recording fails after it started.
    init(onSamples: @escaping (UnsafeBufferPointer<Int16>) -> Void, onError: @escaping (String) -> Void) {
        self.onSamples = onSamples
        self.onError = onError
    }

    /// The audio inputs of this Mac, including external and virtual devices.
    static func inputs() -> [MicInput] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { MicInput(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// The device of the input ID. An empty ID or a device that is gone
    /// gives the system default input.
    static func device(for id: String) -> AVCaptureDevice? {
        if !id.isEmpty, let d = AVCaptureDevice(uniqueID: id), d.isConnected { return d }
        return AVCaptureDevice.default(for: .audio)
    }

    /// Starts recording from the device. A capture that stopped does not start.
    func start(_ device: AVCaptureDevice) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            control.async { [self] in
                done.resume(with: Result { try startOnControl(device) })
            }
        }
    }

    private func startOnControl(_ device: AVCaptureDevice) throws {
        guard !stopped else { throw CancellationError() }
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: MicPackets.rate,
            AVNumberOfChannelsKey: MicPackets.channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: samples)
        let input = try makeInput(device)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw FluxError("\(device.localizedName) cannot record audio for Flux")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        self.input = input
        observer = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] n in
            let error = n.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.onError("The microphone stopped: \(error?.localizedDescription ?? "unknown error")")
        }
        session.startRunning()
        guard session.isRunning else { throw FluxError("\(device.localizedName) did not start recording") }
    }

    /// Switches to another device while the stream keeps running.
    func use(_ device: AVCaptureDevice) {
        control.async { [self] in
            guard !stopped, let old = input, old.device.uniqueID != device.uniqueID else { return }
            do {
                let new = try makeInput(device)
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                session.removeInput(old)
                guard session.canAddInput(new) else {
                    session.addInput(old)
                    throw FluxError("\(device.localizedName) cannot record audio for Flux")
                }
                session.addInput(new)
                input = new
            } catch {
                onError(String(describing: error))
            }
        }
    }

    /// Stops recording. It does not block.
    func stop() {
        control.async { [self] in
            stopped = true
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            session.stopRunning()
        }
    }

    private func makeInput(_ device: AVCaptureDevice) throws -> AVCaptureDeviceInput {
        do {
            return try AVCaptureDeviceInput(device: device)
        } catch {
            throw FluxError("\(device.localizedName) could not start: \(error.localizedDescription)")
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let format = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return }
        guard Self.isStreamFormat(format) else {
            onError("The microphone gave \(Int(format.mSampleRate)) Hz audio with \(format.mChannelsPerFrame) channels that Flux cannot send")
            return
        }
        try? sampleBuffer.withAudioBufferList { list, _ in
            for buffer in list {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                onSamples(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: count))
            }
        }
    }

    /// True for interleaved native 16-bit signed PCM at the stream rate and channels.
    private static func isStreamFormat(_ f: AudioStreamBasicDescription) -> Bool {
        f.mFormatID == kAudioFormatLinearPCM
            && f.mSampleRate == Double(MicPackets.rate)
            && f.mChannelsPerFrame == UInt32(MicPackets.channels)
            && f.mBitsPerChannel == 16
            && f.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
            && f.mFormatFlags & kAudioFormatFlagIsFloat == 0
            && f.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
    }
}
