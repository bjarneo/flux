using System.Runtime.InteropServices;
using FluxKit;

namespace Flux;

// Opens the files that Get files downloaded, with the app that Windows
// picks or in File Explorer. Each file gets the Mark of the Web before it
// opens, so that Windows and Office check it as a file from the internet.
public sealed class WindowsBrowseFiles : IBrowseFiles
{
    public void Open(string path)
    {
        Mark(path);
        ThisComputer.Open(path);
    }

    public void Reveal(string path) => ThisComputer.ShowInFolder(path);

    // Writes the Mark of the Web, as the share feature does for received files.
    public static void Mark(string path) => new WindowsShare(null).MarkDownloaded(path);
}

// The kind of a file in words, such as "Text Document", from the file
// types of Windows.
public static class FileKinds
{
    const uint NormalFile = 0x80;
    const uint TypeName = 0x400;
    const uint UseAttributes = 0x10;

    static readonly Dictionary<string, string> Known = new(StringComparer.OrdinalIgnoreCase);

    // The kind of a file name. Only the extension counts, so the file need
    // not exist on this computer.
    public static string Of(string name)
    {
        var ext = Path.GetExtension(name);
        if (ext.Length < 2)
        {
            return "Document";
        }
        if (Known.TryGetValue(ext, out var kind))
        {
            return kind;
        }
        var info = new FileInfo();
        kind = SHGetFileInfo(ext, NormalFile, ref info, (uint)Marshal.SizeOf<FileInfo>(), TypeName | UseAttributes) != IntPtr.Zero &&
               info.TypeName is { Length: > 0 } t
            ? t
            : ext[1..].ToUpperInvariant() + " file";
        Known[ext] = kind;
        return kind;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct FileInfo
    {
        public IntPtr Icon;
        public int IconIndex;
        public uint Attributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string DisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)]
        public string TypeName;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SHGetFileInfo(string path, uint attributes, ref FileInfo info, uint size, uint flags);
}
