namespace FluxKit;

// The texts of approvals. They are the texts of ApproveTexts.swift of the Mac
// app with these changes: "this computer" for "this Mac", and Windows Hello
// for Touch ID and the Secure Enclave. Windows Hello also takes its PIN, so
// the texts name the PIN where the Mac names only the fingerprint. The texts
// that go to the computer as an error also show on the computer, after the
// words "the phone could not make the key". docs/approve.md and
// docs/approvals.md use the same words.
public static class ApproveTexts
{
    // The name of the user check.
    public const string UserCheck = "Windows Hello";

    public const string DeviceNoun = "this computer";
    const string Device = "This computer";

    // Where the user sets up Windows Hello.
    const string SignInOptions = "Settings > Accounts > Sign-in options";

    // The command that starts approvals on the computer.
    public const string SetupCommand = "sudo flux-cli approve setup";

    public const string NotValid = "The request is not valid";

    // The summary of a request that is not valid, in the history.
    public const string NotValidSummary = "A request that is not valid";

    public const string ClockSkew = $"The clocks of {DeviceNoun} and the computer differ by more than 10 minutes";
    public const string NoKey = $"{Device} has no key for the computer. Run: sudo flux-cli approve enroll";
    public const string AnotherOpen = $"Another request is open on {DeviceNoun}";
    public const string NotConnected = "The computer is not connected.";

    public static string EnrollTitle(string host) => $"Enroll {DeviceNoun} on {host}?";

    public static string EnrollDetail(string computer) =>
        $"Flux makes a key for {computer} in {UserCheck} on {DeviceNoun}. Each approval then needs {UserCheck}: a fingerprint, a face, or the PIN.";

    public static string EnrollReplaces(string computer) => $"This replaces the current approval key for {computer}.";

    public static string EnrollQuestion(string user, string host) => $"Use {DeviceNoun} to approve sudo for user {user} on host {host}?";

    // The reason that the prompt of the user check shows.
    public static string EnrollReason(string user, string host) => $"enroll {DeviceNoun} to approve sudo for {user} on {host}";

    public static string ApproveReason(ApproveRequest r) => $"approve {r.Service} for {r.User} on {r.Host}";

    // The title of the notification of a request, and of its Inbox item.
    public static string Title(ApproveRequest r) => r.Kind == ApproveKind.Approve
        ? $"Approve {r.Service} on {r.Host}?"
        : EnrollTitle(r.Host);

    public static string NotReached(string computer, bool oldKeyStays) =>
        $"The new key did not reach {computer}." + (oldKeyStays ? " The old key stays." : "");

    // Windows Hello reports that the key is gone or not valid, for example
    // after a reset of the PIN.
    public const string KeyInvalid = $"{UserCheck} on {DeviceNoun} no longer has the approval key. Enroll again with: sudo flux-cli approve enroll";
    public const string SaveFailed = $"{Device} could not save its approval key.";
    public const string NotSetUp = $"Set up {UserCheck} in {SignInOptions} first.";
    public const string LockedOut = $"{UserCheck} is locked. Unlock {DeviceNoun} with the password first.";
    public const string Unavailable = $"{UserCheck} is not available on {DeviceNoun}.";
    public const string NotRecognized = $"{UserCheck} did not recognize you.";
    public const string DeviceLocked = $"{Device} is locked, so it cannot use its approval key.";
    public const string MakeFailed = $"{Device} could not make its approval key.";
    public const string UseFailed = $"{Device} could not use its approval key.";

    // Why a computer without Windows Hello cannot approve. Flux never makes
    // a key outside Windows Hello.
    public const string NoSecureHardware = $"{Device} has no {UserCheck}, so it cannot keep an approval key. Set up a PIN in {SignInOptions}.";

    // The PIN of Windows Hello can sign. docs/approve.md, section Windows,
    // tells why.
    public const string PinNote = $"The {UserCheck} PIN can approve too. Anyone who knows the PIN can approve at {DeviceNoun}.";

    // The hint while the user check runs.
    public const string Working = $"Confirm with {UserCheck}.";

    // The hint while an enrollment runs. Windows Hello asks once to make the
    // key, and once for the signature of the enrollment.
    public const string EnrollWorking = $"Confirm with {UserCheck} 2 times: to make the key, and to sign with it.";

    // The texts of the prompt. ApprovePrompt.swift of the Mac app has them.
    public const string PromptTitle = "Flux Approval";
    public const string ApproveHint = "Approve only if you just typed the command.";
    public const string ApproveButton = "Approve";
    public const string EnrollButton = "Enroll";
    public const string DenyButton = "Deny";

