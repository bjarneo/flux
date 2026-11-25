using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using FluxKit;

namespace Flux;

// The main window: the sidebar with the list of chats, Control, and
// Computers, and the page of the selected destination with its header. A
// chat fills the detail column with its own top bar. ContentView.swift of
// the Mac app has the same layout.
public sealed class MainWindow : Window
{
    readonly AppModel model;
    readonly ShellView shell;

    // True when the app quits, so that the close does not only hide the window.
    public bool Quitting { get; set; }

    public MainWindow(AppModel model, Func<AppModel, Destination, Page> roots, Func<AppModel, Route, Page> routes)
    {
        this.model = model;
        Title = "Flux";
        Width = 980;
        Height = 640;
        MinWidth = 820;
        MinHeight = 520;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = Faces.Body;
        shell = new ShellView(model, roots, routes);
        Content = shell;
        ApplyTheme();
        Tn.Changed += ApplyTheme;
        SourceInitialized += (_, _) => ApplyCaption();
        Closing += (_, e) =>
        {
            // Flux keeps running in the tray after the window closes.
            if (!Quitting)
            {
                e.Cancel = true;
                Hide();
            }
        };
        InputBindings.Add(new KeyBinding(new Relay(() => model.Go(Destination.Chat)), Key.D1, ModifierKeys.Control));
        InputBindings.Add(new KeyBinding(new Relay(() => model.Go(Destination.Control)), Key.D2, ModifierKeys.Control));
        InputBindings.Add(new KeyBinding(new Relay(() => model.Go(Destination.Computers)), Key.D3, ModifierKeys.Control));
        InputBindings.Add(new KeyBinding(new Relay(model.Back), Key.Escape, ModifierKeys.None));
        InputBindings.Add(new KeyBinding(new Relay(model.Back), Key.Left, ModifierKeys.Alt));
        InputBindings.Add(new KeyBinding(new Relay(() => OpenSettings?.Invoke()), Key.OemComma, ModifierKeys.Control));
        InputBindings.Add(new KeyBinding(new Relay(shell.FocusSearch), Key.F, ModifierKeys.Control));
        // The chat of an agent takes the keys of the agents window.
        InputBindings.Add(new KeyBinding(new Relay(() => (shell.CurrentPage as ChatsPage)?.Agent?.Refresh()), Key.R, ModifierKeys.Control));
        InputBindings.Add(new KeyBinding(new Relay(() => (shell.CurrentPage as ChatsPage)?.Agent?.ShowChanges()), Key.D, ModifierKeys.Control));
    }

    // Opens the settings window. The app sets it.
    public Action? OpenSettings { get; set; }

    void ApplyTheme()
    {
        Background = Tn.Current.Bg;
        Foreground = Tn.Current.Text;
        ApplyCaption();
    }

    // Draws the title bar in the theme: the dark mode of the frame, and the
    // caption color of Windows 11.
    void ApplyCaption()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero)
        {
            return;
        }
        var dark = Tn.Current.Dark ? 1 : 0;
        _ = DwmSetWindowAttribute(hwnd, DwmUseImmersiveDarkMode, ref dark, sizeof(int));
        var c = Tn.Current.Bg.Color;
        var colorref = c.R | (c.G << 8) | (c.B << 16);
        _ = DwmSetWindowAttribute(hwnd, DwmCaptionColor, ref colorref, sizeof(int));
        var text = Tn.Current.Text.Color;
        var textref = text.R | (text.G << 8) | (text.B << 16);
        _ = DwmSetWindowAttribute(hwnd, DwmTextColor, ref textref, sizeof(int));
    }

    const int DwmUseImmersiveDarkMode = 20;
    const int DwmCaptionColor = 35;
    const int DwmTextColor = 36;

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    // Shows the window in front of the other windows.
    public void ShowFront()
    {
        Show();
        if (WindowState == WindowState.Minimized)
        {
            WindowState = WindowState.Normal;
        }
        Activate();
        Topmost = true;
        Topmost = false;
        Focus();
    }

    // The page on screen. Tests read it.
    internal Page? CurrentPage => shell.CurrentPage;

    // Draws the shell now. Tests call it.
    internal void DrawShell() => shell.Draw();

    // The list of chats in the sidebar. Tests read it.
    internal ChatsList Chats => shell.Chats;
}

