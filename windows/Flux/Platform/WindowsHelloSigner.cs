using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using FluxKit;
using Windows.Foundation.Metadata;
using Windows.Security.Credentials;
using Windows.Security.Cryptography;
using Windows.Security.Cryptography.Core;
using Windows.Storage.Streams;
using Windows.UI;

namespace Flux;

// The approval keys of Flux in Windows Hello. KeyCredentialManager makes each
// key: RSA 2048, in the TPM when the computer has one. The private key never
// leaves Windows Hello. Windows Hello asks for a fingerprint, a face, or its
// PIN before it makes a key and before each signature, so 1 check never
// signs 2 requests. A signature is RSASSA-PKCS1-v1_5 with SHA-256. Windows has
// no setting that takes only biometrics, so the PIN can sign. The user chose
// this exception on 2026-10-15. docs/approve.md, section Windows, is the
// design.
//
// The prompt of Windows Hello belongs to the window that owner gives, the
// approval prompt of Flux. KeyCredentialManager has no interop interface for
// a window handle, as UserConsentVerifierInterop has for UserConsentVerifier.
// Windows 11 24H2 and later have RequestCreateForWindowAsync and
// RequestSignForWindowAsync, which take the window. On an older Windows, Flux
// brings the prompt of Windows Hello to the front after it opens.
public sealed class WindowsHelloSigner : IApproveSigner
{
    // The window class of the prompt of Windows Hello.
    const string PromptClass = "Credential Dialog Xaml Host";

    // The HRESULT values of a key that does not exist: NTE_NOT_FOUND,
    // NTE_BAD_KEYSET, and ERROR_FILE_NOT_FOUND.
    const int NotFound = unchecked((int)0x80090011);
    const int BadKeyset = unchecked((int)0x80090016);
    const int FileNotFound = unchecked((int)0x80070002);

    // The time between 2 checks of IsSupportedAsync that HasSecureHardware starts.
    const long RecheckMilliseconds = 5000;

    // True when this Windows takes the window of the Flux prompt for the
    // prompt of Windows Hello.
    static readonly Lazy<bool> TakesWindow = new(() =>
    {
        try
        {
            return ApiInformation.IsMethodPresent("Windows.Security.Credentials.KeyCredentialManager", "RequestCreateForWindowAsync") &&
                   ApiInformation.IsMethodPresent("Windows.Security.Credentials.KeyCredential", "RequestSignForWindowAsync");
        }
        catch (COMException)
        {
            return false;
        }
    });

    readonly Func<IntPtr> owner;

    // 1 call of Windows Hello at a time, in the order of the calls. So a
    // delete that FluxKit asks for ends before the next key starts.
    readonly SemaphoreSlim gate = new(1, 1);

    // The last answer of IsSupportedAsync: 0 while no answer came, 1 for yes,
    // 2 for no.
    int supported;
    int checking;
    long checkedAt = long.MinValue / 2;

    // owner gives the handle of the window that the prompt of Windows Hello
    // belongs to, or 0. Any thread can call it.
    public WindowsHelloSigner(Func<IntPtr>? owner = null)
    {
        this.owner = owner ?? (() => IntPtr.Zero);
        Recheck();
    }

    // The last answer of IsSupportedAsync, so that the read is fast. While
    // the answer is no, each read starts a new check at most every 5
    // seconds. So a PIN that the user sets up while Flux runs counts from the
    // next request on.
    public bool HasSecureHardware
    {
        get
        {
            var yes = Volatile.Read(ref supported) == 1;
            if (!yes)
            {
                Recheck();
            }
            return yes;
        }
    }

    void Recheck()
    {
        var now = Environment.TickCount64;
        if (now - Interlocked.Read(ref checkedAt) < RecheckMilliseconds || Interlocked.Exchange(ref checking, 1) == 1)
        {
            return;
        }
        Interlocked.Exchange(ref checkedAt, now);
        _ = Task.Run(async () =>
        {
            try
            {
                await IsSupportedAsync(CancellationToken.None).ConfigureAwait(false);
            }
            finally
            {
                Volatile.Write(ref checking, 0);
            }
        });
    }

