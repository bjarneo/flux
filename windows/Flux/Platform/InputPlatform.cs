using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using FluxKit;

namespace Flux;

// The pointer of this computer while the touchpad holds it: the pointer
// stays in a rectangle of the screen, and it goes back to the center after
// each motion, so that it never stops at an edge. The positions are in
// pixels of the screen.
public static class PointerClip
{
    // Keeps the pointer in the rectangle. It returns false when Windows refused.
    public static bool Clip(Rect area)
    {
        var r = new Rectangle
        {
            Left = (int)Math.Round(area.Left),
            Top = (int)Math.Round(area.Top),
            Right = (int)Math.Round(area.Right),
            Bottom = (int)Math.Round(area.Bottom),
        };
        return ClipCursor(ref r);
    }

    // Lets the pointer go anywhere again.
    public static void Free() => ClipCursor(IntPtr.Zero);

    public static Point? Position() => GetCursorPos(out var p) ? new Point(p.X, p.Y) : null;

    public static void MoveTo(Point p) => SetCursorPos((int)Math.Round(p.X), (int)Math.Round(p.Y));

    [StructLayout(LayoutKind.Sequential)]
    struct Rectangle
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct Spot
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    static extern bool ClipCursor(ref Rectangle area);

    [DllImport("user32.dll")]
    static extern bool ClipCursor(IntPtr area);

    [DllImport("user32.dll")]
    static extern bool GetCursorPos(out Spot point);

    [DllImport("user32.dll")]
    static extern bool SetCursorPos(int x, int y);
}

// The text of a key in the keyboard layout of this computer.
public static class KeyText
{
    const int ShiftKey = 0x10;
    // Windows 10 1607 and later: the call does not change the state of a
    // dead key that waits.
    const uint KeepState = 4;

    // The text of the virtual key without modifiers except Shift, such as
    // "c" for the C key, or null for a key without text.
    public static string? Plain(int virtualKey, bool shift)
    {
        var state = new byte[256];
        if (shift)
        {
            state[ShiftKey] = 0x80;
        }
        var layout = GetKeyboardLayout(0);
        var scan = MapVirtualKeyEx((uint)virtualKey, 0, layout);
        var buffer = new char[8];
        var n = ToUnicodeEx((uint)virtualKey, scan, state, buffer, buffer.Length, KeepState, layout);
        // A dead key gives its character with a negative count.
        n = Math.Abs(n);
        return n == 0 ? null : new string(buffer, 0, Math.Min(n, buffer.Length));
    }

    [DllImport("user32.dll")]
    static extern IntPtr GetKeyboardLayout(uint thread);

    [DllImport("user32.dll")]
    static extern uint MapVirtualKeyEx(uint code, uint type, IntPtr layout);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int ToUnicodeEx(uint virtualKey, uint scanCode, byte[] state, [Out] char[] text, int size, uint flags, IntPtr layout);
}

// Takes the Windows key from Windows while a view types on the computer
// with Super. Windows handles shortcuts such as Windows+1 before the window
// sees them, so a low-level keyboard hook takes them first. The hook runs
// only while the view needs it: the touchpad holds the pointer, or the
// pointer is over the remote desktop. The hook gives each key that goes
// down while the Windows key is down to press, and Windows does not see
// these keys or the Windows key.
public sealed class SuperKeys : IDisposable
{
    const int KeyboardHook = 13;
    const int KeyDown = 0x100;
    const int SystemKeyDown = 0x104;
    const int KeyUp = 0x101;
    const int SystemKeyUp = 0x105;
    const int LeftWindows = 0x5B;
    const int RightWindows = 0x5C;

    readonly Action<int, RemoteMods, bool> press;
    readonly HookProc proc;
    readonly HashSet<int> taken = [];
    IntPtr hook;
    bool windowsDown;

    // press gets the virtual key, the held modifiers with Super, and true
    // while the right Alt key is down.
    public SuperKeys(Action<int, RemoteMods, bool> press)
    {
        this.press = press;
        proc = Callback;
        hook = SetWindowsHookEx(KeyboardHook, proc, GetModuleHandle(null), 0);
        if (hook == IntPtr.Zero)
        {
            FluxLog.Error("app", $"the Windows key stays with Windows: error {Marshal.GetLastWin32Error()}");
        }
    }

    IntPtr Callback(int code, IntPtr message, IntPtr data)
    {
        if (code >= 0)
        {
            var key = Marshal.ReadInt32(data);
            var m = message.ToInt32();
            var down = m is KeyDown or SystemKeyDown;
            var up = m is KeyUp or SystemKeyUp;
            if (key is LeftWindows or RightWindows)
            {
                // Only a Windows key that went down here comes up here, so
                // that Windows never sees half of a press.
                if (down)
                {
                    windowsDown = true;
                    taken.Add(key);
                    return 1;
                }
                if (up && taken.Remove(key))
                {
                    windowsDown = taken.Contains(LeftWindows) || taken.Contains(RightWindows);
                    return 1;
                }
            }
            else if (down && windowsDown && !IsModifier(key))
            {
                var held = new RemoteMods(Down(0x11), Down(0x12), Down(0x10), true);
                taken.Add(key);
                press(key, held, Down(0xA5));
                return 1;
            }
            else if (up && taken.Remove(key))
            {
                return 1;
            }
        }
        return CallNextHookEx(hook, code, message, data);
    }

    static bool IsModifier(int key) => key is 0x10 or 0x11 or 0x12 or >= 0xA0 and <= 0xA5;

    static bool Down(int key) => (GetAsyncKeyState(key) & 0x8000) != 0;

    public void Dispose()
    {
        if (hook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(hook);
            hook = IntPtr.Zero;
        }
    }

    delegate IntPtr HookProc(int code, IntPtr message, IntPtr data);

    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr SetWindowsHookEx(int type, HookProc proc, IntPtr module, uint thread);

    [DllImport("user32.dll")]
    static extern bool UnhookWindowsHookEx(IntPtr hook);

    [DllImport("user32.dll")]
    static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);

    [DllImport("user32.dll")]
    static extern short GetAsyncKeyState(int key);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr GetModuleHandle(string? name);
}

// The horizontal wheel of a window. WPF has no event for it, so a hook on
// the window reads WM_MOUSEHWHEEL. A positive delta scrolls right.
public static class HorizontalWheel
{
    const int MouseHorizontalWheel = 0x020E;

    // Gives each horizontal wheel delta of the window to run. run returns
    // true when it used the delta.
    public static void Watch(Window window, Func<int, bool> run)
    {
        void Add()
        {
            if (HwndSource.FromHwnd(new WindowInteropHelper(window).Handle) is { } source)
            {
                source.AddHook((IntPtr hwnd, int message, IntPtr w, IntPtr l, ref bool handled) =>
                {
                    if (message == MouseHorizontalWheel && run((short)((w.ToInt64() >> 16) & 0xFFFF)))
                    {
                        handled = true;
                    }
                    return IntPtr.Zero;
                });
            }
        }
        if (new WindowInteropHelper(window).Handle != IntPtr.Zero)
        {
            Add();
        }
        else
        {
            window.SourceInitialized += (_, _) => Add();
        }
    }
}
