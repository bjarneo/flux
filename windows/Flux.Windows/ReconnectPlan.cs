using System.Net;

namespace Flux.Windows;

internal static class ReconnectPlan
{
    public static DiscoveredPeer[] Targets(IEnumerable<SavedPeer> saved, IEnumerable<DiscoveredPeer> discovered,
        IReadOnlySet<string> paired, IReadOnlySet<string> connected) =>
        discovered.Concat(saved.Select(p => p.ToPeer()))
            .Where(p => paired.Contains(p.Identity.DeviceId) && !connected.Contains(p.Identity.DeviceId) &&
                !p.Address.Equals(IPAddress.None) && DiscoveryCatalog.IsLocalAddress(p.Address) && p.Port is >= 12100 and <= 12108)
            .GroupBy(p => p.Identity.DeviceId).Select(group => group.First()).Take(16).ToArray();
}
