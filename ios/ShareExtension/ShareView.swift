import SwiftUI

/// Send with Flux: what goes out, the computer to send it to, and the
/// message that Flux sends it when it opens.
struct ShareView: View {
    @Bindable var composer: ShareComposer

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Send with Flux")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch composer.phase {
        case .choosing, .queueing:
            form
        case .queued(let name):
            ContentUnavailableView {
                Label {
                    Text("Queued for \(name)")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } description: {
                Text("Flux sends this to \(name) when you open Flux.")
            }
        case .failed(let message):
            ContentUnavailableView("Flux could not queue this", systemImage: "exclamationmark.triangle", description: Text(message))
        }
    }

    private var form: some View {
        Form {
            Section("Send") {
                Label(ShareSummary.text(composer.summary), systemImage: symbol)
                if let preview = composer.preview {
                    Text(preview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }
            Section {
                if !composer.hasQueue {
                    Text("This build of Flux has no App Group, so it cannot keep items to send.")
                        .foregroundStyle(.secondary)
                } else if composer.computers.isEmpty {
                    Text("Pair a computer in Flux first.")
                        .foregroundStyle(.secondary)
                }
                ForEach(composer.computers) { computer in
                    ComputerRow(computer: computer, chosen: composer.chosen == computer.id) { composer.chosen = computer.id }
                }
            } header: {
                Text("To")
            } footer: {
                Text("The share sheet cannot connect to your computers. Flux sends what you share when you open it.")
            }
        }
        .disabled(composer.phase == .queueing)
    }

    private var symbol: String {
        let s = composer.summary
        if s.count == s.photos { return "photo" }
        if s.count == s.videos { return "video" }
        if s.count == s.links { return "link" }
        if s.count == s.texts { return "text.alignleft" }
        return "doc"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch composer.phase {
        case .choosing, .queueing:
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { composer.cancel() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if composer.phase == .queueing {
                    ProgressView()
                } else {
                    Button("Send") { composer.send() }
                        .disabled(!composer.canSend)
                }
            }
        case .queued:
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { composer.finish?(true) }
            }
        case .failed:
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { composer.finish?(false) }
            }
        }
    }
}

/// A paired computer with the time that Flux last saw it connected.
private struct ComputerRow: View {
    let computer: SharedComputer
    let chosen: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 12) {
                Image(systemName: DeviceSymbol.name(computer.type))
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(computer.name)
                        .foregroundStyle(.primary)
                    Text(seen)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if chosen {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(.primary)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private var seen: String {
        guard let date = computer.lastOnline else { return "Not connected yet" }
        if computer.online { return "Connected when Flux was last open" }
        return "Connected " + date.formatted(.relative(presentation: .named))
    }
}
