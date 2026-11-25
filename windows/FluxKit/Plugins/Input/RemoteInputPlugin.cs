using System.Collections.Immutable;

namespace FluxKit;

// The last flux.input of 1 computer. Desktop is null when an older fluxd
// does not report it.
public sealed record RemoteInputState(bool Enabled, bool? Desktop, bool KeyRepeat);

// Whether each computer accepts remote input and shows its screen, for the
// UI.
public sealed class RemoteInputModel : Model
{
    ImmutableDictionary<string, RemoteInputState> states = ImmutableDictionary<string, RemoteInputState>.Empty;

    // The last flux.input of each computer. A computer that has not told
    // this computer yet has no entry.
    public ImmutableDictionary<string, RemoteInputState> States
    {
        get => states;
        private set => Set(ref states, value);
    }

    // The enabled field of the last flux.input, or null before the first.
    public bool? Enabled(string deviceId) => states.TryGetValue(deviceId, out var s) ? s.Enabled : null;

    // True when remote input is on at the computer.
    public bool IsOn(string deviceId) => Enabled(deviceId) == true;

    // True while the computer shows its screen to this computer: the
    // desktop field of the last flux.input.
    public bool IsDesktopOn(string deviceId) => states.TryGetValue(deviceId, out var s) && s.Desktop == true;

    // True when a packet can ask the computer to press a key many times, see
    // RemoteInput.Keys.
    public bool CanRepeat(string deviceId) => states.TryGetValue(deviceId, out var s) && s.KeyRepeat;

    // Each flux.input tells the full state again.
    internal void Set(string deviceId, bool on, bool? desktop = null, bool keyRepeat = false) =>
        States = States.SetItem(deviceId, new RemoteInputState(on, desktop, keyRepeat));
}

// flux.mousepad.request out, flux.input in: the mouse, the touchpad, and
// the keyboard of this computer control the pointer and the keys of the
// Omarchy computer. The computer runs the input only while its
// remote_input setting is on. It sends flux.input {"enabled": bool,
// "desktop": bool, "keyRepeat": bool} after the link starts and after a
// setting changes. desktop tells whether remote_desktop is on, for
// DesktopPlugin. keyRepeat tells that a key packet can have repeat.
public sealed class RemoteInputPlugin : IFluxPlugin
{
    FluxCore? core;

    public RemoteInputModel Model { get; } = new();

    public IReadOnlyList<string> Incoming { get; } = [PacketType.Input];
    public IReadOnlyList<string> Outgoing { get; } = [PacketType.MousepadRequest];

    public void Attach(FluxCore core) => this.core = core;

    // True when the computer takes remote input. An older fluxd does not
    // list flux.mousepad.request.
    public static bool Supported(DeviceSnapshot device) => device.Accepts(PacketType.MousepadRequest);

    public void Handle(Packet packet, Device device)
    {
        if (packet.Bool("enabled") is not { } on)
        {
            return;
        }
        var desktop = packet.Bool("desktop");
        var repeats = packet.Bool("keyRepeat") ?? false;
        var shows = desktop is { } d ? (d ? "on" : "off") : "not reported";
        FluxLog.Info("input", $"remote input is {(on ? "on" : "off")}, remote desktop is {shows} on {device.Name}");
        var id = device.Id;
        core?.Host.Post(() => Model.Set(id, on, desktop, repeats));
    }

    // Sends 1 input packet. It returns false when the computer is offline.
    public bool Send(Packet packet, string deviceId) => core?.Send(packet, deviceId) ?? false;

    // Sends the packets in order. It returns false when 1 of them did not
    // go out.
    public bool Send(IEnumerable<Packet> packets, string deviceId)
    {
        var all = true;
        foreach (var p in packets)
        {
            all &= Send(p, deviceId);
        }
        return all;
    }
}
