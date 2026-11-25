namespace FluxKit;

// A new approval key: the name of the key in the platform, and the public
// key. The private key stays in the platform.
public sealed record ApproveNewKey(string Name, byte[] PublicKey);

// Whether the user check of the platform works now.
public enum ApproveUserCheck
{
    Ready,

    // The user did not set up Windows Hello.
    NotSetUp,

    // Windows Hello is locked after too many failed tries.
    LockedOut,

    // Windows Hello is not available now, for example by a policy.
    Unavailable,
}

// Why a call of the platform signer failed.
public enum ApproveKeyError
{
    // The user or the system closed the user check, or FluxKit cancelled the
    // call. The prompt asks again.
    Cancelled,

    // Windows Hello did not recognize the user.
    NotRecognized,

    // Windows Hello is locked after too many failed tries.
    LockedOut,

    // The user did not set up Windows Hello.
    NotSetUp,

    // Windows Hello is not available now.
    Unavailable,

    // The key is not valid any more, for example after a reset of the
    // Windows Hello PIN. Flux deletes the key, and the user enrolls again.
    KeyInvalid,

    // The computer is locked, so the key does not work.
    DeviceLocked,

    // Any other failure of the key or of Windows Hello.
    Failed,
}

// A failure of the platform signer. Any other exception from the signer
// counts as ApproveKeyError.Failed.
public sealed class ApproveKeyException(ApproveKeyError error, string? detail = null, Exception? inner = null)
    : Exception(detail ?? error.ToString(), inner)
{
    public ApproveKeyError Error { get; } = error;
}

// The names of the Windows Hello keys of 1 computer. A computer has 2 names,
// as the aliases of Flux for Android: flux-approve-<computer ID> and
// flux-approve-<computer ID>.b. An enrollment makes its new key under the
// name that the current key does not use, so that the current key stays
// until the computer got the new key. docs/approve.md is the design.
public static class ApproveKeyNames
{
    public const string Prefix = "flux-approve-";

    // The first name of the key of the computer.
    public static string First(string computerId) => Prefix + computerId;

    // The second name of the key of the computer.
    public static string Second(string computerId) => Prefix + computerId + ".b";

    // The name of the new key of an enrollment. current is the name of the
    // current key of the computer, or null.
    public static string Next(string computerId, string? current) =>
        current == First(computerId) ? Second(computerId) : First(computerId);
}

// The approval keys of the platform and the user check before each
// signature. The Windows app implements it with Windows Hello: each key is an
// RSA 2048 key of KeyCredentialManager, in the TPM when the computer has one.
// Each signature needs Windows Hello first: a fingerprint, a face, or the
// Windows Hello PIN. The tests use a software key.
//
// The rules of docs/approve.md apply to each implementation:
// - Make each key in Windows Hello. Never make a key outside it. A computer
//   without Windows Hello reports false for HasSecureHardware.
// - Keep the private key in the platform. FluxKit gets only the name of the
//   key and its public key.
// - Each call of SignAsync asks the user check of the platform for that 1
//   signature. A check never signs 2 messages, and nothing signs without it.
//   No other member signs.
// - A signature of an RSA 2048 key is RSASSA-PKCS1-v1_5 with SHA-256 over
//   the message, the scheme of Windows Hello. A signature of an EC P-256 key
//   is ECDSA with SHA-256 in ASN.1 DER. ApproveMessage.Verify checks each
//   signature before it goes out.
//
// FluxKit calls CheckUserAsync, CreateKeyAsync, and SignAsync from a thread
// of the pool, 1 call at a time. An implementation that needs the UI thread
// for the prompt of the user check moves the call there itself. FluxKit reads
// HasSecureHardware on the UI thread, so it must be fast. FluxKit calls
// DeleteKey on the UI thread or on a thread of the pool, so it must be fast
// and safe on each thread.
public interface IApproveSigner
{
    // True when this computer can make approval keys: Windows Hello is set
    // up for the user. The value can change while the app runs, for example
    // after the user sets up a PIN. FluxKit reads it for each request, so it
    // must be fast.
    bool HasSecureHardware { get; }

    // Whether the user check works now. It does not ask the user.
    Task<ApproveUserCheck> CheckUserAsync(CancellationToken cancel);

    // Makes a new signing key in Windows Hello for the computer computerId.
    // It returns the name and the public key as SubjectPublicKeyInfo DER.
    // currentKey is the name of the current key of that computer, or null.
    // The new key never takes that name, so that the current key stays.
    // Windows Hello can ask the user before it makes the key. FluxKit calls
    // DeleteKey for each key that it does not keep.
    Task<ApproveNewKey> CreateKeyAsync(string computerId, string? currentKey, CancellationToken cancel);

    // Asks the user check of the platform, then signs the message with the
    // key. reason tells the user what the signature approves. It returns the
    // signature over the SHA-256 of message, see above. When cancel ends, the
    // implementation closes the prompt and throws an OperationCanceledException
    // or an ApproveKeyException with ApproveKeyError.Cancelled. It throws an
    // ApproveKeyException for the other failures that it knows.
    Task<byte[]> SignAsync(string keyName, byte[] message, string reason, CancellationToken cancel);

    // Deletes the key from the platform. A key that does not exist is not an
    // error. An implementation can delete in the background. It then deletes
    // in the order of the calls, and before its next CreateKeyAsync starts.
    // It throws an ApproveKeyException when it knows at once that the
    // platform cannot delete the key.
    void DeleteKey(string keyName);
}
