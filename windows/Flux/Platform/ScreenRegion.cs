using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using FluxKit;
using Drawing = System.Drawing;

namespace Flux;

// A part of the screen that the user picks. Flux hides the camera window,
// takes a picture of all displays, and shows it in a window over the
// displays. The user drags over the part to read, and Esc cancels. The Mac
// runs the screenshot tool of macOS in its place.
public static class ScreenRegion
{
    // Returns the part, or null when the user cancels or the capture fails.
    // fail gets a message for the user.
    public static async Task<BgraImage?> PickAsync(Window? owner, Action<string> fail)
    {
        owner?.Hide();
        try
        {
            // The desktop draws the screen again without the window first.
            await Task.Delay(250);
            if (Capture() is not { } shot)
            {
                fail("Cannot take a picture of the screen");
                return null;
            }
            var picker = new RegionWindow(shot);
            picker.ShowDialog();
            return picker.Result;
        }
        finally
        {
            if (owner is not null)
            {
                owner.Show();
                owner.Activate();
            }
        }
    }

    // A picture of all displays in their pixels. The thread takes the DPI
    // awareness of each display for the capture, so that a display with
    // another scale gives its real pixels.
    internal static BgraImage? Capture()
    {
        var old = SetThreadDpiAwarenessContext(PerMonitorAwareV2);
        try
        {
            int x = GetSystemMetrics(VirtualLeft), y = GetSystemMetrics(VirtualTop);
            int w = GetSystemMetrics(VirtualWidth), h = GetSystemMetrics(VirtualHeight);
            if (w <= 0 || h <= 0)
            {
                return null;
            }
            using var bitmap = new Drawing.Bitmap(w, h, Drawing.Imaging.PixelFormat.Format32bppArgb);
            using (var g = Drawing.Graphics.FromImage(bitmap))
            {
                g.CopyFromScreen(x, y, 0, 0, new Drawing.Size(w, h), Drawing.CopyPixelOperation.SourceCopy);
            }
            var data = bitmap.LockBits(new Drawing.Rectangle(0, 0, w, h), Drawing.Imaging.ImageLockMode.ReadOnly, Drawing.Imaging.PixelFormat.Format32bppArgb);
            try
            {
                var pixels = new byte[w * h * 4];
                for (var row = 0; row < h; row++)
                {
                    Marshal.Copy(data.Scan0 + row * data.Stride, pixels, row * w * 4, w * 4);
                }
                // The screen has no transparency. GDI leaves the alpha bytes open.
                for (var i = 3; i < pixels.Length; i += 4)
                {
                    pixels[i] = 255;
                }
                return new BgraImage(w, h, pixels);
            }
            finally
            {
                bitmap.UnlockBits(data);
            }
        }
        catch (Exception e) when (e is ExternalException or ArgumentException or InvalidOperationException)
        {
            FluxLog.Error("camera", $"the screen capture failed: {e.Message}");
            return null;
        }
        finally
        {
            if (old != IntPtr.Zero)
            {
                SetThreadDpiAwarenessContext(old);
            }
        }
    }

    static readonly IntPtr PerMonitorAwareV2 = new(-4);
    const int VirtualLeft = 76;
    const int VirtualTop = 77;
    const int VirtualWidth = 78;
    const int VirtualHeight = 79;

    [DllImport("user32.dll")]
    static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

    [DllImport("user32.dll")]
    static extern int GetSystemMetrics(int index);
}

// The window over all displays with the picture of the screen. A drag
// selects a part. The selection maps to the picture by its part of the
// window, so that it fits also when the displays have different scales.
sealed class RegionWindow : Window
{
    readonly BgraImage shot;
    readonly System.Windows.Shapes.Path dim;
    readonly Border selection;
    Point start;
    bool dragging;

    public BgraImage? Result { get; private set; }

