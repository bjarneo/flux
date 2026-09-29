import Foundation

/// Loads the album art that a computer names. The computer chooses the URL,
/// so the load goes only to http and https, sends no cookies, keeps no
/// cache, and stops at `maxBytes`.
public enum AlbumArtLoader {
    /// The largest image that Flux loads, in bytes.
    public static let maxBytes = 4 << 20

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// Reports whether Flux loads art from the URL: http or https with a host.
    public static func loads(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !(url.host ?? "").isEmpty
    }

    /// Returns the image data, or nil for another scheme, an error, an HTTP
    /// status other than 200, or more than `maxBytes`.
    public static func load(_ url: URL) async -> Data? {
        guard loads(url) else { return nil }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            // An early return stops the download.
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.expectedContentLength <= Int64(maxBytes) else { return nil }
            // A redirect can lead to another scheme.
            guard let final = http.url, loads(final) else { return nil }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { return nil }
            }
            return data
        } catch {
            return nil
        }
    }
}
