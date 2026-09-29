import SwiftUI
import Foundation
import FluxCore
#if canImport(QuickLook)
import QuickLook
#endif

/// One received file in `Application Support/Downloads/` (browse
/// downloads + desktop-to-phone sends land here via `TransferEngine`).
/// The bytes were always arriving — but nothing in the app surfaced
/// them, so received files were stranded in the sandbox (device
/// 2026-09-29: "no way to find them and do something with them").
public struct DownloadedFile: Identifiable, Equatable, Sendable {
    public var name: String
    public var path: String
    public var size: Int64
    public var modified: Date

    public init(name: String, path: String, size: Int64, modified: Date) {
        self.name = name
        self.path = path
        self.size = size
        self.modified = modified
    }

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path) }
}

/// Lists + deletes the receive folder (pure Foundation, unit-tested).
/// The directory is a parameter so tests never touch the real folder.
public enum DownloadsStore {
    public static func list(
        directory: URL = TransferEngine.defaultDownloadsDirectory()
    ) -> [DownloadedFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles])
        else { return [] }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { return nil }
            return DownloadedFile(
                name: url.lastPathComponent,
                path: url.path,
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast)
        }
        .sorted {
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Deletes one listed file. Refuses paths outside the receive
    /// folder (never delete user files on a stale path).
    @discardableResult
    public static func remove(
        _ file: DownloadedFile,
        in directory: URL = TransferEngine.defaultDownloadsDirectory()
    ) -> Bool {
        let dir = directory.standardizedFileURL.path
        let target = file.url.standardizedFileURL.path
        guard target.hasPrefix(dir + "/") else { return false }
        do {
            try FileManager.default.removeItem(atPath: target)
            return true
        } catch {
            return false
        }
    }
}

/// Downloads screen: received files with preview + share + delete.
/// State + closures (no backend); previews carry fixtures. Preview and
/// share ride UIKit bridges (free-tier-safe: no extension, no App
/// Group) and compile out on macOS — the sim runs the real UI.
public struct DownloadsScreen: View {
    public var files: [DownloadedFile]
    public var onRefresh: () -> Void
    public var onDelete: (DownloadedFile) -> Void

    public init(
        files: [DownloadedFile] = [],
        onRefresh: @escaping () -> Void = {},
        onDelete: @escaping (DownloadedFile) -> Void = { _ in }
    ) {
        self.files = files
        self.onRefresh = onRefresh
        self.onDelete = onDelete
    }

    public var body: some View {
        Group {
            if files.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Files from your computers").foregroundStyle(.secondary)
                    Text("Nothing here yet").font(.headline).padding(.top, 32)
                    Text("Browse a computer's files or send one with `flux send` — it lands here.")
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                // Root List: collapses the large title and insets the last
                // row above the home indicator (VStack-wrapped List clips it).
                List {
                    ForEach(files) { file in
                        DownloadRow(
                            file: file,
                            onDelete: { onDelete(file) }
                        )
                    }
                }
                .listStyle(.plain)
                .safeAreaInset(edge: .top, spacing: 0) {
                    Text("Files from your computers")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.bar)
                }
            }
        }
        .navigationTitle("Downloads")
        .onAppear { onRefresh() }
    }
}

/// One received file: preview on tap, share + delete buttons.
/// The UIKit sheets live on the row so many files never collide.
private struct DownloadRow: View {
    var file: DownloadedFile
    var onDelete: () -> Void
    @State private var preview: SheetFile?
    @State private var share: SheetFile?

    var body: some View {
        HStack {
            Button {
#if os(iOS)
                preview = SheetFile(file: file)
#endif
            } label: {
                Label {
                    VStack(alignment: .leading) {
                        Text(file.name)
                        Text("\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)) · \(file.modified.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: Self.icon(for: file.name))
                }
            }
            .buttonStyle(.plain)
            Spacer()
#if os(iOS)
            Button { share = SheetFile(file: file) } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share \(file.name)")
            .buttonStyle(.borderless)
#endif
            Button(role: .destructive) { onDelete() } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Delete \(file.name)")
            .buttonStyle(.borderless)
        }
#if os(iOS)
        .sheet(item: $preview) { item in
            QuickLookPreview(url: item.url)
                .ignoresSafeArea()
        }
        .sheet(item: $share) { item in
            ActivitySheet(url: item.url)
        }
#endif
    }

    /// SF Symbol by extension (mirrors the browse download icons).
    static func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "gif", "webp": "photo"
        case "pdf": "doc.richtext"
        case "txt", "md", "log": "doc.text"
        case "zip", "tar", "gz": "archivebox"
        case "mp3", "wav", "m4a", "ogg": "music.note"
        case "mp4", "mov", "m4v": "film"
        default: "doc"
        }
    }
}

/// Sheet identity: one file per presentation (rows never share sheets).
private struct SheetFile: Identifiable {
    var id: String { file.path }
    var url: URL { file.url }
    private var file: DownloadedFile

    init(file: DownloadedFile) {
        self.file = file
    }
}

#if os(iOS)
/// System preview (tap a download to view it).
private struct QuickLookPreview: UIViewControllerRepresentable {
    var url: URL

    func makeCoordinator() -> DataSource { DataSource(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    /// Retained by the coordinator (the controller holds it weakly).
    final class DataSource: NSObject, QLPreviewControllerDataSource {
        private let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            url as NSURL
        }
    }
}

/// System share sheet: Save to Files, AirDrop, Open In, print, …
private struct ActivitySheet: UIViewControllerRepresentable {
    var url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // iPad popovers need an anchor: the sheet itself, no arrow.
        if UIDevice.current.userInterfaceIdiom == .pad,
           let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(
                x: controller.view.bounds.midX, y: controller.view.bounds.midY,
                width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

#Preview("Downloads with files") {
    DownloadsScreen(files: [
        DownloadedFile(name: "flux-master.zip", path: "/tmp/flux-master.zip", size: 614_219, modified: Date()),
        DownloadedFile(name: "IMG_9055.PNG", path: "/tmp/IMG_9055.PNG", size: 66_598, modified: Date().addingTimeInterval(-3600)),
        DownloadedFile(name: "scan-2026-09-28.txt", path: "/tmp/scan.txt", size: 57, modified: Date().addingTimeInterval(-7200)),
    ])
}

#Preview("Downloads empty") {
    DownloadsScreen()
}
