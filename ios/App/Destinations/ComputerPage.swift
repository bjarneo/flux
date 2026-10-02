import FluxKit
import SwiftUI

/// The page of 1 paired computer under Computers: its link, its address,
/// the approval setup, and Unpair. The approval key is a trust setting of
/// the computer, so it is here and not under Control.
struct ComputerPage: View {
    let deviceId: String
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUnpair = false

    var body: some View {
        Group {
            if let d = model.device(deviceId), d.paired {
                content(d)
            } else {
                ContentUnavailableView("Not paired", systemImage: "link",
                                       description: Text("Pair with the computer again under Computers."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.device(deviceId)?.paired != true) { _, gone in
            if gone { dismiss() }
        }
    }

    private func content(_ d: DeviceSnapshot) -> some View {
        let battery = model.core.plugin(BatteryPlugin.self)?.model.computers[d.id]
        let approve = model.core.plugin(ApprovePlugin.self)
        return ScrollView {
            VStack(alignment: .leading, spacing: TiledMetrics.gap) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        LinkDot(online: d.online)
                        if d.online, let battery {
                            BatteryDot(battery)
                        }
                        Text(d.linkText(battery: battery))
                            .font(.subheadline)
                            .foregroundStyle(tn.text)
                    }
                    if !d.ip.isEmpty {
                        Text(d.ip)
                            .font(.footnote.monospaced())
                            .foregroundStyle(tn.sub)
                            .textSelection(.enabled)
                    }
                    if !d.online {
                        Text("Check that Flux runs on \(d.name), and that both are on the same Wi-Fi.")
                            .font(.footnote)
                            .foregroundStyle(tn.sub)
                        Button("Retry") { model.retry() }
                            .buttonStyle(FluxButtonStyle(kind: .text))
                            .padding(.leading, -12)
                    }
                    Button(model.scope == d.id ? "Show all computers" : "Show only \(d.name)") {
                        model.setScope(model.scope == d.id ? nil : d.id)
                    }
                    .buttonStyle(FluxButtonStyle(kind: .text))
                    .padding(.leading, -12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .tiledTile(fill: tn.tile, border: tn.line)
                if let approve, d.isFlux || approve.model.keys[d.id] != nil {
                    let texts = ApproveTexts.current
                    let waiting = approve.model.current?.computerId == d.id
                    SectionLabel("Approval")
                    ToolRow(icon: texts.symbol, title: Self.approvalTitle(texts),
                            line: ApproveTile.subtitle(user: approve.model.keys[d.id]?.user, waiting: waiting,
                                                       availability: ApprovePlugin.availability()),
                            badge: waiting ? 1 : 0) {
                        model.computersPath.append(.feature(.approve(d.id)))
                    }
                }
                SectionLabel("Pairing")
                Button("Unpair \(d.name)") { confirmUnpair = true }
                    .buttonStyle(FluxButtonStyle(kind: .destructive, fullWidth: true))
                    .frame(maxWidth: TiledMetrics.maxActionWidth)
            }
            .padding(.horizontal, TiledMetrics.gutter)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: TiledMetrics.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(d.name)
        .confirmationDialog("Unpair \(d.name)?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { model.unpair(d.id) }
        } message: {
            Text(model.unpairMessage(d))
        }
    }

    /// "Face ID approval", or "Approval" on an iPhone without biometry.
    static func approvalTitle(_ texts: ApproveTexts) -> String {
        ["Face ID", "Touch ID", "Optic ID"].contains(texts.biometry) ? "\(texts.biometry) approval" : "Approval"
    }
}
