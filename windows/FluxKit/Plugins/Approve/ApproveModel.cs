namespace FluxKit;

// What happened to 1 request.
public enum ApproveOutcomeKind
{
    Open,
    Approved,
    Enrolled,
    Denied,

    // This computer could not sign, and told the computer.
    Failed,

    // This computer refused the request without asking the user.
    Refused,

    // The computer ended the request.
    Cancelled,

    // The wait of the computer ended.
    Expired,

    // This computer or the computer ended the pairing.
    Unpaired,
}

// What happened to 1 request, with the message of a failure or a refusal.
public sealed record ApproveOutcome(ApproveOutcomeKind Kind, string Message = "")
{
    public static readonly ApproveOutcome Open = new(ApproveOutcomeKind.Open);
    public static readonly ApproveOutcome Approved = new(ApproveOutcomeKind.Approved);
    public static readonly ApproveOutcome Enrolled = new(ApproveOutcomeKind.Enrolled);
    public static readonly ApproveOutcome Denied = new(ApproveOutcomeKind.Denied);
    public static readonly ApproveOutcome Cancelled = new(ApproveOutcomeKind.Cancelled);
    public static readonly ApproveOutcome Expired = new(ApproveOutcomeKind.Expired);
    public static readonly ApproveOutcome Unpaired = new(ApproveOutcomeKind.Unpaired);

    public static ApproveOutcome Failed(string message) => new(ApproveOutcomeKind.Failed, message);
    public static ApproveOutcome Refused(string message) => new(ApproveOutcomeKind.Refused, message);

    public string Text => Kind switch
    {
        ApproveOutcomeKind.Open => "Waiting",
        ApproveOutcomeKind.Approved => "Approved",
        ApproveOutcomeKind.Enrolled => "Enrolled",
        ApproveOutcomeKind.Denied => "Denied",
        ApproveOutcomeKind.Failed => $"Failed: {Message}",
        ApproveOutcomeKind.Refused => $"Refused: {Message}",
        ApproveOutcomeKind.Cancelled => "Cancelled by the computer",
        ApproveOutcomeKind.Expired => "Timed out",
        _ => "Ended by the unpair",
    };
}

// 1 entry of the recent requests.
public sealed record ApproveRecord(
    Guid Id,
    string RequestId,
    string ComputerId,
    ApproveKind Kind,
    // The question of the request, or a note for a request that is not valid.
    string Summary,
    DateTimeOffset Received,
    ApproveOutcome Outcome,
    // The request, for the chat. It is null for a request that is not valid.
    ApproveRequest? Request = null,
    // When the request ended, or null while it is open.
    DateTimeOffset? Resolved = null);

// Whether this computer can approve.
public enum ApproveAvailabilityKind
{
    Ready,

    // The user did not set up Windows Hello, or the app has no signer.
    NoSecureHardware,

    // Windows Hello is not set up, locked, or not available now.
    UserCheck,
}

public sealed record ApproveAvailability(ApproveAvailabilityKind Kind, string Message = "")
{
    public static readonly ApproveAvailability Ready = new(ApproveAvailabilityKind.Ready);
}

// The steps of the approval prompt.
public enum ApprovePhaseKind
{
    // The prompt asks the user.
    Ask,

    // Windows Hello runs.
    Working,

    // The enrollment is done. The prompt shows the key code in Text.
    Enrolled,

    // The request failed. The prompt shows the message in Text. The computer
    // asks for the password.
    Failed,
}

public sealed record ApprovePhase(ApprovePhaseKind Kind, string Text = "")
{
    public static readonly ApprovePhase Ask = new(ApprovePhaseKind.Ask);
    public static readonly ApprovePhase Working = new(ApprovePhaseKind.Working);

    public static ApprovePhase Enrolled(string code) => new(ApprovePhaseKind.Enrolled, code);
    public static ApprovePhase Failed(string message) => new(ApprovePhaseKind.Failed, message);
}

// The UI state of approvals. ApprovePlugin changes it on the UI thread.
// ApproveModel.swift of the Mac app has the same state.
public sealed class ApproveModel : Model
{
    internal const int HistoryLimit = 20;

    ApproveRequest? current;
    DateTimeOffset? deadline;
    int secondsLeft;
    ApproveRequest? shown;
    ApprovePhase phase = ApprovePhase.Ask;
    ValueList<ApproveRecord> history = ValueList<ApproveRecord>.Empty;
    ValueList<ApproveKeyInfo> keys = ValueList<ApproveKeyInfo>.Empty;

    internal ApproveModel()
    {
    }

    // Asks the app to bring the prompt to the front, on the UI thread.
    public event Action? PresentRequested;

    // The open request, or null. This computer has at most 1 open request.
    public ApproveRequest? Current
    {
        get => current;
        internal set
        {
            if (Set(ref current, value))
            {
                Changed(nameof(ExpiresText));
            }
        }
    }

    // When the open request expires.
    public DateTimeOffset? Deadline
    {
        get => deadline;
        internal set => Set(ref deadline, value);
    }

    // The whole seconds until the open request expires, for the countdown.
    // The plugin counts it down once a second. It is 0 without a request.
    public int SecondsLeft
    {
        get => secondsLeft;
        internal set
        {
            if (Set(ref secondsLeft, value))
            {
                Changed(nameof(ExpiresText));
            }
        }
    }

    // The text of the countdown, or null without an open request.
    public string? ExpiresText => current is null ? null : ApproveTexts.Expires(secondsLeft);

    // The request that the prompt shows. It stays after an enrollment or a
    // failure, so that the prompt can show the result.
    public ApproveRequest? Shown
    {
        get => shown;
        internal set => Set(ref shown, value);
    }

    public ApprovePhase Phase
    {
        get => phase;
        internal set => Set(ref phase, value);
    }

    // The recent requests, the newest first.
    public ValueList<ApproveRecord> History
    {
        get => history;
        internal set => Set(ref history, value);
    }

    // The enrolled keys, by computer ID in order.
    public ValueList<ApproveKeyInfo> Keys
    {
        get => keys;
        internal set => Set(ref keys, value);
    }

    // The key of the computer, or null.
    public ApproveKeyInfo? KeyFor(string computerId) => keys.FirstOrDefault(k => k.ComputerId == computerId);

    internal void Present() => PresentRequested?.Invoke();

    internal void Record(ApproveRecord r) => History = ValueList.From(history.Prepend(r).Take(HistoryLimit));

    internal void Resolve(string requestId, ApproveOutcome outcome)
    {
        var i = history.ToList().FindIndex(r => r.RequestId == requestId && r.Outcome == ApproveOutcome.Open);
        if (i < 0)
        {
            return;
        }
        var list = history.ToArray();
        list[i] = list[i] with { Outcome = outcome, Resolved = DateTimeOffset.Now };
        History = ValueList.From(list);
    }
}
