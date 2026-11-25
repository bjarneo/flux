using System.Runtime.InteropServices;
using System.Security;
using System.Text;
using FluxKit;
using Windows.Data.Xml.Dom;
using Windows.UI.Notifications;

namespace Flux;

// Shows the notifications of Flux as Windows toasts. Windows shows a toast of
// an app without a package only when a Start menu shortcut carries the app
// ID, so the backend writes that shortcut at the start.
public sealed class ToastBackend : INotificationBackend
{
    public const string AppId = "Omarchy.Flux";
    const string Group = "flux";

    readonly Notifier notifier;
    readonly ToastNotifier? toaster;

    public ToastBackend(Notifier notifier)
    {
        this.notifier = notifier;
        try
        {
            _ = SetCurrentProcessExplicitAppUserModelID(AppId);
            Shortcut.Ensure(AppId);
            toaster = ToastNotificationManager.CreateToastNotifier(AppId);
        }
        catch (Exception e) when (e is COMException or UnauthorizedAccessException or IOException or ArgumentException)
        {
            FluxLog.Error("app", $"toasts are off: {e.Message}");
        }
    }

    public void Show(SystemNotification n, IReadOnlyList<NotificationAction> actions)
    {
        if (toaster is null)
        {
            return;
        }
        try
        {
            var xml = new XmlDocument();
            xml.LoadXml(Xml(n, actions));
            var toast = new ToastNotification(xml) { Tag = Tag(n.Id), Group = Group };
            toast.Activated += (_, args) =>
            {
                if (args is not ToastActivatedEventArgs a)
                {
                    return;
                }
                var action = a.Arguments.StartsWith("action=", StringComparison.Ordinal) ? a.Arguments["action=".Length..] : Notifier.DefaultAction;
                string? reply = a.UserInput.TryGetValue("reply", out var value) ? value as string : null;
                notifier.Activate(n.Category, action, n.UserInfo, reply);
            };
            toaster.Show(toast);
        }
        catch (Exception e) when (e is COMException or ArgumentException)
        {
            FluxLog.Error("app", $"cannot show a toast: {e.Message}");
        }
    }

    public void Remove(string id)
    {
        try
        {
            ToastNotificationManager.History.Remove(Tag(id), Group, AppId);
        }
        catch (Exception e) when (e is COMException or ArgumentException)
        {
        }
    }

    // A tag has at most 64 characters, so a long ID goes as its hash.
    static string Tag(string id) => id.Length <= 64 ? id : Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(id)))[..32];

    internal static string Xml(SystemNotification n, IReadOnlyList<NotificationAction> actions)
    {
        static string E(string s) => SecurityElement.Escape(s) ?? "";
        var b = new StringBuilder();
        b.Append("<toast launch=\"action=default\"><visual><binding template=\"ToastGeneric\">");
        b.Append("<text>").Append(E(n.Title)).Append("</text>");
        if (n.Body.Length > 0)
        {
            b.Append("<text>").Append(E(n.Body)).Append("</text>");
        }
        if (n.Subtitle is { Length: > 0 } subtitle)
        {
            b.Append("<text placement=\"attribution\">").Append(E(subtitle)).Append("</text>");
        }
        if (n.Image is { } image)
        {
            b.Append("<image placement=\"hero\" src=\"").Append(E(new Uri(image).AbsoluteUri)).Append("\"/>");
        }
        b.Append("</binding></visual>");
        if (actions.Count > 0)
        {
            b.Append("<actions>");
            if (actions.Any(a => a.TextInput))
            {
                b.Append("<input id=\"reply\" type=\"text\" placeHolderContent=\"Reply\"/>");
            }
            foreach (var a in actions)
            {
                b.Append("<action content=\"").Append(E(a.Title)).Append("\" arguments=\"action=").Append(E(a.Id)).Append('"');
                if (a.TextInput)
                {
                    b.Append(" hint-inputId=\"reply\"");
                }
                b.Append(" activationType=\"foreground\"/>");
            }
            b.Append("</actions>");
        }
        if (!n.Sound)
        {
            b.Append("<audio silent=\"true\"/>");
        }
        b.Append("</toast>");
        return b.ToString();
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
}

// The Start menu shortcut of Flux with the app ID. It also gives Flux an
// entry in the Start menu.
static class Shortcut
{
    public static void Ensure(string appId) =>
        Write(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "Flux.lnk"), "Flux for Omarchy", appId);

    // Writes a shortcut to this Flux.exe at the path, with the app ID when
    // one is given.
    public static void Write(string path, string description, string? appId)
    {
        var exe = Environment.ProcessPath ?? "";
        if (exe.Length == 0)
        {
            return;
        }
        var link = (IShellLinkW)new CShellLink();
        link.SetPath(exe);
        link.SetArguments("");
        link.SetWorkingDirectory(Path.GetDirectoryName(exe) ?? "");
        link.SetDescription(description);
        if (appId is not null)
        {
            var store = (IPropertyStore)link;
            var key = new PropertyKey(new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), 5);
            var value = new PropVariant(appId);
            try
            {
                store.SetValue(ref key, ref value);
                store.Commit();
            }
            finally
            {
                value.Clear();
            }
        }
        ((IPersistFile)link).Save(path, true);
    }

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    class CShellLink
    {
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
    interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder file, int max, IntPtr data, uint flags);
        void GetIDList(out IntPtr list);
        void SetIDList(IntPtr list);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder name, int max);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder dir, int max);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string dir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder args, int max);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
        void GetHotkey(out short key);
        void SetHotkey(short key);
        void GetShowCmd(out int cmd);
        void SetShowCmd(int cmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int max, out int index);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int index);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
        void Resolve(IntPtr hwnd, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string file);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("0000010b-0000-0000-C000-000000000046")]
    interface IPersistFile
    {
        void GetClassID(out Guid id);
        [PreserveSig]
        int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string file, uint mode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string file, [MarshalAs(UnmanagedType.Bool)] bool remember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string file);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string file);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    interface IPropertyStore
    {
        void GetCount(out uint count);
        void GetAt(uint index, out PropertyKey key);
        void GetValue(ref PropertyKey key, out PropVariant value);
        void SetValue(ref PropertyKey key, ref PropVariant value);
        void Commit();
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct PropertyKey(Guid format, uint id)
    {
        public Guid Format = format;
        public uint Id = id;
    }

    // A PROPVARIANT that holds 1 string as VT_LPWSTR.
    [StructLayout(LayoutKind.Explicit)]
    struct PropVariant
    {
        [FieldOffset(0)]
        ushort vt;
        [FieldOffset(8)]
        IntPtr pointer;
        [FieldOffset(16)]
        IntPtr padding;

        public PropVariant(string value)
        {
            vt = 31;
            pointer = Marshal.StringToCoTaskMemUni(value);
            padding = IntPtr.Zero;
        }

        public void Clear() => PropVariantClear(ref this);

        [DllImport("ole32.dll")]
        static extern int PropVariantClear(ref PropVariant value);
    }
}
