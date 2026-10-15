import FluxKit
import SwiftUI

/// Picks a folder on a computer for a new agent. It browses the folders of
/// Get files: the home folder and the usual folders, without hidden ones.
/// fluxd has 1 Get files session for each computer, so the picker shares it
/// with the Get files window, and a folder that opens here also opens there.
/// It opens at `chosen`, the chosen folder in the form of herdr. `onPick`
/// gets the folder in the same form, such as `~/Code/app`.
struct FolderBrowserSheet: View {
    let app: AppModel
    let deviceId: String
    let name: String
    let chosen: String
    let onPick: (String) -> Void
    @Environment(\.tn) private var tn
    @Environment(\.dismiss) private var dismiss
    @State private var browser: BrowseModel?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose a folder on \(name)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tn.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if let browser {
                content(browser)
            } else {
                ContentUnavailableView("Cannot browse \(name)", systemImage: "folder",
                                       description: Text("Get files is not available for \(name)."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 520, height: 560)
        .background(tn.bg)
        .onAppear { browser = BrowseWindows.shared.lease(deviceId, app: app) }
        .onDisappear { if browser != nil { BrowseWindows.shared.release(deviceId) } }
    }

    private func content(_ browser: BrowseModel) -> some View {
        let home = browser.roots.first?.path ?? ""
        let folder = browser.path.isEmpty ? "" : NewPane.homeRelative(browser.path, home: home)
        return VStack(spacing: 0) {
            crumbBar(browser)
            Divider()
            Group {
                if let error = browser.error {
                    ContentUnavailableView {
                        Label("Cannot list the folder", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { browser.retry() }
                    }
                } else if browser.loading && browser.entries.isEmpty {
                    ProgressView(browser.path.isEmpty ? "Connecting to \(name)…" : "Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    folderList(browser)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 10) {
                Text(folder.isEmpty ? " " : folder)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(tn.sub)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button("Use This Folder") {
                    onPick(folder)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(folder.isEmpty || browser.loading || browser.error != nil)
            }
            .padding(16)
        }
        .onChange(of: browser.roots, initial: true) { openChosen(browser) }
    }

    /// Opens the chosen folder when the session knows its shared folders. A
    /// folder outside them leaves the picker where Get files is.
    private func openChosen(_ browser: BrowseModel) {
        guard let home = browser.roots.first?.path,
              let path = NewPane.absoluteFolder(chosen, home: home),
              BrowsePath.root(of: path, in: browser.roots) != nil,
              path != browser.path else { return }
        browser.open(path)
    }

    /// Up, then the folders from the root down to the current one.
    private func crumbBar(_ browser: BrowseModel) -> some View {
        HStack(spacing: 4) {
            Button { browser.goUp() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(!browser.canGoUp)
                .help("Open the folder above")
                .accessibilityLabel("Up")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(browser.crumbs.enumerated()), id: \.offset) { i, crumb in
                        if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(tn.dim) }
                        Button(crumb.name) { browser.open(crumb.path) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(i == browser.crumbs.count - 1 ? tn.text : tn.sub)
                    }
                }
            }
            if browser.roots.count > 1 {
                Menu {
                    ForEach(browser.roots, id: \.path) { r in Button(r.name) { browser.open(r.path) } }
                } label: {
                    Image(systemName: "externaldrive")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Open another shared folder")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func folderList(_ browser: BrowseModel) -> some View {
        let folders = browser.entries.filter(\.dir)
        if folders.isEmpty {
            Text("No folders in here. Use this folder, or go up.")
                .font(.system(size: 12))
                .foregroundStyle(tn.sub)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(folders) { entry in
                Button { browser.open(entry.path) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill").foregroundStyle(tn.accent)
                        Text(entry.name).foregroundStyle(tn.text).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(tn.dim)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}
