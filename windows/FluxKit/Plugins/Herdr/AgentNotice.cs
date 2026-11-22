namespace FluxKit;

// How a notification action acts. Choice sends a choice. Reply sends the
// text of the user. A tap on the notification itself opens the thread.
public enum NoticeKind
{
    Choice,
    Reply,
}

// One action of the agent notification. Key is the key of the choice for a
// Choice, or empty.
public sealed record NoticeAction(NoticeKind Kind, string Label, string Key);

// The text of the notification of an agent. Text is the line of the
// notification. BigText is the full text with each choice in full. DialogId
// is the ID of the dialog that the texts came from, or empty. The actions
// carry it, so that the ID and the labels match. It is a port of
// AgentNotice.kt of the Android app, with the same test vectors. Windows
// shows a toast with buttons, so it has no step for an Android version
// before the unlock of a button.
public sealed record AgentNotice(string Title, string Text, string BigText, ValueList<NoticeAction> Actions, string DialogId = "")
{
    // The longest label of an action, in characters.
    public const int ActionLabelMax = 24;

    // The words that end the text of a notification of a computer with Agent control off.
    public const string ReadOnly = "Read only";

    // The most choices that get 1 action each.
    const int MaxChoiceActions = 3;

    const string Ellipsis = "…";

    // Cuts label at a word end to max characters, and adds an ellipsis when it cuts.
    public static string CutLabel(string label, int max = ActionLabelMax)
    {
        var t = label.Trim();
        if (t.Length <= max)
        {
            return t;
        }
        // The label may end exactly at the limit, so the next character must be a space.
        var head = t[..(max + 1)];
        var space = head.LastIndexOf(' ');
        var cut = space > 0 ? head[..space] : t[..max];
        return cut.TrimEnd(',', ';', ':', '.', ' ') + Ellipsis;
    }

    // The line of a dialog for the notification: the first line above the
    // choices, for example the command, and then the question.
    static string Summary(AgentDialog dialog)
    {
        var first = dialog.Lines.FirstOrDefault()?.Trim() ?? "";
        var head = first.Length == 0 || ".?!".Contains(first[^1]) ? first : first + ".";
        return string.Join(' ', new[] { head, dialog.Question.Trim() }.Where(s => s.Length > 0));
    }

    // Builds the notification of agent. dialog is the dialog that the last
    // read found, or null. control is true when the computer accepts input
    // from this computer.
    //
    // A blocked agent with 2 or 3 choices gets 1 action for each choice. A
    // blocked agent with no choices gets Reply. Other agents get no action.
    // With control off, the text ends with Read only and the notification
    // has no action.
    public static AgentNotice Build(HerdrAgent agent, AgentDialog? dialog, bool control)
    {
        var where = new[] { agent.Project, agent.Workspace, agent.Pane }.FirstOrDefault(s => s.Length > 0) ?? agent.Pane;
        if (agent.Status != AgentStatus.Blocked)
        {
            return new AgentNotice($"{agent.Agent} in {where} finished", agent.Title, agent.Title, ValueList<NoticeAction>.Empty);
        }
        var summary = dialog is null ? "" : Summary(dialog);
        var question = summary.Length > 0 ? summary : agent.Title;
        var numbered = string.Join('\n', (dialog?.Choices ?? ValueList<AgentChoice>.Empty).Select(c => $"{c.Key}. {c.Label}"));
        var suffix = control ? "" : ReadOnly;
        var text = string.Join(' ', new[] { question, suffix }.Where(s => s.Length > 0));
        var big = string.Join('\n', new[] { question, numbered }.Where(s => s.Length > 0));
        if (suffix.Length > 0)
        {
            big = big.Length == 0 ? suffix : big + "\n" + suffix;
        }
        var actions = new List<NoticeAction>();
        var reply = false;
        if (control && dialog is not null)
        {
            var n = dialog.Choices.Count;
            if (n is >= 2 and <= MaxChoiceActions)
            {
                actions.AddRange(dialog.Choices.Select(c => new NoticeAction(NoticeKind.Choice, CutLabel(c.Label), c.Key)));
            }
            else if (n == 0)
            {
                reply = true;
                actions.Add(new NoticeAction(NoticeKind.Reply, "Reply", ""));
            }
        }
        var title = reply ? $"{agent.Agent} in {where} asks a question" : $"{agent.Agent} in {where} needs input";
        return new AgentNotice(title, text, big, ValueList.From(actions), dialog?.Id ?? "");
    }
}
