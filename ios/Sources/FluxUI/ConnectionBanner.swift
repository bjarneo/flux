import SwiftUI

/// M7 background-reconnect UX (`docs/ios-plan.md` §3.2): iOS suspends the
/// LAN link ~30 s after backgrounding. The app never fakes presence — it
/// shows an honest banner instead, mirroring Android's "Turn off Flux"
/// semantics. `flux status` on the desktop shows offline, which is correct.
///
/// The Xcode project wires a live presence source later; `ContentView` takes
/// a value so the seam is ready and previews/screenshots can show each state.
public enum LinkPresence: String, Sendable, Equatable, CaseIterable {
    case connected
    case reconnecting
    case suspended
    case offline

    /// Only `connected` hides the banner.
    public var showsBanner: Bool { self != .connected }

    public var bannerTitle: String {
        switch self {
        case .connected: return ""
        case .reconnecting: return "Reconnecting…"
        case .suspended: return "Background suspended"
        case .offline: return "No computers online"
        }
    }

    public var bannerMessage: String {
        switch self {
        case .connected: return ""
        case .reconnecting: return "Re-announcing on the local network."
        case .suspended:
            return "Open Flux to stay connected. Your computer shows this phone as offline."
        case .offline: return "Open Flux on your computer on the same Wi-Fi."
        }
    }
}

/// Display-only banner for a non-connected `LinkPresence`. Renders nothing
/// when connected.
public struct ConnectionBanner: View {
    public var presence: LinkPresence

    public init(presence: LinkPresence) {
        self.presence = presence
    }

    public var body: some View {
        if presence.showsBanner {
            HStack(spacing: 12) {
                Image(systemName: presence == .reconnecting ? "arrow.triangle.2.circlepath" : "wifi.slash")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(presence.bannerTitle)
                        .font(.subheadline)
                        .bold()
                    Text(presence.bannerMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(presence.bannerTitle). \(presence.bannerMessage)")
        }
    }
}

#Preview("Banner suspended") {
    ConnectionBanner(presence: .suspended)
        .padding()
}

#Preview("Banner reconnecting") {
    ConnectionBanner(presence: .reconnecting)
        .padding()
}

#Preview("Banner offline") {
    ConnectionBanner(presence: .offline)
        .padding()
}
