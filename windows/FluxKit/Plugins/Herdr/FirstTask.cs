namespace FluxKit;

public enum FirstTaskState
{
    // The computer starts the agent.
    Starting,

    // The agent runs and is not ready yet.
    Waiting,

    // The agent asks a question. The task goes after the answer.
    Answering,

    // The prompt went, and the computer did not answer yet.
    Sending,

    // The agent got the task.
    Sent,

    // The task did not go, for the reason in Error.
    Failed,
}

// The phase of a first task. Error is the reason of a failed task.
public readonly record struct FirstTaskPhase(FirstTaskState State, string Error = "")
{
    public static FirstTaskPhase Starting => new(FirstTaskState.Starting);
    public static FirstTaskPhase Waiting => new(FirstTaskState.Waiting);
    public static FirstTaskPhase Answering => new(FirstTaskState.Answering);
    public static FirstTaskPhase Sending => new(FirstTaskState.Sending);
    public static FirstTaskPhase Sent => new(FirstTaskState.Sent);
    public static FirstTaskPhase Failed(string error) => new(FirstTaskState.Failed, error);
}

// The first task of a new agent. The text goes as a prompt when the new
// agent is ready for input. When the agent asks a question first, such as
// whether it may trust the folder, the task waits until the user answered
// and the agent is ready. The agent must stay ready with no dialog for Hold,
// because an agent can show the next dialog right after the user answered
// the last one. It is a value: a change makes a new copy, as in the Mac app.
public record struct FirstTask
{
    // How long the agent must stay ready with no dialog before the task goes, in seconds.
    public const double Hold = 2;

    // How long the task waits for the new pane in the agent list, as long
    // as a create waits for its answer, in seconds.
    public const double AppearLimit = 60;

    public FirstTask(string text, int action = 0)
    {
        Text = text.Trim();
        Action = action;
    }

    // The prompt, without blanks at its ends.
    public string Text { get; }

    // The number of the create of the agent, see HerdrAction.Seq.
    public int Action { get; }

    // The pane of the new agent, when the computer reported it.
    public string? Pane { get; private set; }

    public FirstTaskPhase Phase { get; private set; } = FirstTaskPhase.Starting;

    // The number of the prompt reply, see HerdrReply.Seq.
    internal int? Reply { get; set; }

    // True after the agent list had the pane.
    bool seen;

    // Since when the agent is ready with no dialog, in seconds of the clock of the plugin.
    double? readyAt;

    // Since when the task waits for the pane in the agent list, in seconds of the clock of the plugin.
    double? missingSince;

    // True when the task went or failed.
    public readonly bool Finished => Phase.State is FirstTaskState.Sent or FirstTaskState.Failed;

    // Takes the answer to the create: the new pane, or why the agent did not start.
    public void Created(string? pane, string? error)
    {
        if (Phase.State != FirstTaskState.Starting)
        {
            return;
        }
        if (error is not null)
        {
            Phase = FirstTaskPhase.Failed(error);
        }
        else if (pane is not null)
        {
            Pane = pane;
            Phase = FirstTaskPhase.Waiting;
        }
        else
        {
            Phase = FirstTaskPhase.Failed("The computer did not report the new agent.");
        }
    }

    // The time when the task can go, when the agent is ready now. Call
    // Update again then.
    public readonly double? Due => readyAt + Hold;

    // The time when the task fails, when the agent list never had the
    // pane. Call Update again then.
    public readonly double? AppearDue => seen || Finished ? null : missingSince + AppearLimit;

    // Takes the status of the agent at now, null when the agent list does
    // not have its pane, and whether the output on screen ends with a
    // dialog. It returns true when the task must go now.
    public bool Update(AgentStatus? status, bool choices, double now)
    {
        if (Phase.State is not (FirstTaskState.Waiting or FirstTaskState.Answering))
        {
            return false;
        }
        if (status is not { } s)
        {
            if (seen)
            {
                Phase = FirstTaskPhase.Failed("The agent stopped before it got the task.");
            }
            else if (missingSince is { } since && now - since >= AppearLimit)
            {
                Phase = FirstTaskPhase.Failed("The agent did not appear.");
            }
            else if (missingSince is null)
            {
                missingSince = now;
            }
            readyAt = null;
            return false;
        }
        seen = true;
        if (s == AgentStatus.Blocked || choices)
        {
            Phase = FirstTaskPhase.Answering;
            readyAt = null;
            return false;
        }
        if (!s.Ready())
        {
            readyAt = null;
            return false;
        }
        if (readyAt is not { } ready)
        {
            readyAt = now;
            return false;
        }
        if (now - ready < Hold)
        {
            return false;
        }
        Phase = FirstTaskPhase.Sending;
        return true;
    }

    // Takes the answer to the prompt.
    public void Sent(string? error)
    {
        if (Phase.State != FirstTaskState.Sending)
        {
            return;
        }
        Phase = error is null ? FirstTaskPhase.Sent : FirstTaskPhase.Failed(error);
    }
}
