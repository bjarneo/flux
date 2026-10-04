import AppKit
import FluxKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The content of a browse window: a path bar, the folder, and the downloads.
struct BrowseView: View {
    let browser: BrowseModel
    @State private var selection = Set<BrowseEntry.ID>()
    @State private var preview: URL?

    var body: some View {
        VStack(spacing: 0) {
            BrowseBar(browser: browser)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !browser.downloads.isEmpty {
                Divider()
                BrowseDownloads(browser: browser, preview: $preview)
            }
        }
        .frame(minWidth: 560, minHeight: 360)
        .quickLookPreview($preview)
        .onChange(of: browser.path) { selection = [] }
        .onChange(of: browser.query) { selection = [] }
        .onExitCommand { if browser.inSearch { browser.endSearch() } }
    }

    @ViewBuilder
    private var content: some View {
        if let error = browser.error {
            ContentUnavailableView {
                Label("Cannot open the files", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { browser.retry() }
            }
        } else if browser.inSearch {
            search
        } else if browser.loading && browser.entries.isEmpty {
            ProgressView("Opening the files of \(browser.deviceName)…")
        } else if browser.entries.isEmpty {
            ContentUnavailableView("This folder is empty", systemImage: "folder", description: Text("Go up to open another folder."))
        } else {
            table
        }
    }

    /// The search results, or the wait, the error, or no match.
    @ViewBuilder
    private var search: some View {
        if let error = browser.searchError {
            ContentUnavailableView {
                Label("Cannot search", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { browser.retry() }
            }
        } else if let found = browser.found, !found.results.isEmpty {
            VStack(spacing: 0) {
                results(found.results)
                if found.more || found.partial {
                    Divider()
                    Text(found.more ? "Showing the first 100 matches. Type more of the name."
                                    : "The search stopped after 10 seconds. Search in a folder to find more.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
            }
        } else if browser.searching {
            ProgressView("Searching…")
        } else {
            ContentUnavailableView {
                Label("No file or folder has \"\(browser.query)\"", systemImage: "magnifyingglass")
            } description: {
                Text("Type another part of the name, or search in another folder.")
            }
        }
    }

    /// The files and the folders that the search found, with the folder
    /// that holds each one. Opening a folder ends the search.
    private func results(_ found: [BrowseEntry]) -> some View {
        actions(Table(found, selection: $selection) {
            TableColumn("Name") { entry in
                Label {
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(nsImage: BrowseFormat.icon(entry))
                        .resizable()
                        .frame(width: 16, height: 16)
                }
            }
            TableColumn("Place") { entry in
                Text(browser.location(of: entry))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .width(min: 120, ideal: 240)
            TableColumn("Size") { entry in
                Text(entry.dir ? "--" : BrowseFormat.bytes(entry.size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 90, max: 120)
        }, rows: found)
    }

    private var table: some View {
        actions(Table(browser.entries, selection: $selection) {
            TableColumn("Name") { entry in
                Label {
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(nsImage: BrowseFormat.icon(entry))
                        .resizable()
                        .frame(width: 16, height: 16)
                }
            }
            TableColumn("Size") { entry in
                Text(entry.dir ? "--" : BrowseFormat.bytes(entry.size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 90, max: 120)
            TableColumn("Kind") { entry in
                Text(BrowseFormat.kind(entry)).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 150, max: 240)
        }, rows: browser.entries)
    }

    /// The context menu and the double click of a table of entries.
    private func actions(_ table: some View, rows: [BrowseEntry]) -> some View {
        table.contextMenu(forSelectionType: BrowseEntry.ID.self) { ids in
            let chosen = entries(ids, in: rows)
            if chosen.count == 1, let entry = chosen.first, entry.dir {
                Button("Open") { browser.open(entry.path) }
            }
            let files = chosen.filter { !$0.dir }
            if !files.isEmpty {
                Button(files.count == 1 ? "Download" : "Download \(files.count) Files") {
                    files.forEach(browser.download)
                }
            }
        } primaryAction: { ids in
            let chosen = entries(ids, in: rows)
            if chosen.count == 1, let entry = chosen.first {
                browser.activate(entry)
            } else {
                chosen.filter { !$0.dir }.forEach(browser.download)
            }
        }
    }

    private func entries(_ ids: Set<BrowseEntry.ID>, in rows: [BrowseEntry]) -> [BrowseEntry] {
        rows.filter { ids.contains($0.id) }
    }
}

/// Back, the folders from the root, the roots, the search, and reload.
private struct BrowseBar: View {
    let browser: BrowseModel

    var body: some View {
        HStack(spacing: 8) {
            Button { browser.goUp() } label: { Image(systemName: "chevron.left") }
                .disabled(!browser.canGoBack)
                .help(browser.inSearch ? "End the search" : "Enclosing folder")
                .keyboardShortcut(.upArrow, modifiers: .command)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(browser.crumbs.enumerated()), id: \.element.path) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                        }
                        Button(crumb.name) { browser.open(crumb.path) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(index == browser.crumbs.count - 1 ? .primary : .secondary)
                            .lineLimit(1)
                    }
                }
            }
            if browser.inSearch ? (browser.searching && !(browser.found?.results.isEmpty ?? true)) : (browser.loading && !browser.entries.isEmpty) {
                ProgressView().controlSize(.small)
            }
            if browser.canSearch {
                BrowseSearchField(browser: browser)
            }
            if browser.roots.count > 1 {
                Menu {
                    ForEach(browser.roots, id: \.path) { root in
                        Button { browser.open(root.path) } label: {
                            Label(root.name, systemImage: BrowseFormat.rootSymbol(root.name))
                        }
                    }
                } label: {
                    Label(browser.root?.name ?? "Places", systemImage: BrowseFormat.rootSymbol(browser.root?.name ?? ""))
                }
                .fixedSize()
                .help("Folders that \(browser.deviceName) shares")
            }
            Button { browser.retry() } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload")
                .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// The search field of the window. Return searches at once, and Escape
/// ends the search.
private struct BrowseSearchField: View {
    let browser: BrowseModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(browser.searchPrompt, text: Binding(get: { browser.searchText }, set: { browser.setSearchText($0) }))
                .textFieldStyle(.plain)
                .onSubmit { browser.search(browser.searchText) }
                .onExitCommand { browser.endSearch() }
            if !browser.searchText.isEmpty {
                Button { browser.endSearch() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
                    .help("Clear the search")
            }
        }
        .padding(.horizontal, 6)
        .frame(width: 220, height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary))
    }
}

/// The downloads of the window, with Quick Look, Open, and Show in Finder.
private struct BrowseDownloads: View {
    let browser: BrowseModel
    @Binding var preview: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Clear") { browser.clearDownloads() }
                    .buttonStyle(.borderless)
                    .disabled(browser.downloads.count == browser.activeDownloads)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(browser.downloads.reversed()) { item in
                        row(item)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)
        }
        .background(.bar)
    }

    private func row(_ item: BrowseDownload) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: BrowseFormat.icon(BrowseEntry(name: item.name, path: item.name, dir: false, size: item.size)))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                switch item.state {
                case .running:
                    if let fraction = item.fraction {
                        ProgressView(value: fraction).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                    Text("\(BrowseFormat.bytes(item.received)) of \(BrowseFormat.bytes(item.size))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                case .done:
                    Text("\(BrowseFormat.bytes(item.size)) · Saved in Downloads").font(.caption).foregroundStyle(.secondary)
                case .failed(let reason):
                    Text(reason).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            switch item.state {
            case .running:
                Button { browser.cancel(item.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Stop the download")
            case .done(let url):
                Button { preview = url } label: { Image(systemName: "eye") }
                    .buttonStyle(.borderless)
                    .help("Quick Look")
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.borderless)
                    .help("Open")
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
            case .failed:
                EmptyView()
            }
        }
    }
}

/// Icons, kinds, and sizes of remote entries.
private enum BrowseFormat {
    static func type(_ entry: BrowseEntry) -> UTType {
        if entry.dir { return .folder }
        let ext = (entry.name as NSString).pathExtension
        return ext.isEmpty ? .data : UTType(filenameExtension: ext) ?? .data
    }

    static func icon(_ entry: BrowseEntry) -> NSImage { NSWorkspace.shared.icon(for: type(entry)) }

    static func kind(_ entry: BrowseEntry) -> String {
        entry.dir ? "Folder" : type(entry).localizedDescription ?? "Document"
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
