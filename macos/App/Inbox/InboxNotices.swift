import Accessibility
import AppKit
import FluxKit
import SwiftUI

/// The notices of the Inbox: a new pairing, the items on other computers
/// that need the user, the computers that are not reachable, and the
/// Local Network permission. Flux for macOS has no notification notice.
struct InboxNotices: View {
    let status: InboxStatus
    /// True when the large tile already tells about the new pairing.
    let pairedTile: Bool
    /// True when the status line or the large tile already tells about the computers that are not reachable.
    let offlineInLine: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let localNetworkOff = model.state.localNetworkDenied && !model.state.devices.contains(where: \.online)
        VStack(spacing: TiledMetrics.gap) {
            if let name = status.pairedName, !pairedTile {
                NoticeRow(icon: "checkmark.circle", ink: tn.green, text: "\(name) is paired. What waits for you on \(name) shows here first.")
                    .onAppear {
                        let text: String = "\(name) is paired. What waits for you on \(name) shows here first."
                        AccessibilityNotification.Announcement(text).post()
                    }
            }
            if status.elsewhere > 0 {
                NoticeRow(dot: tn.red, text: status.elsewhere == 1
                    ? "1 item on another computer needs you"
                    : "\(status.elsewhere) items on other computers need you") {
                    Button("Show all computers") { model.setScope(nil) }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                }
            }
            if let offline = status.offlineLine, !offlineInLine {
                NoticeRow(ring: true, text: offline) {
                    Button("Retry") { model.retry() }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                }
            }
            if localNetworkOff {
                NoticeRow(icon: "wifi.exclamationmark", ink: tn.yellow, text: LocalNetworkNotice.text) {
                    Button("Open System Settings") { NSWorkspace.shared.open(LocalNetworkNotice.settings) }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                }
            }
        }
    }
}

/// 1 notice: a mark, the text, and the actions at the end of the row.
private struct NoticeRow<Actions: View>: View {
    var icon: String?
    var ink: Color?
    var dot: Color?
    var ring = false
    let text: String
    let actions: Actions
    @Environment(\.tn) private var tn

    init(icon: String? = nil, ink: Color? = nil, dot: Color? = nil, ring: Bool = false, text: String,
         @ViewBuilder actions: () -> Actions) {
        self.icon = icon
        self.ink = ink
        self.dot = dot
        self.ring = ring
        self.text = text
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15))
                        .foregroundStyle(ink ?? tn.sub)
                } else if let dot {
                    Circle().fill(dot).frame(width: 8, height: 8)
                } else if ring {
                    LinkDot(online: false)
                }
            }
            .frame(width: 18)
            .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(tn.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: TiledMetrics.tileCorner, style: .continuous).fill(tn.offTile))
        .overlay(RoundedRectangle(cornerRadius: TiledMetrics.tileCorner, style: .continuous).strokeBorder(tn.line, lineWidth: 1))
    }
}

extension NoticeRow where Actions == EmptyView {
    init(icon: String? = nil, ink: Color? = nil, dot: Color? = nil, ring: Bool = false, text: String) {
        self.init(icon: icon, ink: ink, dot: dot, ring: ring, text: text) { EmptyView() }
    }
}
