namespace Flux.Windows;
public partial class App : System.Windows.Application
{
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
            var lines = new List<string> { "Flux Windows v16 UI error", DateTimeOffset.UtcNow.ToString("O") };
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
