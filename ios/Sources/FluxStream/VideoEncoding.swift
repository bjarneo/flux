import Foundation
import FluxProto
import FluxCamera
#if canImport(VideoToolbox)
import VideoToolbox
import CoreMedia
#endif

/// Hardware H.264 encoder. Ports Android `webcam/H264Encoder.kt` to
/// `VideoToolbox`: pixel buffers in, Annex-B bytes out through the shared
/// `AnnexBFramer` (SPS/PPS before every IDR, drop pre-IDR frames).
///
/// The webcam (`1280x720`/`1920x1080` from `WebcamConfig`) and the screen
/// mirror (`MirrorSize.fit`) share it; only the bitrate/size differ
/// (camera: `bitrateFor`, screen: `MirrorSize.bitrate`).
///
/// Encoding needs hardware (gated in `ios/README.md` M5); the Annex-B tail
/// is unit-tested, and the bytes are E2E-held through `StreamEngine`.

#if canImport(VideoToolbox)
/// Encodes `CVPixelBuffer` frames to H.264 Annex B.
public final class H264VideoEncoder {
    private var session: VTCompressionSession?
    private let framer = AnnexBFramer()
    private let lock = NSLock()
    private var forceKeyFrame = false

    /// Annex-B chunk + whether it opens with an IDR (framer output).
    public var onFrame: ((Data, Bool) -> Void)?
    /// Fatal encoder error (the session ends, like Android `onError`).
    public var onError: ((String) -> Void)?

    public init() {}

    /// Configures the session: Main profile (Android parity; Baseline on
    /// encoders rejecting it), 1 s keyframes, no reordering, realtime.
    public func configure(width: Int, height: Int, bitrate: Int, fps: Int32 = 30) throws {
        invalidate()
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: encodeCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &s
        )
        guard status == noErr, let session = s else {
            throw H264VideoError.configuration("The video encoder did not start (status \(status))")
        }
        self.session = session
        try set(session, key: kVTCompressionPropertyKey_RealTime, value: true)
        try set(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps)
        try set(session, key: kVTCompressionPropertyKey_AverageBitRate, value: Int32(bitrate))
        try set(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: fps)
        try set(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: false)
        if (try? set(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)) == nil {
            try set(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        }
        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            throw H264VideoError.configuration("The video encoder did not start")
        }
    }

    /// Asks for an IDR on the next frame (e.g. when the computer connects).
    public func requestKeyFrame() {
        lock.withLock { forceKeyFrame = true }
    }

    /// Encodes one frame. Not thread-safe with `invalidate`.
    public func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) throws {
        guard let session else { throw H264VideoError.notConfigured }
        var flags = VTEncodeInfoFlags()
        var options: [String: Any]?
        if lock.withLock({ forceKeyFrame }) {
            lock.withLock { forceKeyFrame = false }
            options = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true]
        }
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime, duration: .invalid,
            frameProperties: options as CFDictionary?,
            sourceFrameRefcon: nil, infoFlagsOut: &flags)
        if status != noErr {
            throw H264VideoError.encode("The video encoder stopped (\(status))")
        }
    }

    /// Stops the session. Does not close the output.
    public func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
    }

    deinit { invalidate() }

    private func set(_ session: VTCompressionSession, key: CFString, value: Any) throws {
        let cfValue: CFTypeRef
        switch value {
        case let b as Bool: cfValue = NSNumber(value: b)
        case let i as Int32: cfValue = NSNumber(value: i)
        case let s as CFString: cfValue = s
        default: throw H264VideoError.configuration("The video encoder rejected a setting")
        }
        guard VTSessionSetProperty(session, key: key, value: cfValue) == noErr else {
            throw H264VideoError.configuration("The video encoder rejected a setting")
        }
    }

    fileprivate func receive(status: OSStatus, sample: CMSampleBuffer?) {
        guard status == noErr, let sample else {
            if status != noErr { onError?("The video encoder stopped (\(status))") }
            return
        }
        let sync = CMGetAttachment(sample, key: kCMSampleAttachmentKey_NotSync, attachmentModeOut: nil)
        let keyFrame = (sync as? Bool) != true
        storeParameterSets(sample)
        guard let block = CMSampleBufferGetDataBuffer(sample),
              let annexB = avccToAnnexB(block)
        else { return }
        if let out = framer.onFrame(annexB, keyFrame: keyFrame) {
            onFrame?(out, keyFrame)
        }
    }

    private func storeParameterSets(_ sample: CMSampleBuffer) {
        guard !framer.hasConfig,
              let desc = CMSampleBufferGetFormatDescription(sample)
        else { return }
        // Parameter-set indices are dense from 0 (SPS first, then PPS).
        var config = Data()
        var j = 0
        while true {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                desc, parameterSetIndex: j, parameterSetPointerOut: &ptr,
                parameterSetSizeOut: &size, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil) == noErr,
                let ptr
            else { break }
            config += Data([0, 0, 0, 1]) + Data(bytes: ptr, count: size)
            j += 1
        }
        if !config.isEmpty { framer.onConfig(config) }
    }

    /// Turns length-prefixed (AVCC) NALs into start-code-prefixed Annex B.
    fileprivate func avccToAnnexB(_ block: CMBlockBuffer) -> Data? {
        var ptr: UnsafeMutablePointer<Int8>?
        var total = 0
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &total, dataPointerOut: &ptr) == noErr,
              let ptr, total > 4
        else { return nil }
        let bytes = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
        var out = Data()
        var i = 0
        while i + 4 <= total {
            let n = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            i += 4
            guard n > 0, i + n <= total else { return nil }
            out += Data([0, 0, 0, 1]) + Data(bytes: bytes.advanced(by: i), count: n)
            i += n
        }
        return out.isEmpty ? nil : out
    }
}

private func encodeCallback(
    _ refcon: UnsafeMutableRawPointer?,
    _ sourceFrame: UnsafeMutableRawPointer?,
    _ status: OSStatus,
    _ flags: VTEncodeInfoFlags,
    _ sample: CMSampleBuffer?
) {
    guard let refcon else { return }
    Unmanaged<H264VideoEncoder>.fromOpaque(refcon).takeUnretainedValue().receive(status: status, sample: sample)
}

public enum H264VideoError: Error, Equatable {
    case configuration(String)
    case encode(String)
    case notConfigured
}
#endif