// The sidebar, the header, the page, and the toast. The hosts and the list
// of chats stay, so that a page and the search keep their parent, their
// state, and their focus while the sidebar and the header draw again.
sealed class ShellView : ContentControl
{
    readonly AppModel model;
    readonly Func<AppModel, Destination, Page> roots;
    readonly Func<AppModel, Route, Page> routes;
    readonly Dictionary<Destination, Page> rootPages = [];
    readonly Dictionary<Route, Page> routePages = [];
    readonly ScopeMenu scopeMenu;
    readonly Border sidebarHost = new();
    readonly Border markHost = new();
    readonly Border bottomHost = new();
    readonly Border headerHost = new();
    readonly ContentControl pageHost = new() { Focusable = false };
    readonly Border toastHost = new() { IsHitTestVisible = false };
    readonly DockPanel detail = new();
    bool pending;

    public ShellView(AppModel model, Func<AppModel, Destination, Page> roots, Func<AppModel, Route, Page> routes)
    {
        this.model = model;
        this.roots = roots;
        this.routes = routes;
        Focusable = false;
        scopeMenu = new ScopeMenu(model);
        Chats = new ChatsList(model);
        var side = new DockPanel();
        DockPanel.SetDock(markHost, Dock.Top);
        DockPanel.SetDock(bottomHost, Dock.Bottom);
        side.Children.Add(markHost);
        side.Children.Add(bottomHost);
        side.Children.Add(Chats);
        sidebarHost.Child = side;
        sidebarHost.BorderThickness = new Thickness(0, 0, 1, 0);
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(SidebarWidth) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(sidebarHost, 0);
        grid.Children.Add(sidebarHost);
        DockPanel.SetDock(headerHost, Dock.Top);
        detail.Children.Add(headerHost);
        detail.Children.Add(pageHost);
        var overlay = new Grid();
        overlay.Children.Add(detail);
        overlay.Children.Add(toastHost);
        Grid.SetColumn(overlay, 1);
        grid.Children.Add(overlay);
        Content = grid;
        model.PropertyChanged += (_, _) => Refresh();
        Tn.Changed += Refresh;
        Draw();
    }

    // The width of the sidebar, for the list of chats.
    public const double SidebarWidth = 300;

    public Page? CurrentPage { get; private set; }

    // The list of chats in the sidebar.
    public ChatsList Chats { get; }

    // Gives the focus to the search of the chats, for Ctrl+F.
    public void FocusSearch() => Chats.FocusSearch();

