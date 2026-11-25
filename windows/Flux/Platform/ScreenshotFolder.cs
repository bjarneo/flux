using System.Runtime.InteropServices;
using FluxKit;

namespace Flux;

// The Screenshots folder of Windows: the known folder FOLDERID_Screenshots,
// usually Pictures\Screenshots. Windows and Print Screen save there, and so
// does the Snipping Tool of Windows 11 by default. The user can move it with
// the Location tab of the folder.
public sealed class WindowsScreenshots : ICapturePlatform
{
    static readonly Guid Screenshots = new("b7bede81-df94-4682-a7d8-57a52620b86f");

    // Gives the path also while the folder does not exist yet. Windows makes
    // it at the first screenshot.
    const uint DontVerify = 0x00004000;

    public string? ScreenshotFolder()
    {
        try
        {
            if (SHGetKnownFolderPath(Screenshots, DontVerify, IntPtr.Zero, out var path) == 0 && path != IntPtr.Zero)
            {
                try
                {
                    return Marshal.PtrToStringUni(path);
                }
                finally
                {
                    Marshal.FreeCoTaskMem(path);
                }
            }
        }
        catch (Exception e) when (e is EntryPointNotFoundException or DllNotFoundException)
        {
            FluxLog.Info("capture", $"cannot read the screenshot folder: {e.Message}");
        }
        var pictures = Environment.GetFolderPath(Environment.SpecialFolder.MyPictures);
        return pictures.Length > 0 ? Path.Combine(pictures, "Screenshots") : null;
    }

    [DllImport("shell32.dll")]
    static extern int SHGetKnownFolderPath([MarshalAs(UnmanagedType.LPStruct)] Guid id, uint flags, IntPtr token, out IntPtr path);
}
