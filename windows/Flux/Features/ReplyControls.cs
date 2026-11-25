using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using FluxKit;

namespace Flux;

// The dock of an agent under its thread. A blocked agent shows its question
// and the choices, with Write for a text answer. A working agent shows its
// step and Interrupt. A finished agent shows the end of its turn. The key
// row shows while the Keys toggle is on. Under that, the composer takes a
// prompt as text or as dictation, with the clear key and the expand key.
// Each reply asks for Windows Hello first, see ReplyLock.
// ReplyControls.swift and ReplyField.swift of the Mac app have the same
// parts.
public sealed class ReplyControls : View
{
    readonly AgentsWindowModel model;
    readonly string pane;
    readonly AgentDetail detail;
    readonly TextBox field;
    readonly TextBlock hint = Ui.Text("", 13);
    readonly Border fieldFrame;
    readonly Border sendTile = new() { Width = 34, Height = 34, CornerRadius = new CornerRadius(17) };
    readonly PlainButton sendKey;
    // The parts of the dock stay across the drawings, so that the reply
    // field keeps its place and its focus.
    readonly Border topHost = new();
    readonly Border keysHost = new();
    readonly Border problemHost = new();
    readonly VoiceBar voice;
    readonly Border dock;
    HerdrAgent? agent;
    HerdrOutput? output;
    AgentThread? thread;
    AgentAsk? ask;
    Action? review;
    string? lockError;
    // True while a blocked agent shows the composer in the place of its choices.
    bool writing;
    // The output that the last answer answered.
    HerdrOutput? answered;
    // The number of the last reply that cleared the field.
    int handledReply;

    public ReplyControls(AgentsWindowModel model, string pane, AgentDetail detail)
    {
        this.model = model;
        this.pane = pane;
        this.detail = detail;
        field = AgentParts.ReplyField(Send);
        field.Text = model.Drafts.GetValueOrDefault(pane) ?? "";
        field.CaretIndex = field.Text.Length;
        field.TextChanged += (_, _) =>
        {
            model.Drafts[pane] = field.Text;
            UpdateSend();
        };
        var row = FieldKeys.Row(AgentParts.WithHint(field, hint), field, () => Editor().ShowDialog());
        fieldFrame = new Border { Child = row, CornerRadius = new CornerRadius(18), BorderThickness = new Thickness(1), Padding = new Thickness(6, 0, 10, 0) };
        sendKey = new PlainButton(sendTile, Send).Named("Send");
        // A dictation puts its words at the cursor. The text waits in the field for Send, so a prompt still needs the lock.
        voice = VoiceBar.Insert(model.App.Core, field, fieldFrame, sendKey);
        dock = Parts.PageDock(Ui.V(10, topHost, keysHost, voice, problemHost), 14);
        handledReply = Reply?.Seq ?? 0;
    }

    HerdrPlugin Plugin => model.Plugin;
    HerdrReply? Reply => Plugin.Model.Reply(model.DeviceId, pane);

    // The text in the field. Tests read it.
    internal TextBox Field => this.field;

    // The field with the mic key and Send. Tests read it.
    internal VoiceBar Voice => voice;

    // The larger editor of the reply, with Send. The text changes in the
    // field at once.
    internal FieldEditor Editor() => new(Window.GetWindow(this), $"Write to {agent?.Agent ?? "the agent"}", field.Text, text => field.Text = text,
        new FieldEditorAction("Send", CanSend, Send, $"Send the text to {agent?.Agent ?? "the agent"}"));

    // Puts the text of a first task that did not go in the field, unless
    // the user wrote something there.
    public void Fill(string text)
    {
        if (field.Text.Length == 0)
        {
            field.Text = text;
            field.CaretIndex = text.Length;
        }
    }

    // Draws the dock for the agent, its output, and its thread. The detail
    // calls it at each drawing.
    public void Show(HerdrAgent agent, HerdrOutput? output, AgentThread? thread, AgentAsk? ask, Action? review)
    {
        this.agent = agent;
        this.output = output;
        this.thread = thread;
        this.ask = ask;
        this.review = review;
        Redraw();
    }

