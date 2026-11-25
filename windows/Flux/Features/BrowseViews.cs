using System.ComponentModel;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using FluxKit;

namespace Flux;

// The Get files windows, 1 for each computer. A window has 1 SSH session
// to the computer, which ends when the window closes. BrowseWindows.swift
// of the Mac app has the same rules.
public static class BrowseWindows
{
    static readonly Dictionary<string, BrowseWindow> Open = [];

    // The open windows.
    public static IReadOnlyList<BrowseWindow> All => Open.Values.ToArray();

    // Shows the files of a computer, and opens its window when it is not open.
    public static void Show(AppModel model, string deviceId)
    {
        if (Open.TryGetValue(deviceId, out var open))
        {
            open.ShowFront();
            return;
        }
        // The folder picker of a new agent can hold the same session, so the
        // window takes a lease, and the last release closes the session.
        if (BrowseLease.Take(model, deviceId) is not { } browser)
        {
            return;
        }
        var w = new BrowseWindow(browser);
        Open[deviceId] = w;
        w.Closed += (_, _) =>
        {
            Open.Remove(deviceId);
            BrowseLease.Release(model, deviceId);
        };
        w.ShowFront();
    }
}

// The window of the files of a computer. It asks before a close stops
// running downloads, and it writes the Mark of the Web on each file that a
// download saved.
public sealed class BrowseWindow : Window
{
    readonly BrowseModel browser;
    readonly HashSet<Guid> marked = [];

    public BrowseWindow(BrowseModel browser)
    {
        this.browser = browser;
        Title = $"Files on {browser.DeviceName}";
        Width = 780;
        Height = 540;
        MinWidth = 560;
        MinHeight = 360;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = Faces.Body;
        View = new BrowseView(browser);
        Content = View;
        Theme();
        Tn.Changed += Theme;
        browser.PropertyChanged += Changed;
        Closing += (_, e) =>
        {
            var n = browser.ActiveDownloads;
            if (n > 0 && !Quitting && !Dialogs.Confirm(this, n == 1 ? "Stop the download?" : $"Stop {n} downloads?",
                    $"Closing the window ends the session with {browser.DeviceName}, and unfinished files are deleted.", "Stop and close", destructive: true))
            {
                e.Cancel = true;
            }
        };
        Closed += (_, _) =>
        {
            Tn.Changed -= Theme;
            browser.PropertyChanged -= Changed;
        };
        InputBindings.Add(new KeyBinding(new Relay(browser.GoUp), Key.Up, ModifierKeys.Control));
        InputBindings.Add(new KeyBinding(new Relay(browser.Retry), Key.R, ModifierKeys.Control));
        InputBindings.Add(new KeyBinding(new Relay(View.FocusSearch), Key.F, ModifierKeys.Control));
        InputBindings.Add(new KeyBinding(new Relay(() =>
        {
            if (browser.InSearch)
            {
                browser.EndSearch();
            }
            else
            {
                Close();
            }
        }), Key.Escape, ModifierKeys.None));
    }

    internal BrowseView View { get; }

    // True when Flux quits. The close then asks nothing.
    public bool Quitting { get; set; }

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

    // A download that finished gets the Mark of the Web at once, before the
    // user can open it.
    void Changed(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(BrowseModel.Downloads))
        {
            return;
        }
        foreach (var d in browser.Downloads)
        {
            if (d.State is BrowseDownloadState.Done done && marked.Add(d.Id))
            {
                WindowsBrowseFiles.Mark(done.Path);
            }
        }
    }
}

// 1 row of the list of a folder or of the search.
public sealed record BrowseRow(BrowseEntry Entry, string Glyph, string Name, string Size, string Kind, string Place);

// The content of a Get files window: a path bar, the folder or the search,
// and the downloads. BrowseView.swift of the Mac app has the same parts.
// The bar and the lists stay, so that the search field and the lists keep
// their text, their selection, and their focus.
public sealed class BrowseView : View
{
    static readonly WindowsBrowseFiles Files = new();

