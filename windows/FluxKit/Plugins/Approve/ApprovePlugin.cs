using System.Diagnostics;
using System.Globalization;

namespace FluxKit;

// flux.approve in both directions. A paired computer asks this computer to
// approve sudo, polkit, or a lock screen, or to make the key for approvals.
// This computer signs with its Windows Hello key only after Windows Hello,
// and the root helper on the computer checks the signature. This computer shows 1 request
// at a time. ApprovePlugin.swift of the Mac app has the same rules.
// docs/approve.md is the security design.
//
// The plugin changes its state only on the UI thread. The user check and the
// signature run on a thread of the pool.
public sealed class ApprovePlugin : IFluxPlugin
{
    public const string NotificationCategory = "approve";
    internal const string NotificationId = "approve";
    internal const string ApproveAction = "approve";
    internal const string DenyAction = "deny";

    readonly IApproveSigner? signer;
    FluxCore? core;
    ApproveKeys? keys;
    // The countdown and the expiry of the open request.
    CancellationTokenSource? timer;
    // Ends the running user check and signature. A cancel closes the prompt
    // of Windows Hello.
    CancellationTokenSource? signing;

    // signer is null while the app cannot keep approval keys. This computer
    // then does not list flux.approve, and it refuses each request.
    public ApprovePlugin(IApproveSigner? signer = null)
    {
        this.signer = signer;
        Incoming = signer is null ? [] : [PacketType.Approve];
        Outgoing = signer is null ? [] : [PacketType.Approve];
    }

    public ApproveModel Model { get; } = new();

    public IReadOnlyList<string> Incoming { get; }
    public IReadOnlyList<string> Outgoing { get; }
    public IReadOnlyList<string> HandledTypes { get; } = [PacketType.Approve];

    // The length of 1 second of the countdown. A test sets a shorter time.
    internal TimeSpan Second { get; set; } = TimeSpan.FromSeconds(1);

    public void Attach(FluxCore core)
    {
        this.core = core;
        var keys = new ApproveKeys(core.Paths.File("approve"), name => signer?.DeleteKey(name));
        this.keys = keys;
        if (signer is not null)
        {
            keys.DiscardLeftovers();
        }
        core.Host.Notifier.Register(NotificationCategory, NotificationActions, (action, info, _) =>
        {
            if (info.TryGetValue("id", out var id))
            {
                core.Host.Post(() => NotificationAction(action, id));
            }
        });
        core.Host.Post(() => Model.Keys = keys.All());
    }

    // The core lock is held. The UI queue keeps the order of the packets.
    public void Handle(Packet packet, Device device)
    {
        var computerId = device.Id;
        var computerName = device.Name;
        core?.Host.Post(() => Receive(packet, computerId, computerName));
    }

    // An unpair from either side ends the open request of the computer. A
    // link that only drops leaves it, because the computer can connect again
    // before the request expires. The core lock is held.
    public void OnDisconnected(Device device)
    {
        if (device.Paired)
        {
            return;
        }
        var computerId = device.Id;
        core?.Host.Post(() => Unpaired(computerId));
    }

    // Ends the open request or enrollment of a computer that is no longer
    // paired. An enrollment also drops its new key.
    internal void Unpaired(string computerId)
    {
        if (Model.Current is not { } r || r.ComputerId != computerId)
        {
            return;
        }
        FluxLog.Info("approve", $"the request of {r.ComputerName} ended with the unpair");
        if (r.Kind == ApproveKind.Enroll)
        {
            keys?.Discard(computerId);
        }
        End(r.Id, ApproveOutcome.Unpaired);
    }

    // Requests

    internal void Receive(Packet p, string computerId, string computerName)
    {
        switch (p.String("kind"))
        {
            case "cancel":
                // Only the computer of the open request can cancel it.
                if (p.String("id") is { } id && Model.Current?.ComputerId == computerId)
                {
                    End(id, ApproveOutcome.Cancelled);
                }
                break;
            case "request":
            case "enroll":
                Open(p, computerId, computerName);
                break;
        }
    }

