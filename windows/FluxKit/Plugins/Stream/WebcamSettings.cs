using System.Text.Json.Nodes;

namespace FluxKit;

// The webcam settings of this computer. The UI and the computer both change
// them through Update. Each change is saved, so that the next stream starts
// with the same settings. WebcamSettings.swift of the Mac app has the same
// rules.
internal sealed class WebcamSettings
{
    internal const string Key = "webcam.config";

    readonly FluxSettings settings;
    readonly Lock gate = new();
    WebcamConfig config;
    WebcamCaps caps;

    public WebcamSettings(FluxSettings settings, WebcamCaps caps)
    {
        this.settings = settings;
        this.caps = caps;
        config = new WebcamConfig().Merged(settings.Node(Key) as JsonObject).Clamped(caps);
    }

    public WebcamConfig Config
    {
        get
        {
            lock (gate)
            {
                return config;
            }
        }
    }

    public WebcamCaps Caps
    {
        get
        {
            lock (gate)
            {
                return caps;
            }
        }
    }

    // Changes the settings. The result is clamped to the caps and saved. It
    // returns the new settings, or null when nothing changed.
    public WebcamConfig? Update(Func<WebcamConfig, WebcamConfig> change)
    {
        lock (gate)
        {
            var next = change(config).Clamped(caps);
            if (next == config)
            {
                return null;
            }
            config = next;
            settings.Set(Key, next.Json());
            return next;
        }
    }

    // Applies a "config" message from the computer.
    public WebcamConfig? ApplyRemote(bool reset, JsonObject? partial) =>
        Update(c => (reset ? c.Reset() : c).Merged(partial));

    // Sets what the current camera supports, and clamps the settings to it.
    public WebcamConfig? SetCaps(WebcamCaps next)
    {
        lock (gate)
        {
            caps = next;
        }
        return Update(c => c);
    }
}
