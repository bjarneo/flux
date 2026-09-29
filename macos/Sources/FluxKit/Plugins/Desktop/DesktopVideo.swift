import AVFoundation
import CoreMedia

/// Shows the H.264 frames of the remote desktop on a display layer. The
/// layer decodes with VideoToolbox and shows each frame at once, with no
/// clock, for a short delay. The frames arrive on a network thread, and the
/// layer can change on the main thread, so a lock guards the state.
public final class DesktopVideo: @unchecked Sendable {
    private let lock = NSLock()
    private var renderer: AVSampleBufferVideoRenderer?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [[UInt8]] = []
    /// True until a key frame starts the picture on the renderer.
    private var needKey = true

    public init() {}

    /// Shows the video on the layer, or on no layer. The next key frame
    /// starts the picture.
    public func attach(_ layer: AVSampleBufferDisplayLayer?) {
        lock.withLock {
            renderer = layer?.sampleBufferRenderer
            renderer?.flush()
            needKey = true
        }
    }

    /// Takes the video from the layer, when the video still shows on it.
    /// A view that goes away calls it, so that the layer of a new view that
    /// took the video keeps it.
    public func detach(_ layer: AVSampleBufferDisplayLayer) {
        lock.withLock {
            guard let renderer, renderer === layer.sampleBufferRenderer else { return }
            self.renderer = nil
            needKey = true
        }
    }

    /// True when the video shows on the layer.
    func shows(on layer: AVSampleBufferDisplayLayer) -> Bool {
        lock.withLock { renderer != nil && renderer === layer.sampleBufferRenderer }
    }

    /// Forgets the stream, so that the next stream starts clean.
    func reset() {
        lock.withLock {
            format = nil
            parameterSets = []
            needKey = true
            renderer?.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }

    /// Sets the SPS and the PPS of the stream. It returns false when
    /// VideoToolbox refuses them.
    @discardableResult
    func configure(sps: [UInt8], pps: [UInt8]) -> Bool {
        if lock.withLock({ parameterSets == [sps, pps] }) { return true }
        guard let f = Self.format(sps: sps, pps: pps) else { return false }
        lock.withLock {
            format = f
            parameterSets = [sps, pps]
            needKey = true
        }
        return true
    }

    /// Shows 1 frame in Annex-B form. The frames before the first key frame
    /// do not show, because a decoder cannot start with them.
    func show(_ annexB: [UInt8], key: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let renderer, let format else { return }
        // A renderer that failed, for example after the Mac slept, starts again at a key frame.
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            needKey = true
        }
        if needKey && !key { return }
        guard let sample = Self.sample(DesktopH264.avcc(annexB), format: format, key: key) else { return }
        renderer.enqueue(sample)
        if key { needKey = false }
    }

    /// The format description of an H.264 stream with 4-byte NAL unit lengths.
    static func format(sps: [UInt8], pps: [UInt8]) -> CMVideoFormatDescription? {
        guard !sps.isEmpty, !pps.isEmpty else { return nil }
        var out: CMFormatDescription?
        let status = sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: [s.baseAddress!, p.baseAddress!], parameterSetSizes: [sps.count, pps.count],
                    nalUnitHeaderLength: 4, formatDescriptionOut: &out
                )
            }
        }
        return status == noErr ? out : nil
    }

    /// A sample of 1 frame in AVCC form. It shows at once, and a frame that
    /// is not a key frame depends on the frames before it.
    static func sample(_ avcc: [UInt8], format: CMVideoFormatDescription, key: Bool) -> CMSampleBuffer? {
        guard !avcc.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = avcc.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            set(dict, kCMSampleAttachmentKey_DisplayImmediately, true)
            set(dict, kCMSampleAttachmentKey_NotSync, !key)
        }
        return sample
    }

    private static func set(_ dict: CFMutableDictionary, _ key: CFString, _ value: Bool) {
        let flag: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
        CFDictionarySetValue(dict, Unmanaged.passUnretained(key).toOpaque(), Unmanaged.passUnretained(flag).toOpaque())
    }
}