    void Open(Packet p, string computerId, string computerName)
    {
        if (p.String("id") is not { } id || keys is null)
        {
            return;
        }
        var r = ApproveMessage.Parse(p, computerId, computerName);
        // The same request again brings the prompt to the front.
        if (r is not null && Model.Current is { } open && open.Id == r.Id && open.ComputerId == computerId)
        {
            Model.Present();
            return;
        }
        var problem = Refusal(r, DateTimeOffset.UtcNow.ToUnixTimeSeconds(), keys.Has(computerId), Model.Current is not null,
            signer?.HasSecureHardware == true);
        if (problem is not null)
        {
            FluxLog.Info("approve", $"refused a request from {computerName}: {problem}");
            core?.Send(ApproveMessage.Failed(id, problem), computerId);
            var kind = r?.Kind ?? (p.String("kind") == "enroll" ? ApproveKind.Enroll : ApproveKind.Approve);
            Model.Record(new ApproveRecord(Guid.NewGuid(), id, computerId, kind,
                r is null ? ApproveTexts.NotValidSummary : ApproveMessage.Question(r), DateTimeOffset.Now, ApproveOutcome.Refused(problem)));
            return;
        }
        // Refusal answers each request that is not valid.
        if (r is null)
        {
            return;
        }
        Model.Current = r;
        Model.Shown = r;
        Model.Phase = ApprovePhase.Ask;
        Model.Deadline = DateTimeOffset.Now.AddSeconds(r.TimeoutSeconds);
        Model.SecondsLeft = r.TimeoutSeconds;
        Model.Record(new ApproveRecord(Guid.NewGuid(), r.Id, computerId, r.Kind, ApproveMessage.Question(r), DateTimeOffset.Now,
            ApproveOutcome.Open, r));
        Arm(r);
        core?.Host.Notifier.Post(new SystemNotification(NotificationId, NotificationCategory, ApproveTexts.Title(r),
            string.Join("\n", new[] { ApproveMessage.Question(r) }.Concat(Details(r, ReplacesKey(r)))))
        {
            UserInfo = new Dictionary<string, string> { ["id"] = r.Id },
        });
        Model.Present();
    }

    // Why this computer refuses the request without asking the user, or
    // null. r is null for a request that is not valid. Without Windows Hello,
    // each request fails at once, because Flux never makes a key outside it.
    internal static string? Refusal(ApproveRequest? r, long now, bool hasKey, bool busy, bool secureHardware)
    {
        if (r is null)
        {
            return ApproveTexts.NotValid;
        }
        if (!secureHardware)
        {
            return ApproveTexts.NoSecureHardware;
        }
        if (!ApproveMessage.Fresh(r, now))
        {
            return ApproveTexts.ClockSkew;
        }
        if (r.Kind == ApproveKind.Approve && !hasKey)
        {
            return ApproveTexts.NoKey;
        }
        if (busy)
        {
            return ApproveTexts.AnotherOpen;
        }
        return null;
    }

    // The actions of the notification.
    internal static IReadOnlyList<NotificationAction> NotificationActions { get; } =
    [
        new NotificationAction(ApproveAction, ApproveTexts.ApproveButton),
        new NotificationAction(DenyAction, ApproveTexts.DenyButton),
    ];

    // What a notification action does.
    internal enum NotificationRoute
    {
        // Shows the prompt.
        Present,

        // Shows the prompt and asks for Windows Hello at once.
        Approve,

        Deny,
    }

    // Approve asks for Windows Hello at once, as on the Mac. A click on the
    // notification itself shows the prompt.
    internal static NotificationRoute Route(string action) => action switch
    {
        ApproveAction => NotificationRoute.Approve,
        DenyAction => NotificationRoute.Deny,
        _ => NotificationRoute.Present,
    };