    void Refresh()
    {
        if (pending)
        {
            return;
        }
        pending = true;
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background, () =>
        {
            pending = false;
            Draw();
        });
    }

    Page PageFor(Destination d, IReadOnlyList<Route> path)
    {
        if (path.Count > 0)
        {
            var route = path[^1];
            if (!routePages.TryGetValue(route, out var p))
            {
                p = routes(model, route);
                routePages[route] = p;
            }
            // Pages of routes that left the stacks go away.
            foreach (var gone in routePages.Keys.Where(r => !model.Path.Contains(r)).ToArray())
            {
                routePages.Remove(gone);
            }
            return p;
        }
        if (!rootPages.TryGetValue(d, out var root))
        {
            root = roots(model, d);
            rootPages[d] = root;
        }
        return root;
    }

    // Draws the sidebar, the header, and the toast, and puts the current page
    // in its host.
    internal void Draw()
    {
        var tn = Tn.Current;
        var page = PageFor(model.Destination, model.Path);
        if (CurrentPage != page)
        {
            if (CurrentPage is not null)
            {
                CurrentPage.HeaderChanged -= DrawHeader;
            }
            CurrentPage = page;
            page.HeaderChanged += DrawHeader;
            pageHost.Content = page;
        }
        detail.Background = tn.Bg;
        DrawSidebar();
        DrawHeader();
        toastHost.Child = model.Toast is { } toast
            ? new Border
            {
                Child = Ui.Text(toast, 13, wrap: true),
                Background = tn.TileHi,
                BorderBrush = tn.LineHi,
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(18),
                Padding = new Thickness(14, 8, 14, 8),
                MaxWidth = 520,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Bottom,
                Margin = new Thickness(0, 0, 0, 16),
            }.Named(toast)
            : null;
    }

    void DrawHeader()
    {
        if (CurrentPage is { } page)
        {
            headerHost.Child = page.OwnHeader ? null : Header(page);
        }
    }

    // Draws the parts of the sidebar around the list of chats: the Flux mark
    // with the key that starts an agent at the top, and Control, Computers,
    // and this computer at the bottom. The list draws itself.
    void DrawSidebar()
    {
        var tn = Tn.Current;
        sidebarHost.Background = tn.Bg;
        sidebarHost.BorderBrush = tn.Line;
        var start = model.Paired.Count > 0 && model.Core.Plugin<HerdrPlugin>() is not null
            ? new FluxButton("", ButtonKind.Text, () => AgentsFeature.StartAnywhere(model), Icons.Add).Named("Start Agent").Help("Start a coding agent on a computer")
            : null;
        markHost.Child = Ui.H(8, Mark(), Ui.Spacer(), start).Margin(14, 12, 8, 4);
        var rows = new List<UIElement?>();
        foreach (var d in new[] { Destination.Control, Destination.Computers })
        {
            var selected = model.Destination == d;
            var row = Ui.H(10,
                Ui.Icon(d.Glyph(), 15, selected ? tn.Accent : tn.Sub, 20),
                Ui.Text(d.Title(), 13, selected ? FontWeights.SemiBold : FontWeights.Normal).Fill());
            var tile = new Border
            {
                Child = row,
                Background = selected ? tn.Line : Brushes.Transparent,
                CornerRadius = new CornerRadius(Metrics.SmallCorner),
                Padding = new Thickness(10, 7, 10, 7),
                MinHeight = Metrics.RowHeight,
            };
            var dest = d;
            var button = new PlainButton(tile, () => model.Go(dest)).Named(d.Title()).Help($"{d.Title()} (Ctrl+{(int)d + 1})");
            System.Windows.Automation.AutomationProperties.SetItemStatus(button, selected ? "Selected" : "");
            rows.Add(button.Margin(8, 0, 8, 2));
        }
        var self = Ui.H(8,
            Ui.Icon(model.Core.Host.DeviceType == "laptop" ? Icons.Laptop : Icons.Desktop, 13, tn.Text),
            Ui.Text(model.State.DeviceName, 12).Fill(),
            model.State.Enabled ? null : Ui.Text("Off", 12, color: tn.Sub)).Margin(14, 8, 14, 12);
        rows.Add(self);
        bottomHost.Child = Ui.V(0, rows).Margin(0, 6, 0, 0);
        bottomHost.BorderBrush = tn.Line;
        bottomHost.BorderThickness = new Thickness(0, 1, 0, 0);
    }

    // The Flux mark: a square ring in the text color and a bar in the accent.
    static FrameworkElement Mark()
    {
        var tn = Tn.Current;
        var canvas = new Canvas { Width = 22, Height = 22 };
        var ring = new System.Windows.Shapes.Rectangle { Width = 13.75, Height = 13.75, Stroke = tn.Text, StrokeThickness = 2.75 };
        Canvas.SetLeft(ring, 4.1);
        Canvas.SetTop(ring, 4.1);
        var bar = new System.Windows.Shapes.Rectangle { Width = 2.75, Height = 19.25, Fill = tn.Accent };
        Canvas.SetLeft(bar, 9.6);
        Canvas.SetTop(bar, 1.4);
        canvas.Children.Add(ring);
        canvas.Children.Add(bar);
        return Ui.H(8, canvas, Ui.Text("flux", 16, FontWeights.Bold, mono: true)).Named("Flux");
    }

    UIElement Header(Page page)
    {
        var tn = Tn.Current;
        var back = model.Path.Count > 0
            ? new FluxButton("", ButtonKind.Text, model.Back, Icons.Back).Named("Back").Help("Back (Esc)")
            : null;
        var titles = Ui.V(1,
            Ui.Text(page.Title, 15, FontWeights.SemiBold),
            page.Subtitle.Length > 0 ? Ui.Text(page.Subtitle, 11, color: tn.Sub, mono: true) : null).Fill();
        System.Windows.Automation.AutomationProperties.SetHeadingLevel(titles, System.Windows.Automation.AutomationHeadingLevel.Level1);
        var showScope = model.Path.Count == 0 && model.Paired.Count > 0;
        if (showScope)
        {
            scopeMenu.Redraw();
        }
        var row = Ui.H(8, back, titles, showScope ? scopeMenu : null);
        return new Border { Child = row, Padding = new Thickness(Metrics.Gutter, 10, Metrics.Gutter, 8), Background = tn.Bg };
    }
}

// A command for a key binding.
sealed class Relay(Action run) : ICommand
{
    public event EventHandler? CanExecuteChanged
    {
        add { }
        remove { }
    }

    public bool CanExecute(object? parameter) => true;
    public void Execute(object? parameter) => run();
}
