using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using FluxKit;

namespace Flux;

// The tray of the chat of a computer, under the composer: the 4 newest
// screenshots of the Screenshots folder of Windows with All screenshots,
// and the tools in rows of 4. A click on a screenshot selects it, and its
// number shows the order. The send key of the dock sends the selected
// screenshots. A click on a tool closes the tray and opens the tool. The
// tools take no click while the computer is not reachable. Windows has no
// photo library, so the tray shows the screenshots in the place of the
// photos of the phone. ChatTray.kt of the Android app has the same parts.
public sealed class ChatTray(AppModel model, Action close, Action changed)
{
    // The number of screenshots in the tray.
    public const int Recent = 4;

    // The width in pixels that a thumbnail decodes to.
    const int ThumbWidth = 240;

    readonly List<string> selected = [];
    IReadOnlyList<Shot> shots = [];
    // The number of the last read, so that only the newest read shows.
    int reads;

    // 1 screenshot: its file, and its thumbnail, or null when Windows cannot decode it.
    sealed record Shot(string Path, ImageSource? Thumb);

    // The selected screenshots, in the order of their selection.
    public IReadOnlyList<string> Selected => selected;

    // Forgets the selection, after a send.
    public void Clear() => selected.Clear();

    // The Screenshots folder, or null without the screenshot watch.
    string? Folder => model.Core.Plugin<CaptureWatchPlugin>()?.Model.ScreenshotFolder is { Length: > 0 } f ? f : null;

    // Reads the newest screenshots and their thumbnails off the UI thread,
    // then draws the tray again.
    public void Load()
    {
        if (Folder is not { } folder)
        {
            return;
        }
        var read = ++reads;
        var dispatcher = Dispatcher.CurrentDispatcher;
        _ = Task.Run(() =>
        {
            var found = Newest(folder).Select(p => new Shot(p, Thumb(p))).ToArray();
            dispatcher.BeginInvoke(() =>
            {
                if (read == reads)
                {
                    shots = found;
                    changed();
                }
            });
        });
    }

    // The newest screenshots of the folder. The scan skips the names that
    // start with a dot and the hidden files, as the screenshot watch does.
    static string[] Newest(string folder)
    {
        try
        {
            return new DirectoryInfo(folder).EnumerateFiles()
                .Where(f => !f.Name.StartsWith('.') && (f.Attributes & (FileAttributes.Hidden | FileAttributes.System)) == 0 && CaptureRules.IsScreenshot(f.Name))
                .OrderByDescending(f => f.LastWriteTimeUtc).Take(Recent).Select(f => f.FullName).ToArray();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return [];
        }
    }

    // A small image of the file, decoded off the UI thread, or null.
    static ImageSource? Thumb(string path)
    {
        try
        {
            var image = new BitmapImage();
            image.BeginInit();
            image.UriSource = new Uri(path);
            image.DecodePixelWidth = ThumbWidth;
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or NotSupportedException or ArgumentException or
                                       FormatException or InvalidOperationException or System.Runtime.InteropServices.COMException)
        {
            return null;
        }
    }

    // The tray for the computer d.
    public UIElement Build(DeviceSnapshot d)
    {
        var tn = Tn.Current;
        var items = new List<UIElement?>();
        if (Folder is { } folder && model.Core.Plugin<SharePlugin>() is { } share)
        {
            var all = new FluxButton("All screenshots", ButtonKind.Text, () => PickAll(folder, share, d), enabled: d.Online)
                .Named("All screenshots").Help("Pick screenshots or other images to send");
            items.Add(Ui.H(8, Ui.Text("Recent screenshots", 12, FontWeights.Medium, tn.Sub).Fill(), all));
            if (shots.Count == 0)
            {
                items.Add(Ui.Text("No screenshots yet. Windows+Print Screen and the Snipping Tool save them in the Screenshots folder.",
                    12, color: tn.Sub, wrap: true).Margin(2, 0, 2, 4));
            }
            else
            {
                var cells = shots.Select(Cell).ToList();
                while (cells.Count < Recent)
                {
                    cells.Add(new Border());
                }
                items.Add(Parts.GridRows(cells, Recent));
            }
        }
        var tools = ChatDock.Tools.Select(make => make(model, d)).OfType<(string Title, string Glyph, Action Run)>()
            .Select(t => (UIElement)Tool(t.Title, t.Glyph, t.Run, d.Online)).ToList();
        if (tools.Count > 0)
        {
            while (tools.Count % Recent != 0)
            {
                tools.Add(new Border());
            }
            items.Add(Parts.GridRows(tools, Recent));
        }
        return new ScrollViewer
        {
            Content = Ui.V(Metrics.Gap, items).Margin(0, 2, 0, 0),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            MaxHeight = 280,
            Focusable = false,
        };
    }