    // The lines under the question: the terminal, the remote host, and who
    // asks. An enrollment that replaces the current key of the computer says
    // so.
    public static IReadOnlyList<string> Details(ApproveRequest r, bool replacesKey = false)
    {
        if (r.Kind == ApproveKind.Enroll)
        {
            var detail = ApproveTexts.EnrollDetail(r.ComputerName);
            return replacesKey ? [detail, ApproveTexts.EnrollReplaces(r.ComputerName)] : [detail];
        }
        var lines = new List<string>();
        if (r.Tty.Length > 0)
        {
            lines.Add($"Terminal: {r.Tty}");
        }
        if (r.Rhost.Length > 0)
        {
            lines.Add($"From: {r.Rhost}");
        }
        var time = r.Time <= DateTimeOffset.MaxValue.ToUnixTimeSeconds()
            ? DateTimeOffset.FromUnixTimeSeconds(r.Time).ToLocalTime().ToString("T", CultureInfo.CurrentCulture)
            : r.Time.ToString(CultureInfo.InvariantCulture);
        lines.Add($"Asked at {time} by {r.ComputerName}");
        return lines;
    }

    // True when the enrollment r replaces the current key of its computer.
    public bool ReplacesKey(ApproveRequest r) => r.Kind == ApproveKind.Enroll && Model.KeyFor(r.ComputerId) is not null;

    // Counts the open request down once a second, and ends it when its time
    // ends. The computer stops its wait at the same time.
    void Arm(ApproveRequest r)
    {
        timer?.Cancel();
        timer?.Dispose();
        var cts = new CancellationTokenSource();
        timer = cts;
        _ = CountAsync(r.Id, r.TimeoutSeconds, cts);
    }

    async Task CountAsync(string id, int seconds, CancellationTokenSource cts)
    {
        var start = Stopwatch.GetTimestamp();
        var token = cts.Token;
        try
        {
            for (var left = seconds - 1; left >= 0; left--)
            {
                // Each step waits for the next whole second from the start,
                // so that the delays do not add up.
                var wait = (seconds - left) * Second - Stopwatch.GetElapsedTime(start);
                if (wait > TimeSpan.Zero)
                {
                    await Task.Delay(wait, token).ConfigureAwait(false);
                }
                var now = left;
                core?.Host.Post(() => Tick(id, now, cts));
            }
        }
        catch (OperationCanceledException)
        {
        }
    }

    void Tick(string id, int left, CancellationTokenSource cts)
    {
        // A tick of an earlier request does nothing.
        if (timer != cts)
        {
            return;
        }
        if (left > 0)
        {
            Model.SecondsLeft = left;
        }
        else
        {
            End(id, ApproveOutcome.Expired);
        }
    }

    // Actions

    // Asks for Windows Hello, signs the open request, and sends the
    // signature. For an enrollment, it first makes a new key. Call it on the
    // UI thread.
    public void Approve()
    {
        if (Model.Current is not { } r || Model.Phase != ApprovePhase.Ask || core is null || keys is null)
        {
            return;
        }
        if (signer is null)
        {
            Fail(r, ApproveTexts.NoSecureHardware);
            return;
        }
        // An approval signs with the current key. An enrollment makes its new
        // key under the other name, so that the current key stays.
        var key = keys.Current(r.ComputerId);
        // The user can remove the key while the request is open.
        if (r.Kind == ApproveKind.Approve && key is null)
        {
            Fail(r, ApproveTexts.NoKey);
            return;
        }
        Model.Phase = ApprovePhase.Working;
        var cts = new CancellationTokenSource();
        signing = cts;
        var platform = signer;
        var job = Task.Run(() => SignAsync(platform, r, key, cts.Token));
        var host = core.Host;
        _ = job.ContinueWith(t => host.Post(() => Signed(r, cts, t)), TaskScheduler.Default);
    }

    // Denies the open request. Call it on the UI thread.
    public void Deny()
    {
        if (Model.Current is not { } r)
        {
            return;
        }
        core?.Send(ApproveMessage.Denied(r.Id), r.ComputerId);
        End(r.Id, ApproveOutcome.Denied);
    }

    // Closes the result of an enrollment or a failure. Call it on the UI
    // thread.
    public void CloseResult()
    {
        if (Model.Current is not null)
        {
            return;
        }
        Model.Shown = null;
        Model.Phase = ApprovePhase.Ask;
    }

    // Deletes the key of the computer, also in the platform. The key file on
    // the computer stays until sudo flux-cli approve remove. Call it on the
    // UI thread.
    public void RemoveKey(string computerId)
    {
        if (keys is null)
        {
            return;
        }
        keys.Delete(computerId);
        Model.Keys = keys.All();
    }

