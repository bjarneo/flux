using System.Windows;
using System.Windows.Controls;
using FluxKit;

namespace Flux;

// The pairing states of a computer that is not paired. The layout and the
// rules stay as on the Mac: Accept is not the default button, so that Enter
// cannot accept a request that came while the user typed.
public sealed class PairingPage(AppModel model, string deviceId) : Page(model)
{
    DeviceSnapshot? Device => Model.DeviceOf(deviceId);

    public override string Title => Device?.Name ?? "Pairing";

    public override string Subtitle => Device is { } d ? (d.Ip.Length == 0 ? Texts.StatusText(d) : $"{Texts.StatusText(d)} · {d.Ip}") : "";

    protected override UIElement Build()
    {
        var tn = Tn.Current;
        if (Device is not { } d)
        {
            return Parts.Unavailable(Icons.Desktop, "The computer is gone");
        }
        var items = new List<UIElement?> { Ui.Icon(Texts.Symbol(d), 54, tn.Sub) };
        switch (d.PairState)
        {
            case PairState.Incoming:
                items.Add(Ui.Text($"{d.Name} wants to pair", 20, align: TextAlignment.Center, wrap: true));
                items.Add(Parts.KeyView(d.PairKey));
                items.Add(Ui.Text($"Accept only when {d.Name} shows the same key. Compare all 16 characters.", 13, color: tn.Sub,
                    wrap: true, align: TextAlignment.Center));
                items.Add(Ui.H(8,
                    new FluxButton("Reject", ButtonKind.Outlined, () => Model.Core.CancelPair(d.Id)),
                    new FluxButton("Accept", ButtonKind.Filled, () => Model.Core.AcceptPair(d.Id))).Align(HorizontalAlignment.Center));
                break;
            case PairState.Requested:
                items.Add(Ui.Text($"Confirm on {d.Name}", 20, align: TextAlignment.Center, wrap: true));
                items.Add(Parts.KeyView(d.PairKey));
                items.Add(Ui.Text("Accept the request on the computer when it shows the same key.", 13, color: tn.Sub,
                    wrap: true, align: TextAlignment.Center));
                items.Add(Parts.Spinner().Align(HorizontalAlignment.Center));
                items.Add(new FluxButton("Cancel", ButtonKind.Outlined, () => Model.Core.CancelPair(d.Id)).Align(HorizontalAlignment.Center));
                break;
            default:
                items.Add(Ui.Text(d.Name, 20, align: TextAlignment.Center));
                if (d.Online)
                {
                    items.Add(Ui.Text("Pair this computer to share files, the clipboard, media controls, and more.", 13,
                        color: tn.Sub, wrap: true, align: TextAlignment.Center));
                    var pair = new FluxButton("Pair…", ButtonKind.Filled, () => Dialogs.PairRequest(Window.GetWindow(this), Model, d)) { IsDefault = true };
                    items.Add(pair.Align(HorizontalAlignment.Center));
                }
                else
                {
                    items.Add(Ui.Text("Offline", 13, color: tn.Sub, align: TextAlignment.Center));
                }
                break;
        }
        var column = Ui.V(18, items);
        column.MaxWidth = 460;
        return Ui.Scroll(column.Align(HorizontalAlignment.Center, VerticalAlignment.Center).Margin(40));
    }
}

// The page of a paired computer: its state, the scope, the sections of the
// features, such as the approval, and Unpair.
public sealed class ComputerPage(AppModel model, string deviceId) : Page(model)
{
    DeviceSnapshot? Device => Model.PairedDevice(deviceId);

    public override string Title => Device?.Name ?? "Computer";

    public override string Subtitle
    {
        get
        {
            if (Device is not { } d)
            {
                return "";
            }
            var battery = Batteries.Of(Model, d.Id);
            return Texts.LinkText(d, battery?.Charge, battery?.Charging == true);
        }
    }

    protected override UIElement Build()
    {
        var tn = Tn.Current;
        if (Device is not { } d)
        {
            return Parts.Unavailable(Icons.Desktop, "The computer is gone", "The computer is no longer paired.");
        }
        var inScope = Model.Scope == d.Id;
        var head = Ui.H(12,
            Ui.Icon(Texts.Symbol(d), 28, d.Online ? tn.Accent : tn.Sub),
            Ui.V(3, Ui.Text(d.Name, 20, FontWeights.SemiBold), d.Ip.Length > 0 ? Ui.SelectableText(d.Ip, 11, color: tn.Sub) : null).Fill(),
            new FluxButton(inScope ? "Show all computers" : $"Show only {d.Name}", ButtonKind.Outlined,
                () => Model.SetScope(inScope ? null : d.Id)));
        var items = new List<UIElement?>
        {
            Ui.Tile(head, tn.Tile, inScope ? tn.Accent : tn.Line),
        };
        items.AddRange(ComputerSections.For(Model, d));
        items.Add(Parts.SectionLabel("Pairing"));
        items.Add(new FluxButton($"Unpair {d.Name}…", ButtonKind.Destructive, () => Shared.ConfirmUnpair(Model, d, this)).Margin(4, 0, 4, 0));
        return Ui.Scroll(Ui.Column(Ui.V(Metrics.Gap, items), 8, 24));
    }
}

// The sections that features add to the page of a paired computer, in the
// order of Makers. Features.cs adds 1 maker for each feature.
public static class ComputerSections
{
    public static List<Func<AppModel, DeviceSnapshot, UIElement?>> Makers { get; } = [];

    public static IEnumerable<UIElement> For(AppModel model, DeviceSnapshot device) =>
        Makers.Select(make => make(model, device)).OfType<UIElement>();
}
