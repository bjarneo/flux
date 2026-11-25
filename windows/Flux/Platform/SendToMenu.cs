using FluxKit;

namespace Flux;

// The entry of Flux in the Send to menu of File Explorer: a shortcut to
// Flux.exe in the SendTo folder of the user. Windows starts Flux with the
// selected files, and Flux sends them to the computer, as the Send to Flux
// service of the Mac app does.
public static class SendToMenu
{
    static string Path => System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.SendTo), "Flux.lnk");

    public static bool Enabled => File.Exists(Path);

    // Adds or removes the entry. It returns false when Windows refused.
    public static bool Set(bool on)
    {
        try
        {
            if (on)
            {
                Shortcut.Write(Path, "Send to the Omarchy computer with Flux", null);
            }
            else if (File.Exists(Path))
            {
                File.Delete(Path);
            }
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
        {
            FluxLog.Error("app", $"cannot change the Send to menu: {e.Message}");
            return false;
        }
    }
}