    protected override UIElement Build()
    {
        var tn = Tn.Current;
        if (agent is null)
        {
            return new Border();
        }
        var reply = Reply;
        // A prompt that the computer accepted leaves the field.
        if (reply is { Action: "prompt", Sending: false, Error: null } && reply.Seq != handledReply)
        {
            handledReply = reply.Seq;
            field.Clear();
            model.Drafts.Remove(pane);
            writing = false;
        }
        var blocked = agent.Status == AgentStatus.Blocked;
        var choices = blocked && output is not null ? output.Choices : ValueList<AgentChoice>.Empty;
        var asking = blocked && choices.Count > 0 && !writing;
        var sendingPrompt = reply is { Sending: true, Action: "prompt" };
        var top = new List<UIElement?>();
        if (blocked)
        {
            top.Add(AskHeader(choices.Count > 0));
            if (asking)
            {
                if (ask is not null)
                {
                    top.Add(AgentParts.AskText(ask, 15, true, 6).Margin(4, 0, 4, 0));
                }
                // A choice takes no click while a reply goes, and after an answer until the next output.
                var open = reply?.Sending != true && (answered is null || output != answered && output?.Loading == false);
                top.Add(Ui.V(6, choices.Select((c, i) => (UIElement)AgentParts.AskChoiceButton(c, i == 0, open, () => Answer(c)))));
            }
        }
        else if (agent.Status == AgentStatus.Working)
        {
            top.Add(WorkingRow());
        }
        else if (agent.Status == AgentStatus.Done)
        {
            top.Add(DoneRow());
        }
        Put(topHost, top.Count == 0 ? null : Ui.V(10, top));
        Put(keysHost, detail.KeysOpen ? KeyRow(blocked && choices.Count == 0) : null);
        Composer(sendingPrompt);
        voice.Shown(!asking);
        Put(problemHost, (lockError ?? reply?.Error) is { } problem ? ProblemRow(problem, reply) : null);
        dock.Background = tn.Tile;
        dock.BorderBrush = tn.Line;
        return dock;
    }

    // Puts the content in the host, and hides an empty host, so that it takes no gap.
    static void Put(Border host, UIElement? content)
    {
        if (content is not null)
        {
            Ui.Detach(content);
        }
        host.Child = content;
        host.Shown(content is not null);
    }

    // The top row of the dock of a blocked agent: the agent asks, then
    // Write. Write shows the composer in the place of the choices, and
    // Choices shows the choices again.
    UIElement AskHeader(bool hasChoices)
    {
        var tn = Tn.Current;
        return Ui.H(8,
            AgentParts.PulseDot(tn.Red),
            Ui.Text($"{agent!.Agent} asks", 12, FontWeights.Medium, tn.Red).Fill(),
            hasChoices
                ? new FluxButton(writing ? "Choices" : "Write", ButtonKind.Text, () =>
                {
                    writing = !writing;
                    Invalidate();
                }, Icons.Edit).Help(writing ? "Show the choices" : "Write an answer in the place of the choices")
                : null).Margin(4, 0, 4, 0).MinHeight(24);
    }

    // The dock row of a working agent: its step and time, and Interrupt,
    // which sends Escape.
    UIElement WorkingRow()
    {
        var tn = Tn.Current;
        var step = thread?.Step is { Length: > 0 } s ? s : "Working";
        var line = string.Join(" · ", new[] { thread?.Elapsed ?? "", $"{agent!.Agent} is working" }.Where(p => p.Length > 0));
        var interrupt = new PlainButton(new Border
        {
            Child = Ui.H(6, Ui.Text("Interrupt", 12, FontWeights.SemiBold), Ui.Text("esc", 11, color: tn.Sub, mono: true)),
            Background = tn.Line,
            CornerRadius = new CornerRadius(Metrics.SmallCorner),
            Padding = new Thickness(12, 0, 12, 0),
            MinHeight = Metrics.ButtonHeight,
        }, () => Keys("esc")).Named($"Interrupt {agent.Agent}").Help($"Send Escape to {agent.Agent}");
        return Ui.H(12,
            Parts.Spinner(18, tn.Accent),
            Ui.V(2, Ui.Text(step, 13, FontWeights.SemiBold, maxLines: 2), Ui.Text(line, 11, color: tn.Sub, mono: true)).Fill(),
            interrupt).Margin(4, 0, 4, 0);
    }

    // The dock row of a finished agent: the end of its turn, and Review changes.
    UIElement DoneRow()
    {
        var tn = Tn.Current;
        return Ui.H(10,
            Ui.Icon(AgentGlyphs.Completed, 14, tn.Green),
            Ui.Text(AgentParts.DoneText(thread?.Worked ?? ""), 13, FontWeights.SemiBold).Fill(),
            review is { } r ? new FluxButton("Review changes", ButtonKind.Text, r).Named("Review changes").Help("Show the changes of the repository (Ctrl+D)") : null)
            .Margin(4, 0, 4, 0).MinHeight(24);
    }

