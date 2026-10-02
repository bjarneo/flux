import AppKit
import FluxKit
import SwiftUI
import UniformTypeIdentifiers

/// Send: the tools that send to the computer in scope. Before the first
/// pairing, each tool shows dimmed, so that the page shows what it holds.
struct SendView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @State private var ask: TargetAsk?
    @State private var dropping = false

    var body: some View {
        let share = model.core.plugin(SharePlugin.self)
        let clipboard = model.core.plugin(ClipboardPlugin.self)
        let target = ToolTarget.of(model)
        let browse = ToolTarget.of(model, can: { $0.accepts(PacketType.sftpRequest) })
        ScrollView {
            VStack(alignment: .leading, spacing: TiledMetrics.gap) {
                TargetLine(verb: "Sends to")
                if let clipboard {
                    MasterTool(icon: "doc.on.clipboard", title: "Send clipboard", line: "Paste it on the computer",
                               enabled: ToolTarget.ready(target)) {
                        ToolTarget.run(target, title: "Send the clipboard to", ask: $ask) { d in
                            _ = clipboard.sendClipboard(to: d.id)
                        }
                    }
                }
                SectionLabel("Files")
                if share != nil {
                    ToolRow(icon: "doc.badge.arrow.up", title: "Send files", line: "Pick files on this Mac",
                            enabled: ToolTarget.ready(target)) {
                        ToolTarget.run(target, title: "Send files to", ask: $ask) { d in
                            ShareActions.pickFiles(to: d, model: model)
                        }
                    }
                    ToolRow(icon: "text.bubble", title: "Text and links", line: "Send text, links, and see the transfers",
                            enabled: ToolTarget.ready(target)) {
                        ToolTarget.run(target, title: "Send text and links to", ask: $ask) { d in
                            model.push(.card(.share, d.id))
                        }
                    }
                }
                if clipboard != nil {
                    // Clipboard sync applies to all computers, so the page needs no computer that is online.
                    ToolRow(icon: "arrow.left.arrow.right", title: "Clipboard", line: "Sync the clipboard with the computers",
                            enabled: !model.paired.isEmpty) {
                        if let id = model.scope ?? model.paired.first?.id { model.push(.card(.clipboard, id)) }
                    }
                }
                if model.paired.isEmpty || Inbox.hasFeature(scope: model.scope, devices: model.state.devices, can: { $0.accepts(PacketType.sftpRequest) }) {
                    ToolRow(icon: "folder", title: "Get files", line: "Open the home folder of the computer, read-only",
                            enabled: ToolTarget.ready(browse)) {
                        ToolTarget.run(browse, title: "Get files from", ask: $ask) { d in
                            BrowseWindows.shared.show(d.id, app: model)
                        }
                    }
                }
                SectionLabel("Camera")
                ForEach(CameraMode.allCases) { mode in
                    ToolRow(icon: mode.systemImage, title: mode.label, line: mode.hint, enabled: ToolTarget.ready(target)) {
                        ToolTarget.run(target, title: "Open the camera for", ask: $ask) { d in
                            CameraWindows.shared.show(d, mode: mode, app: model)
                        }
                    }
                }
                Text("To send files from Finder, drop them on this page or on the Dock icon, or select Services > Send to Flux.")
                    .font(.system(size: 12))
                    .foregroundStyle(tn.sub)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, TiledMetrics.gutter)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: TiledMetrics.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: TiledMetrics.tileCorner, style: .continuous)
                    .strokeBorder(tn.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $dropping) { providers in
            guard let share, let id = ShareActions.target(model) else { return false }
            ShareActions.drop(providers, to: id, share: share)
            return true
        }
        .targetPicker($ask)
        .destinationRoot(.send)
    }
}
