#if os(iOS)
import Network
import ReplayKit
import Security
import VideoToolbox
import CoreMedia

/// Screen-mirror Broadcast Upload Extension (M5). Runs independently of
/// host-app suspension (the plan §3.2 backgrounding contract): the system
/// launches it for the broadcast picker, and it streams H.264 Annex B to
/// the desktop's `flux.screen` listener until the user stops broadcast.
///
/// Wiring (host app ↔ extension, App Group `group.org.omarchy.flux`):
/// - The host writes `screen.json` before the picker opens: the stream
///   `port`, the desktop certificate DER (pinned like every stream), and
///   the frame size from `MirrorSize.fit`.
/// - The extension reads that config in `broadcastStarted`, opens the TLS
///   client connection with the host's identity, sends nothing (the host
///   already announced `flux.screen start`), and writes Annex-B bytes from
///   `VideoToolbox` (`H264VideoEncoder` in the shared `FluxStream` module;
///   duplicated here only if the extension target cannot link it — prefer
///   linking, so the SPS/PPS-per-IDR framing stays one implementation).
/// - Audio (`RPSampleBufferType.audioApp`) is dropped: the desktop mirror
///   plays no audio (same as Android, whose mirror is video-only).
/// - No input control flows back (same as Android).
///
/// Needs a device + the broadcast entitlement; unverifiable in `swift
/// build` (the extension is an Xcode target, not an SPM one) and on the
/// simulator (no broadcast picker). See the M5 section of `ios/README.md`.
public final class SampleHandler: RPBroadcastSampleHandler {
    private var encoder: H264VideoEncoder?
    private var connection: ScreenStreamConnection?
    private var frameCount = 0

    override public func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let config = ScreenBroadcastConfig.load() else {
            finishBroadcastWithError(NSError(
                domain: "org.omarchy.flux.screen", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The screen mirror is not configured"]))
            return
        }
        let encoder = H264VideoEncoder()
        guard (try? encoder.configure(width: config.width, height: config.height, bitrate: config.bitrate)) != nil,
              let connection = ScreenStreamConnection(config: config)
        else {
            finishBroadcastWithError(NSError(
                domain: "org.omarchy.flux.screen", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The screen mirror could not start"]))
            return
        }
        encoder.onFrame = { [weak self] annexB, _ in self?.connection?.write(annexB) }
        encoder.onError = { [weak self] message in
            self?.finishBroadcastWithError(NSError(
                domain: "org.omarchy.flux.screen", code: 2,
                userInfo: [NSLocalizedDescriptionKey: message]))
        }
        self.encoder = encoder
        self.connection = connection
        frameCount = 0
    }

    override public func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        with sampleBufferType: RPSampleBufferType
    ) {
        guard sampleBufferType == .video, let encoder, let connection else { return }
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // First frame (and any resize the host asks for) opens with an IDR
        // so the desktop player joins immediately.
        if frameCount == 0 { encoder.requestKeyFrame() }
        frameCount += 1
        do {
            try encoder.encode(pixels, presentationTime: time)
        } catch {
            connection.close()
            finishBroadcastWithError(error)
        }
    }

    override public func broadcastFinished() {
        encoder?.invalidate()
        encoder = nil
        connection?.close()
        connection = nil
    }
}

/// The host-written config (`screen.json` in the App Group container).
/// `port` is the `flux.screen start` listener the desktop dials into;
/// `peerDER` pins the desktop certificate on the TLS client connection.
public struct ScreenBroadcastConfig: Sendable, Codable {
    public var port: Int
    public var host: String
    public var peerDER: Data
    public var width: Int
    public var height: Int
    public var bitrate: Int

    public static let appGroup = "group.org.omarchy.flux"
    public static let fileName = "screen.json"

    public static func load() -> ScreenBroadcastConfig? {
        guard let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup),
            let data = try? Data(contentsOf: base.appendingPathComponent(fileName)),
            let config = try? JSONDecoder().decode(ScreenBroadcastConfig.self, from: data)
        else { return nil }
        return config.port > 0 ? config : nil
    }
}

/// TLS client to the desktop's `flux.screen` listener. The desktop dials
/// the phone's listener in every other stream (Go `DialPeer`); the
/// broadcast extension instead dials out, because the extension cannot
/// receive inbound connections reliably while the host app is suspended.
/// The peer certificate must equal the paired desktop certificate
/// (`peerDER`) — the same pin the listeners enforce.
public final class ScreenStreamConnection {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "org.omarchy.flux.screen-out")

    public init?(config: ScreenBroadcastConfig) {
        let tls = NWProtocolTLS.Options()
        let peerDER = config.peerDER
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions, { _, secTrust, complete in
                let peer = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate]
                let der = peer?.first.flatMap { SecCertificateCopyData($0) as Data? }
                complete(der == peerDER)
            }, queue)
        let host = NWEndpoint.Host(config.host)
        let port = NWEndpoint.Port(rawValue: UInt16(config.port))
        guard let port else { return nil }
        connection = NWConnection(host: host, port: port, using: .init(tls: tls, tcp: .init()))
        connection.start(queue: queue)
    }

    public func write(_ bytes: Data) {
        connection.send(content: bytes, completion: .idempotent)
    }

    public func close() {
        connection.cancel()
    }
}
#else
import Foundation

/// Broadcast Upload Extensions need iOS (ReplayKit `RPBroadcastSampleHandler`
/// has no macOS equivalent). This target builds in Xcode for iOS only.
public enum BroadcastExtensionUnavailable {
    public static let reason = "The screen-mirror extension needs iOS hardware."
}
#endif
