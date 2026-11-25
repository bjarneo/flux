using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using FluxKit;

namespace Flux;

// The camera windows, 1 for each computer. Closing a window stops its
// camera, and the camera pauses while its window is minimized.
// CameraWindows.swift of the Mac app has the same rules.
public static class CameraWindows
{
    static readonly Dictionary<string, CameraWindow> Open = [];

    // The open windows.
    public static IReadOnlyList<CameraWindow> All => Open.Values.ToArray();

    // Shows the camera window of a computer in a mode, and opens it when it is not open.
    public static CameraWindow Show(AppModel model, DeviceSnapshot device, CameraMode mode)
    {
        if (Open.TryGetValue(device.Id, out var open))
        {
            open.Model.Mode = mode;
            open.ShowFront();
            return open;
        }
        var w = new CameraWindow(new CameraWindowModel(device.Id, model, mode, StreamFeature.Cameras));
        Open[device.Id] = w;
        w.Closed += (_, _) => Open.Remove(device.Id);
        w.ShowFront();
        return w;
    }

    public static void CloseAll()
    {
        foreach (var w in All)
        {
            w.Close();
        }
    }
}

// The camera window of 1 computer: the mode bar, the camera picker, and the
// mode. Space is the shutter, Ctrl+V pastes an image, Ctrl+Z undoes a
// stroke, Ctrl+Enter sends the scanned text, and Esc closes the window.
public sealed class CameraWindow : Window
{
    public CameraWindow(CameraWindowModel model)
    {
        Model = model;
        Title = $"Camera for {model.DeviceName}";
        Width = 760;
        Height = 680;
        MinWidth = 640;
        MinHeight = 560;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = Faces.Body;
        View = new CameraView(model);
        Content = View;
        Theme();
        Tn.Changed += Theme;
        Loaded += (_, _) =>
        {
            model.Camera.Start();
            model.Apply();
        };
        // The camera pauses while the window is minimized.
        StateChanged += (_, _) => model.Camera.SetVisible(WindowState != WindowState.Minimized);
        // The user can come back from the privacy settings of Windows.
        Activated += (_, _) => model.Camera.RefreshAccess();
        Closed += (_, _) =>
        {
            Tn.Changed -= Theme;
            View.Stop();
            model.Close();
        };
        PreviewKeyDown += (_, e) =>
        {
            // Before the text field, so that Ctrl+Enter sends and adds no line.
            if (e.Key == Key.Enter && Keyboard.Modifiers == ModifierKeys.Control && View.SendText())
            {
                e.Handled = true;
            }
            // Before a focused button, so that Space is the shutter while the
            // mode shows one, as on the Mac. Else Space presses the button.
            if (e.Key == Key.Space && Keyboard.Modifiers == ModifierKeys.None && !Typing && View.Shutter())
            {
                e.Handled = true;
            }
        };
        KeyDown += (_, e) =>
        {
            if (RunKey(e.Key == Key.System ? e.SystemKey : e.Key))
            {
                e.Handled = true;
            }
        };
    }

    public CameraWindowModel Model { get; }

    internal CameraView View { get; }

    // True while the keys go to a text field or a list.
    static bool Typing => Keyboard.FocusedElement is TextBoxBase or ComboBox or ComboBoxItem or MenuItem;

    // Runs the shortcut of a key that no control took. A text field keeps its own keys.
    bool RunKey(Key key)
    {
        var modifiers = Keyboard.Modifiers;
        if (key == Key.Escape && modifiers == ModifierKeys.None)
        {
            Close();
            return true;
        }
        if (Typing)
        {
            return false;
        }
        switch (key)
        {
            case Key.V when modifiers == ModifierKeys.Control:
                View.PasteImage();
                return true;
            case Key.Z when modifiers == ModifierKeys.Control:
                View.UndoInk();
                return true;
        }
        return false;
    }

    void Theme()
    {
        Background = Tn.Current.Bg;
        Foreground = Tn.Current.Text;
    }

    public void ShowFront()
    {
        Show();
        if (WindowState == WindowState.Minimized)
        {
            WindowState = WindowState.Normal;
        }
        Activate();
    }
}

// The view of the camera window. The live preview, the outline layer, the
// text field, the ink canvas, and the page strip stay across the drawings.
// CameraView.swift, CaptureModeViews.swift, and ScanModeViews.swift of the
// Mac app have the same parts.
public sealed class CameraView : View
{
    // The surfaces of paper: the canvas of a drawn signature and the
    // background of a signature with transparency, from the light palette.
    static readonly ThemeColors Paper = new(ThemePalette.TokyoNightDay);

    readonly CameraWindowModel model;
    readonly Image preview = new() { Stretch = Stretch.UniformToFill };
    readonly Canvas outlines = new() { IsHitTestVisible = false, ClipToBounds = true };
    readonly Grid live = new() { ClipToBounds = true };
    readonly Border stage = new() { CornerRadius = new CornerRadius(14), ClipToBounds = true, Margin = new Thickness(16, 10, 16, 10), AllowDrop = true };
    readonly TextBox editor = new()
    {
        AcceptsReturn = true,
        TextWrapping = TextWrapping.Wrap,
        MinHeight = 120,
        MaxHeight = 220,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        Padding = new Thickness(8, 6, 8, 6),
        FontSize = 13,
    };
    // The text field with the mic key. A dictation puts its words at the cursor, else at the end of the text.
    readonly VoiceBar voice;
    readonly InkCanvas ink = new() { EditingMode = InkCanvasEditingMode.Ink };
    readonly ComboBox cameraBox = new() { MinWidth = 160, VerticalAlignment = VerticalAlignment.Center };
    readonly ConditionalWeakTable<BgraImage, BitmapSource> bitmaps = new();
    bool dropping;
    bool fillingCameras;

