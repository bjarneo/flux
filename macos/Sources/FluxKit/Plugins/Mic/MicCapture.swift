@preconcurrency import AVFoundation

/// One audio input of this Mac, or one route of the iPhone.
public struct MicInput: Identifiable, Hashable, Sendable {
    /// The unique ID of the capture device, or the UID of the route.
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

#if os(macOS)
import CoreMedia

/// Records one audio input of this Mac as 48 kHz mono s16le PCM. The capture
/// output converts the format of the device. Samples arrive on a private
/// serial queue.
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
#else
/// Records the input of the iPhone as 48 kHz mono s16le PCM. The audio
/// session picks the input by its route, and AVAudioEngine records it, also
/// while Flux is in the background with the audio background mode.
/// MicConvert converts each buffer on the audio thread of the engine.
final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    /// Runs the blocking engine calls in order.
    private let control = DispatchQueue(label: "org.omarchy.flux.mic.control")
    private let onSamples: (UnsafeBufferPointer<Int16>) -> Void
    private let onError: (String) -> Void
    // Guarded by control.
    private var stopped = false
    private var running = false
    private var observers: [NSObjectProtocol] = []
    /// True while this capture holds the audio session.
    private var holdsSession = false
    /// Owned by the audio thread of the tap.
    private var converter: AVAudioConverter?

    /// onSamples gets each buffer of samples. onError gets a message for the
    /// user when the recording fails after it started.
    init(onSamples: @escaping (UnsafeBufferPointer<Int16>) -> Void, onError: @escaping (String) -> Void) {
        self.onSamples = onSamples
        self.onError = onError
    }

    /// The inputs are the routes of the audio session, because the iPhone
    /// records from the route that the session picks. Nil keeps the list,
    /// see `AudioSession.inputs`.
    static func inputs() -> [MicInput]? {
        AudioSession.inputs()
    }

    /// Starts recording from the route with the ID, or from the input that
    /// iOS picks when the ID is empty. A capture that stopped does not start.
    func start(route: String) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            control.async { [self] in
                done.resume(with: Result { try startOnControl(route: route) })
            }
        }
    }

    private func startOnControl(route: String) throws {
        guard !stopped else { throw CancellationError() }
        try AudioSession.activate(.mic)
        holdsSession = true
        AudioSession.prefer(route)
        do {
            try run()
        } catch {
            releaseSession()
            throw error
        }
        let center = NotificationCenter.default
        observers = [
            // A new route, such as a headset, changes the format of the input.
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                self?.control.async { self?.restart() }
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] n in
                let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
                if type == .began { self?.onError("The microphone stopped because another app took it") }
            },
        ]
    }

    /// Installs the tap in the format of the input and starts the engine.
    private func run() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw FluxError(MicPlugin.noMicrophoneText()) }
        input.removeTap(onBus: 0)
        // About 100 ms per buffer. The engine may pick another size.
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) { [weak self] buffer, _ in
            self?.convert(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw FluxError("The microphone did not start: \(error.localizedDescription)")
        }
        running = true
    }

    /// Starts the engine again in the new format of the input.
    private func restart() {
        guard !stopped, running else { return }
        engine.stop()
        do {
            try run()
        } catch {
            running = false
            onError(String(describing: error))
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) {
        do {
            let data = try MicConvert.s16Mono48k(buffer, converter: &converter)
            data.withUnsafeBytes { onSamples($0.bindMemory(to: Int16.self)) }
        } catch {
            onError("The microphone audio cannot go to the computer: \(error)")
        }
    }

    /// Stops recording. It does not block.
    func stop() {
        control.async { [self] in
            stopped = true
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers = []
            if running {
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
                running = false
            }
            releaseSession()
        }
    }

    /// Ends the use of the audio session, once. Runs on control.
    private func releaseSession() {
        guard holdsSession else { return }
        holdsSession = false
        AudioSession.deactivate(.mic)
    }
}
#endif