    public RegionWindow(BgraImage shot)
    {
        this.shot = shot;
        var tn = Tn.Current;
        Title = "Select a part of the screen";
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Left = SystemParameters.VirtualScreenLeft;
        Top = SystemParameters.VirtualScreenTop;
        Width = SystemParameters.VirtualScreenWidth;
        Height = SystemParameters.VirtualScreenHeight;
        Cursor = Cursors.Cross;
        Background = tn.Bg;
        FontFamily = Faces.Body;
        var veil = new SolidColorBrush(tn.Bg.Color) { Opacity = 0.45 };
        veil.Freeze();
        dim = new System.Windows.Shapes.Path { Fill = veil, IsHitTestVisible = false };
        selection = new Border { BorderBrush = tn.Accent, BorderThickness = new Thickness(2), IsHitTestVisible = false, Visibility = Visibility.Collapsed };
        var hint = Ui.Tile(Ui.Text("Drag over the part of the screen to read. Esc cancels.", 13), tn.TileHi, tn.LineHi, 10);
        hint.HorizontalAlignment = HorizontalAlignment.Center;
        hint.VerticalAlignment = VerticalAlignment.Top;
        hint.Margin = new Thickness(0, 40, 0, 0);
        hint.IsHitTestVisible = false;
        var canvas = new Canvas();
        canvas.Children.Add(selection);
        var root = new Grid();
        root.Children.Add(new Image { Source = CameraImaging.ToBitmap(shot), Stretch = Stretch.Fill });
        root.Children.Add(dim);
        root.Children.Add(canvas);
        root.Children.Add(hint);
        Content = root;
        AutomationNamed(root);
        SizeChanged += (_, _) => Draw(new Rect());
        MouseLeftButtonDown += (_, e) =>
        {
            start = e.GetPosition(this);
            dragging = true;
            CaptureMouse();
            Draw(new Rect(start, start));
        };
        MouseMove += (_, e) =>
        {
            if (dragging)
            {
                Draw(new Rect(start, e.GetPosition(this)));
            }
        };
        MouseLeftButtonUp += (_, e) =>
        {
            if (!dragging)
            {
                return;
            }
            dragging = false;
            ReleaseMouseCapture();
            var rect = new Rect(start, e.GetPosition(this));
            if (rect.Width < 4 || rect.Height < 4)
            {
                Draw(new Rect());
                return;
            }
            Result = Crop(rect);
            Close();
        };
        MouseRightButtonUp += (_, _) => Close();
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                Close();
            }
        };
        Loaded += (_, _) => Activate();
    }

    static void AutomationNamed(FrameworkElement e) =>
        System.Windows.Automation.AutomationProperties.SetName(e, "Picture of the screen. Drag over the part to read. Esc cancels.");

    // Dims the screen outside the selection and draws its border.
    void Draw(Rect rect)
    {
        var all = new RectangleGeometry(new Rect(0, 0, ActualWidth, ActualHeight));
        dim.Data = rect.IsEmpty || rect.Width == 0 ? all : new CombinedGeometry(GeometryCombineMode.Exclude, all, new RectangleGeometry(rect));
        selection.Visibility = rect.IsEmpty || rect.Width == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (!rect.IsEmpty)
        {
            Canvas.SetLeft(selection, rect.X - 2);
            Canvas.SetTop(selection, rect.Y - 2);
            selection.Width = rect.Width + 4;
            selection.Height = rect.Height + 4;
        }
    }

    BgraImage Crop(Rect rect)
    {
        var sx = shot.Width / Math.Max(1, ActualWidth);
        var sy = shot.Height / Math.Max(1, ActualHeight);
        var left = (int)Math.Round(rect.X * sx);
        var top = (int)Math.Round(rect.Y * sy);
        var width = (int)Math.Round(rect.Width * sx);
        var height = (int)Math.Round(rect.Height * sy);
        return shot.Crop(new SignatureCrop(left, top, Math.Max(1, width), Math.Max(1, height)), CameraImages.MaxStillSide);
    }
}
