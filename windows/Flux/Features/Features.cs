using System.Windows;
using FluxKit;

namespace Flux;

// The features of the app. Each feature adds 1 line to each list that it
// uses. Keep 1 entry per line, so that features merge without conflicts.
// Features.swift of the Mac app has the same job.
public static class Features
{
    // The clipboard of Windows, for the clipboard sync and the dock of the chat.
    public static readonly WindowsClipboard Clipboard = new();

    // The sound output of the remote desktop.
    static readonly DesktopSound Sound = new();

    static Features()
    {
        ControlTools.ModelMakers.Add(m => m.Core.Plugin<MprisPlugin>()?.Model);
        ControlTools.ModelMakers.Add(m => m.Core.Plugin<RunCommandPlugin>()?.Model);
        ControlTools.ModelMakers.Add(m => m.Core.Plugin<HerdrPlugin>()?.Model);
        ControlTools.Sections.Add(AgentsFeature.ControlSection);
        ControlTools.ModelMakers.Add(m => m.Core.Plugin<RemoteInputPlugin>()?.Model);
        ControlTools.ModelMakers.Add(m => m.Core.Plugin<DesktopPlugin>()?.Model);
        ControlTools.Tools.Add(ControlViews.OmarchyTool);
        ControlTools.Tools.Add(ControlViews.DesktopTool);
        ControlTools.Tools.Add(ControlViews.TouchpadTool);
        ControlTools.Tools.Add(m => m.Core.Plugin<RunCommandPlugin>() is null || !ControlTools.HasFeature(m, PacketType.RunCommandRequest) ? null
            : ControlTools.Tool(m, Icons.Commands, "Commands", "Run a command", PacketType.RunCommandRequest,
                d => m.Push(new Route.Feature(Card.Commands, d.Id))));
        // The dock opens the media, so the tool shows only while no player shows there.
        ControlTools.Tools.Add(m => m.Core.Plugin<MprisPlugin>() is null || !ControlTools.HasFeature(m, PacketType.MprisRequest) || MediaDock.Shows(m) ? null
            : ControlTools.Tool(m, Icons.Audio, "Media", "Play, pause, and volume", PacketType.MprisRequest,
                d => m.Push(new Route.Feature(Card.Media, d.Id))));
        ControlTools.Streams.Add(StreamFeature.MicTool);
        ControlTools.Streams.Add(StreamFeature.WebcamTool);
        ControlTools.Streams.Add(StreamFeature.MirrorTool);

        FeatureSettings.ModelMakers.Add(m => m.Core.Plugin<ClipboardPlugin>()?.Model);
        FeatureSettings.ModelMakers.Add(m => m.Core.Plugin<SharePlugin>()?.Model);
        FeatureSettings.Makers.Add(ShareViews.Settings);
        FeatureSettings.Makers.Add(ClipboardSettings);
        FeatureSettings.ModelMakers.Add(m => m.Core.Plugin<HerdrPlugin>()?.Model);
        FeatureSettings.Makers.Add(AgentsFeature.Settings);
        FeatureSettings.Makers.Add(ControlViews.Settings);
        FeatureSettings.ModelMakers.Add(m => m.Core.Plugin<CaptureWatchPlugin>()?.Model);
        FeatureSettings.Makers.Add(CameraFeature.CaptureSettings);

        ChatDock.SendText = (m, id, text) => m.Core.Plugin<SharePlugin>()?.SendText(text, id) == true;
        ChatDock.Tools.Add(CameraFeature.DockTool(CameraMode.Photo, "Camera"));
        ChatDock.Tools.Add((m, d) => m.Core.Plugin<SharePlugin>() is null || !d.Accepts(PacketType.Share) ? null
            : ("File", Icons.Upload, () => ShareViews.PickAndSend(m, d.Id)));
        ChatDock.Tools.Add(CameraFeature.DockTool(CameraMode.Document, "Scan"));
        ChatDock.Tools.Add(CameraFeature.DockTool(CameraMode.Text, "Text"));
        ChatDock.Tools.Add(CameraFeature.DockTool(CameraMode.Qr, "QR"));
        ChatDock.Tools.Add(CameraFeature.DockTool(CameraMode.Signature, "Signature"));
        ChatDock.Tools.Add(ControlViews.GetFilesTool);
        ChatDock.Tools.Add(AgentsFeature.DockTool);

        TrayActions.Makers.Add((m, d) => m.Core.Plugin<SharePlugin>() is { } s && d.Accepts(PacketType.Share)
            ? ("Send file…", () =>
            {
                var dialog = new Microsoft.Win32.OpenFileDialog { Multiselect = true, Title = $"Send to {d.Name}" };
                if (dialog.ShowDialog() == true)
                {
                    s.SendFiles(dialog.FileNames, d.Id);
                }
            })
            : null);
        TrayActions.Makers.Add((m, d) => m.Core.Plugin<ClipboardPlugin>() is { } c && d.Accepts(PacketType.Clipboard)
            ? ("Send clipboard", () => _ = c.SendClipboardAsync(d.Id))
            : null);
        TrayActions.Makers.Add((m, d) => m.Core.Plugin<MprisPlugin>() is { } p && p.Model.Media(d.Id).Player is { } player
            ? (player.Playing ? "Pause" : "Play", () => p.Action(d.Id, "PlayPause"))
            : null);
        TrayActions.Makers.Add(AgentsFeature.TrayAction);
        TrayActions.Makers.Add((m, d) => m.Core.Plugin<RunCommandPlugin>() is not null && d.Accepts(PacketType.RunCommandRequest)
            ? ("Commands…", () =>
            {
                m.Go(Destination.Control);
                m.Push(new Route.Feature(Card.Commands, d.Id));
                m.ShowMain?.Invoke();
            })
            : null);
        TrayActions.Makers.Add(ControlViews.TouchpadAction);
        TrayActions.Makers.Add(ControlViews.DesktopAction);
        TrayActions.Makers.Add(ControlViews.BrowseAction);
        TrayActions.Makers.Add(ApproveFeature.TrayAction);

        ComputerSections.Makers.Add(ApproveFeature.Section);
        TrayActions.Makers.Add(StreamFeature.StopWebcamAction);
        TrayActions.Makers.Add(StreamFeature.StopMirrorAction);
        TrayActions.Makers.Add(StreamFeature.MicAction);
        TrayActions.Makers.Add(CameraFeature.TrayAction);
    }

