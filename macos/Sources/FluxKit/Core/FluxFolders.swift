import Foundation

/// The folders that Flux saves files in.
enum FluxFolders {
    #if os(macOS)
    /// ~/Downloads, for received and downloaded files.
    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// The name of the downloads folder in messages.
    static let downloadsName = "Downloads"
    #else
    /// The Documents folder of the app, for received and downloaded files.
    /// The Files app shows it under On My iPhone. iOS creates it with the app.
    static var downloads: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// The name of the place where received files show, in messages.
    static let downloadsName = "Files"
    #endif
}
