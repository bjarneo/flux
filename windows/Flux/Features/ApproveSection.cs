using System.Globalization;
using System.Windows;
using System.Windows.Media;
using FluxKit;

namespace Flux;

// Windows Hello approval for 1 computer on its page: the open request, the
// enrollment, the key code, Remove Key, and the recent requests. The computer
// starts each enrollment with sudo flux-cli approve setup or sudo flux-cli
// approve enroll. ApproveSection.swift and ApproveBanner of the Mac app have
// the same parts.
public sealed class ApproveSection : View
{
    // The last answer of the check of Windows Hello, for all sections, and
    // the tick count of its start. The page of a computer draws often, so
    // the check runs at most every 5 seconds.
    static ApproveAvailability? availability;
    static long checkedAt = long.MinValue / 2;

    readonly ApprovePlugin plugin;
    readonly DeviceSnapshot device;

    public ApproveSection(ApprovePlugin plugin, DeviceSnapshot device)
    {
        this.plugin = plugin;
        this.device = device;
        Watch(plugin.Model);
        Loaded += (_, _) => _ = CheckAsync();
    }

    // The section of a paired computer of Flux, or of a computer with a key.
    public static UIElement? Make(AppModel model, DeviceSnapshot device) =>
        model.Core.Plugin<ApprovePlugin>() is { } plugin && (device.IsFlux || plugin.Model.KeyFor(device.Id) is not null)
            ? new ApproveSection(plugin, device)
            : null;

    // Asks whether Windows Hello works. It does not ask the user.
    async Task CheckAsync()
    {
        var now = Environment.TickCount64;
        if (now - checkedAt < 5000)
        {
            return;
        }
        checkedAt = now;
        var next = await plugin.AvailabilityAsync();
        if (next != availability)
        {
            availability = next;
            Invalidate();
        }
    }

    protected override UIElement Build()
    {
        var tn = Tn.Current;
        var m = plugin.Model;
        var key = m.KeyFor(device.Id);
        var items = new List<UIElement?> { Parts.SectionLabel("Approval") };
        if (m.Current is { } open && open.ComputerId == device.Id)
        {
            items.Add(Banner(open));
        }

        var status = Ui.H(6, Ui.Dot(key is null ? tn.Sub : tn.Green, 7),
            Ui.Text(key is null ? ApproveTexts.NotSetUpStatus : ApproveTexts.EnrolledStatus, 12, FontWeights.Medium, key is null ? tn.Sub : tn.Green));
        var body = new List<UIElement?>
        {
            Ui.H(10, Ui.Icon(Icons.Fingerprint, 17, tn.Accent, 24), Ui.Text(ApproveTexts.SectionTitle, 13, FontWeights.SemiBold).Fill(), status),
        };
        if (key is not null)
        {
            body.Add(Ui.Text(ApproveTexts.EnrolledFor(key.User, key.Host), 13, color: tn.Sub, wrap: true));
        }
        else
        {
            body.Add(Ui.Text(ApproveTexts.Setup(device.Name), 13, color: tn.Sub, wrap: true));
            body.Add(Parts.CommandBlock(ApproveTexts.SetupCommand));
        }
        if (availability is { Kind: not ApproveAvailabilityKind.Ready } problem)
        {
            body.Add(Ui.H(8, Ui.Icon(Icons.Warning, 14, tn.Red), Ui.Text(problem.Message, 12, color: tn.Red, wrap: true).Fill()));
        }
        body.Add(Ui.Text(ApproveTexts.PinNote, 12, color: tn.Sub, wrap: true));
        if (key is not null)
        {
            body.Add(Ui.Divider());
            body.Add(Row(ApproveTexts.KeyCode, Ui.SelectableText(key.Code, 12, color: tn.Text)));
            body.Add(Row(ApproveTexts.EnrolledStatus, Ui.Text(key.Enrolled.ToLocalTime().ToString("g", CultureInfo.CurrentCulture), 12)));
            var remove = new FluxButton($"{ApproveTexts.RemoveKeyButton}…", ButtonKind.Destructive, ConfirmRemove).Named($"{ApproveTexts.RemoveKeyButton}…")
                .Help(ApproveTexts.RemoveKeyQuestion(device.Name));
            body.Add(Ui.H(8, Ui.Text(ApproveTexts.EnrollAgain(device.Name), 12, color: tn.Sub, wrap: true).Fill(), remove));
        }
        body.Add(Ui.Divider());
        body.Add(Ui.Text(ApproveTexts.RecentRequests, 13, FontWeights.Medium));
        var records = m.History.Where(r => r.ComputerId == device.Id).ToArray();
        if (records.Length == 0)
        {
            body.Add(Ui.Text(ApproveTexts.NoRequests, 12, color: tn.Sub));
        }
        foreach (var r in records)
        {
            body.Add(RecordRow(r));
        }
        items.Add(Ui.Tile(Ui.V(8, body)));
        return Ui.V(Metrics.Gap, items);
    }

