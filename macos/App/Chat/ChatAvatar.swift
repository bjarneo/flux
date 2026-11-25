import FluxKit
import SwiftUI

/// The picture of a chat: a symbol in `tint` on a square with round
/// corners. `fill` is the color of the square, `tile` by default, and
/// `edge` adds a `line` border. `badge` is the color of the dot at the
/// bottom right, or nil. `spinner` draws a ring that turns in the place of
/// the dot, for an agent that works. `ground` is the color around the dot,
/// `bg` by default. It is a port of ChatAvatar on Android, in the sizes of
/// the Mac app.
struct ChatAvatar: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 36
    var fill: Color?
    var edge = true
    var badge: Color?
    var spinner = false
    var ground: Color?
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size >= 36 ? 10 : 8, style: .continuous)
        let dot: CGFloat = size >= 36 ? 11 : 10
        let around = ground ?? tn.bg
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.46))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(shape.fill(fill ?? tn.tile))
                .overlay { if edge { shape.strokeBorder(tn.line, lineWidth: 1) } }
            if spinner {
                RingSpinner(size: dot - 3, color: tn.accent)
                    .frame(width: dot + 1, height: dot + 1)
                    .background(Circle().fill(around))
                    .offset(x: 3, y: 3)
            } else if let badge {
                Circle().fill(badge)
                    .frame(width: dot - 4, height: dot - 4)
                    .padding(2)
                    .background(Circle().fill(around))
                    .offset(x: 3, y: 3)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The picture of a computer: its symbol in `text`, with a green dot while
/// it is online. `ground` is the color around the dot.
struct ComputerAvatar: View {
    let device: DeviceSnapshot
    var size: CGFloat = 36
    var ground: Color?
    @Environment(\.tn) private var tn

    var body: some View {
        ChatAvatar(symbol: device.symbol, tint: tn.text, size: size, badge: device.online ? tn.green : nil, ground: ground)
    }
}

/// The picture of an agent in its chat: the agent symbol on `accentTile`,
/// with a dot of its status: red while it waits, green when it is done, and
/// `dim` while it is idle. While it works, a ring turns in the place of the
/// dot. `ground` is the color around the dot.
struct AgentAvatar: View {
    let status: AgentStatus?
    var size: CGFloat = 28
    var ground: Color?
    @Environment(\.tn) private var tn

    var body: some View {
        let active = status == .working || status == .blocked || status == .done
        ChatAvatar(symbol: "brain", tint: active ? tn.accent : tn.sub, size: size, fill: tn.accentTile, edge: false,
                   badge: Self.badge(status, tn), spinner: status == .working, ground: ground)
    }

    /// The color of the dot of an agent: red while it waits, green when it
    /// is done, nil while it works, and `dim` for the other states.
    static func badge(_ status: AgentStatus?, _ tn: ThemeColors) -> Color? {
        switch status {
        case .blocked: return tn.red
        case .done: return tn.green
        case .working: return nil
        default: return tn.dim
        }
    }
}