    public static IReadOnlyList<IFluxPlugin> Plugins(Notifier notifier)
    {
        var clipboard = new ClipboardPlugin(Clipboard);
        return
        [
            new PingPlugin(),
            new SharePlugin(new WindowsShare(clipboard), new SharedNotificationLimit(notifier)),
            clipboard,
            new CaptureWatchPlugin(new WindowsScreenshots()),
            new RunCommandPlugin(),
            new MprisPlugin(),
            new RemoteInputPlugin(),
            new DesktopPlugin(Sound),
            new BrowsePlugin(new WindowsBrowseFiles()),
            new NotificationsPlugin(new ToastHistory()),
            new BatteryPlugin(new BatterySource()),
            new ThemePlugin(),
            new HerdrPlugin(),
            new ApprovePlugin(new WindowsHelloSigner(ApprovePrompts.Owner)),
            new MicPlugin(StreamFeature.Microphone),
            new WebcamPlugin(StreamFeature.Cameras, StreamFeature.Renderer, StreamFeature.Encoders),
            new ScreenPlugin(StreamFeature.Screens, StreamFeature.Encoders),
            new StreamRequestPlugin(StreamFeature.Starter),
        ];
    }

    // The page of a destination root.
    public static Page Root(AppModel model, Destination d) => d switch
    {
        Destination.Chat => new ChatsPage(model),
        Destination.Control => new ControlPage(model),
        _ => new ComputersPage(model),
    };

    // The page of a route.
    public static Page Route(AppModel model, Route route) => route switch
    {
        Flux.Route.Pairing p => new PairingPage(model, p.DeviceId),
        Flux.Route.Computer c => new ComputerPage(model, c.DeviceId),
        Flux.Route.Feature { Card: Card.Commands } f => new CommandsPage(model, f.DeviceId),
        Flux.Route.Feature { Card: Card.Media } f => new MediaPage(model, f.DeviceId),
        Flux.Route.Feature { Card: Card.Mic } f => new MicPage(model, f.DeviceId),
        Flux.Route.Feature { Card: Card.Stream } f => new StreamPage(model, f.DeviceId),
        _ => new ComputersPage(model),
    };

    // Runs once after the start, before the network starts.
    public static void DidLaunch(AppModel model)
    {
        AgentsFeature.DidLaunch(model);
        ApproveFeature.DidLaunch(model);
        ReplyLock.Watch();
        StreamFeature.DidLaunch(model);
        if (model.Core.Plugin<ClipboardPlugin>() is { } clipboard && model.Core.Plugin<SharePlugin>() is { } share)
        {
            // A clip that Send clipboard sent shows in the chat.
            clipboard.ClipSent += clip => share.RecordClip(clip.DeviceIds, clip.Text, clip.Stamp);
        }
        if (model.Core.Plugin<NotificationsPlugin>() is { } notifications)
        {
            // A click on a notification of a computer opens its chat.
            notifications.Opened += id =>
            {
                if (model.PairedDevice(id) is not null)
                {
                    model.OpenChat(new ChatKey.Computer(id));
                }
                else
                {
                    model.Go(Destination.Chat);
                }
                model.ShowMain?.Invoke();
            };
        }
    }

    // Files that the user gave to Flux, from Send to or Open with.
    public static void Open(AppModel model, IReadOnlyList<string> files)
    {
        var folders = files.Where(Directory.Exists).ToArray();
        if (folders.Length > 0)
        {
            model.Show(folders.Length == 1 ? "Flux sends no folders. Send the files in it." : "Flux sends no folders. Send the files in them.");
        }
        ShareViews.SendFiles(model, files.Where(File.Exists).ToArray());
    }

    // Runs when the app quits.
    public static void WillQuit(AppModel model)
    {
        ControlViews.CloseWindows();
        model.Core.Plugin<ClipboardPlugin>()?.Dispose();
        AgentsWindows.CloseAll();
        ApprovePrompts.Close();
        StreamFeature.WillQuit(model);
        CameraFeature.WillQuit(model);
    }

    static (string Label, UIElement Content)? ClipboardSettings(AppModel model)
    {
        if (model.Core.Plugin<ClipboardPlugin>() is not { } clipboard)
        {
            return null;
        }
        return ("Clipboard", SettingsView.Group(
            SettingsView.Toggle("Sync clipboard", clipboard.Model.Sync, clipboard.SetSync),
            SettingsView.Note("Text that you copy goes to the connected computers, and text that they copy comes here. Copies that a password manager marks as private stay on this computer.")));
    }
}
