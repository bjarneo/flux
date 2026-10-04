import FluxKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@MainActor
enum BrowseFeature {
    /// A tap on the notification of a download opens the file with Quick Look.
    static func didLaunch() {
        Notifier.shared.register(category: BrowsePlugin.downloadCategory) { action, info, _ in
            guard action == UNNotificationDefaultActionIdentifier, let path = info[BrowsePlugin.pathKey] as? String else { return }
            let url = URL(fileURLWithPath: path)
            DispatchQueue.main.async { ShareFeature.shared.preview = url }
        }
    }
}

/// Opens the files of a computer that shares them, read-only.
struct BrowseTile: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if device.accepts(PacketType.sftpRequest), model.core.plugin(BrowsePlugin.self) != nil {
            FeatureTile("Browse files", systemImage: "folder", tint: .blue, subtitle: "Read-only, save to Files") {
                model.path.append(.feature(.browse(device.id)))
            }
            .disabled(!device.online)
        }
    }
}

/// The files of a computer: the shared folders, the folder on screen, and
/// the downloads. A tap on a folder opens it, and a tap on a file saves it
/// in Files. The session with the computer ends when the screen closes.
struct BrowseScreen: View {
    @Environment(AppModel.self) private var model
    let deviceId: String
    @State private var browser: BrowseModel?

    var body: some View {
        Group {
            if let browser {
                BrowseContent(browser: browser)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if browser == nil { browser = model.core.plugin(BrowsePlugin.self)?.browser(for: deviceId) }
        }
        .onDisappear {
            model.core.plugin(BrowsePlugin.self)?.close(deviceId)
            browser = nil
        }
    }
}

private struct BrowseContent: View {
    let browser: BrowseModel

    var body: some View {
        if browser.canSearch {
            list
                .searchable(text: Binding(get: { browser.searchText }, set: { browser.setSearchText($0) }),
                            placement: .navigationBarDrawer(displayMode: .always), prompt: Text(browser.searchPrompt))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(of: .search) { browser.search(browser.searchText) }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if browser.roots.count > 1 {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(browser.roots, id: \.path) { root in
                                let on = browser.root?.path == root.path
                                Button { browser.open(root.path) } label: {
                                    Label(root.name, systemImage: BrowseFormat.rootSymbol(root.name))
                                        .font(.subheadline.weight(.medium))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(Capsule().fill(on ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemFill)))
                                        .foregroundStyle(on ? Color.accentColor : .primary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
            }
            if !browser.downloads.isEmpty {
                Section {
                    ForEach(browser.downloads) { DownloadRow(browser: browser, item: $0) }
                } header: {
                    HStack {
                        Text("Downloads")
                        Spacer()
                        if browser.downloads.contains(where: { $0.state != .running }) {
                            Button("Clear") { browser.clearDownloads() }.font(.caption.weight(.semibold))
                        }
                    }
                }
            }
            if browser.inSearch {
                Section {
                    results
                } header: {
                    Text(browser.searchScope.isEmpty ? "All shared folders" : browser.crumbs.map(\.name).joined(separator: " › "))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textCase(nil)
                } footer: {
                    if let found = browser.found, browser.searchError == nil {
                        if found.more {
                            Text("Showing the first 100 matches. Type more of the name.")
                        } else if found.partial {
                            Text("The search stopped after 10 seconds. Search in a folder to find more.")
                        }
                    }
                }
            } else {
                Section {
                    folder
                } header: {
                    if !browser.crumbs.isEmpty {
                        Text(browser.crumbs.map(\.name).joined(separator: " › "))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .textCase(nil)
                    }
                }
            }
        }
        .refreshable { browser.retry() }
        .overlay { overlay }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if browser.inSearch {
                    if browser.searching && !(browser.found?.results.isEmpty ?? true) { ProgressView() }
                } else {
                    if browser.loading && !browser.entries.isEmpty { ProgressView() }
                    if browser.canGoUp {
                        Button { browser.goUp() } label: { Label("Up", systemImage: "arrow.up") }
                    }
                }
            }
        }
    }

