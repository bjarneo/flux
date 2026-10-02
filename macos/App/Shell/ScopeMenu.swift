import FluxKit
import SwiftUI

/// The scope in the window toolbar: the name of the computer in scope or
/// "All computers", with a link dot and a battery dot for each computer, at
/// most 4. A click opens the choices. The scope filters the Inbox, Send,
/// and Control, and it picks the theme of the Computer setting.
struct ScopeMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @State private var showing = false

    var body: some View {
        let paired = model.paired
        let current = model.pairedDevice(model.scope)
        let name = current?.name ?? "All computers"
        let shown = current.map { [$0] } ?? Array(paired.prefix(4))
        let batteries = model.core.plugin(BatteryPlugin.self)?.model.computers ?? [:]
        let shape = RoundedRectangle(cornerRadius: TiledMetrics.chipCorner, style: .continuous)
        Button { showing.toggle() } label: {
            HStack(spacing: 8) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tn.text)
                    .lineLimit(1)
                ForEach(shown) { d in
                    HStack(spacing: 3) {
                        LinkDot(online: d.online)
                        if d.online, let battery = batteries[d.id] {
                            BatteryDot(battery)
                        }
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tn.sub)
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(minHeight: TiledMetrics.buttonHeight)
            .background(shape.fill(tn.tile))
            .overlay(shape.strokeBorder(tn.line, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(TilePressStyle())
        .help("Change the scope")
        .accessibilityLabel(accessibilityText(name: name, shown: shown, batteries: batteries))
        .accessibilityHint("Change the scope")
        .popover(isPresented: $showing) {
            ScopeChoices(model: model, tn: tn) { showing = false }
        }
    }

    private func accessibilityText(name: String, shown: [DeviceSnapshot], batteries: [String: BatteryState]) -> String {
        let parts = shown.map { "\($0.name): \(linkText($0, battery: batteries[$0.id]))" }
        return (["Scope: \(name)"] + parts).joined(separator: ". ")
    }
}

/// The choices of the scope: all computers, then each paired computer with
/// its link text. The current choice has a check in `accent`.
private struct ScopeChoices: View {
    let model: AppModel
    let tn: ThemeColors
    let close: () -> Void

    var body: some View {
        let batteries = model.core.plugin(BatteryPlugin.self)?.model.computers ?? [:]
        VStack(alignment: .leading, spacing: 2) {
            row(id: nil, name: "All computers", detail: model.paired.count == 1 ? "1 paired computer" : "\(model.paired.count) paired computers")
            ForEach(model.paired) { d in
                row(id: d.id, name: d.name, detail: linkText(d, battery: batteries[d.id]))
            }
        }
        .padding(6)
        .frame(width: 280)
        .background(tn.tileHi)
        .environment(\.colorScheme, tn.dark ? .dark : .light)
    }

    private func row(id: String?, name: String, detail: String) -> some View {
        let selected = model.scope == id
        return Button {
            model.setScope(id)
            close()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tn.accent)
                    .opacity(selected ? 1 : 0)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(tn.text)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(tn.sub)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: TiledMetrics.rowHeight, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: TiledMetrics.smallCorner, style: .continuous).fill(selected ? tn.accentTile : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(TilePressStyle())
        .accessibilityLabel("\(name), \(detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
