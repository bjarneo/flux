import CoreMedia
import Foundation
import VideoToolbox

/// An H.264 encoder with the settings of the Android encoder: Main profile
/// at level 4.1, variable bitrate, 30 frames per second, a key frame each
/// second, and realtime priority. Frames keep their order, for a low delay.
/// It writes the stream in Annex-B form, with SPS and PPS in front of each
/// IDR frame, through output. After 100 ms without a new frame it encodes
/// the last frame again, so a still scene keeps feeding the computer. It
/// does not repeat while backlogged returns true, so a slow network does
/// not get more frames.
final class H264Encoder: @unchecked Sendable {
    static let repeatAfter: Double = 0.1

    let width: Int
    let height: Int
    private let session: VTCompressionSession
    private let output: @Sendable ([UInt8]) -> Void
    private let onError: @Sendable (String) -> Void
    private let backlogged: @Sendable () -> Bool
    private let timer: DispatchSourceTimer

    private let lock = NSLock()
    private var last: CVPixelBuffer?
    private var lastTime = CMTime.zero
    private var lastSubmit = DispatchTime.now()
    private var forceKey = true
    private var failed = false
    private var released = false

    /// Output runs on a VideoToolbox thread. The framer belongs to it.
    private let outputLock = NSLock()
    private var framer = AnnexBFramer()

    init(
        width: Int, height: Int, bitrate: Int, backlogged: @escaping @Sendable () -> Bool = { false },
        output: @escaping @Sendable ([UInt8]) -> Void, onError: @escaping @Sendable (String) -> Void
    ) throws {
        self.width = width
        self.height = height
        self.output = output
        self.onError = onError
        self.backlogged = backlogged
        let spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanTrue] as CFDictionary
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created
        )
        guard status == noErr, let created else { throw FluxError("This Mac cannot encode \(width) × \(height) video (\(status))") }
        session = created
        func set(_ key: CFString, _ value: CFTypeRef) -> Bool { VTSessionSetProperty(created, key: key, value: value) == noErr }
        _ = set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        // Some encoders reject the profile or the level. They use their defaults.
        if !set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_4_1) {
            FluxLog.plugin.info("encoder rejected main profile, using defaults")
        }
        _ = set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        _ = set(kVTCompressionPropertyKey_ExpectedFrameRate, WebcamPackets.fps as CFNumber)
        _ = set(kVTCompressionPropertyKey_MaxKeyFrameInterval, WebcamPackets.fps as CFNumber)
        _ = set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 1 as CFNumber)
        _ = set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        _ = set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        _ = set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        _ = set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(created)

        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "org.omarchy.flux.encoder.repeat"))
        timer.schedule(deadline: .now() + Self.repeatAfter, repeating: Self.repeatAfter / 2)
        timer.setEventHandler { [weak self] in self?.repeatLast() }
        timer.resume()
    }

    /// Encodes 1 frame of width x height pixels.
    func encode(_ buffer: CVPixelBuffer) {
        lock.withLock {
            last = buffer
            submit(buffer)
        }
    }

    /// Makes the next frame an IDR frame, for example after a camera switch.
    func requestKeyFrame() {
        lock.withLock { forceKey = true }
    }

    /// Writes the frames in flight and stops the encoder.
    func release() {
        let first = lock.withLock { () -> Bool in
            defer { released = true; last = nil }
            return !released
        }
        guard first else { return }
        timer.cancel()
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    private func repeatLast() {
        // A repeat adds no new image, so it waits while the network is behind.
        guard !backlogged() else { return }
        lock.withLock {
            guard let last, DispatchTime.now().uptimeNanoseconds - lastSubmit.uptimeNanoseconds >= UInt64(Self.repeatAfter * 1e9) else { return }
            submit(last)
        }
    }

    /// Hands 1 frame to VideoToolbox. The lock is held.
    private func submit(_ buffer: CVPixelBuffer) {
        guard !released, !failed else { return }
        var pts = CMClockGetTime(CMClockGetHostTimeClock())
        if pts <= lastTime { pts = lastTime + CMTime(value: 1, timescale: 1000) }
        lastTime = pts
        lastSubmit = .now()
        let properties = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        forceKey = false
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            self?.encoded(status, sample)
        }
        if status != noErr { fail("The video encoder failed (\(status))") }
    }

    private func encoded(_ status: OSStatus, _ sample: CMSampleBuffer?) {
        guard status == noErr else {
            lock.withLock { fail("The video encoder failed (\(status))") }
            return
        }
        guard let sample, let block = CMSampleBufferGetDataBuffer(sample),
              let format = CMSampleBufferGetFormatDescription(sample),
              let config = Self.parameterSets(format) else { return }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == kCMBlockBufferNoErr,
              AnnexB.convertLengthPrefixed(&bytes, headerLength: config.headerLength) else { return }
        let key = Self.isKeyFrame(sample)
        let out: [UInt8]? = outputLock.withLock {
            if key { framer.onConfig(config.annexB) }
            return framer.onFrame(bytes, keyFrame: key)
        }
        if let out { output(out) }
    }

    /// Reports an error once. The lock is held.
    private func fail(_ message: String) {
        guard !failed, !released else { return }
        failed = true
        FluxLog.plugin.error("\(message, privacy: .public)")
        onError(message)
    }

    private static func isKeyFrame(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    /// Returns SPS and PPS in Annex-B form, and the size of the length field
    /// in front of each NAL unit of the frames.
    private static func parameterSets(_ format: CMFormatDescription) -> (annexB: [UInt8], headerLength: Int)? {
        var count = 0
        var headerLength: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength
        ) == noErr else { return nil }
        var out: [UInt8] = []
        for i in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer else { return nil }
            out += AnnexB.startCode
            out += UnsafeBufferPointer(start: pointer, count: size)
        }
        return (out, Int(headerLength))
    }
}