    readonly BrowseModel browser;
    readonly DockPanel root = new();
    readonly Border bar = new() { BorderThickness = new Thickness(0, 0, 0, 1), Padding = new Thickness(12, 8, 12, 8) };
    readonly Border content = new();
    readonly Border downloadsHost = new() { BorderThickness = new Thickness(0, 1, 0, 0) };
    readonly FluxButton back;
    readonly FluxButton reload;
    readonly ScrollViewer crumbs = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, Focusable = false };
    readonly Border spinner = new();
    readonly Border searchHost = new() { BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(Metrics.SmallCorner), Width = 220 };
    readonly TextBox search = new()
    {
        BorderThickness = new Thickness(0),
        Background = System.Windows.Media.Brushes.Transparent,
        VerticalContentAlignment = VerticalAlignment.Center,
        FontSize = 12.5,
        MinHeight = 26,
    };
    readonly TextBlock prompt = Ui.Text("", 12.5);
    readonly PlainButton endSearch;
    readonly Border roots = new();
    readonly ListView list = new() { SelectionMode = SelectionMode.Extended, BorderThickness = new Thickness(0) };
    readonly ListView results = new() { SelectionMode = SelectionMode.Extended, BorderThickness = new Thickness(0) };
    readonly Dictionary<Guid, DownloadRow> downloadRows = [];
    readonly StackPanel downloadList = new() { Margin = new Thickness(12) };
    readonly FluxButton clearDownloads;
    IReadOnlyList<BrowseEntry>? listed;
    IReadOnlyList<BrowseEntry>? found;
    ThemeColors? columnsTheme;
    bool updating;

    public BrowseView(BrowseModel browser)
    {
        this.browser = browser;
        Watch(browser);
        back = new FluxButton("", ButtonKind.Text, browser.GoUp, Icons.Back).Named("Back");
        reload = new FluxButton("", ButtonKind.Text, browser.Retry, Icons.Refresh).Named("Reload").Help("Reload (Ctrl+R)");
        endSearch = new PlainButton(Ui.Icon(Icons.Close, 10).Margin(6, 0, 6, 0), browser.EndSearch).Named("Clear the search").Help("Clear the search");
        prompt.IsHitTestVisible = false;
        prompt.Margin = new Thickness(6, 0, 0, 0);
        AutomationProperties.SetName(search, "Search");
        search.TextChanged += (_, _) =>
        {
            if (!updating)
            {
                browser.SetSearchText(search.Text);
            }
        };
        search.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter)
            {
                browser.Search(search.Text);
                e.Handled = true;
            }
            else if (e.Key == Key.Escape && browser.InSearch)
            {
                browser.EndSearch();
                e.Handled = true;
            }
        };
        var field = new Grid();
        field.Children.Add(prompt);
        field.Children.Add(search);
        searchHost.Child = Ui.H(4, Ui.Icon(Icons.Search, 12).Margin(6, 0, 0, 0), field.Fill(), endSearch);
        bar.Child = Ui.H(8, back, crumbs.Fill(), spinner, searchHost, roots, reload);
        Setup(list);
        Setup(results);
        clearDownloads = new FluxButton("Clear", ButtonKind.Text, browser.ClearDownloads).Help("Remove the finished downloads from the list");
        var heading = Ui.H(8, Ui.Text("Downloads", 13, FontWeights.SemiBold), Ui.Spacer(), clearDownloads).Margin(12, 8, 12, 0);
        var downloadScroll = new ScrollViewer { Content = downloadList, MaxHeight = 150, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Focusable = false };
        downloadsHost.Child = Ui.V(0, heading, downloadScroll);
        DockPanel.SetDock(bar, Dock.Top);
        DockPanel.SetDock(downloadsHost, Dock.Bottom);
        root.Children.Add(bar);
        root.Children.Add(downloadsHost);
        root.Children.Add(content);
    }

    public void FocusSearch()
    {
        if (browser.CanSearch)
        {
            search.Focus();
        }
    }

    // The lists, for the tests.
    internal ListView List => list;
    internal ListView Results => results;

    protected override UIElement Build()
    {
        var tn = Tn.Current;
        if (!ReferenceEquals(columnsTheme, tn))
        {
            columnsTheme = tn;
            list.View = Columns(search: false);
            results.View = Columns(search: true);
        }
        DrawBar();
        content.Child = Folder();
        DrawDownloads();
        return root;
    }

    // Back, the folders from the root, the search, the roots, and reload.
    void DrawBar()
    {
        var tn = Tn.Current;
        bar.Background = tn.Bg;
        bar.BorderBrush = tn.Line;
        back.IsEnabled = browser.CanGoBack;
        back.ToolTip = browser.InSearch ? "End the search (Esc)" : "Enclosing folder (Ctrl+Up)";
        var path = browser.Crumbs;
        var parts = new List<UIElement>();
        for (var i = 0; i < path.Count; i++)
        {
            var crumb = path[i];
            if (i > 0)
            {
                parts.Add(Ui.Icon(Icons.ChevronRight, 9, tn.Dim));
            }
            var last = i == path.Count - 1;
            var label = Ui.Text(crumb.Name, 13, last ? FontWeights.SemiBold : FontWeights.Normal, last ? tn.Text : tn.Sub).Margin(4, 2, 4, 2);
            parts.Add(new PlainButton(label, () => browser.Open(crumb.Path)).Named(crumb.Name).Help($"Open {crumb.Name}"));
        }
        crumbs.Content = Ui.H(2, parts);
        var busy = browser.InSearch ? browser.Searching && browser.Found is { Results.Count: > 0 } : browser.Loading && browser.Entries.Count > 0;
        spinner.Child = busy ? Parts.Spinner(12) : null;
        searchHost.Visibility = browser.CanSearch ? Visibility.Visible : Visibility.Collapsed;
        searchHost.Background = tn.Tile;
        searchHost.BorderBrush = search.IsKeyboardFocused ? tn.Accent : tn.Line;
        search.Foreground = tn.Text;
        search.CaretBrush = tn.Accent;
        if (search.Text != browser.SearchText)
        {
            updating = true;
            search.Text = browser.SearchText;
            search.CaretIndex = search.Text.Length;
            updating = false;
        }
        prompt.Text = browser.SearchPrompt;
        prompt.Foreground = tn.Dim;
        prompt.Visibility = search.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        endSearch.Visibility = search.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        roots.Child = browser.Roots.Count > 1 ? RootsButton() : null;
        reload.ToolTip = "Reload (Ctrl+R)";
    }

    // The folders that the computer shares, in a menu.
    UIElement RootsButton()
    {
        var current = browser.Root?.Name ?? "Places";
        FluxButton? button = null;
        button = new FluxButton(current, ButtonKind.Outlined, () =>
        {
            var menu = new ContextMenu { PlacementTarget = button, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
            foreach (var root in browser.Roots)
            {
                var item = new MenuItem { Header = root.Name, Icon = Ui.Icon(RootGlyph(root.Name), 13) };
                item.Click += (_, _) => browser.Open(root.Path);
                menu.Items.Add(item);
            }
            menu.IsOpen = true;
        }, RootGlyph(current));
        return button.Help($"Folders that {browser.DeviceName} shares");
    }

    static string RootGlyph(string name) => name.ToLowerInvariant() switch
    {
        "home" => ControlGlyphs.Home,
        "downloads" => Icons.Download,
        "documents" => Icons.Document,
        "pictures" => Icons.Photo,
        "music" => Icons.Audio,
        "videos" => ControlGlyphs.Video,
        _ => Icons.Folder,
    };

    // The folder, the search, or why neither shows.
    UIElement Folder()
    {
        var tn = Tn.Current;
        if (browser.Error is { } error)
        {
            return Message(Icons.Warning, "Cannot open the files", error, new FluxButton("Try again", ButtonKind.Filled, browser.Retry));
        }
        if (browser.InSearch)
        {
            return Search();
        }
        if (browser.Loading && browser.Entries.Count == 0)
        {
            return Ui.H(10, Parts.Spinner(), Ui.Text($"Opening the files of {browser.DeviceName}…", 13, color: tn.Sub))
                .Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        }
        if (browser.Entries.Count == 0)
        {
            return Parts.Unavailable(Icons.Folder, "This folder is empty", "Go up to open another folder.");
        }
        if (!ReferenceEquals(listed, browser.Entries))
        {
            listed = browser.Entries;
            list.ItemsSource = listed.Select(e => Row(e, "")).ToArray();
        }
        Paint(list);
        return list;
    }

    // The search results, or the wait, the error, or no match.
    UIElement Search()
    {
        var tn = Tn.Current;
        if (browser.SearchError is { } error)
        {
            return Message(Icons.Warning, "Cannot search", error, new FluxButton("Try again", ButtonKind.Filled, browser.Retry));
        }
        if (browser.Found is { Results.Count: > 0 } f)
        {
            if (!ReferenceEquals(found, f.Results))
            {
                found = f.Results;
                results.ItemsSource = f.Results.Select(e => Row(e, browser.Location(e))).ToArray();
            }
            Paint(results);
            if (!f.More && !f.Partial)
            {
                return results;
            }
            var note = Ui.Text(f.More ? "Showing the first 100 matches. Type more of the name."
                : "The search stopped after 10 seconds. Search in a folder to find more.", 12.5, color: tn.Sub, wrap: true);
            var footer = new Border { Child = note, Padding = new Thickness(12, 6, 12, 6), BorderBrush = tn.Line, BorderThickness = new Thickness(0, 1, 0, 0) };
            var layout = new DockPanel();
            DockPanel.SetDock(footer, Dock.Bottom);
            layout.Children.Add(footer);
            content.Child = null;
            Ui.Detach(results);
            layout.Children.Add(results);
            return layout;
        }
        if (browser.Searching)
        {
            return Ui.H(10, Parts.Spinner(), Ui.Text("Searching…", 13, color: tn.Sub)).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        }
        return Parts.Unavailable(Icons.Search, $"No file or folder has \"{browser.Query}\"", "Type another part of the name, or search in another folder.");
    }

    static UIElement Message(string glyph, string title, string text, UIElement action)
    {
        var stack = Parts.Unavailable(glyph, title, text);
        stack.Children.Add(action);
        if (action is FrameworkElement fe)
        {
            fe.HorizontalAlignment = HorizontalAlignment.Center;
        }
        return stack;
    }

    static BrowseRow Row(BrowseEntry e, string place)
    {
        var image = Path.GetExtension(e.Name).ToLowerInvariant() is ".png" or ".jpg" or ".jpeg" or ".gif" or ".webp" or ".heic" or ".bmp" or ".svg";
        return new BrowseRow(e, e.Dir ? Icons.Folder : image ? Icons.Photo : Icons.Document, e.Name,
            e.Dir ? "--" : Texts.Bytes(e.Size), e.Dir ? "Folder" : FileKinds.Of(e.Name), place);
    }

    // Draws the colors of a list. A list that another layout holds leaves
    // it. A list that the content holds stays, so that it keeps the focus.
    void Paint(ListView view)
    {
        var tn = Tn.Current;
        view.Background = tn.Bg;
        view.Foreground = tn.Text;
        if (view.Parent is not null && view.Parent != content)
        {
            Ui.Detach(view);
        }
    }

    // The columns of a list: the name, then the size and the kind for a
    // folder, or the place and the size for the search.
    static GridView Columns(bool search)
    {
        var tn = Tn.Current;
        var view = new GridView();
        view.Columns.Add(new GridViewColumn { Header = "Name", Width = search ? 300 : 380, CellTemplate = NameCell() });
        if (search)
        {
            view.Columns.Add(new GridViewColumn { Header = "Place", Width = 240, CellTemplate = TextCell(nameof(BrowseRow.Place), tn.Sub) });
        }
        view.Columns.Add(new GridViewColumn { Header = "Size", Width = 90, CellTemplate = TextCell(nameof(BrowseRow.Size), tn.Sub) });
        if (!search)
        {
            view.Columns.Add(new GridViewColumn { Header = "Kind", Width = 170, CellTemplate = TextCell(nameof(BrowseRow.Kind), tn.Sub) });
        }
        return view;
    }

    static DataTemplate NameCell()
    {
        var tn = Tn.Current;
        var panel = new FrameworkElementFactory(typeof(DockPanel));
        var icon = new FrameworkElementFactory(typeof(TextBlock));
        icon.SetBinding(TextBlock.TextProperty, new Binding(nameof(BrowseRow.Glyph)));
        icon.SetValue(TextBlock.FontFamilyProperty, Faces.Icons);
        icon.SetValue(TextBlock.FontSizeProperty, 14.0);
        icon.SetValue(TextBlock.ForegroundProperty, tn.Accent);
        icon.SetValue(FrameworkElement.MarginProperty, new Thickness(0, 0, 8, 0));
        icon.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
        var name = new FrameworkElementFactory(typeof(TextBlock));
        name.SetBinding(TextBlock.TextProperty, new Binding(nameof(BrowseRow.Name)));
        name.SetValue(TextBlock.TextTrimmingProperty, TextTrimming.CharacterEllipsis);
        name.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
        panel.AppendChild(icon);
        panel.AppendChild(name);
        return new DataTemplate { VisualTree = panel };
    }

    static DataTemplate TextCell(string property, System.Windows.Media.Brush color)
    {
        var text = new FrameworkElementFactory(typeof(TextBlock));
        text.SetBinding(TextBlock.TextProperty, new Binding(property));
        text.SetValue(TextBlock.ForegroundProperty, color);
        text.SetValue(TextBlock.TextTrimmingProperty, TextTrimming.CharacterEllipsis);
        return new DataTemplate { VisualTree = text };
    }

    // A double click or Enter opens a folder or downloads a file. With more
    // rows selected, the files download. The context menu has Open and
    // Download.
    void Setup(ListView view)
    {
        AutomationProperties.SetName(view, view == list ? "Files" : "Search results");
        view.MouseDoubleClick += (_, e) =>
        {
            if (ItemsControl.ContainerFromElement(view, e.OriginalSource as DependencyObject) is ListViewItem)
            {
                Activate(view);
                e.Handled = true;
            }
        };
        view.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter)
            {
                Activate(view);
                e.Handled = true;
            }
        };
        view.ContextMenu = new ContextMenu();
        view.ContextMenuOpening += (_, e) =>
        {
            var menu = view.ContextMenu;
            menu.Items.Clear();
            var chosen = Selected(view);
            if (chosen is [{ Dir: true } folder])
            {
                menu.Items.Add(Item("Open", () => browser.Open(folder.Path)));
            }
            var files = chosen.Where(c => !c.Dir).ToArray();
            if (files.Length > 0)
            {
                menu.Items.Add(Item(files.Length == 1 ? "Download" : $"Download {files.Length} files", () =>
                {
                    foreach (var f in files)
                    {
                        browser.Download(f);
                    }
                }));
            }
            if (menu.Items.Count == 0)
            {
                e.Handled = true;
            }
        };
    }

    static BrowseEntry[] Selected(ListView view) => view.SelectedItems.OfType<BrowseRow>().Select(r => r.Entry).ToArray();

    void Activate(ListView view)
    {
        var chosen = Selected(view);
        if (chosen.Length == 1)
        {
            browser.Activate(chosen[0]);
            return;
        }
        foreach (var f in chosen.Where(c => !c.Dir))
        {
            browser.Download(f);
        }
    }

    static MenuItem Item(string header, Action run)
    {
        var item = new MenuItem { Header = header };
        item.Click += (_, _) => run();
        return item;
    }

    // The downloads, the newest first. A row stays while its download
    // stays, so that its keys keep the focus while the bytes come in.
    void DrawDownloads()
    {
        var tn = Tn.Current;
        var all = browser.Downloads;
        downloadsHost.Visibility = all.IsEmpty ? Visibility.Collapsed : Visibility.Visible;
        downloadsHost.Background = tn.Tile;
        downloadsHost.BorderBrush = tn.Line;
        clearDownloads.IsEnabled = all.Count != browser.ActiveDownloads;
        foreach (var gone in downloadRows.Keys.Where(id => all.All(d => d.Id != id)).ToArray())
        {
            downloadRows.Remove(gone);
        }
        var order = all.Reverse().Select(d =>
        {
            if (!downloadRows.TryGetValue(d.Id, out var row))
            {
                row = new DownloadRow(browser);
                downloadRows[d.Id] = row;
            }
            row.Update(d, DownloadsName());
            return row;
        }).ToArray();
        if (!downloadList.Children.Cast<UIElement>().SequenceEqual(order))
        {
            downloadList.Children.Clear();
            foreach (var row in order)
            {
                Ui.Detach(row);
                downloadList.Children.Add(row);
            }
        }
    }

    static string DownloadsName() => Path.GetFileName(ThisComputer.Downloads().TrimEnd('\\', '/')) is { Length: > 0 } n ? n : "Downloads";

    // 1 download: the icon, the name, the progress or the result, and its
    // keys: Stop while it runs, Open and Show in folder when it is done.
    sealed class DownloadRow : Border
    {
        readonly BrowseModel browser;
        readonly TextBlock icon = Ui.Icon(Icons.Document, 20, width: 26);
        readonly TextBlock name = Ui.Text("", 13);
        readonly Border status = new();
        readonly Border keys = new();
        string shownKind = "";

        public DownloadRow(BrowseModel browser)
        {
            this.browser = browser;
            Child = Ui.H(10, icon, Ui.V(3, name, status).Fill(), keys);
            Margin = new Thickness(0, 0, 0, 6);
        }

        public void Update(BrowseDownload item, string folder)
        {
            var tn = Tn.Current;
            icon.Foreground = tn.Accent;
            name.Text = item.Name;
            name.Foreground = tn.Text;
            AutomationProperties.SetName(this, item.Name);
            switch (item.State)
            {
                case BrowseDownloadState.Running:
                    var bar = Parts.ProgressLine(item.Fraction, slide: item.Fraction is null);
                    bar.Height = 3;
                    status.Child = Ui.V(3, bar, Ui.Text($"{Texts.Bytes(item.Received)} of {Texts.Bytes(item.Size)}", 11, color: tn.Sub, mono: true));
                    break;
                case BrowseDownloadState.Done:
                    status.Child = Ui.Text($"{Texts.Bytes(item.Size)} · Saved in {folder}", 11, color: tn.Sub);
                    break;
                case BrowseDownloadState.Failed failed:
                    status.Child = Ui.Text(failed.Reason, 11, color: tn.Red, wrap: true, maxLines: 2);
                    break;
            }
            var kind = item.State.GetType().Name;
            if (kind == shownKind)
            {
                return;
            }
            shownKind = kind;
            keys.Child = item.State switch
            {
                BrowseDownloadState.Running => Key(Icons.Close, "Stop the download", () => browser.Cancel(item.Id)),
                BrowseDownloadState.Done done => Ui.H(2,
                    Key(Icons.Open, "Open", () => Files.Open(done.Path)),
                    Key(Icons.Folder, "Show in File Explorer", () => Files.Reveal(done.Path))),
                _ => null,
            };
        }

        static UIElement Key(string glyph, string help, Action run) =>
            new PlainButton(Ui.Icon(glyph, 13, Tn.Current.Sub).Margin(8), run).Named(help).Help(help);
    }
}