    // Unpairs the computer and deletes the approval key of this computer for
    // it, so that a new pairing needs a new enrollment. The app calls it in
    // place of FluxCore.Unpair. Call it on the UI thread.
    public void Unpair(string computerId)
    {
        core?.Unpair(computerId);
        RemoveKey(computerId);
    }

    // Whether this computer can approve: it needs Windows Hello. It never
    // falls back to a key outside Windows Hello.
    public async Task<ApproveAvailability> AvailabilityAsync(CancellationToken cancel = default)
    {
        if (signer is null || !signer.HasSecureHardware)
        {
            return Availability(false, null);
        }
        var check = await signer.CheckUserAsync(cancel).ConfigureAwait(false);
        return Availability(true, ApproveTexts.Problem(check));
    }

    // Without Windows Hello, no other check matters, so it comes first.
    internal static ApproveAvailability Availability(bool secureHardware, string? problem)
    {
        if (!secureHardware)
        {
            return new ApproveAvailability(ApproveAvailabilityKind.NoSecureHardware, ApproveTexts.NoSecureHardware);
        }
        return problem is null ? ApproveAvailability.Ready : new ApproveAvailability(ApproveAvailabilityKind.UserCheck, problem);
    }

    void NotificationAction(string action, string id)
    {
        if (Model.Current?.Id != id)
        {
            return;
        }
        switch (Route(action))
        {
            case NotificationRoute.Approve:
                Model.Present();
                Approve();
                break;
            case NotificationRoute.Deny:
                Deny();
                break;
            case NotificationRoute.Present:
                Model.Present();
                break;
        }
    }

    // The result of 1 signature. NewKey is the key that an enrollment made.
    sealed record SignResult(byte[] Signature, ApproveNewKey? NewKey);

    // Checks the user, then signs. It runs on a thread of the pool. key is
    // the current key of the computer. An enrollment deletes its new key when
    // a step fails. Each signature must verify with its public key before it
    // goes out.
    static async Task<SignResult> SignAsync(IApproveSigner signer, ApproveRequest r, ApproveKeyRecord? key, CancellationToken cancel)
    {
        var check = await signer.CheckUserAsync(cancel).ConfigureAwait(false);
        if (check != ApproveUserCheck.Ready)
        {
            throw new ApproveKeyException(check switch
            {
                ApproveUserCheck.NotSetUp => ApproveKeyError.NotSetUp,
                ApproveUserCheck.LockedOut => ApproveKeyError.LockedOut,
                _ => ApproveKeyError.Unavailable,
            });
        }
        if (r.Kind == ApproveKind.Approve)
        {
            var message = ApproveMessage.Approval(r);
            var signature = await signer.SignAsync(key!.Name, message, ApproveTexts.ApproveReason(r), cancel).ConfigureAwait(false);
            if (!ApproveMessage.Verify(key.PublicKey, message, signature))
            {
                throw new ApproveKeyException(ApproveKeyError.Failed, "the signature does not verify with the stored public key" + ApproveMessage.Scheme(key.PublicKey, message, signature));
            }
            return new SignResult(signature, null);
        }
        var created = await signer.CreateKeyAsync(r.ComputerId, key?.Name, cancel).ConfigureAwait(false);
        var kept = false;
        try
        {
            var message = ApproveMessage.Enrollment(r, created.PublicKey);
            var signature = await signer.SignAsync(created.Name, message, ApproveTexts.EnrollReason(r.User, r.Host), cancel).ConfigureAwait(false);
            if (!ApproveMessage.Verify(created.PublicKey, message, signature))
            {
                throw new ApproveKeyException(ApproveKeyError.Failed, "the signature does not verify with the new public key" + ApproveMessage.Scheme(created.PublicKey, message, signature));
            }
            kept = true;
            return new SignResult(signature, created);
        }
        finally
        {
            if (!kept)
            {
                DeleteQuietly(signer, created.Name);
            }
        }
    }

    static void DeleteQuietly(IApproveSigner signer, string name)
    {
        try
        {
            signer.DeleteKey(name);
        }
        catch (ApproveKeyException e)
        {
            FluxLog.Error("approve", $"cannot delete an approval key in the platform: {e.Message}");
        }
    }