    public static string Expires(int seconds) => $"Expires in {seconds} s";

    public const string EnrolledTitle = "Compare the key code";

    // The terminal does not show the code. It asks the user to type it, see
    // docs/approvals.md.
    public const string EnrolledHint = "Type this code in the terminal, all 16 characters.";

    public const string FailedHint = "The computer asks for the password.";

    // The texts of the approval card of a computer. ApproveSection.swift of
    // the Mac app has them.
    public const string SectionTitle = $"{UserCheck} Approval";
    public const string NotSetUpStatus = "Not set up";
    public const string EnrolledStatus = "Enrolled";
    public const string KeyCode = "Key code";
    public const string RecentRequests = "Recent requests";
    public const string NoRequests = "No requests yet.";
    public const string RemoveKeyButton = "Remove Key";

    public static string Setup(string computer) =>
        $"Approve sudo, polkit, and the lock screen of {computer} with {UserCheck} on {DeviceNoun}. Run this command on {computer}, then select Enroll on {DeviceNoun}:";

    public static string EnrolledFor(string user, string host) => $"Approves sudo, polkit, and the lock screen for {user} on {host}.";

    public static string EnrollAgain(string computer) => $"To enroll again, run sudo flux-cli approve enroll on {computer}.";

    public static string RemoveKeyQuestion(string computer) => $"Remove the approval key for {computer}?";

    public static string RemoveKeyDetail(string computer) =>
        $"{Device} can no longer approve requests of {computer}. Run sudo flux-cli approve remove on {computer} to delete its key file too.";

    // The banner of the page of a computer while its request is open.
    public const string ShowPrompt = "Show…";

    // The item of the menu of a computer while its request is open.
    public static string MenuTitle(ApproveRequest r) => r.Kind == ApproveKind.Approve ? $"Approve {r.Service} Request…" : "Enrollment Request…";

    // The tooltips of the buttons of the chat card. The card never approves
    // by itself.
    public const string DenyHelp = "Deny the request";
    public const string ReviewHelp = $"Open the approval prompt. It asks for {UserCheck} before it approves.";

    // The user and the terminal of a request, such as "user dev · pts/3".
    public static string RequestLine(ApproveRequest r) =>
        string.Join(" · ", new[] { r.User.Length == 0 ? "" : $"user {r.User}", r.Tty }.Where(p => p.Length > 0));

    // The state word of the answer of this computer to a request.
    public static string AnswerState(ApproveRecord r) => r.Outcome.Kind switch
    {
        ApproveOutcomeKind.Enrolled => "Enrolled",
        ApproveOutcomeKind.Approved => "Approved",
        _ => "Denied",
    };

    // The title of the answer card, such as "Approved sudo for dev". A
    // record without its request shows its summary.
    public static string AnswerTitle(ApproveRecord record)
    {
        if (record.Request is not { } r)
        {
            return record.Summary;
        }
        var forUser = r.User.Length == 0 ? "" : $" for {r.User}";
        return record.Outcome.Kind switch
        {
            ApproveOutcomeKind.Enrolled => $"Enrolled {DeviceNoun} on {r.Host}",
            ApproveOutcomeKind.Denied when r.Kind == ApproveKind.Enroll => $"Denied the enrollment on {r.Host}",
            ApproveOutcomeKind.Denied => $"Denied {r.Service}{forUser}",
            _ => $"Approved {r.Service}{forUser}",
        };
    }

    // The sentence that the unpair dialog adds when this computer has a key
    // for the computer. AppModel.swift of the Mac app has it.
    public static string UnpairNote(string computer) =>
        $"{Device} deletes its approval key for {computer}. The key file on the computer stays until you run: sudo flux-cli approve remove";

    // The text of a problem of the user check, or null when it works.
    public static string? Problem(ApproveUserCheck check) => check switch
    {
        ApproveUserCheck.Ready => null,
        ApproveUserCheck.NotSetUp => NotSetUp,
        ApproveUserCheck.LockedOut => LockedOut,
        _ => Unavailable,
    };

    // The text of a failed signature. kind tells whether the key was new.
    public static string Failure(ApproveKeyError error, ApproveKind kind) => error switch
    {
        ApproveKeyError.NotRecognized => NotRecognized,
        ApproveKeyError.LockedOut => LockedOut,
        ApproveKeyError.NotSetUp => NotSetUp,
        ApproveKeyError.Unavailable => Unavailable,
        ApproveKeyError.KeyInvalid => KeyInvalid,
        ApproveKeyError.DeviceLocked => DeviceLocked,
        _ => kind == ApproveKind.Enroll ? MakeFailed : UseFailed,
    };
}
