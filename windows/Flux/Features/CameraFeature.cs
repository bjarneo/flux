using System.Windows;
using FluxKit;

namespace Flux;

// The camera modes and the screenshots in the app: the tools of the tray of
// a chat, the tray action, the setting Send new screenshots, and the end of
// the camera windows. ChatDock.swift, CameraSection.swift, and
// ShareSettings.swift of the Mac app have the same parts.
public static class CameraFeature
{
    // The mode that the camera window opened in last.
    internal const string ModeKey = "camera.mode";

    // The computers that take what the camera makes.
    static bool Takes(DeviceSnapshot d) => d.Accepts(PacketType.Share);

    // A camera mode in the tray of the chat of a computer. The camera window
    // holds the other modes in its mode bar.
    public static Func<AppModel, DeviceSnapshot, (string Title, string Glyph, Action Run)?> DockTool(CameraMode mode, string title) =>
        (m, d) => m.Core.Plugin<SharePlugin>() is null || !Takes(d) ? null : (title, mode.Glyph(), () => CameraWindows.Show(m, d, mode));

    // Camera… in the menu of a computer in the tray. It opens the mode that
    // opened last.
    public static (string Title, Action Run)? TrayAction(AppModel m, DeviceSnapshot d)
    {
        if (m.Core.Plugin<SharePlugin>() is null || !Takes(d))
        {
            return null;
        }
        return ("Camera…", () => CameraWindows.Show(m, d, CameraModes.FromKey(m.Core.Settings.String(ModeKey)) ?? CameraMode.Text));
    }

    // Send new screenshots, in Settings > Features.
    public static (string Label, UIElement Content)? CaptureSettings(AppModel m)
    {
        if (m.Core.Plugin<CaptureWatchPlugin>() is not { } capture)
        {
            return null;
        }
        var folder = capture.Model.ScreenshotFolder;
        var where = folder.Length > 0 ? $"in {folder} " : "";
        return ("Send by themselves", SettingsView.Group(
            SettingsView.Toggle("Send new screenshots", capture.Model.Screenshots, capture.SetSendScreenshots),
            SettingsView.Note($"Each new screenshot {where}goes to your connected computers once. Screenshots wait until a computer connects. Windows and Print Screen, and the Snipping Tool, save there.")));
    }

    // Closes the camera windows, so that the cameras stop before Flux quits.
    public static void WillQuit(AppModel m)
    {
        CameraWindows.CloseAll();
        m.Core.Plugin<CaptureWatchPlugin>()?.Dispose();
    }
}
