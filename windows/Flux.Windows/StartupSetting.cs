using System.IO;
using Microsoft.Win32;

namespace Flux.Windows;

internal static class StartupSetting
{
    private const string KeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "Flux.Windows";
    public static bool Enabled
    {
        get {
            using var key = Registry.CurrentUser.OpenSubKey(KeyPath);
            return key?.GetValue(ValueName) is string command && command.EndsWith(" --background", StringComparison.Ordinal);
        }
    }
    public static void SetEnabled(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(KeyPath, writable: true);
        if (!enabled) { key.DeleteValue(ValueName, throwOnMissingValue: false); return; }
        var path = Environment.ProcessPath;
        if (path is null || !Path.GetFileName(path).Equals("Flux.Windows.exe", StringComparison.OrdinalIgnoreCase) || path.Contains('"'))
            throw new IOException("Start the published Flux.Windows.exe before enabling login startup.");
        key.SetValue(ValueName, "\"" + path + "\" --background", RegistryValueKind.String);
    }
}
