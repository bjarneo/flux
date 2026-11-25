using System.Windows.Automation;
using Flux;
using FluxKit;
using static Harness;

// The chat of a computer: the clipboard row, the + key that opens the tray
// and turns into a cross, the screenshots and the tools of the tray, and
// the tools of a computer that is not reachable.
public static class ChatsChecks
{
    public static void Run(Harness h)
    {
        var window = h.Window;
        var model = h.Model;
        h.ApplyDevices();
        model.OpenChat(new ChatKey.Computer(h.Paired.Id));
        Pump();
        if (window.CurrentPage is not ChatsPage { Computer: { } chat })
        {
            h.Check(false, "the chat of the computer shows");
            return;
        }
        var dock = chat.Composer;
        h.Check(Shows(dock.Root, "Clipboard on this computer"), "the dock shows the clipboard of this computer");
        h.Check(Has(dock.Root, "Send the clipboard"), "the clipboard row has Send");

        Click(dock.Root, "Tools");
        h.Check(dock.TrayOpen, "+ opens the tray");
        h.Check(Has(dock.Root, "Close the tools"), "+ turns into the key that closes the tray");
        foreach (var tool in new[] { "Camera", "File", "Scan", "Text", "QR", "Signature", "Get files" })
        {
            h.Check(Has(dock.Root, tool), $"the tray has {tool}");
        }
        h.Check(!Has(dock.Root, "Agent"), "the tray has Agent only for a computer that lets this computer start agents");
        if (h.Core.Plugin<CaptureWatchPlugin>()?.Model.ScreenshotFolder.Length > 0)
        {
            h.Check(Shows(dock.Root, "Recent screenshots") && Has(dock.Root, "All screenshots"), "the tray shows the recent screenshots");
        }
        Click(dock.Root, "Close the tools");
        h.Check(!dock.TrayOpen && Has(dock.Root, "Tools"), "the cross closes the tray");

        // The herdr computer that allows control gets Agent in the tray.
        var herdr = h.Core.Plugin<HerdrPlugin>()!;
        herdr.Model.States = herdr.Model.States.SetItem(h.Paired.Id, new HerdrState(true, true, [], control: true));
        Pump();
        Click(dock.Root, "Tools");
        h.Check(Has(dock.Root, "Agent"), "the tray has Agent for a computer that allows control");
        Click(dock.Root, "Close the tools");
        herdr.Model.States = System.Collections.Immutable.ImmutableDictionary<string, HerdrState>.Empty;

        // The tools of a computer that is not reachable take no click.
        model.OpenChat(new ChatKey.Computer(h.Offline.Id));
        Pump();
        if (window.CurrentPage is ChatsPage { Computer: { } offline })
        {
            Click(offline.Composer.Root, "Tools");
            var camera = Buttons(offline.Composer.Root).FirstOrDefault(b => AutomationProperties.GetName(b) == "Camera");
            h.Check(camera is { IsEnabled: false }, "the tools of an offline computer take no click");
            Click(offline.Composer.Root, "Close the tools");
        }
        else
        {
            h.Check(false, "the chat of the offline computer shows");
        }
        model.OpenChat(new ChatKey.Computer(h.Paired.Id));
        model.SetScope(null);
        Pump();
    }

    // True when the element has a button with the name that a screen reader reads.
    static bool Has(System.Windows.DependencyObject root, string name) => Buttons(root).Any(b => AutomationProperties.GetName(b) == name);
}
