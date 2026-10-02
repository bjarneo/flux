namespace Flux.Protocol;

// Callers serialize registry access. Cleanup must name the exact session so
// an old read loop cannot remove a newer connection to the same device.
public sealed class PeerSessions<T> where T : class
{
    private readonly Dictionary<string, T> sessions = new(StringComparer.Ordinal);
    private readonly int limit;
    public PeerSessions(int limit = 16) => this.limit = limit;
    public T? Get(string id) => sessions.GetValueOrDefault(id);
    public IReadOnlyList<T> Values => sessions.Values.ToArray();
    public bool TryAdd(string id, T session)
    {
        if (sessions.Count >= limit || sessions.ContainsKey(id)) return false;
        sessions.Add(id, session); return true;
    }
    public bool Remove(string id, T session)
    {
        if (!ReferenceEquals(Get(id), session)) return false;
        return sessions.Remove(id);
    }
    public bool Replace(string id, T previous, T next)
    {
        if (!ReferenceEquals(Get(id), previous)) return false;
        sessions[id] = next; return true;
    }
}
