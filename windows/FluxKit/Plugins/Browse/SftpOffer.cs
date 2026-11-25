namespace FluxKit;

// The body of flux.sftp. The computer sends a tunnel token, the user, a
// one-time password, and the folders that it shares. Search is true when
// the computer can search the names in its shared folders.
public sealed record SftpOffer(string Tunnel, string User, string Password, ValueList<BrowseRoot> Roots, bool Search = false)
{
    // Parses flux.sftp. It returns null for an error answer, a packet
    // without a tunnel, or root lists that are empty or differ in length.
    public static SftpOffer? Parse(Packet p)
    {
        if (p.Type != PacketType.Sftp || p.Has("errorMessage") ||
            p.String("user") is not { } user || p.String("password") is not { } password ||
            p.String("tunnel") is not { Length: > 0 } tunnel)
        {
            return null;
        }
        var paths = p.Strings("multiPaths");
        var names = p.Strings("pathNames");
        if (paths.Count == 0 || paths.Count != names.Count)
        {
            return null;
        }
        var roots = names.Zip(paths, (name, path) => new BrowseRoot(name, path));
        return new SftpOffer(tunnel, user, password, ValueList.From(roots), p.Bool("search") ?? false);
    }
}