    /// The files and the folders that the search found. A tap on a folder
    /// ends the search and opens the folder.
    @ViewBuilder
    private var results: some View {
        if browser.searchError == nil {
            ForEach(browser.found?.results ?? []) { entry in
                Button { browser.activate(entry) } label: { EntryRow(entry: entry, place: browser.location(of: entry)) }
                    .tint(.primary)
                    .contextMenu {
                        if entry.dir {
                            Button("Open", systemImage: "folder") { browser.open(entry.path) }
                        } else {
                            Button("Download", systemImage: "arrow.down.circle") { browser.download(entry) }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var folder: some View {
        if browser.error == nil {
            ForEach(browser.entries) { entry in
                Button { browser.activate(entry) } label: { EntryRow(entry: entry) }
                    .tint(.primary)
                    .contextMenu {
                        if entry.dir {
                            Button("Open", systemImage: "folder") { browser.open(entry.path) }
                        } else {
                            Button("Download", systemImage: "arrow.down.circle") { browser.download(entry) }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        if let error = browser.error {
            ContentUnavailableView {
                Label("Cannot open the files", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { browser.retry() }
            }
        } else if browser.inSearch {
            searchOverlay
        } else if browser.loading && browser.entries.isEmpty {
            ProgressView("Opening the files of \(browser.deviceName)…")
        } else if browser.entries.isEmpty {
            ContentUnavailableView("This folder is empty", systemImage: "folder", description: Text("Go up to open another folder."))
        }
    }

    /// The state of a search without results: the wait, the error, or no match.
    @ViewBuilder
    private var searchOverlay: some View {
        if let error = browser.searchError {
            ContentUnavailableView {
                Label("Cannot search", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { browser.retry() }
            }
        } else if browser.found?.results.isEmpty ?? true {
            if browser.searching {
                ProgressView("Searching…")
            } else {
                ContentUnavailableView {
                    Label("No file or folder has \"\(browser.query)\"", systemImage: "magnifyingglass")
                } description: {
                    Text("Type another part of the name, or search in another folder.")
                }
            }
        }
    }
}

/// One entry of a folder: its icon, name, size, and date. A search result
/// shows its place in place of the date.
private struct EntryRow: View {
    let entry: BrowseEntry
    var place: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: BrowseFormat.symbol(entry))
                .font(.system(size: 18))
                .foregroundStyle(entry.dir ? Color.accentColor : .secondary)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(place.map { BrowseFormat.found(entry, place: $0) } ?? BrowseFormat.details(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: entry.dir ? "chevron.right" : "arrow.down.circle")
                .font(entry.dir ? .caption.weight(.semibold) : .body)
                .foregroundStyle(entry.dir ? Color(.tertiaryLabel) : Color.accentColor)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(entry.dir ? "Opens the folder" : "Saves the file in Files")
    }
}

/// One download: its progress, or Quick Look and the share sheet when it is done.
private struct DownloadRow: View {
    let browser: BrowseModel
    let item: BrowseDownload

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: BrowseFormat.symbol(BrowseEntry(name: item.name, path: item.name, dir: false, size: item.size)))
                .foregroundStyle(.secondary)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                switch item.state {
                case .running:
                    if let fraction = item.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                    Text("\(BrowseFormat.bytes(item.received)) of \(BrowseFormat.bytes(item.size))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                case .done:
                    Text("\(BrowseFormat.bytes(item.size)) · Saved in Files").font(.caption).foregroundStyle(.secondary)
                case .failed(let reason):
                    Text(reason).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            switch item.state {
            case .running:
                Button { browser.cancel(item.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Stop the download")
            case .done(let url):
                Button { ShareFeature.shared.preview = url } label: { Image(systemName: "eye") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Quick Look")
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Share")
            case .failed:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }
}

/// Icons, sizes, and dates of remote entries.
enum BrowseFormat {
    static func type(_ entry: BrowseEntry) -> UTType {
        if entry.dir { return .folder }
        let ext = (entry.name as NSString).pathExtension
        return ext.isEmpty ? .data : UTType(filenameExtension: ext) ?? .data
    }

    static func symbol(_ entry: BrowseEntry) -> String {
        if entry.dir { return "folder.fill" }
        let t = type(entry)
        if t.conforms(to: .image) { return "photo" }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return "film" }
        if t.conforms(to: .audio) { return "music.note" }
        if t.conforms(to: .pdf) { return "doc.richtext" }
        if t.conforms(to: .archive) { return "doc.zipper" }
        if t.conforms(to: .sourceCode) || t.conforms(to: .script) || t.conforms(to: .shellScript) {
            return "chevron.left.forwardslash.chevron.right"
        }
        if t.conforms(to: .text) { return "doc.text" }
        return "doc"
    }

    /// The size and the date of a file, or the date of a folder.
    static func details(_ entry: BrowseEntry) -> String {
        let date = entry.modified?.formatted(date: .abbreviated, time: .shortened)
        let parts = [entry.dir ? "Folder" : bytes(entry.size), date].compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    /// The place and the size of a search result, or the place of a folder.
    static func found(_ entry: BrowseEntry, place: String) -> String {
        entry.dir ? place : "\(place) · \(bytes(entry.size))"
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    static func rootSymbol(_ name: String) -> String {
        switch name.lowercased() {
        case "home": "house"
        case "downloads": "arrow.down.circle"
        case "documents": "doc"
        case "pictures": "photo"
        case "music": "music.note"
        case "videos": "film"
        default: "folder"
        }
    }
}
