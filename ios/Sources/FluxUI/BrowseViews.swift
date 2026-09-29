import SwiftUI
import FluxProto

/// Browse-files screen: the desktop's shared folders, read-only.
/// Ports Android `ui/RemoteScreens.kt BrowseScreen`: roots chips, folder
/// navigation with up-row, tap-a-file downloads into Downloads.
/// State + closures (no backend); previews carry fixtures.
public struct BrowseScreen: View {
    public var computer: String
    public var online: Bool
    public var state: BrowseViewState
    public var onOpen: () -> Void
    public var onClose: () -> Void
    public var onBrowse: (String) -> Void
    public var onDownload: (BrowseEntry) -> Void

    public init(
        computer: String, online: Bool = true,
        state: BrowseViewState = BrowseViewState(),
        onOpen: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {},
        onBrowse: @escaping (String) -> Void = { _ in },
        onDownload: @escaping (BrowseEntry) -> Void = { _ in }
    ) {
        self.computer = computer
        self.online = online
        self.state = state
        self.onOpen = onOpen
        self.onClose = onClose
        self.onBrowse = onBrowse
        self.onDownload = onDownload
    }

    /// Up-navigation is offered unless the current path is one of the
    /// roots (Android `atRoot` parity).
    var canGoUp: Bool {
        !state.path.isEmpty && !state.roots.map(\.path).contains(state.path)
    }

    public var body: some View {
        Group {
            if !online {
                VStack(alignment: .leading, spacing: 8) {
                    Text("On \(computer)").foregroundStyle(.secondary)
                    Text("Browsing needs a connection.").foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let error = state.error {
                VStack(alignment: .leading, spacing: 8) {
                    Text("On \(computer)").foregroundStyle(.secondary)
                    Text("Cannot open the files").font(.headline).padding(.top, 24)
                    Text(error).foregroundStyle(.secondary)
                    Button("Try again") { onOpen() }
                        .padding(.top, 4)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if state.loading, state.entries.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("On \(computer)").foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading the files of \(computer)").foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if state.entries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("On \(computer)").foregroundStyle(.secondary)
                    Text("This folder is empty").font(.headline).padding(.top, 32)
                    Text("Go back to open another folder.").foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                // The file list is the root scroll view so the large title
                // collapses on scroll and the bottom safe-area inset applies
                // to the rows (a List inside a VStack leaves the tall gap
                // above the title and clips the last row). Chips + path stay
                // pinned above via safeAreaInset.
                List {
                    if canGoUp {
                        Button {
                            onBrowse(browseParentPath(state.path))
                        } label: {
                            Label("Up", systemImage: "chevron.up")
                        }
                    }
                    ForEach(state.entries, id: \.path) { entry in
                        if entry.dir {
                            Button { onBrowse(entry.path) } label: {
                                Label {
                                    Text(entry.name)
                                } icon: {
                                    Image(systemName: "folder")
                                }
                            }
                        } else {
                            HStack {
                                Label {
                                    VStack(alignment: .leading) {
                                        Text(entry.name)
                                        Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: Self.icon(for: entry))
                                }
                                Spacer()
                                Button { onDownload(entry) } label: {
                                    Image(systemName: "arrow.down.circle")
                                }
                                .accessibilityLabel("Download \(entry.name)")
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("On \(computer)")
                            .foregroundStyle(.secondary)
                        if state.roots.count > 1 {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(state.roots, id: \.path) { root in
                                        Button(root.name) { onBrowse(root.path) }
                                            .buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                        if state.loading {
                            ProgressView()
                        }
                        Text(state.path.isEmpty ? " " : state.path)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
                }
            }
        }
        .navigationTitle("Browse files")
        .onAppear(perform: onOpen)
        .onDisappear(perform: onClose)
    }

    static func icon(for entry: BrowseEntry) -> String {
        switch browseKind(name: entry.name, dir: entry.dir) {
        case .folder: return "folder"
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "music.note"
        case .pdf: return "doc.richtext"
        case .text: return "doc.text"
        case .archive: return "archivebox"
        case .apk: return "app.badge"
        case .iso: return "opticaldisc"
        case .file: return "doc"
        }
    }
}

#Preview {
    BrowseScreen(
        computer: "archlinux",
        state: BrowseViewState(
            loading: false,
            roots: [BrowseRoot(name: "Home", path: "/home/ed"),
                    BrowseRoot(name: "Downloads", path: "/home/ed/Downloads")],
            path: "/home/ed",
            entries: [
                BrowseEntry(name: "Documents", path: "/home/ed/Documents", dir: true, size: 96),
                BrowseEntry(name: "notes.txt", path: "/home/ed/notes.txt", dir: false, size: 1234),
                BrowseEntry(name: "scan.pdf", path: "/home/ed/scan.pdf", dir: false, size: 2427723),
            ]))
}

#Preview {
    BrowseScreen(computer: "archlinux")
}

#Preview {
    BrowseScreen(
        computer: "archlinux",
        state: BrowseViewState(
            loading: false,
            error: "Browsing is off on this computer. Set share_home = true in ~/.config/flux/config.toml"))
}