    // Takes the result of a signature on the UI thread.
    void Signed(ApproveRequest r, CancellationTokenSource cts, Task<SignResult> job)
    {
        if (signing == cts)
        {
            signing = null;
        }
        cts.Dispose();
        // The request ended while Windows Hello ran: the answer is too late.
        if (Model.Current != r)
        {
            if (job.IsCompletedSuccessfully && job.Result.NewKey is { } late && signer is not null)
            {
                DeleteQuietly(signer, late.Name);
            }
            return;
        }
        if (job.IsCompletedSuccessfully)
        {
            var s = job.Result;
            if (s.NewKey is { } key)
            {
                Enrolled(r, key, s.Signature);
            }
            else if (core?.Send(ApproveMessage.Approved(r.Id, s.Signature), r.ComputerId) == true)
            {
                End(r.Id, ApproveOutcome.Approved);
            }
            else
            {
                Fail(r, ApproveTexts.NotConnected);
            }
            return;
        }
        var error = job.Exception?.InnerException;
        if (job.IsCanceled || error is OperationCanceledException or ApproveKeyException { Error: ApproveKeyError.Cancelled })
        {
            Model.Phase = ApprovePhase.Ask;
            return;
        }
        var kind = error is ApproveKeyException e ? e.Error : ApproveKeyError.Failed;
        FluxLog.Error("approve", $"signing failed: {error?.GetType().Name}: {error?.Message}");
        // A key that the platform refuses goes, and the user enrolls again.
        if (kind == ApproveKeyError.KeyInvalid && r.Kind == ApproveKind.Approve)
        {
            RemoveKey(r.ComputerId);
        }
        Fail(r, ApproveTexts.Failure(kind, r.Kind));
    }

    // The old key stays until the new key reached the computer, so that a
    // failed enrollment keeps the approvals working.
    void Enrolled(ApproveRequest r, ApproveNewKey key, byte[] signature)
    {
        try
        {
            keys!.Stage(key.Name, key.PublicKey, r.ComputerId, r.Host, r.User);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            FluxLog.Error("approve", $"saving the key failed: {e.Message}");
            DeleteQuietly(signer!, key.Name);
            Fail(r, ApproveTexts.SaveFailed);
            return;
        }
        if (core?.Send(ApproveMessage.Enrolled(r.Id, key.PublicKey, signature), r.ComputerId) != true)
        {
            keys.Discard(r.ComputerId);
            Fail(r, ApproveTexts.NotReached(r.ComputerName, keys.Has(r.ComputerId)));
            return;
        }
        try
        {
            keys.Commit(r.ComputerId);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            FluxLog.Error("approve", $"saving the key failed: {e.Message}");
            keys.Discard(r.ComputerId);
            Fail(r, ApproveTexts.SaveFailed);
            return;
        }
        Model.Keys = keys.All();
        Model.Phase = ApprovePhase.Enrolled(ApproveMessage.Fingerprint(key.PublicKey));
        End(r.Id, ApproveOutcome.Enrolled);
    }

    void Fail(ApproveRequest r, string message)
    {
        core?.Send(ApproveMessage.Failed(r.Id, message), r.ComputerId);
        Model.Phase = ApprovePhase.Failed(message);
        End(r.Id, ApproveOutcome.Failed(message));
    }

    // Ends the request id: it closes the notification, the prompt of Windows
    // Hello, and the prompt, unless the prompt shows a result.
    void End(string id, ApproveOutcome outcome)
    {
        if (Model.Current?.Id != id)
        {
            return;
        }
        Model.Current = null;
        Model.Deadline = null;
        Model.SecondsLeft = 0;
        timer?.Cancel();
        timer?.Dispose();
        timer = null;
        // The continuation of the signature disposes it.
        signing?.Cancel();
        signing = null;
        core?.Host.Notifier.Remove(NotificationId);
        Model.Resolve(id, outcome);
        if (Model.Phase.Kind is ApprovePhaseKind.Ask or ApprovePhaseKind.Working)
        {
            Model.Shown = null;
            Model.Phase = ApprovePhase.Ask;
        }
    }
}
