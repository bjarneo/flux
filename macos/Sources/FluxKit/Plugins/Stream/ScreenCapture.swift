import AppKit
import ScreenCaptureKit

/// One display of this Mac.
public struct DisplayInfo: Sendable, Hashable, Identifiable {
    public let id: CGDirectDisplayID
    public let name: String
    /// The size in pixels.
    public let width: Int
    public let height: Int
}

/// Captures 1 display with ScreenCaptureKit at 30 frames per second. Each new
/// frame goes to onFrame on the capture queue. ScreenCaptureKit sends no
/// frame while the screen does not change; the encoder repeats the last one.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let accessMessage = "Flux cannot record the screen. Allow Flux in System Settings, Privacy & Security, Screen & System Audio Recording, then open Flux again."

    private let queue = DispatchQueue(label: "org.omarchy.flux.screen.frames", qos: .userInteractive)
    private let onFrame: (CVPixelBuffer) -> Void
    private let onStop: @Sendable (String) -> Void
    private let lock = NSLock()
    private var stream: SCStream?
    private var display: SCDisplay?

    init(onFrame: @escaping (CVPixelBuffer) -> Void, onStop: @escaping @Sendable (String) -> Void) {
        self.onFrame = onFrame
        self.onStop = onStop
    }

    /// True when macOS lets Flux record the screen.
    static var hasAccess: Bool { CGPreflightScreenCaptureAccess() }

    /// The displays that Flux can mirror, the main display first. A display
    /// that mirrors another one is left out.
    @MainActor
    static func displays() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[number.uint32Value] = screen.localizedName
            }
        }
        return ids.prefix(Int(count))
            .filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
            .sorted { (CGDisplayIsMain($0) != 0 ? 0 : 1, $0) < (CGDisplayIsMain($1) != 0 ? 0 : 1, $1) }
            .compactMap { id in
                guard let size = pixelSize(id) else { return nil }
                return DisplayInfo(id: id, name: names[id] ?? "Display \(id)", width: size.width, height: size.height)
            }
    }

    /// The current size of a display in pixels, or nil when it is gone.
    static func pixelSize(_ id: CGDirectDisplayID) -> (width: Int, height: Int)? {
        guard let mode = CGDisplayCopyDisplayMode(id), mode.pixelWidth > 0, mode.pixelHeight > 0 else { return nil }
        return (mode.pixelWidth, mode.pixelHeight)
    }

    /// Finds the display for ScreenCaptureKit. It fails with a message for the
    /// user when macOS does not let Flux record the screen, and then asks
    /// macOS to show its permission prompt.
    func prepare(display id: CGDirectDisplayID) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch let error as SCStreamError where error.code == .userDeclined {
            CGRequestScreenCaptureAccess()
            throw FluxError(Self.accessMessage)
        }
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw FluxError("The display is not connected") }
        lock.withLock { self.display = display }
    }

    /// Starts the capture of the prepared display at width x height pixels.
    func start(width: Int, height: Int) async throws {
        guard let display = lock.withLock({ display }) else { throw FluxError("The display is not connected") }
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: Self.configuration(width: width, height: height), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        lock.withLock { self.stream = stream }
        try await stream.startCapture()
        FluxLog.plugin.info("screen capture of display \(display.displayID) runs at \(width)x\(height)")
    }

    /// Changes the frame size of the running capture.
    func resize(width: Int, height: Int) async throws {
        guard let stream = lock.withLock({ stream }) else { return }
        try await stream.updateConfiguration(Self.configuration(width: width, height: height))
    }

    func stop() {
        guard let stream = lock.withLock({ () -> SCStream? in
            defer { self.stream = nil }
            return self.stream
        }) else { return }
        stream.stopCapture { _ in }
        FluxLog.plugin.info("screen capture stopped")
    }

    private static func configuration(width: Int, height: Int) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = width
        c.height = height
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(WebcamPackets.fps))
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        c.colorSpaceName = CGColorSpace.sRGB
        c.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        c.showsCursor = true
        c.queueDepth = 5
        return c
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = sampleBuffer.imageBuffer else { return }
        onFrame(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let current = lock.withLock { self.stream === stream }
        if current { onStop("The screen capture stopped: \(error.localizedDescription)") }
    }
}
