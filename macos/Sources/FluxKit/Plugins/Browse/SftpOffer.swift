import Foundation

/// A top folder that the computer shares, like Home or Downloads.
public struct BrowseRoot: Sendable, Equatable, Hashable {
    public var name: String
    public var path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// The body of flux.sftp. The computer sends a tunnel token, the user, a
/// one-time password, and the folders that it shares.
public struct SftpOffer: Sendable, Equatable {
    /// The token of the Flux tunnel that carries the SSH session.
    public var tunnel: String
    public var user: String
    public var password: String
    public var roots: [BrowseRoot]

    /// Parses flux.sftp. It returns nil for an error answer, a packet
    /// without a tunnel, or root lists that are empty or differ in length.
    public static func parse(_ p: Packet) -> SftpOffer? {
        guard p.type == PacketType.sftp, !p.has("errorMessage"),
              let user = p.string("user"), let password = p.string("password"),
              let tunnel = p.string("tunnel"), !tunnel.isEmpty else { return nil }
        let paths = p.strings("multiPaths")
        let names = p.strings("pathNames")
        guard !paths.isEmpty, paths.count == names.count else { return nil }
        let roots = zip(names, paths).map { BrowseRoot(name: $0, path: $1) }
        return SftpOffer(tunnel: tunnel, user: user, password: password, roots: roots)
    }
}