    // A screenshot. A click selects it, or ends its selection. A selected
    // screenshot takes an accent border of 2 px and its number.
    UIElement Cell(Shot shot)
    {
        var tn = Tn.Current;
        var index = selected.IndexOf(shot.Path);
        var on = index >= 0;
        var name = Path.GetFileName(shot.Path);
        var picture = new Border
        {
            Height = 72,
            CornerRadius = new CornerRadius(10),
            BorderThickness = new Thickness(on ? 2 : 1),
            BorderBrush = on ? tn.Accent : tn.Line,
            Background = shot.Thumb is { } thumb ? new ImageBrush(thumb) { Stretch = Stretch.UniformToFill } : tn.Bg,
            Child = shot.Thumb is null ? Ui.Icon(Icons.Photo, 18, tn.Sub) : null,
        };
        var grid = new Grid();
        grid.Children.Add(picture);
        if (on)
        {
            grid.Children.Add(new Border
            {
                Child = Ui.Text((index + 1).ToString(CultureInfo.InvariantCulture), 11, FontWeights.Bold, tn.OnAccent, mono: true, align: TextAlignment.Center),
                Width = 20,
                Height = 20,
                CornerRadius = new CornerRadius(10),
                Background = tn.Accent,
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0, 5, 5, 0),
            });
        }
        var button = new PlainButton(grid, () =>
        {
            if (!selected.Remove(shot.Path))
            {
                selected.Add(shot.Path);
            }
            changed();
        }).Named(name).Help(on ? $"{name}: selected as number {index + 1}" : $"Select {name}");
        System.Windows.Automation.AutomationProperties.SetItemStatus(button, on ? $"Selected, number {index + 1}" : "");
        return button;
    }

    // A tool: an icon over its label, on bg with a line border.
    PlainButton Tool(string title, string glyph, Action run, bool enabled)
    {
        var tn = Tn.Current;
        var body = Ui.V(4,
            Ui.Icon(glyph, 18, enabled ? tn.Accent : tn.Sub),
            Ui.Text(title, 12, FontWeights.SemiBold, align: TextAlignment.Center));
        body.HorizontalAlignment = HorizontalAlignment.Center;
        body.VerticalAlignment = VerticalAlignment.Center;
        var tile = Ui.Tile(body, tn.Bg, tn.Line, 0, 10);
        tile.MinHeight = 60;
        var b = new PlainButton(tile, () =>
        {
            close();
            run();
        }) { IsEnabled = enabled };
        return b.Named(title).Help(enabled ? title : $"{title}: the computer is not reachable");
    }

    // Asks for screenshots or other images in the Screenshots folder, and
    // sends them to the computer at once.
    static void PickAll(string folder, SharePlugin share, DeviceSnapshot d)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Multiselect = true,
            Title = $"Send to {d.Name}",
            InitialDirectory = Directory.Exists(folder) ? folder : Environment.GetFolderPath(Environment.SpecialFolder.MyPictures),
            Filter = "Images|*.png;*.jpg;*.jpeg;*.gif;*.bmp;*.heic;*.tif;*.tiff|All files|*.*",
        };
        if (dialog.ShowDialog(Application.Current?.MainWindow) == true)
        {
            share.SendFiles(dialog.FileNames, d.Id);
        }
    }
}
