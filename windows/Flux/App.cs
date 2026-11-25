using System.Reflection;
using System.Windows;
using System.Windows.Threading;
using FluxKit;

namespace Flux;

// The app: it starts the core, the main window, the tray, and the toasts.
// Flux keeps running in the tray after the window closes. FluxMacApp.swift of
// the Mac app has the same job.
public sealed class App : Application
{
    static App? current;
    AppModel? model;
    MainWindow? main;
    SettingsWindow? settings;
    Tray? tray;
    FluxCore? core;

    // The version of the app, from the build.
    public static string Version =>
        Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "";

    public App()
    {
        current = this;
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        DispatcherUnhandledException += (_, e) =>
        {
            FluxLog.Error("app", $"unhandled: {e.Exception}");
            e.Handled = true;
        };
    }

    // Starts Flux. With background, only the tray shows, as after a login.
    public void Start(bool background)
    {
        var paths = FluxPaths.Standard();
        Directory.CreateDirectory(paths.Data);
        var log = new FileLog(paths.File("flux.log"));
        FluxLog.Sink = log.Write;
        var notifier = new Notifier();
        var host = new FluxHost
        {
            DeviceName = () => Environment.MachineName,
            DeviceType = ThisComputer.DeviceType,
            AppName = "windows",
            AppVersion = Version,
            KeyProtector = new DpapiKeyProtector(),
            Post = action => Dispatcher.BeginInvoke(action),
            Notifier = notifier,
            Downloads = ThisComputer.Downloads,
        };
        try
        {
            core = new FluxCore(paths, host, LanConfig.FromEnvironment(), Features.Plugins(notifier));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.Cryptography.CryptographicException or InvalidDataException)
        {
            FluxLog.Error("app", $"the core did not start: {e}");
            Dialogs.LaunchError(e.Message);
            Shutdown(1);
            return;
        }
        notifier.Backend = new ToastBackend(notifier);
        model = new AppModel(core);
        ApplyTheme();
        model.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(AppModel.Theme) or nameof(AppModel.Scope))
            {
                ApplyTheme();
            }
        };
        if (core.Plugin<ThemePlugin>() is { } theme)
        {
            theme.Model.PropertyChanged += (_, _) => ApplyTheme();
        }
        Microsoft.Win32.SystemEvents.UserPreferenceChanged += (_, _) => Dispatcher.BeginInvoke(ApplyTheme);
        main = new MainWindow(model, Features.Root, Features.Route) { OpenSettings = OpenSettings };
        MainWindow = main;
        model.ShowMain = ShowMain;
        tray = new Tray(model, ShowMain, OpenSettings, Quit);
        Features.DidLaunch(model);
        model.StartConnectGrace();
        core.Start();
        if (!background)
        {
            main.ShowFront();
        }
    }

    // Puts the palette of the theme setting into effect, with the light or
    // dark mode of the standard controls.
    void ApplyTheme()
    {
        if (model is null)
        {
            return;
        }
        var palette = model.Palette(ThisComputer.SystemDark);
        Tn.Apply(palette);
        Resources["Flux.Accent"] = Tn.Current.Accent;
#pragma warning disable WPF0001
        ThemeMode = palette.Dark ? System.Windows.ThemeMode.Dark : System.Windows.ThemeMode.Light;
#pragma warning restore WPF0001
    }

    public void ShowMain() => main?.ShowFront();

    public static void OpenSettings()
    {
        if (current?.model is not { } model)
        {
            return;
        }
        if (current.settings is not { IsLoaded: true })
        {
            current.settings = new SettingsWindow(model) { Owner = current.main?.IsVisible == true ? current.main : null };
        }
        current.settings.Show();
        current.settings.Activate();
    }

    public static void OpenUrl(string url) => ThisComputer.Open(url);

    // Brings the window of the running Flux to the front, for a second start.
    public static void Activate() => current?.Dispatcher.BeginInvoke(() => current.ShowMain());

    // Sends files that the user gave to Flux, from Send to or Open with, to
    // the computer. It runs on the UI thread after the start.
    public static void OpenFiles(IReadOnlyList<string> files) => current?.Dispatcher.BeginInvoke(() =>
    {
        if (current.model is not { } model)
        {
            return;
        }
        current.ShowMain();
        Features.Open(model, files);
    });

    public void Quit()
    {
        if (main is not null)
        {
            main.Quitting = true;
        }
        tray?.Dispose();
        if (model is not null)
        {
            Features.WillQuit(model);
        }
        core?.Dispose();
        Shutdown();
    }
}