    // A banner while a request of the computer waits for Windows Hello.
    UIElement Banner(ApproveRequest r)
    {
        var tn = Tn.Current;
        var question = ApproveMessage.Question(r);
        var show = new FluxButton(ApproveTexts.ShowPrompt, ButtonKind.Outlined, () => ApprovePrompts.Show(plugin)).Named(ApproveTexts.ShowPrompt)
            .Help("Show the approval prompt");
        var row = Ui.H(10, AgentParts.PulseDot(tn.Red, 8), Ui.Text(question, 13, FontWeights.SemiBold, wrap: true).Fill(), show);
        var tile = Ui.Tile(row, tn.Tile, tn.Red, 0, borderWidth: 2);
        tile.Padding = new Thickness(12, 8, 12, 8);
        return tile;
    }

    static UIElement Row(string label, UIElement value) =>
        Ui.H(8, Ui.Text(label, 12, color: Tn.Current.Sub).Width(96), value);

    // 1 recent request: the mark of its outcome, the question, the outcome,
    // and the time.
    static UIElement RecordRow(ApproveRecord r)
    {
        var tn = Tn.Current;
        UIElement mark = r.Outcome.Kind switch
        {
            ApproveOutcomeKind.Open => AgentParts.PulseDot(tn.Red, 8),
            ApproveOutcomeKind.Approved or ApproveOutcomeKind.Enrolled => Ui.Icon(Icons.Check, 13, tn.Green),
            ApproveOutcomeKind.Denied => Ui.Icon(Icons.Close, 12, tn.Sub),
            ApproveOutcomeKind.Failed or ApproveOutcomeKind.Refused => Ui.Icon(Icons.Warning, 13, tn.Red),
            _ => Ui.Ring(tn.Sub, 9),
        };
        var text = Ui.V(2, Ui.Text(r.Summary, 13, wrap: true), Ui.Text(r.Outcome.Text, 11, color: OutcomeInk(r.Outcome.Kind), wrap: true));
        return Ui.H(8, Ui.Box(mark, 0, 3, 0, 0).Width(18).Top(), text.Fill(), Ui.Text(Texts.ClockTime(r.Received), 11, color: tn.Sub, mono: true).Top())
            .Named($"{r.Summary}, {r.Outcome.Text}");
    }

    static Brush OutcomeInk(ApproveOutcomeKind kind) => kind switch
    {
        ApproveOutcomeKind.Approved or ApproveOutcomeKind.Enrolled => Tn.Current.Green,
        ApproveOutcomeKind.Failed or ApproveOutcomeKind.Refused => Tn.Current.Red,
        _ => Tn.Current.Sub,
    };

    void ConfirmRemove()
    {
        if (Dialogs.Confirm(Window.GetWindow(this), ApproveTexts.RemoveKeyQuestion(device.Name), ApproveTexts.RemoveKeyDetail(device.Name),
                ApproveTexts.RemoveKeyButton, destructive: true))
        {
            plugin.RemoveKey(device.Id);
        }
    }
}