    public CameraView(CameraWindowModel model)
    {
        this.model = model;
        Watch(model);
        Watch(model.Text);
        Watch(model.Codes);
        Watch(model.Photo);
        Watch(model.Document);
        Watch(model.Signature);
        voice = VoiceBar.Insert(model.App.Core, editor, editor, key: 36);
        AutomationProperties.SetName(preview, "Camera preview");
        live.Children.Add(preview);
        live.Children.Add(outlines);
        live.SizeChanged += (_, _) => DrawOutlines();
        AutomationProperties.SetName(editor, "Scanned text");
        editor.TextChanged += (_, _) =>
        {
            if (model.Text.Text != editor.Text)
            {
                model.Text.Text = editor.Text;
            }
        };
        AutomationProperties.SetName(ink, "Signature canvas");
        ink.DefaultDrawingAttributes = new System.Windows.Ink.DrawingAttributes
        {
            Color = Paper.Text.Color,
            Width = SignatureDrawing.LineWidth,
            Height = SignatureDrawing.LineWidth,
            FitToCurve = true,
            IgnorePressure = true,
        };
        ink.StrokeCollected += (_, e) =>
        {
            model.Signature.Drawing.Add(e.Stroke.StylusPoints.Select(p => new InkPoint(p.X, p.Y)));
            model.Signature.DrawingChanged();
        };
        AutomationProperties.SetName(cameraBox, "Camera");
        cameraBox.SelectionChanged += (_, _) =>
        {
            if (!fillingCameras && cameraBox.SelectedItem is ComboBoxItem { Tag: string id })
            {
                model.Camera.Select(id);
            }
        };
        stage.DragEnter += Dragging;
        stage.DragOver += Dragging;
        stage.DragLeave += (_, _) => SetDropping(false);
        stage.Drop += (_, e) =>
        {
            SetDropping(false);
            if (model.AcceptsImages)
            {
                model.Use(CameraImaging.Dropped(e.Data, model.Show));
            }
            e.Handled = true;
        };
        Loaded += (_, _) => model.Camera.PropertyChanged += CameraChanged;
        Unloaded += (_, _) => model.Camera.PropertyChanged -= CameraChanged;
    }