    // Asks Windows whether the user can make a key. It does not ask the user.
    async Task<bool> IsSupportedAsync(CancellationToken cancel)
    {
        bool yes;
        try
        {
            yes = await KeyCredentialManager.IsSupportedAsync().AsTask(cancel).ConfigureAwait(false);
        }
        catch (Exception e) when (e is COMException or UnauthorizedAccessException)
        {
            FluxLog.Error("approve", $"Windows Hello did not answer: {e.Message}");
            yes = false;
        }
        Volatile.Write(ref supported, yes ? 1 : 2);
        return yes;
    }

    public async Task<ApproveUserCheck> CheckUserAsync(CancellationToken cancel) =>
        await IsSupportedAsync(cancel).ConfigureAwait(false) ? ApproveUserCheck.Ready : ApproveUserCheck.NotSetUp;

    // The new key takes the name that the current key does not use. A key
    // that has that name is a leftover, so the new key takes its place.
    public async Task<ApproveNewKey> CreateKeyAsync(string computerId, string? currentKey, CancellationToken cancel)
    {
        var name = ApproveKeyNames.Next(computerId, currentKey);
        await gate.WaitAsync(cancel).ConfigureAwait(false);
        try
        {
            KeyCredentialRetrievalResult result;
            try
            {
                if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 26100) && Window() is { } window)
                {
                    result = await KeyCredentialManager.RequestCreateForWindowAsync(window, name, KeyCredentialCreationOption.ReplaceExisting)
                        .AsTask(cancel).ConfigureAwait(false);
                }
                else
                {
                    result = await InFrontAsync(() => KeyCredentialManager.RequestCreateAsync(name, KeyCredentialCreationOption.ReplaceExisting), cancel)
                        .ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException)
            {
                // Windows Hello can make the key before the cancel arrives.
                await DeleteNowAsync(name).ConfigureAwait(false);
                throw;
            }
            catch (COMException e)
            {
                throw new ApproveKeyException(ApproveKeyError.Failed, $"Windows Hello could not make the key: {e.Message}", e);
            }
            Check(result.Status);
            try
            {
                var spki = Bytes(result.Credential.RetrievePublicKey(CryptographicPublicKeyBlobType.X509SubjectPublicKeyInfo));
                return new ApproveNewKey(name, spki);
            }
            catch (COMException e)
            {
                await DeleteNowAsync(name).ConfigureAwait(false);
                throw new ApproveKeyException(ApproveKeyError.Failed, $"Windows Hello did not give the public key: {e.Message}", e);
            }
        }
        finally
        {
            gate.Release();
        }
    }

    // The prompt of Windows Hello has its own text, so reason does not show.
    // The approval prompt of Flux shows the request next to it.
    public async Task<byte[]> SignAsync(string keyName, byte[] message, string reason, CancellationToken cancel)
    {
        await gate.WaitAsync(cancel).ConfigureAwait(false);
        try
        {
            KeyCredentialOperationResult result;
            try
            {
                var opened = await KeyCredentialManager.OpenAsync(keyName).AsTask(cancel).ConfigureAwait(false);
                Check(opened.Status);
                var key = opened.Credential;
                var data = CryptographicBuffer.CreateFromByteArray(message);
                if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 26100) && Window() is { } window)
                {
                    result = await key.RequestSignForWindowAsync(window, data).AsTask(cancel).ConfigureAwait(false);
                }
                else
                {
                    result = await InFrontAsync(() => key.RequestSignAsync(data), cancel).ConfigureAwait(false);
                }
            }
            catch (COMException e)
            {
                throw new ApproveKeyException(ApproveKeyError.Failed, $"Windows Hello could not sign: {e.Message}", e);
            }
            Check(result.Status);
            return Bytes(result.Result);
        }
        finally
        {
            gate.Release();
        }
    }

    public void DeleteKey(string keyName) => _ = DeleteAsync(keyName);

    async Task DeleteAsync(string name)
    {
        await gate.WaitAsync().ConfigureAwait(false);
        try
        {
            await DeleteNowAsync(name).ConfigureAwait(false);
        }
        finally
        {
            gate.Release();
        }
    }

    // Deletes the key while the caller holds the gate. A key that does not
    // exist is not an error.
    static async Task DeleteNowAsync(string name)
    {
        try
        {
            await KeyCredentialManager.DeleteAsync(name).AsTask().ConfigureAwait(false);
        }
        catch (Exception e) when (e is COMException or FileNotFoundException or UnauthorizedAccessException)
        {
            if (e.HResult is not (NotFound or BadKeyset or FileNotFound))
            {
                FluxLog.Error("approve", $"Windows Hello could not delete an approval key: {e.Message}");
            }
        }
    }

    // Runs 1 call that shows the prompt of Windows Hello without a window
    // for it, and brings the prompt to the front. A cancel cancels the call,
    // and Windows Hello closes its prompt.
    static async Task<T> InFrontAsync<T>(Func<Windows.Foundation.IAsyncOperation<T>> plain, CancellationToken cancel)
    {
        using var front = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        _ = BringPromptToFrontAsync(front.Token);
        try
        {
            return await plain().AsTask(cancel).ConfigureAwait(false);
        }
        finally
        {
            front.Cancel();
        }
    }

    // The window for the prompt of Windows Hello, so that the prompt belongs
    // to the Flux prompt. It is null when this Windows or Flux has none.
    [SupportedOSPlatform("windows10.0.26100.0")]
    WindowId? Window()
    {
        if (!TakesWindow.Value)
        {
            return null;
        }
        var hwnd = owner();
        if (hwnd == IntPtr.Zero)
        {
            return null;
        }
        try
        {
            return GetWindowIdFromWindow(hwnd, out var id) >= 0 ? new WindowId(id) : null;
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException)
        {
            FluxLog.Error("approve", $"cannot give the window to Windows Hello: {e.Message}");
            return null;
        }
    }

    // The prompt of Windows Hello opens a moment after the call, and it can
    // open behind the windows of Flux. The user just clicked in Flux, so
    // Flux may bring another window to the front.
    static async Task BringPromptToFrontAsync(CancellationToken cancel)
    {
        try
        {
            for (var i = 0; i < 20; i++)
            {
                await Task.Delay(150, cancel).ConfigureAwait(false);
                var prompt = FindWindow(PromptClass, null);
                if (prompt != IntPtr.Zero)
                {
                    SetForegroundWindow(prompt);
                    return;
                }
            }
        }
        catch (OperationCanceledException)
        {
        }
    }

    // Throws the error of a status of Windows Hello.
    static void Check(KeyCredentialStatus status)
    {
        if (ErrorOf(status) is { } error)
        {
            throw new ApproveKeyException(error, $"Windows Hello answered {status}");
        }
    }

    // The error of a status of Windows Hello, or null for a success. A user
    // who closes the prompt or picks the password gets the Flux prompt
    // again. A key that Windows Hello does not find is not valid any more,
    // for example after a reset of the PIN, so the user enrolls again. A
    // locked security device is the lock of the TPM after too many tries.
    internal static ApproveKeyError? ErrorOf(KeyCredentialStatus status) => status switch
    {
        KeyCredentialStatus.Success => null,
        KeyCredentialStatus.UserCanceled or KeyCredentialStatus.UserPrefersPassword => ApproveKeyError.Cancelled,
        KeyCredentialStatus.NotFound => ApproveKeyError.KeyInvalid,
        KeyCredentialStatus.SecurityDeviceLocked => ApproveKeyError.LockedOut,
        _ => ApproveKeyError.Failed,
    };

    static byte[] Bytes(IBuffer buffer)
    {
        CryptographicBuffer.CopyToByteArray(buffer, out var bytes);
        return bytes ?? [];
    }

    [DllImport("ext-ms-win-windowing-external-l1-1-0.dll", ExactSpelling = true)]
    static extern int GetWindowIdFromWindow(IntPtr hwnd, out ulong id);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "FindWindowW")]
    static extern IntPtr FindWindow(string className, string? windowName);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool SetForegroundWindow(IntPtr hwnd);
}
