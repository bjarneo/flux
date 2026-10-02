import FluxKit
import SwiftUI

/// The scope chip in the navigation bar of each tab root: "All computers"
/// or 1 computer, with a link dot and a battery dot for each computer in
/// scope, at most 4. A tap opens the menu of scopes. The scope filters the
/// Inbox, Send, and Control, and it picks the computer theme.
struct ScopeChip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let paired = model.paired
        let current = paired.first { $0.id == model.scope }
        let shown = Array((current.map { [$0] } ?? paired).prefix(4))
        let name = current?.name ?? "All computers"
        let batteries = model.core.plugin(BatteryPlugin.self)?.model.computers ?? [:]
        let spoken = (["Scope: \(name)"] + shown.map { "\($0.name): \($0.linkText(battery: batteries[$0.id]))" }).joined(separator: ". ")
        Menu {
            Picker("Scope", selection: Binding(get: { model.scope }, set: { model.setScope($0) })) {
                Label("All computers", systemImage: "laptopcomputer.and.iphone")
                    .tag(String?.none)
                ForEach(paired) { d in
                    Label {
                        Text(d.name)
                        Text(d.linkText(battery: batteries[d.id]))
                    } icon: {
                        Image(systemName: d.symbol)
                    }
                    .tag(String?.some(d.id))
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
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
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tn.sub)
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(minHeight: 36)
            .background(tileShape(TiledMetrics.chipCorner).fill(tn.tile))
            .overlay(tileShape(TiledMetrics.chipCorner).strokeBorder(tn.line, lineWidth: 1))
            .contentShape(tileShape(TiledMetrics.chipCorner))
            // The chip draws 36 pt high to fit the navigation bar. The hit area is 44 pt high.
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(spoken)
        .accessibilityHint("Changes the scope")
    }
}

extension DeviceSnapshot {
    /// The link and the battery of a computer in words, for VoiceOver and the scope menu.
    func linkText(battery: BatteryState?) -> String {
        guard online else { return "Not reachable" }
        guard let battery else { return "Connected" }
        return "Connected, battery \(battery.charge)%" + (battery.charging ? ", charging" : "")
    }
}
