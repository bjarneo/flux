namespace Flux.Windows;
public partial class App : System.Windows.Application
{
    internal static bool StartInBackground { get; private set; }
    private Mutex? instance;
    private EventWaitHandle? activation;
    private RegisteredWaitHandle? activationWait;
    private bool ownsInstance;
    protected override void OnStartup(System.Windows.StartupEventArgs e)
    {
        StartInBackground = e.Args.Contains("--background", StringComparer.Ordinal);
        var name = "Local\\Flux.Windows." + Environment.UserName;
        instance = new Mutex(true, name + ".Instance", out ownsInstance);
        activation = new EventWaitHandle(false, EventResetMode.AutoReset, name + ".Show");
        if (!ownsInstance) { activation.Set(); Shutdown(); return; }
        activationWait = ThreadPool.RegisterWaitForSingleObject(activation, (_, _) => Dispatcher.BeginInvoke(new Action(() => {
            if (MainWindow is not MainWindow window) return;
            window.Show();
            if (window.WindowState == System.Windows.WindowState.Minimized) window.WindowState = System.Windows.WindowState.Normal;
            window.Activate();
        })), null, Timeout.Infinite, false);
        base.OnStartup(e);
    }
    protected override void OnExit(System.Windows.ExitEventArgs e)
    {
        activationWait?.Unregister(null);
        activation?.Dispose();
        if (ownsInstance) instance?.ReleaseMutex();
        instance?.Dispose();
        base.OnExit(e);
    }
    public App()
    {
        DispatcherUnhandledException += (_, e) => {
            var report = SaveCrashReport(e.Exception);
            System.Windows.MessageBox.Show("Flux encountered an unexpected interface error and must close." +
                (report is null ? "" : "\n\nDiagnostic report: " + report), "Flux", System.Windows.MessageBoxButton.OK,
                System.Windows.MessageBoxImage.Error);
            // Do not continue running an interface in an unknown state.
            e.Handled = true;
            Shutdown(1);
        };
    }
    private static string? SaveCrashReport(Exception exception)
    {
        try {
            var directory = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Flux.Windows");
            System.IO.Directory.CreateDirectory(directory);
            var path = System.IO.Path.Combine(directory,"last-crash.txt");
            var lines = new List<string> { "Flux Windows UI error", DateTimeOffset.UtcNow.ToString("O") };
            // Store exception types and method names only. Exception messages,
            // filenames, packet contents and local variables may be private.
            for (var inner = 0; inner < 4; inner++) {
                lines.Add(exception.GetType().FullName ?? "Exception");
                foreach (var frame in new System.Diagnostics.StackTrace(exception,false).GetFrames().Take(24)) {
                    var method = frame.GetMethod();
                    lines.Add($"  {method?.DeclaringType?.FullName}.{method?.Name}");
                }
                if (exception.InnerException is null) break;
                exception = exception.InnerException;
            }
            System.IO.File.WriteAllLines(path,lines);
            return path;
        } catch { return null; }
    }
}
