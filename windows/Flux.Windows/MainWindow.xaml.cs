using System.Windows;
using System.Diagnostics;
using System.IO;
using Microsoft.Win32;
using System.Windows.Media;
using Flux.Protocol;

namespace Flux.Windows;
public partial class MainWindow : Window
{
    private Companion? companion;
    private string displayedKey = "";
    private string displayedConnectionId = "";
    private bool refreshingRows;
    private DiscoveredPeer? selectedPeer;
    private readonly Dictionary<string, PeerView> views = new();
    private bool connecting;
    private string? connectingId;
    private readonly Dictionary<string, FileTransferView> transfers = new();
    private readonly Queue<string> diagnosticLines = new();
    private IReadOnlyList<DiscoveredPeer> discovered = Array.Empty<DiscoveredPeer>();
    private readonly Dictionary<string, PeerConnection> connections = new();
    private IReadOnlySet<string> saved = new HashSet<string>();
    private IReadOnlyList<SavedPeer> savedPeers = Array.Empty<SavedPeer>();
    private readonly Dictionary<string, OmarchyTheme> deviceThemes = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Color> fallbackColors = new(StringComparer.Ordinal);
    private OmarchyTheme? appliedTheme;
    internal void SetDeviceTheme(string deviceId, OmarchyTheme? theme)
    {
        if (theme is null) deviceThemes.Remove(deviceId); else deviceThemes[deviceId] = theme;
        ApplySelectedTheme();
    }
    private void ApplySelectedTheme()
    {
        if (fallbackColors.Count == 0) return;
        var id = selectedPeer?.Identity.DeviceId;
        var next = id is not null && deviceThemes.TryGetValue(id, out var theme) ? theme : null;
        if (Equals(next, appliedTheme)) return;
        appliedTheme = next;
        var values = next is null ? fallbackColors : new Dictionary<string, Color> {
            ["BackgroundBrush"] = Rgb(next.Background), ["TileBrush"] = Rgb(next.Tile),
            ["TileHiBrush"] = Rgb(next.TileHi), ["LineBrush"] = Rgb(next.Line),
            ["TextBrush"] = Rgb(next.Text), ["SubBrush"] = Rgb(next.Sub),
            ["AccentBrush"] = Rgb(next.Accent), ["GreenBrush"] = Rgb(next.Green),
            ["RedBrush"] = Rgb(next.Red)
        };
        foreach (var (key, color) in values) Resources[key] = new SolidColorBrush(color);
        // The connection dot is assigned in code, rather than through DynamicResource.
        UpdateConnectButton();
    }
    private static Color Rgb(int color) => Color.FromRgb((byte)(color >> 16), (byte)(color >> 8), (byte)color);
    private void RefreshRows()
    {
        var livePeers = discovered.Concat(views.Values.Where(v => connections.ContainsKey(v.DeviceId)).Select(v => v.Peer)).ToArray();
        var visibleIds = livePeers.Select(p => p.Identity.DeviceId).ToHashSet(StringComparer.Ordinal);
        var offlinePeers = saved.Where(id => !visibleIds.Contains(id)).Select(id =>
            savedPeers.FirstOrDefault(p => p.DeviceId == id) ?? new SavedPeer(id, id[..8], "", 1716));
        var peers = livePeers.Concat(offlinePeers.Select(p => p.ToPeer()))
            .GroupBy(p => (p.Identity.DeviceId,p.Address,p.Port)).Select(g => g.Last()).ToArray();
        var rows = peers.Select(p => PeerRow.Create(p, connections.GetValueOrDefault(p.Identity.DeviceId) ?? new(null,null,false), saved)).ToArray();
        var selected = PeerRow.RestoreSelection(rows, selectedPeer);
        selectedPeer = selected?.Peer;
        var devices = rows.GroupBy(r => r.Peer.Identity.DeviceId).Select(group =>
            group.FirstOrDefault(r => connections.TryGetValue(r.Peer.Identity.DeviceId, out var connection) && connection.Address?.Equals(r.Peer.Address) == true)
            ?? group.FirstOrDefault(r => selectedPeer?.Identity.DeviceId == r.Peer.Identity.DeviceId &&
                selectedPeer.Address.Equals(r.Peer.Address) && selectedPeer.Port == r.Peer.Port)
            ?? group.First()).ToArray();
        refreshingRows = true;
        try {
            Devices.ItemsSource = devices;
            Devices.SelectedItem = devices.FirstOrDefault(r => r.Peer.Identity.DeviceId == selectedPeer?.Identity.DeviceId);
            Target.ItemsSource = rows.Where(r => r.Peer.Identity.DeviceId == selectedPeer?.Identity.DeviceId && r.HasAddress).ToArray();
            Target.SelectedItem = selected?.HasAddress == true ? selected : null;
            NoDevices.Visibility = rows.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            ConnectionCount.Text = $"{connections.Count} device{(connections.Count == 1 ? "" : "s")} connected";
        } finally { refreshingRows = false; }
        RenderSelection();
    }
    private void RenderSelection()
    {
        var id = selectedPeer?.Identity.DeviceId;
        ApplySelectedTheme();
        displayedKey = ""; displayedConnectionId = "";
        Verification.Text = ""; Pair.IsEnabled = false; Accept.IsEnabled = false; Reject.IsEnabled = false;
        UpdateConnectButton();
        Forget.IsEnabled = id is not null && saved.Contains(id);
        Target.IsEnabled = id is not null && selectedPeer?.Address.Equals(System.Net.IPAddress.None) == false;
        SendFile.IsEnabled = id is not null && connections.TryGetValue(id,out var current) && current.Connected && current.Paired;
        SelectedName.Text = selectedPeer?.Identity.Name ?? "Select a device";
        var selectedAddress = selectedPeer is null ? "" : selectedPeer.Address.Equals(System.Net.IPAddress.None)
            ? "no saved address" : $"{selectedPeer.Address}:{selectedPeer.Port}";
        ActiveAddress.Text = id is not null && connections.TryGetValue(id, out var link) && link.Connected
            ? $"active {link.Address}" + (views.TryGetValue(id, out var activeView) && activeView.Peer.Address.Equals(link.Address) ? $":{activeView.Peer.Port}" : "")
            : selectedPeer is null ? "" : saved.Contains(id!) ? $"offline · last known {selectedAddress}" : $"discovered {selectedAddress}";
        SendHint.Text = SendFile.IsEnabled ? "Send to " + SelectedName.Text : "Select a connected, paired device in the sidebar.";
        if (id is not null && views.TryGetValue(id, out var view)) {
            Status.Text = view.Status; Detail.Text = view.Detail; Verification.Text = view.Key;
            displayedKey = view.Key.Replace(" ", "", StringComparison.Ordinal);
            displayedConnectionId = view.ConnectionId;
            Pair.IsEnabled = view.CanPair; Accept.IsEnabled = view.CanAccept; Reject.IsEnabled = view.Key.Length > 0;
        } else if (selectedPeer is not null) {
            Status.Text = "Selected: " + selectedPeer.Identity.Name;
            Detail.Text = "Connect this device. Existing connections stay open.";
        } else {
            Status.Text = "No device selected";
            Detail.Text = "Keep Flux open on your phone or computer, then scan for devices.";
        }
        PairingPeer.Text = selectedPeer is null ? "" : $"{selectedPeer.Identity.Name} · {selectedAddress}";
        PairingCard.Visibility = Verification.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        var otherRequests = views.Values.Count(v => v.DeviceId != id && v.Key.Length > 0);
        PendingNotice.Text = otherRequests == 1 ? "Another device asks to pair. Select it to compare keys." :
            $"{otherRequests} other devices ask to pair. Select one to compare keys.";
        PendingNotice.Visibility = otherRequests > 0 ? Visibility.Visible : Visibility.Collapsed;
        RefreshTransfers();
    }
    private void UpdateConnectButton()
    {
        var id = selectedPeer?.Identity.DeviceId;
        var connected = id is not null && connections.TryGetValue(id, out var current) && current.Connected;
        Connect.IsEnabled = !connecting && id is not null && !connected && !selectedPeer!.Address.Equals(System.Net.IPAddress.None);
        Connect.Content = connected ? "Connected" : "Connect";
        var paired = connected && connections[id!].Paired;
        ConnectionLabel.Text = paired ? "connected" : connected ? "not paired" : id == connectingId && connecting ? "connecting" : id is null ? "offline" : saved.Contains(id) ? "offline" : "discovered";
        ConnectionDot.Fill = (System.Windows.Media.Brush)FindResource(paired ? "GreenBrush" : "SubBrush");
        ConnectionLabel.Foreground = ConnectionDot.Fill;
    }
    private void MinimizeClick(object sender, RoutedEventArgs e) => SystemCommands.MinimizeWindow(this);
    private void MaximizeClick(object sender, RoutedEventArgs e)
    {
        if (WindowState == WindowState.Maximized) SystemCommands.RestoreWindow(this);
        else SystemCommands.MaximizeWindow(this);
    }
    private void CloseClick(object sender, RoutedEventArgs e) => SystemCommands.CloseWindow(this);
    public MainWindow() : this(true) { }
    internal MainWindow(bool startCompanion)
    {
        InitializeComponent();
        foreach (var key in new[] { "BackgroundBrush", "TileBrush", "TileHiBrush", "LineBrush", "TextBrush",
            "SubBrush", "AccentBrush", "GreenBrush", "RedBrush" })
            fallbackColors[key] = ((SolidColorBrush)FindResource(key)).Color;
        StateChanged += (_, _) => Maximize.Content = WindowState == WindowState.Maximized ? "\uE923" : "\uE922";
        Loaded += async (_, _) => {
            if (!startCompanion) return;
            try {
                companion = new Companion();
                companion.Diagnostic += line => Dispatcher.InvokeAsync(() => {
                    diagnosticLines.Enqueue(line.Length > 1000 ? line[..1000] : line);
                    while (diagnosticLines.Count > 16) diagnosticLines.Dequeue();
                    Diagnostics.Text = string.Join(Environment.NewLine, diagnosticLines);
                    Diagnostics.ScrollToEnd();
                });
                companion.TransferChanged += view => Dispatcher.InvokeAsync(() => {
                    transfers[view.Id] = view;
                    while (transfers.Count > 50) transfers.Remove(transfers.Keys.First());
                    RefreshTransfers();
                });
                ReceivePath.Text = "Received files: " + companion.ReceiveDirectory;
                saved = companion.SavedPeerIds.ToHashSet(StringComparer.Ordinal);
                savedPeers = companion.SavedPeers;
                foreach (var (id, theme) in companion.SavedThemes) deviceThemes[id] = theme;
                ApplySelectedTheme();
                companion.ThemeChanged += (id, theme) => Dispatcher.InvokeAsync(() => SetDeviceTheme(id, theme));
                companion.PeersChanged += peers => Dispatcher.InvokeAsync(() => {
                    SetDiscoveredPeers(peers);
                });
                companion.ConnectionChanged += current => Dispatcher.InvokeAsync(() => {
                    SetPeerConnection(current);
                });
                companion.ViewChanged += view => Dispatcher.InvokeAsync(() => SetPeerView(view));
                companion.SavedPairsChanged += ids => Dispatcher.InvokeAsync(() => { saved = ids.ToHashSet(StringComparer.Ordinal); RefreshRows(); });
                companion.SavedPeersChanged += peers => Dispatcher.InvokeAsync(() => { savedPeers = peers; RefreshRows(); });
                companion.Changed += (status, detail, key, canPair, canAccept) => Dispatcher.InvokeAsync(() => {
                    // Global discovery/progress must not replace a selected
                    // device's pending verification key or approval buttons.
                    if (selectedPeer is null || !views.ContainsKey(selectedPeer.Identity.DeviceId)) {
                        Status.Text = status; Detail.Text = detail;
                    }
                });
                await companion.StartAsync();
                Network.Text = companion.NetworkSummary;
            } catch (Exception ex) { companion?.Dispose(); Status.Text = "Cannot start Flux"; Detail.Text = ex.Message; }
        };
        Closed += (_, _) => companion?.Dispose();
    }
    internal void SetDiscoveredPeers(IReadOnlyList<DiscoveredPeer> peers)
    {
        discovered = peers;
        RefreshRows();
    }
    internal void SetPeerConnection(PeerConnection current)
    {
        if (current.DeviceId is not null) {
            if (current.Connected) connections[current.DeviceId] = current;
            else connections.Remove(current.DeviceId);
        }
        RefreshRows();
    }
    internal void SetPeerView(PeerView view)
    {
        views[view.DeviceId] = view;
        RefreshRows();
    }
    internal void SetSavedPeers(IReadOnlyList<SavedPeer> peers)
    {
        savedPeers = peers;
        saved = peers.Select(p => p.DeviceId).ToHashSet(StringComparer.Ordinal);
        foreach (var id in deviceThemes.Keys.Where(id => !saved.Contains(id)).ToArray()) deviceThemes.Remove(id);
        RefreshRows();
    }
    private void ShowPage(string page)
    {
        Heading.Text = page;
        FilesPage.Visibility = page == "Files" ? Visibility.Visible : Visibility.Collapsed;
        OverviewPage.Visibility = page == "Overview" ? Visibility.Visible : Visibility.Collapsed;
        FilesNav.Tag = page == "Files" ? "active" : "";
        OverviewNav.Tag = page == "Overview" ? "active" : "";
    }
    private void OverviewClick(object sender, RoutedEventArgs e) => ShowPage("Overview");
    private void FilesClick(object sender, RoutedEventArgs e) => ShowPage("Files");
    internal static FileTransferView[] VisibleTransfers(IEnumerable<FileTransferView> history, string? deviceId, bool allDevices) =>
        history.Where(t => allDevices || t.DeviceId == deviceId).Reverse().ToArray();
    private void RefreshTransfers()
    {
        if (Files is null || ThisDeviceFilter is null) return;
        var visible = VisibleTransfers(transfers.Values, selectedPeer?.Identity.DeviceId, AllDevicesFilter.IsChecked == true);
        Files.ItemsSource = visible;
        NoFiles.Visibility = visible.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
    }
    private void FilterChanged(object sender, RoutedEventArgs e) => RefreshTransfers();
    private void DeviceSelected(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (refreshingRows) return;
        selectedPeer = (Devices.SelectedItem as PeerRow)?.Peer;
        RefreshRows();
    }
    private void TargetSelected(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (refreshingRows) return;
        selectedPeer = (Target.SelectedItem as PeerRow)?.Peer;
        RefreshRows();
    }
    private async void ConnectClick(object sender, RoutedEventArgs e) {
        if (connecting) return;
        if (companion is null || selectedPeer is null) {
            Status.Text = "Select a device first"; Detail.Text = "Click the Omarchy row in the list, then Connect."; return;
        }
        connecting = true; connectingId = selectedPeer.Identity.DeviceId; Connect.IsEnabled = false;
        var peer = selectedPeer;
        Status.Text = "Connect clicked: " + peer.Identity.Name; Detail.Text = "Preparing the connection…";
        try { await companion.ConnectAsync(peer); }
        catch (Exception ex) { Status.Text = "Connection failed"; Detail.Text = ex.Message; }
        finally { connecting = false; connectingId = null; UpdateConnectButton(); }
    }
    private async void SendFileClick(object sender, RoutedEventArgs e) {
        if (companion is null || selectedPeer is null) return;
        var peer = selectedPeer;
        var chooser = new OpenFileDialog {Title="Send a file to " + peer.Identity.Name,Multiselect=false,CheckFileExists=true};
        if (chooser.ShowDialog(this) != true) return;
        try { await companion.SendFileAsync(peer.Identity.DeviceId,chooser.FileName); }
        catch (Exception ex) { Status.Text="File send failed"; Detail.Text=ex.Message; }
    }
    private void OpenReceivedClick(object sender, RoutedEventArgs e) {
        if (companion is null) return;
        try {
            Directory.CreateDirectory(companion.ReceiveDirectory);
            Process.Start(new ProcessStartInfo(companion.ReceiveDirectory) {UseShellExecute=true});
        } catch (Exception ex) { Status.Text="Cannot open received folder"; Detail.Text=ex.Message; }
    }
    private void CancelTransferClick(object sender, RoutedEventArgs e)
    {
        if (companion is null || (sender as System.Windows.Controls.Button)?.DataContext is not FileTransferView transfer) return;
        try {
            if (!companion.CancelTransfer(transfer.Id)) { Status.Text = "Transfer already finished"; Detail.Text = transfer.Name; }
        } catch (Exception ex) { Status.Text = "Could not cancel transfer"; Detail.Text = ex.Message; }
    }
    private async void ForgetClick(object sender, RoutedEventArgs e)
    {
        if (companion is null || selectedPeer is null) return;
        var peer = selectedPeer;
        if (MessageBox.Show(this, $"Remove the saved pairing for {peer.Identity.Name} ({peer.Identity.DeviceId[..8]})?",
            "Forget device", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        try { await companion.ForgetAsync(peer.Identity.DeviceId); }
        catch (Exception ex) { Status.Text = "Could not forget device"; Detail.Text = ex.Message; }
    }
    private async void FindClick(object sender, RoutedEventArgs e) {
        try { if (companion != null) await companion.FindAsync(); }
        catch (Exception ex) { Status.Text = "Discovery failed"; Detail.Text = ex.Message; }
    }
    private async void PairClick(object sender, RoutedEventArgs e) {
        try { if (companion != null) await companion.RequestPairAsync(selectedPeer?.Identity.DeviceId ?? ""); }
        catch (Exception ex) { Status.Text = "Pairing failed"; Detail.Text = ex.Message; }
    }
    private async void AcceptClick(object sender, RoutedEventArgs e) {
        try { if (companion != null) await companion.AcceptAsync(selectedPeer?.Identity.DeviceId ?? "", displayedConnectionId, displayedKey); }
        catch (Exception ex) { Status.Text = "Pairing failed"; Detail.Text = ex.Message; }
    }
    private async void RejectClick(object sender, RoutedEventArgs e) {
        try { if (companion != null) await companion.RejectAsync(selectedPeer?.Identity.DeviceId ?? "", displayedConnectionId); }
        catch (Exception ex) { Status.Text = "Pairing failed"; Detail.Text = ex.Message; }
    }
}