    // The keys Esc, Tab, Up, Down, and Enter. accent marks Enter when the
    // dialog needs it.
    UIElement KeyRow(bool accent)
    {
        (string Label, string Key, string Help)[] keys =
            [("esc", "esc", "Escape"), ("tab", "tab", "Tab"), ("↑", "up", "Up"), ("↓", "down", "Down"), ("enter", "enter", "Enter")];
        var buttons = keys.Select(k => (UIElement)KeyButton(k.Label, k.Help, accent && k.Key == "enter", () => Keys(k.Key))).ToArray();
        return Parts.GridRows(buttons, buttons.Length);
    }

    static UIElement KeyButton(string label, string help, bool accent, Action action)
    {
        var tn = Tn.Current;
        var tile = new Border
        {
            Child = Ui.Text(label, 12, FontWeights.Medium, accent ? tn.Accent : tn.Sub, mono: true, align: TextAlignment.Center),
            Background = accent ? tn.AccentTile : tn.Bg,
            BorderBrush = accent ? tn.Accent : tn.Line,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Metrics.SmallCorner),
            MinHeight = Metrics.ButtonHeight,
        };
        return new PlainButton(tile, action).Named(help).Help(help);
    }

    // The composer: the reply field, the mic key, and the send key. While
    // this computer listens, the listening panel of the voice bar takes its
    // place.
    void Composer(bool sending)
    {
        var tn = Tn.Current;
        var a = agent!;
        hint.Text = a.Status switch
        {
            AgentStatus.Blocked => $"Tell {a.Agent} what to do differently",
            AgentStatus.Working => $"Steer {a.Agent} while it works",
            _ => $"Write to {a.Agent}",
        };
        hint.Foreground = tn.Dim;
        System.Windows.Automation.AutomationProperties.SetName(field, hint.Text);
        field.Foreground = tn.Text;
        field.CaretBrush = tn.Accent;
        fieldFrame.Background = tn.Bg;
        fieldFrame.BorderBrush = tn.LineHi;
        sendTile.Child = sending ? Parts.Spinner(14, tn.OnAccent) : Ui.Icon(AgentGlyphs.ArrowUp, 14, tn.OnAccent);
        sendTile.Background = tn.Accent;
        sendKey.Help($"Send the text to {a.Agent}");
        UpdateSend();
    }

    void UpdateSend()
    {
        // The key keeps its color with no text. It takes no click then.
        sendKey.IsEnabled = CanSend();
        sendKey.Opacity = 1;
    }

    // True when the field has text and no prompt goes out now.
    bool CanSend() => field.Text.Trim().Length > 0 && Reply is not { Sending: true, Action: "prompt" };

    // The problem under the dock, with the action that solves it.
    UIElement ProblemRow(string problem, HerdrReply? reply)
    {
        var tn = Tn.Current;
        var actions = new List<UIElement?>();
        // fluxd refused the prompt because the agent waits for a choice. The
        // user can type the same text into the dialog.
        if (problem == reply?.Error && reply.Blocked && reply.Text is { } text)
        {
            actions.Add(new FluxButton("Send as answer", ButtonKind.Text, () => AnswerText(text)).Named("Send as answer").Help($"Type the text into the dialog of {agent!.Agent}"));
        }
        return Ui.H(10, new UIElement?[] { Ui.Text(problem, 12, color: tn.Red, wrap: true).Fill() }.Concat(actions));
    }

    void Guarded(Action action)
    {
        lockError = null;
        ReplyLock.Run($"answer agents on {model.Name}", Window.GetWindow(this), action, message =>
        {
            lockError = message;
            Invalidate();
        });
    }

    void Keys(string key)
    {
        var deviceId = model.DeviceId;
        Guarded(() => Plugin.SendKeys(deviceId, pane, [key]));
    }

    // Sends the keys of a choice, and keeps the answer for the thread: the
    // digit of a numbered dialog, or the arrows and Enter of a menu.
    void Answer(AgentChoice c)
    {
        var deviceId = model.DeviceId;
        var shown = output;
        var last = thread?.Blocks.LastOrDefault();
        Guarded(() =>
        {
            answered = shown;
            detail.Answered(new SentAnswer(c.Label, c.SentMeta, last));
            Plugin.SendKeys(deviceId, pane, c.Keys);
            Invalidate();
        });
    }

    void Send()
    {
        var text = field.Text;
        if (!CanSend())
        {
            return;
        }
        var deviceId = model.DeviceId;
        Guarded(() => Plugin.SendPrompt(deviceId, pane, text));
    }

    // Sends the text of a refused prompt again as the answer to the dialog of the agent.
    void AnswerText(string text)
    {
        if (Reply?.Sending == true)
        {
            return;
        }
        var deviceId = model.DeviceId;
        Guarded(() => Plugin.SendPrompt(deviceId, pane, text, answer: true));
    }
}
