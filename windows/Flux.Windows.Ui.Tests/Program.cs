using System.Net;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Threading;
using Flux.Protocol;
using Flux.Windows;

internal static class Program
{
    private static void Check(bool value, string message)
    {
        if (!value) throw new Exception(message);
    }
    private static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T found) yield return found;
            foreach (var item in Descendants<T>(child)) yield return item;
        }
    }
    private static void Pump()
    {
        var frame = new DispatcherFrame();
        Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(() => frame.Continue = false));
        Dispatcher.PushFrame(frame);
    }
    [STAThread]
    private static int Main()
    {
        try {
            // Real WPF templates and data binding, without network or identity state.
            var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            var window = new MainWindow(startCompanion: false);
            Check(((CheckBox)window.FindName("ClipboardSync")).IsChecked != true, "Clipboard sync must default to off.");
            var first = new DiscoveredPeer(new Identity(new string('a',32), "First",8),IPAddress.Loopback,12100);
            var second = new DiscoveredPeer(new Identity(new string('b',32), "Second",8),IPAddress.Loopback,12100);
            var connect = (Button)window.FindName("Connect");
            Check(!connect.IsEnabled, "Connect must start disabled without a target.");
            window.SetDiscoveredPeers(new[] { first, second });
            Check(connect.IsEnabled, "Discovered target must allow Connect.");
            window.SetPeerConnection(new(first.Identity.DeviceId,first.Address,false));
            Check(!connect.IsEnabled, "Connected but unpaired target must disable Connect.");
            var label = (TextBlock)window.FindName("ConnectionLabel");
            var dot = (System.Windows.Shapes.Ellipse)window.FindName("ConnectionDot");
            Check(label.Text == "not paired" && dot.Fill == window.FindResource("SubBrush"), "An unpaired connection must not show trusted green status.");
            window.SetPeerConnection(new(first.Identity.DeviceId,first.Address,true));
            Check(!connect.IsEnabled && connect.Content.ToString() == "Connected", "Paired connection must show disabled Connected.");
            Check(label.Text == "connected" && dot.Fill == window.FindResource("GreenBrush"), "Paired connection must show green dot with connected text.");
            var devices = (ListBox)window.FindName("Devices");
            Check(devices.Items.Count == 2, "Sidebar must have one row per device.");
            devices.SelectedIndex = 1;
            Check(connect.IsEnabled, "Another connected device must not disable a disconnected target.");
            devices.SelectedIndex = 0;
            window.SetPeerConnection(new(first.Identity.DeviceId,first.Address,true,Connected:false));
            Check(connect.IsEnabled, "Disconnected target must allow reconnect.");
            var alternate = first with {Address=IPAddress.Parse("192.168.1.99"),Port=12101};
            window.SetDiscoveredPeers(new[] {first,alternate,second});
            var target = (ComboBox)window.FindName("Target");
            target.SelectedIndex = 1;
            window.SetPeerConnection(new(second.Identity.DeviceId,second.Address,true));
            window.SetPeerView(new PeerView(second.Identity.DeviceId, "second-connection", second,
                "Paired", "Connected", "", false, false));
            Check(((PeerRow)target.SelectedItem).Peer.Address.Equals(alternate.Address) && ((PeerRow)target.SelectedItem).Peer.Port == alternate.Port,
                "Connection refresh switched the selected endpoint.");
            window.SetDiscoveredPeers(new[] {second,first,alternate with {Identity=alternate.Identity with {Name="Renamed"}}});
            Check(((PeerRow)target.SelectedItem).Peer.Address.Equals(alternate.Address) && ((PeerRow)target.SelectedItem).Peer.Port == alternate.Port,
                "Discovery refresh switched the selected endpoint.");
            Check(((PeerRow)devices.SelectedItem).Peer.Identity.DeviceId == ((PeerRow)target.SelectedItem).Peer.Identity.DeviceId,
                "Sidebar device and endpoint selector disagree after refresh.");
            Check(devices.Items.Count == 2, "Alternate addresses must not duplicate sidebar devices.");
            var themePacket = Packet.Create("flux.theme", new { name="sample", colors = new {
                background="#202020", foreground="#f0f0f0", accent="#80c0ff" } });
            Check(OmarchyTheme.TryParse(themePacket.Body, out var sampleTheme) && sampleTheme is not null,
                "UI theme fixture must parse.");
            window.SetDeviceTheme(first.Identity.DeviceId, sampleTheme);
            Check(((SolidColorBrush)window.FindResource("BackgroundBrush")).Color == Color.FromRgb(0x20,0x20,0x20),
                "Selected device theme must update WPF brushes.");
            devices.SelectedIndex = 1;
            Check(((SolidColorBrush)window.FindResource("BackgroundBrush")).Color == Color.FromRgb(0x1a,0x1b,0x26),
                "Another device must use its own theme or Tokyo Night fallback.");
            devices.SelectedIndex = 0;
            Check(((SolidColorBrush)window.FindResource("BackgroundBrush")).Color == Color.FromRgb(0x20,0x20,0x20),
                "Returning to a device must restore its theme.");
            window.SetDeviceTheme(first.Identity.DeviceId, null);
            Check(((SolidColorBrush)window.FindResource("BackgroundBrush")).Color == Color.FromRgb(0x1a,0x1b,0x26),
                "Forgetting a theme must restore Tokyo Night.");
            var history = new[] {
                new FileTransferView("one", first.Identity.DeviceId, "Same name", "one.bin", "Sent", 10, 10, "Sent (peer receipt not confirmed)"),
                new FileTransferView("two", second.Identity.DeviceId, "Same name", "two.bin", "Received", 10, 10, "Saved")
            };
            Check(MainWindow.VisibleTransfers(history, first.Identity.DeviceId, false).Select(t => t.Id).SequenceEqual(new[] { "one" }),
                "This device history must filter by stable DeviceId, not display name.");
            Check(MainWindow.VisibleTransfers(history, first.Identity.DeviceId, true).Length == 2,
                "All devices history must retain transfers from other devices.");
            window.SetDiscoveredPeers(Array.Empty<DiscoveredPeer>());
            window.SetSavedPeers(new[] { new SavedPeer(first.Identity.DeviceId, "Saved computer", "192.168.1.42", 12100) });
            Check(devices.Items.Count == 2, "An authenticated connected device and a saved offline device must both remain visible.");
            window.SetPeerConnection(new(second.Identity.DeviceId, second.Address, true, Connected: false));
            Check(devices.Items.Count == 1 && ((PeerRow)devices.Items[0]).ConnectionLabel == "offline",
                "A saved device must remain visible when discovery and its connection disappear.");
            Check(((PeerRow)devices.Items[0]).Name == "Saved computer", "Offline row must use saved display metadata.");
            Check(((Button)window.FindName("Forget")).IsEnabled, "Saved pairing must expose Forget.");
            window.SetSavedPeers(Array.Empty<SavedPeer>());
            Check(devices.Items.Count == 0 && !((Button)window.FindName("Forget")).IsEnabled,
                "Removing saved trust must remove an offline-only device and disable Forget.");

            ((Button)window.FindName("FilesNav")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            window.Show(); Pump();
            var cardStyle = (Style)window.FindResource("Card");
            var cards = Descendants<Border>(window).Where(b => b.Style == cardStyle).ToArray();
            Check(cards.Length > 0 && cards.All(b => b.CornerRadius == new CornerRadius(0)), "Rendered card surfaces must have square corners.");
            var files = (ListBox)window.FindName("Files");
            foreach (var direction in new[] { "Sent", "Received" }) {
                foreach (var bytes in new long[] { 0, 50, 100 }) {
                    files.ItemsSource = new[] { new FileTransferView("test", first.Identity.DeviceId, "Peer", "fixture.bin", direction, bytes,100,
                        direction == "Sent" ? "Sending" : "Receiving") };
                    window.UpdateLayout(); Pump(); window.UpdateLayout();
                    var progress = Descendants<ProgressBar>(files).Single();
                    var binding = BindingOperations.GetBindingExpression(progress,ProgressBar.ValueProperty)!;
                    Check(binding.ParentBinding.Mode == BindingMode.OneWay && !binding.HasError,
                        "Transfer progress must bind read-only values without a write-back or error.");
                    Check(progress.Value == bytes, "Transfer progress must update for both directions.");
                    Check(Descendants<Button>(files).Single(b => b.Content?.ToString() == "Cancel transfer").Visibility == Visibility.Visible,
                        "An active transfer must show Cancel.");
                }
            }
            files.ItemsSource = new[] { new FileTransferView("done", first.Identity.DeviceId, "Peer", "fixture.bin", "Sent", 100, 100,
                "Sent — receipt not confirmed") };
            window.UpdateLayout(); Pump(); window.UpdateLayout();
            Check(Descendants<Button>(files).Single(b => b.Content?.ToString() == "Cancel transfer").Visibility == Visibility.Collapsed,
                "A completed transfer must hide Cancel.");
            for (var i = 0; i < 75; i++) window.SetTransferView(new FileTransferView(i.ToString(), first.Identity.DeviceId, "Peer", $"file-{i}.bin", "Received", 10,10,"Saved"));
            Check(files.Items.Count == 25 && ((Button)window.FindName("NextHistory")).IsEnabled, "History must paginate rather than discard older transfers.");
            ((Button)window.FindName("NextHistory")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            ((Button)window.FindName("NextHistory")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(((FileTransferView)files.Items[24]).Id == "0" && !((Button)window.FindName("NextHistory")).IsEnabled, "The last history page must expose the oldest retained transfer.");
            ((Button)window.FindName("ClipboardNav")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(((StackPanel)window.FindName("ClipboardPage")).Visibility == Visibility.Visible && files.IsVisible == false,
                "Clipboard navigation must show its own page.");
            window.Close(); app.Shutdown();
            Console.WriteLine("WPF transfer rendering and connection-state checks passed.");
            return 0;
        } catch (Exception ex) {
            Console.Error.WriteLine(ex.GetType().Name + ": " + ex.Message);
            return 1;
        }
    }
}