    // The outlines change often, so they draw without a new drawing of the view.
    void CameraChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(CameraFeed.Outlines):
                DrawOutlines();
                break;
            case nameof(CameraFeed.Preview):
                preview.Source = model.Camera.Preview;
                break;
            case nameof(CameraFeed.FrameWidth):
                DrawOutlines();
                break;
            default:
                Invalidate();
                break;
        }
    }

    // Stops the dictation when the window closes.
    public void Stop() => voice.Dictation.Cancel();

    void Dragging(object sender, DragEventArgs e)
    {
        var ok = model.AcceptsImages && CameraImaging.CanDrop(e.Data);
        e.Effects = ok ? DragDropEffects.Copy : DragDropEffects.None;
        SetDropping(ok);
        e.Handled = true;
    }

    void SetDropping(bool on)
    {
        if (dropping != on)
        {
            dropping = on;
            Invalidate();
        }
    }

    // Keys

    // Space presses the shutter of the mode when it shows and takes a
    // press. It returns false when the mode shows no shutter.
    public bool Shutter()
    {
        var camera = model.Camera;
        switch (model.Mode)
        {
            case CameraMode.Text when model.Text.IsLive && camera.Running:
                model.Text.Capture();
                return true;
            case CameraMode.Photo when camera.Running && !model.Photo.Busy:
                model.Photo.Shoot();
                return true;
            case CameraMode.Document when camera.Running && !model.Document.Sending && !model.Document.Busy:
                model.Document.Capture();
                return true;
            case CameraMode.Signature when model.Signature.IsLive && camera.Running:
                model.Signature.Capture(live.ActualWidth, live.ActualHeight);
                return true;
        }
        return false;
    }

    // Ctrl+V pastes an image when the mode reads images and shows its sources.
    public void PasteImage()
    {
        if (!ShowsSources)
        {
            return;
        }
        if (CameraImaging.Paste() is { } image)
        {
            model.Use([image]);
        }
        else
        {
            model.Show("The clipboard has no image");
        }
    }

    // True when the mode shows Open Image, Screen Region, and Paste Image now.
    bool ShowsSources => model.Mode switch
    {
        CameraMode.Text => model.Text.IsLive,
        CameraMode.Qr => model.Codes.IsLive,
        CameraMode.Document => !model.Document.Sending,
        CameraMode.Signature => model.Signature.IsLive,
        _ => false,
    };

    // Ctrl+Z removes the last stroke of a drawn signature.
    public void UndoInk()
    {
        var s = model.Signature;
        if (model.Mode == CameraMode.Signature && s.State == SignatureCapture.Phase.Live && s.From == SignatureCapture.Source.Draw && !s.Drawing.IsEmpty)
        {
            s.Undo();
        }
    }

    // Ctrl+Enter sends the scanned text. It returns false when Text mode shows no text to send.
    public bool SendText()
    {
        if (model.Mode != CameraMode.Text || model.Text.State != TextScan.Phase.Result || model.Text.Text.Trim().Length == 0)
        {
            return false;
        }
        model.Text.Send();
        return true;
    }

    // Drawing

    protected override UIElement Build()
    {
        var tn = Tn.Current;
        // The kept text field and canvas move into the new layout, and get
        // the focus back after it.
        StreamParts.Refocus(StreamParts.Focused(this));
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star), MinHeight = 200 });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var header = Ui.H(12, ModeBar(), Ui.Spacer(8), CameraPicker()).Margin(16, 16, 16, 0);
        var mode = model.Mode;
        var hint = Ui.H(8, Ui.Icon(mode.Glyph(), 14, tn.Sub), Ui.Text(mode.Hint(), 13, color: tn.Sub)).Margin(16, 8, 16, 0);
        stage.Background = tn.OffTile;
        stage.BorderBrush = tn.Accent;
        stage.BorderThickness = new Thickness(dropping ? 3 : 0);
        Ui.Detach(stage);
        stage.Child = null;
        var (content, bottom) = mode switch
        {
            CameraMode.Text => TextMode(),
            CameraMode.Qr => CodeMode(),
            CameraMode.Photo => PhotoMode(),
            CameraMode.Document => DocumentMode(),
            _ => SignatureMode(),
        };
        stage.Child = content;
        Grid.SetRow(header, 0);
        Grid.SetRow(hint, 1);
        Grid.SetRow(stage, 2);
        Grid.SetRow(bottom, 3);
        root.Children.Add(header);
        root.Children.Add(hint);
        root.Children.Add(stage);
        root.Children.Add(bottom);
        if (model.Message is { } message)
        {
            var toast = Ui.Tile(Ui.Text(message, 13, wrap: true, align: TextAlignment.Center), tn.TileHi, tn.LineHi, 0, 18);
            toast.Padding = new Thickness(14, 8, 14, 8);
            toast.HorizontalAlignment = HorizontalAlignment.Center;
            toast.VerticalAlignment = VerticalAlignment.Top;
            toast.Margin = new Thickness(40, 100, 40, 0);
            toast.IsHitTestVisible = false;
            AutomationProperties.SetLiveSetting(toast, AutomationLiveSetting.Polite);
            Grid.SetRowSpan(toast, 4);
            root.Children.Add(toast);
        }
        return root;
    }

    // The 5 modes as a row of segments.
    UIElement ModeBar()
    {
        var tn = Tn.Current;
        var segments = CameraModes.All.Select(m =>
        {
            var selected = m == model.Mode;
            var chip = new Border
            {
                Child = Ui.Text(m.Label(), 13, FontWeights.SemiBold, selected ? tn.Text : tn.Sub),
                Background = selected ? tn.AccentTile : tn.Tile,
                BorderBrush = selected ? tn.Accent : tn.Line,
                BorderThickness = new Thickness(selected ? 2 : 1),
                CornerRadius = new CornerRadius(Metrics.SmallCorner),
                Padding = new Thickness(12, 5, 12, 5),
                MinHeight = Metrics.ButtonHeight,
            };
            var b = new PlainButton(chip, () => model.Mode = m).Named($"{m.Label()} mode").Help(m.Hint());
            AutomationProperties.SetItemStatus(b, selected ? "Selected" : "");
            return (UIElement)b;
        });
        return Ui.H(4, segments);
    }

    // Picks the camera when this computer has more than 1.
    UIElement? CameraPicker()
    {
        var tn = Tn.Current;
        var camera = model.Camera;
        if (camera.Cameras.Count > 1)
        {
            fillingCameras = true;
            var selected = camera.SelectedId;
            cameraBox.Items.Clear();
            foreach (var c in camera.Cameras)
            {
                var item = new ComboBoxItem { Content = c.Name, Tag = c.Device.DeviceId };
                cameraBox.Items.Add(item);
                if (c.Device.DeviceId == selected)
                {
                    cameraBox.SelectedItem = item;
                }
            }
            if (cameraBox.SelectedItem is null && cameraBox.Items.Count > 0)
            {
                cameraBox.SelectedIndex = 0;
            }
            fillingCameras = false;
            Ui.Detach(cameraBox);
            return cameraBox.Help("The camera of the camera modes. The webcam keeps its own choice.");
        }
        if (camera.Cameras.FirstOrDefault() is { } only)
        {
            return Ui.H(6, Ui.Icon(Icons.Camera, 13, tn.Sub), Ui.Text(only.Name, 13, color: tn.Sub));
        }
        return null;
    }

    // The live preview with outlines, or the reason it cannot show. what
    // ends a sentence, such as "scan text".
    UIElement LiveCamera(string what, bool showOutlines, UIElement? overlay = null)
    {
        var tn = Tn.Current;
        var camera = model.Camera;
        if (camera.Denied)
        {
            return Notice(Icons.Webcam, "Flux cannot use the camera",
                $"Allow desktop apps in Settings > Privacy & security > Camera to {what}. You can also open an image.",
                new FluxButton("Open Privacy Settings", ButtonKind.Tonal, () => Privacy.OpenSettings(Privacy.Camera)).Named("Open Privacy Settings"));
        }
        if (!camera.Listed)
        {
            return Parts.Spinner(18).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        }
        if (camera.Cameras.Count == 0)
        {
            return Notice(Icons.Webcam, "No camera found", "Connect a camera. You can also open an image.");
        }
        if (camera.Error is { } error && !camera.Running)
        {
            return Notice(Icons.Warning, "The camera does not start", error,
                new FluxButton("Try Again", ButtonKind.Tonal, camera.Retry).Named("Try Again"));
        }
        preview.Source = camera.Preview;
        outlines.Visibility = showOutlines ? Visibility.Visible : Visibility.Collapsed;
        while (live.Children.Count > 2)
        {
            live.Children.RemoveAt(2);
        }
        if (overlay is not null)
        {
            Ui.Detach(overlay);
            live.Children.Add(overlay);
        }
        Ui.Detach(live);
        DrawOutlines();
        return live;
    }

    static UIElement Notice(string glyph, string title, string detail, UIElement? action = null)
    {
        var tn = Tn.Current;
        var notice = Ui.V(10,
            Ui.Icon(glyph, 28, tn.Sub),
            Ui.Text(title, 17, FontWeights.SemiBold, align: TextAlignment.Center),
            Ui.Text(detail, 13, color: tn.Sub, wrap: true, align: TextAlignment.Center),
            action is FrameworkElement f ? f.Align(HorizontalAlignment.Center, VerticalAlignment.Center) : null)
            .Align(HorizontalAlignment.Center, VerticalAlignment.Center).Margin(32);
        notice.MaxWidth = 440;
        return notice;
    }

    // Draws the outlines from normalized frame coordinates over the preview,
    // which fills its bounds with the frame and cuts off the overflow.
    void DrawOutlines()
    {
        outlines.Children.Clear();
        var camera = model.Camera;
        double fw = camera.FrameWidth, fh = camera.FrameHeight, vw = live.ActualWidth, vh = live.ActualHeight;
        if (fw <= 0 || fh <= 0 || vw <= 0 || vh <= 0 || outlines.Visibility != Visibility.Visible)
        {
            return;
        }
        var scale = Math.Max(vw / fw, vh / fh);
        var dx = (vw - fw * scale) / 2;
        var dy = (vh - fh * scale) / 2;
        foreach (var outline in camera.Outlines.Where(o => o.Count > 1))
        {
            var polygon = new Polygon
            {
                Stroke = Tn.Current.Accent,
                StrokeThickness = 3,
                StrokeLineJoin = PenLineJoin.Round,
                Points = new PointCollection(outline.Select(p => new Point(dx + p.X * fw * scale, dy + p.Y * fh * scale))),
            };
            outlines.Children.Add(polygon);
        }
    }

    // A still image that fits the stage.
    UIElement Still(BgraImage? image)
    {
        if (image is null)
        {
            return new Grid();
        }
        var source = bitmaps.GetValue(image, CameraImaging.ToBitmap);
        return new Image { Source = source, Stretch = Stretch.Uniform }.Named("Image");
    }

    // A still with a short status over it, such as "Reading text".
    UIElement Busy(BgraImage? image, string text)
    {
        var tn = Tn.Current;
        var badge = Ui.Tile(Ui.H(10, Parts.Spinner(14), Ui.Text(text, 13)), tn.TileHi, tn.LineHi, 0, 18);
        badge.Padding = new Thickness(16, 10, 16, 10);
        badge.HorizontalAlignment = HorizontalAlignment.Center;
        badge.VerticalAlignment = VerticalAlignment.Center;
        var grid = new Grid();
        grid.Children.Add(Still(image));
        grid.Children.Add(badge);
        return grid;
    }

    // The shutter: a filled circle inside a ring. Space presses it.
    UIElement ShutterKey(string label, Action action, bool enabled, bool busy = false)
    {
        var tn = Tn.Current;
        var ring = new Ellipse { Width = 58, Height = 58, Stroke = tn.Text, StrokeThickness = 3, Opacity = 0.8 };
        var dot = new Ellipse { Width = 46, Height = 46, Fill = tn.Text, Opacity = busy ? 0.3 : 0.85 };
        var face = new Grid { Width = 58, Height = 58 };
        face.Children.Add(ring);
        face.Children.Add(dot);
        if (busy)
        {
            face.Children.Add(Parts.Spinner(16).Align(HorizontalAlignment.Center, VerticalAlignment.Center));
        }
        var b = new PlainButton(face, action) { IsEnabled = enabled && !busy, HorizontalAlignment = HorizontalAlignment.Center };
        return b.Named(label).Help($"{label} (Space)");
    }

    // Open Image, Screen Region, and Paste Image, for the modes that read
    // images. Ctrl+V pastes an image too.
    UIElement ImageSources(bool multiple = false)
    {
        FluxButton? button = null;
        button = new FluxButton("From Image", ButtonKind.Outlined, () =>
        {
            var menu = new ContextMenu { PlacementTarget = button, Placement = PlacementMode.Top };
            menu.Items.Add(MenuItem(multiple ? "Open Images…" : "Open Image…", "", () =>
            {
                // A cancel of the dialog gives no images and no message.
                if (CameraImaging.Open(Window.GetWindow(this), multiple, model.Show) is { Count: > 0 } images)
                {
                    model.Use(images);
                }
            }));
            menu.Items.Add(MenuItem("Screen Region…", "", () => _ = RegionAsync()));
            menu.Items.Add(MenuItem("Paste Image", "Ctrl+V", PasteImage));
            menu.IsOpen = true;
        }, Icons.Photo);
        return button.Named("From Image").Help("Open an image, select a part of the screen, or paste an image. You can also drop an image on the camera.");
    }

    static MenuItem MenuItem(string header, string gesture, Action run)
    {
        var item = new MenuItem { Header = header, InputGestureText = gesture };
        item.Click += (_, _) => run();
        return item;
    }

    async Task RegionAsync()
    {
        if (await ScreenRegion.PickAsync(Window.GetWindow(this), model.Show) is { } image)
        {
            model.Use([image]);
        }
    }

    // The row of controls under the stage: the leading part, the center,
    // and the trailing part.
    static UIElement ControlBar(UIElement? leading, UIElement? center, UIElement? trailing)
    {
        var grid = new Grid { MinHeight = 72, Margin = new Thickness(16, 0, 16, 16) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        void Put(UIElement? e, int column, HorizontalAlignment align)
        {
            if (e is null)
            {
                return;
            }
            Ui.Detach(e);
            if (e is FrameworkElement f)
            {
                f.HorizontalAlignment = align;
                f.VerticalAlignment = VerticalAlignment.Center;
            }
            Grid.SetColumn(e, column);
            grid.Children.Add(e);
        }
        Put(leading, 0, HorizontalAlignment.Left);
        Put(center, 1, HorizontalAlignment.Center);
        Put(trailing, 2, HorizontalAlignment.Right);
        return grid;
    }

    // Text

    (UIElement, UIElement) TextMode()
    {
        var scan = model.Text;
        return scan.State switch
        {
            TextScan.Phase.Live => (LiveCamera("scan text", true),
                ControlBar(ImageSources(), ShutterKey("Scan Text", scan.Capture, model.Camera.Running), null)),
            TextScan.Phase.Reading => (Busy(scan.Image, "Reading text"), ControlBar(null, null, null)),
            _ => (Still(scan.Image), TextResult()),
        };
    }

    UIElement TextResult()
    {
        var tn = Tn.Current;
        var scan = model.Text;
        var items = new List<UIElement?>();
        if (!scan.Found)
        {
            items.Add(Ui.Text("No text found. Move closer or add light.", 13, color: tn.Sub, align: TextAlignment.Center).Margin(0, 12, 0, 12)
                .Align(HorizontalAlignment.Center, VerticalAlignment.Center));
        }
        else
        {
            if (editor.Text != scan.Text)
            {
                editor.Text = scan.Text;
                editor.CaretIndex = editor.Text.Length;
            }
            editor.Background = tn.Bg;
            editor.Foreground = tn.Text;
            editor.BorderBrush = tn.LineHi;
            editor.CaretBrush = tn.Accent;
            editor.FontFamily = Faces.Body;
            items.Add(voice);
        }
        var canSend = scan.Text.Trim().Length > 0;
        items.Add(Ui.H(8,
            scan.Found ? new FluxButton("Clear", ButtonKind.Text, () => scan.Text = "", Icons.Close, enabled: scan.Text.Length > 0).Named("Clear").Help("Clear the text") : null,
            Ui.Spacer(8),
            new FluxButton("Retake", ButtonKind.Outlined, scan.Retake, Icons.Refresh).Named("Retake"),
            canSend ? new FluxButton($"Send to {model.DeviceName}", ButtonKind.Filled, scan.Send, Icons.Send).Named($"Send to {model.DeviceName}").Help("Send the text (Ctrl+Enter)") : null));
        return Ui.V(12, items).Margin(16, 0, 16, 16);
    }

    // QR

    (UIElement, UIElement) CodeMode()
    {
        var tn = Tn.Current;
        var scan = model.Codes;
        switch (scan.State)
        {
            case CodeScan.Phase.Live:
                return (LiveCamera("scan codes", true),
                    ControlBar(Ui.Text("Point the camera at a code", 13, color: tn.Sub), null, ImageSources()));
            case CodeScan.Phase.Found when scan.Sheet is { } sheet:
                return (Still(scan.Image), Sheet(sheet));
            default:
                var row = Ui.H(8, Ui.Text("No code found in this image.", 13, color: tn.Sub), Ui.Spacer(8),
                    new FluxButton("Scan Again", ButtonKind.Filled, scan.Again, Icons.QrCode).Named("Scan Again"));
                row.MinHeight = 72;
                return (Still(scan.Image), row.Margin(16, 0, 16, 16));
        }
    }

    // The type line, the value, and the 2 actions of a code.
    UIElement Sheet(CodeSheet sheet)
    {
        var tn = Tn.Current;
        var value = Ui.SelectableText(sheet.Value, 17, mono: false);
        var scroll = new ScrollViewer
        {
            Content = value,
            MaxHeight = 140,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        var actions = sheet.Actions.Select((a, i) => (UIElement)new FluxButton(a.Verb, i == 0 ? ButtonKind.Filled : ButtonKind.Outlined,
            () => model.Codes.Run(a), Glyph(a.Body)).Named(a.Verb));
        var row = Ui.H(8, actions.Append(Ui.Spacer(8)).Append(new FluxButton("Scan Again", ButtonKind.Outlined, model.Codes.Again, Icons.QrCode).Named("Scan Again")));
        var body = Ui.V(12, Ui.Text(sheet.Title, 13, FontWeights.Medium, tn.Accent), scroll, row);
        return Ui.Tile(body, tn.Tile, tn.Line, 16, 14).Margin(16, 0, 16, 16);
    }

    static string Glyph(ShareBody body) => body switch
    {
        ShareBody.OpenUrl => Icons.Open,
        ShareBody.Copy => Icons.Copy,
        _ => Icons.Download,
    };

    // Photo

    (UIElement, UIElement) PhotoMode()
    {
        var shots = model.Photo;
        return (LiveCamera("take photos", false),
            ControlBar(LastPhoto(), ShutterKey("Take Photo", shots.Shoot, model.Camera.Running && !shots.Busy, shots.State == PhotoShots.Phase.Saving), null));
    }

    // The thumbnail of the last photo with its send state. A failed photo sends again on click.
    UIElement? LastPhoto()
    {
        var tn = Tn.Current;
        var shots = model.Photo;
        if (shots.State == PhotoShots.Phase.None)
        {
            return null;
        }
        var failed = shots.State == PhotoShots.Phase.Failed;
        var label = shots.State switch
        {
            PhotoShots.Phase.Saving => "Saving…",
            PhotoShots.Phase.Sending => "Sending…",
            PhotoShots.Phase.Sent => "Sent",
            _ => "Click to send again",
        };
        var thumb = new Border
        {
            Width = 48,
            Height = 48,
            CornerRadius = new CornerRadius(Metrics.SmallCorner),
            Background = tn.Line,
            ClipToBounds = true,
            Child = shots.Thumb is { } t ? new Image { Source = bitmaps.GetValue(t, CameraImaging.ToBitmap), Stretch = Stretch.UniformToFill } : null,
        };
        var row = Ui.H(8, thumb, Ui.Text(label, 12, color: failed ? tn.Accent : tn.Sub));
        var b = new PlainButton(row, shots.Retry) { IsEnabled = failed };
        b.Opacity = 1;
        return b.Named(failed ? "Send the photo again" : label).Help(failed ? shots.Failure : "");
    }

    // Document

    (UIElement, UIElement) DocumentMode()
    {
        var tn = Tn.Current;
        var pages = model.Document;
        var stageContent = new Grid();
        stageContent.Children.Add(LiveCamera("scan pages", true));
        if (pages.Busy)
        {
            stageContent.Children.Add(Busy(null, "Finding the page"));
        }
        var items = new List<UIElement?>();
        if (pages.Pages.Count > 0)
        {
            var strip = Ui.H(10, pages.Pages.Select((p, i) => PageThumb(i + 1, p)));
            items.Add(new ScrollViewer
            {
                Content = strip,
                Height = 104,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
                Padding = new Thickness(16, 0, 16, 0),
            });
        }
        if (pages.Status is { } status)
        {
            items.Add(Ui.Text(status, 13, color: tn.Sub, wrap: true).Margin(16, 6, 16, 0));
        }
        var send = new FluxButton(pages.Pages.Count == 0 ? "Send PDF" : $"Send PDF, {DocumentPages.Label(pages.Pages.Count)}", ButtonKind.Filled,
            pages.Send, Icons.Document, enabled: pages.Pages.Count > 0 && !pages.Sending && !pages.Busy);
        items.Add(ControlBar(ImageSources(multiple: true),
            ShutterKey("Add Page", pages.Capture, model.Camera.Running && !pages.Sending, pages.Busy),
            send.Named(send.IsEnabled ? $"Send PDF to {model.DeviceName}" : "Send PDF")));
        return (stageContent, Ui.V(0, items));
    }

    // 1 page of a document. The menu switches between the found page and the whole image.
    UIElement PageThumb(int number, DocumentPages.Page page)
    {
        var tn = Tn.Current;
        var pages = model.Document;
        var image = new Image { Source = bitmaps.GetValue(page.Image, CameraImaging.ToBitmap), Height = 76, Stretch = Stretch.Uniform };
        var remove = new PlainButton(new Border
        {
            Child = Ui.Icon(Icons.Close, 10, tn.Text),
            Width = 20,
            Height = 20,
            CornerRadius = new CornerRadius(10),
            Background = tn.TileHi,
            BorderBrush = tn.LineHi,
            BorderThickness = new Thickness(1),
        }, () => pages.Remove(page.Id))
        {
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(3),
        }.Named($"Remove page {number}").Help($"Remove page {number}");
        var holder = new Grid { Background = tn.Line };
        holder.Children.Add(image);
        holder.Children.Add(remove);
        var caption = page.Flat is null ? $"{number} · whole image" : $"{number}";
        var body = Ui.V(4, holder, Ui.Text(caption, 11, color: tn.Sub, align: TextAlignment.Center).Align(HorizontalAlignment.Center, VerticalAlignment.Center));
        var menu = new ContextMenu();
        if (page.Flat is not null)
        {
            menu.Items.Add(MenuItem(page.Whole ? "Use Found Page" : "Use Whole Image", "", () => pages.ToggleWhole(page.Id)));
        }
        menu.Items.Add(MenuItem("Remove", "", () => pages.Remove(page.Id)));
        body.ContextMenu = menu;
        AutomationProperties.SetName(body, $"Page {number}");
        return body;
    }

    // Signature

    (UIElement, UIElement) SignatureMode()
    {
        var capture = model.Signature;
        var draw = capture.From == SignatureCapture.Source.Draw;
        switch (capture.State)
        {
            case SignatureCapture.Phase.Live:
                var source = Ui.H(4, new[] { SignatureCapture.Source.Camera, SignatureCapture.Source.Draw }.Select(s => SourceChip(s)));
                var leading = Ui.H(10, source, draw ? null : ImageSources());
                UIElement? center = draw ? null : ShutterKey("Capture Signature", () => capture.Capture(live.ActualWidth, live.ActualHeight), model.Camera.Running);
                UIElement? trailing = !draw ? null : Ui.H(8,
                    new FluxButton("Undo", ButtonKind.Outlined, capture.Undo, CameraModes.UndoGlyph, enabled: !capture.Drawing.IsEmpty).Named("Undo").Help("Undo the last stroke (Ctrl+Z)"),
                    new FluxButton("Clear", ButtonKind.Outlined, capture.Clear, enabled: !capture.Drawing.IsEmpty).Named("Clear").Help("Clear the canvas"),
                    new FluxButton("Done", ButtonKind.Filled, () => capture.FinishDrawing(ink.ActualWidth, ink.ActualHeight), enabled: !capture.Drawing.IsEmpty).Named("Done"));
                return (draw ? DrawingCanvas() : LiveCamera("capture a signature", false, GuideFrame()), ControlBar(leading, center, trailing));
            case SignatureCapture.Phase.Working:
                return (Busy(capture.Image, "Finding the ink"), ControlBar(null, null, null));
            default:
                UIElement result = capture.Ink is { } cut
                    ? SignaturePreview(cut)
                    : Ui.Text(capture.Drawn ? "Draw your signature first." : "No ink found. Use a dark pen on white paper, and fill the frame.", 13,
                        color: Tn.Current.Sub, wrap: true, align: TextAlignment.Center).Align(HorizontalAlignment.Center, VerticalAlignment.Center).Margin(32);
                return (result, SignatureResult());
        }
    }

    UIElement SourceChip(SignatureCapture.Source s)
    {
        var tn = Tn.Current;
        var selected = model.Signature.From == s;
        var chip = new Border
        {
            Child = Ui.Text(SignatureCapture.Label(s), 13, FontWeights.SemiBold, selected ? tn.Text : tn.Sub),
            Background = selected ? tn.AccentTile : tn.Tile,
            BorderBrush = selected ? tn.Accent : tn.Line,
            BorderThickness = new Thickness(selected ? 2 : 1),
            CornerRadius = new CornerRadius(Metrics.SmallCorner),
            Padding = new Thickness(12, 5, 12, 5),
            MinHeight = Metrics.ButtonHeight,
        };
        var b = new PlainButton(chip, () => model.Signature.From = s).Named(SignatureCapture.Label(s))
            .Help(s == SignatureCapture.Source.Camera ? "Sign on paper and take a photo" : "Sign with the mouse, a pen, or a touch screen");
        AutomationProperties.SetItemStatus(b, selected ? "Selected" : "");
        return b;
    }

    // Dims the preview outside the guide frame, and draws the frame and a signature line.
    UIElement GuideFrame()
    {
        var tn = Tn.Current;
        var canvas = new Canvas { IsHitTestVisible = false };
        var veil = new SolidColorBrush(tn.Bg.Color) { Opacity = 0.5 };
        var hint = Ui.Text("Sign with a dark pen. Fit the signature in the frame.", 13, color: tn.Text);
        void Draw()
        {
            canvas.Children.Clear();
            double w = canvas.ActualWidth, h = canvas.ActualHeight;
            if (w <= 0 || h <= 0)
            {
                return;
            }
            var frame = SignatureCut.GuideFrame(w, h);
            var rect = new Rect(frame.X, frame.Y, frame.Width, frame.Height);
            canvas.Children.Add(new System.Windows.Shapes.Path
            {
                Fill = veil,
                Data = new CombinedGeometry(GeometryCombineMode.Exclude, new RectangleGeometry(new Rect(0, 0, w, h)), new RectangleGeometry(rect, 16, 16)),
            });
            var border = new Rectangle { Width = rect.Width, Height = rect.Height, RadiusX = 16, RadiusY = 16, Stroke = tn.Accent, StrokeThickness = 2 };
            Canvas.SetLeft(border, rect.X);
            Canvas.SetTop(border, rect.Y);
            canvas.Children.Add(border);
            var y = rect.Y + rect.Height * 0.75;
            canvas.Children.Add(new Line
            {
                X1 = rect.X + rect.Width * 0.08,
                X2 = rect.Right - rect.Width * 0.08,
                Y1 = y,
                Y2 = y,
                Stroke = tn.Text,
                Opacity = 0.6,
                StrokeThickness = 1,
                StrokeDashArray = [6, 4],
            });
            Ui.Detach(hint);
            hint.Measure(new Size(w, double.PositiveInfinity));
            Canvas.SetLeft(hint, (w - hint.DesiredSize.Width) / 2);
            Canvas.SetTop(hint, 18);
            canvas.Children.Add(hint);
        }
        canvas.SizeChanged += (_, _) => Draw();
        return canvas;
    }

    // A canvas of paper to sign on with the mouse, a pen, or a touch screen.
    UIElement DrawingCanvas()
    {
        var drawing = model.Signature.Drawing;
        // A clear or a send removed strokes from the drawing.
        while (ink.Strokes.Count > drawing.Strokes.Count)
        {
            ink.Strokes.RemoveAt(ink.Strokes.Count - 1);
        }
        ink.Background = Paper.Bg;
        ink.DefaultDrawingAttributes.Color = Paper.Text.Color;
        var grid = new Grid();
        var baseline = new Canvas { IsHitTestVisible = false };
        baseline.SizeChanged += (_, _) =>
        {
            baseline.Children.Clear();
            var y = baseline.ActualHeight * 0.75;
            baseline.Children.Add(new Line
            {
                X1 = baseline.ActualWidth * 0.08,
                X2 = baseline.ActualWidth * 0.92,
                Y1 = y,
                Y2 = y,
                Stroke = Paper.Sub,
                StrokeThickness = 1,
                StrokeDashArray = [6, 4],
            });
        };
        Ui.Detach(ink);
        grid.Children.Add(ink);
        grid.Children.Add(baseline);
        if (drawing.IsEmpty)
        {
            grid.Children.Add(Ui.Text("Sign here with the mouse, a pen, or a touch screen", 13, color: Paper.Sub)
                .Align(HorizontalAlignment.Center, VerticalAlignment.Bottom).Margin(0, 0, 0, 24));
            ((FrameworkElement)grid.Children[^1]).IsHitTestVisible = false;
        }
        return grid;
    }

    // The signature on a light checkerboard, so that the ink and the transparent background both show.
    UIElement SignaturePreview(SignatureInk cut)
    {
        var cell = new GeometryGroup();
        cell.Children.Add(new RectangleGeometry(new Rect(0, 0, 10, 10)));
        cell.Children.Add(new RectangleGeometry(new Rect(10, 10, 10, 10)));
        var tiles = new DrawingBrush(new DrawingGroup
        {
            Children =
            {
                new GeometryDrawing(Paper.Bg, null, new RectangleGeometry(new Rect(0, 0, 20, 20))),
                new GeometryDrawing(Paper.Line, null, cell),
            },
        })
        {
            TileMode = TileMode.Tile,
            Viewport = new Rect(0, 0, 20, 20),
            ViewportUnits = BrushMappingMode.Absolute,
        };
        var grid = new Grid { Background = tiles };
        var image = new Image { Source = CameraImaging.InkBitmap(cut, model.Signature.Color.Of(cut)), Stretch = Stretch.Uniform, Margin = new Thickness(20) };
        grid.Children.Add(image.Named("Signature"));
        return grid;
    }

    UIElement SignatureResult()
    {
        var tn = Tn.Current;
        var capture = model.Signature;
        var items = new List<UIElement?>();
        if (capture.Ink is { } cut)
        {
            var chips = InkColors.All.Where(c => !(capture.Drawn && c == InkColor.Original)).Select(c =>
            {
                var selected = c == capture.Color;
                var swatch = new Ellipse { Width = 12, Height = 12, Fill = new SolidColorBrush(ThemeColors.ColorOf(c.Of(cut))), Stroke = tn.LineHi, StrokeThickness = 1 };
                var chip = new Border
                {
                    Child = Ui.H(6, swatch, Ui.Text(c.Label(), 13, FontWeights.SemiBold)),
                    Background = selected ? tn.AccentTile : tn.Tile,
                    BorderBrush = selected ? tn.Accent : tn.Line,
                    BorderThickness = new Thickness(selected ? 2 : 1),
                    CornerRadius = new CornerRadius(Metrics.SmallCorner),
                    Padding = new Thickness(10, 5, 12, 5),
                    MinHeight = Metrics.ButtonHeight,
                };
                var b = new PlainButton(chip, () => capture.Color = c).Named($"{c.Label()} ink");
                AutomationProperties.SetItemStatus(b, selected ? "Selected" : "");
                return (UIElement)b;
            });
            items.Add(Ui.H(8, chips));
        }
        if (capture.Failure is { } failure)
        {
            items.Add(Ui.Text(failure, 13, color: tn.Red, wrap: true));
        }
        items.Add(Ui.H(8, Ui.Spacer(8),
            new FluxButton(capture.Drawn ? "Draw Again" : "Retake", ButtonKind.Outlined, capture.Retake, Icons.Refresh).Named(capture.Drawn ? "Draw Again" : "Retake"),
            capture.Ink is null ? null : new FluxButton(capture.Sending ? "Sending…" : $"Send to {model.DeviceName}", ButtonKind.Filled, capture.Send, Icons.Send,
                enabled: !capture.Sending).Named($"Send to {model.DeviceName}")));
        var panel = Ui.V(10, items).Margin(16, 0, 16, 16);
        panel.MinHeight = 72;
        return panel;
    }
}
