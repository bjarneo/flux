using System.Windows;
using System.Windows.Controls;
using FluxKit;

namespace Flux;

// Fingerprint approval with Windows Hello in the app: the prompt hook, the
// tray item of a computer with an open request, and the section of the page
// of a computer. Features.swift of the Mac app registers the same parts.
// docs/approve.md is the design.
public static class ApproveFeature
{
    // The prompt shows for each new request, and a click on the
    // notification shows it again.
    public static void DidLaunch(AppModel model) => ApprovePrompts.Install(model);

    // The section of the page of a paired computer.
    public static UIElement? Section(AppModel model, DeviceSnapshot device) => ApproveSection.Make(model, device);

    // Shows the prompt of the open request of the computer from the tray.
    public static (string Title, Action Run)? TrayAction(AppModel model, DeviceSnapshot d) =>
        model.Core.Plugin<ApprovePlugin>() is { } plugin && plugin.Model.Current is { } r && r.ComputerId == d.Id
            ? (ApproveTexts.MenuTitle(r), () => ApprovePrompts.Show(plugin))
            : null;
}

// The chat cards of approvals. ChatCards.swift of the Mac app has the same
// cards.
public static class ApproveCards
{
    // A request that waits for Windows Hello, with Deny and Approve. Approve
    // opens the approval prompt, which asks for Windows Hello. The card never
    // approves by itself. In the tray panel, the prompt takes the focus, and
    // the panel hides. list draws the card for the list of chats.
    public static UIElement ApprovalCard(AppModel model, InboxItem item, ApproveRequest r, DateTimeOffset at, bool list = false)
    {
        var tn = Tn.Current;
        var plugin = model.Core.Plugin<ApprovePlugin>();
        var deny = Button(ApproveTexts.DenyButton, false, () =>
        {
            // Deny acts on the open request, so it must be the request of this card.
            if (plugin?.Model.Current is { } open && open.Id == r.Id && open.ComputerId == r.ComputerId)
            {
                plugin.Deny();
            }
        }).Help(ApproveTexts.DenyHelp);
        var approve = Button(ApproveTexts.ApproveButton, true, () =>
        {
            if (plugin is not null)
            {
                ApprovePrompts.Show(plugin);
            }
        }, Icons.Fingerprint).Help(ApproveTexts.ReviewHelp);
        var row = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Metrics.Gap) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.6, GridUnitType.Star) });
        Grid.SetColumn(approve, 2);
        row.Children.Add(deny);
        row.Children.Add(approve);
        return Cards.InCard(Cards.Head(item.StateWord, tn.Red, r.Service, Texts.ClockTime(at), AgentParts.PulseDot(tn.Red, 8)),
            item.Title, ApproveTexts.RequestLine(r), ask: true, extra: row, list: list);
    }

    // The answer of this computer to a request: Approved, Enrolled, or Denied.
    public static UIElement AnswerCard(ApproveRecord record)
    {
        var tn = Tn.Current;
        var ok = record.Outcome.Kind is ApproveOutcomeKind.Approved or ApproveOutcomeKind.Enrolled;
        var color = ok ? tn.Green : tn.Sub;
        return Cards.InCard(Cards.Head(ApproveTexts.AnswerState(record), color, record.Request?.Service ?? "",
                Texts.ClockTime(record.Resolved ?? record.Received), AgentParts.PulseDot(color, 8, false)),
            ApproveTexts.AnswerTitle(record), record.Request is { } r ? ApproveTexts.RequestLine(r) : "");
    }

    // A button of the card, 40 px high: the primary button in the accent,
    // the other on line.
    static PlainButton Button(string label, bool primary, Action run, string? glyph = null)
    {
        var tn = Tn.Current;
        var ink = primary ? tn.OnAccent : tn.Text;
        var content = Ui.H(6, glyph is null ? null : Ui.Icon(glyph, 14, ink), Ui.Text(label, 13, FontWeights.SemiBold, ink));
        content.HorizontalAlignment = HorizontalAlignment.Center;
        content.VerticalAlignment = VerticalAlignment.Center;
        var tile = new Border
        {
            Child = content,
            Background = primary ? tn.Accent : tn.Line,
            CornerRadius = new CornerRadius(Metrics.SmallCorner),
            Padding = new Thickness(12, 0, 12, 0),
            MinHeight = 40,
        };
        return new PlainButton(tile, run).Named(label);
    }
}
