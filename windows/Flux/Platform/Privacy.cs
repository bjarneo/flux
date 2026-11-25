using FluxKit;
using Microsoft.Win32;

namespace Flux;

// The privacy settings of Windows for the microphone and the camera. Windows
// keeps them in the consent store of the capability access manager. "Deny"
// for this computer, for the apps of the user, for the desktop apps, or for
// Flux itself turns the device off for Flux. A group policy can also deny
// it. Windows does not ask a desktop app before the first use, so Flux only
// reads the settings.
public static class Privacy
{
    public const string Microphone = "microphone";
    public const string Camera = "webcam";

    const string Store = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\";
    const string Policy = @"Software\Policies\Microsoft\Windows\AppPrivacy";

    // True when a privacy setting of Windows denies the capability to Flux.
    public static bool Denied(string capability)
    {
        try
        {
            if (Value(Registry.LocalMachine, Store + capability) == "Deny" || Value(Registry.CurrentUser, Store + capability) == "Deny" ||
                Value(Registry.CurrentUser, Store + capability + @"\NonPackaged") == "Deny")
            {
                return true;
            }
            // Windows 11 keeps a setting for each desktop app under its path,
            // with # in place of each \.
            if (Environment.ProcessPath is { } path &&
                Value(Registry.CurrentUser, Store + capability + @"\NonPackaged\" + path.Replace('\\', '#')) == "Deny")
            {
                return true;
            }
            using var policy = Registry.LocalMachine.OpenSubKey(Policy);
            var name = capability == Microphone ? "LetAppsAccessMicrophone" : "LetAppsAccessCamera";
            // 2 is Force Deny.
            return policy?.GetValue(name) is int force && force == 2;
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            FluxLog.Info("stream", $"cannot read the privacy settings: {e.Message}");
            return false;
        }
    }

    // Opens the page of the capability in the privacy settings of Windows.
    public static void OpenSettings(string capability) =>
        ThisComputer.Open(capability == Microphone ? "ms-settings:privacy-microphone" : "ms-settings:privacy-webcam");

    static string? Value(RegistryKey root, string path)
    {
        using var key = root.OpenSubKey(path);
        return key?.GetValue("Value") as string;
    }
}
