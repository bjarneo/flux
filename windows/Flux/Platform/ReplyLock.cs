using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using FluxKit;
using Microsoft.Win32;
using Windows.Security.Credentials.UI;

namespace Flux;

// Asks for Windows Hello, with a face, a fingerprint, or the PIN, before a
// reply goes to an agent. A reply can make the computer run commands, so the
// person at this computer confirms first. An unlock stays valid for 5
// minutes, like the phone lock on Android. It ends before that when this
// computer sleeps, its display turns off, the session locks, or another user
// takes the session. ReplyLock.swift of the Mac app has the same rules.
public static class ReplyLock
{
    static readonly TimeSpan ValidFor = TimeSpan.FromMinutes(5);

    // The end of the unlock on the tick clock, which also counts the time
    // while this computer sleeps. Null while no unlock is valid.
    static long? until;

    static bool watching;
    static HwndSource? power;

    // True while an earlier unlock is still valid.
    public static bool IsUnlocked => until is { } end && Environment.TickCount64 < end;

    // Ends the unlock, so that the next check asks again.
    public static void Lock() => until = null;

    // Ends the unlock when this computer sleeps, its display turns off, the
    // session locks, or the user session changes. Call it once at the start.
    public static void Watch()
    {
        if (watching)
        {
            return;
        }
        watching = true;
        SystemEvents.PowerModeChanged += (_, e) =>
        {
            if (e.Mode == PowerModes.Suspend)
            {
                Lock();
            }
        };
        SystemEvents.SessionSwitch += (_, e) =>
        {
            if (e.Reason is SessionSwitchReason.SessionLock or SessionSwitchReason.ConsoleDisconnect or SessionSwitchReason.RemoteDisconnect
                or SessionSwitchReason.SessionLogoff)
            {
                Lock();
            }
        };
        WatchDisplay();
    }

    // Windows reports the display state to a window that asks for it. A
    // message-only window gets the report.
    static void WatchDisplay()
    {
        try
        {
            power = new HwndSource(new HwndSourceParameters("Flux power") { ParentWindow = new IntPtr(-3), Width = 0, Height = 0 });
            power.AddHook(PowerHook);
            var display = ConsoleDisplayState;
            _ = RegisterPowerSettingNotification(power.Handle, ref display, DeviceNotifyWindowHandle);
        }
        catch (Exception e) when (e is Win32Exception or EntryPointNotFoundException or InvalidOperationException)
        {
            FluxLog.Error("app", $"cannot watch the display state: {e.Message}");
        }
    }

    const int WmPowerBroadcast = 0x0218;
    const int PbtPowerSettingChange = 0x8013;
    const int DeviceNotifyWindowHandle = 0;
    static Guid ConsoleDisplayState = new("6FE69556-704A-47A0-8F24-C28D936FDA47");

    [StructLayout(LayoutKind.Sequential)]
    struct PowerBroadcastSetting
    {
        public Guid PowerSetting;
        public int DataLength;
        public int Data;
    }

    static IntPtr PowerHook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WmPowerBroadcast && wParam.ToInt64() == PbtPowerSettingChange && lParam != IntPtr.Zero)
        {
            var setting = Marshal.PtrToStructure<PowerBroadcastSetting>(lParam);
            // 0 is off, 1 is on, and 2 is dimmed.
            if (setting.PowerSetting == ConsoleDisplayState && setting.Data == 0)
            {
                Lock();
            }
        }
        return IntPtr.Zero;
    }

    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr RegisterPowerSettingNotification(IntPtr recipient, ref Guid powerSetting, int flags);

    // Runs action after the check, or at once while an unlock is valid.
    // onError gets a message when this computer cannot check or the check
    // fails. onCancel runs after a cancel, and may be null. reason tells what
    // the check is for, for example "answer agents on omarchy". owner is the
    // window that the prompt of Windows Hello belongs to. A call while a
    // check runs does nothing.
    public static void Run(string reason, Window? owner, Action action, Action<string> onError, Action? onCancel = null)
    {
        if (IsUnlocked)
        {
            action();
            return;
        }
        if (!TryStart())
        {
            return;
        }
        _ = CheckAsync(reason, owner, action, onError, onCancel);
    }

    static int checking;

    // True for the caller that starts a check. A check that runs has the flag until it ends.
    internal static bool TryStart() => Interlocked.CompareExchange(ref checking, 1, 0) == 0;

    // Ends the check that TryStart started.
    internal static void End() => Volatile.Write(ref checking, 0);

    static async Task CheckAsync(string reason, Window? owner, Action action, Action<string> onError, Action? onCancel)
    {
        try
        {
            var available = await UserConsentVerifier.CheckAvailabilityAsync();
            if (available != UserConsentVerifierAvailability.Available)
            {
                onError(Unavailable(available));
                return;
            }
            var window = owner ?? Application.Current?.MainWindow;
            var hwnd = window is null ? IntPtr.Zero : new WindowInteropHelper(window).EnsureHandle();
            var message = $"Flux wants to {reason}.";
            var result = hwnd == IntPtr.Zero
                ? await UserConsentVerifier.RequestVerificationAsync(message)
                : await UserConsentVerifierInterop.RequestVerificationForWindowAsync(hwnd, message);
            switch (result)
            {
                case UserConsentVerificationResult.Verified:
                    until = Environment.TickCount64 + (long)ValidFor.TotalMilliseconds;
                    action();
                    break;
                case UserConsentVerificationResult.Canceled:
                    onCancel?.Invoke();
                    break;
                default:
                    onError(Failed(result));
                    break;
            }
        }
        catch (Exception e) when (e is COMException or InvalidOperationException or UnauthorizedAccessException)
        {
            FluxLog.Error("app", $"Windows Hello failed: {e.Message}");
            onError("Windows Hello did not answer. Try again.");
        }
        finally
        {
            End();
        }
    }

    // Why Windows Hello cannot check, for the user.
    static string Unavailable(UserConsentVerifierAvailability a) => a switch
    {
        UserConsentVerifierAvailability.DeviceNotPresent => "This computer has no Windows Hello. Set up a PIN in Settings > Accounts > Sign-in options.",
        UserConsentVerifierAvailability.NotConfiguredForUser => "Set up Windows Hello in Settings > Accounts > Sign-in options, then try again.",
        UserConsentVerifierAvailability.DisabledByPolicy => "A policy of this computer turns Windows Hello off.",
        UserConsentVerifierAvailability.DeviceBusy => "Windows Hello is busy. Try again.",
        _ => "This computer cannot confirm who uses it.",
    };

    // Why the check failed, for the user.
    static string Failed(UserConsentVerificationResult r) => r switch
    {
        UserConsentVerificationResult.RetriesExhausted => "Too many tries. Try again later.",
        UserConsentVerificationResult.DeviceBusy => "Windows Hello is busy. Try again.",
        UserConsentVerificationResult.DisabledByPolicy => "A policy of this computer turns Windows Hello off.",
        UserConsentVerificationResult.NotConfiguredForUser => "Set up Windows Hello in Settings > Accounts > Sign-in options, then try again.",
        _ => "The check failed.",
    };
}
