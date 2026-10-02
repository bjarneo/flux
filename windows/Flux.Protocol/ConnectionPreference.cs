namespace Flux.Protocol;

public static class ConnectionPreference
{
    // Match Go lan.Preferred: both ends retain the socket opened by the
    // lexically larger device ID when dials cross within five seconds.
    public static bool KeepExisting(bool oldOutgoing, bool nextOutgoing,
        TimeSpan oldAge, string selfId, string peerId)
    {
        if (oldAge > TimeSpan.FromSeconds(5)) return false;
        var larger = string.CompareOrdinal(selfId, peerId) > 0 ? selfId : peerId;
        return (oldOutgoing ? selfId : peerId) == larger &&
            (nextOutgoing ? selfId : peerId) != larger;
    }
}
