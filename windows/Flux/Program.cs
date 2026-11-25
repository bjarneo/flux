using System.IO.Pipes;
using System.Security.Principal;
using System.Text;

namespace Flux;

static class Program
{
    // 1 Flux runs for each Windows user. A second start brings the window of
    // the running Flux to the front and ends. A start with files, from Send
    // to or Open with, gives the files to the running Flux first.
    [STAThread]
    static int Main(string[] args)
    {
        var user = WindowsIdentity.GetCurrent().User?.Value ?? "user";
        var files = args.Where(a => !a.StartsWith("--", StringComparison.Ordinal) && (File.Exists(a) || Directory.Exists(a)))
            .Select(Path.GetFullPath).ToArray();
        using var single = new Mutex(true, @"Local\Flux-" + user, out var first);
        using var wake = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\Flux-show-" + user);
        if (!first)
        {
            if (files.Length > 0)
            {
                Hand(user, files);
            }
            wake.Set();
            return 0;
        }
        var app = new App();
        var watcher = new Thread(() =>
        {
            while (wake.WaitOne())
            {
                App.Activate();
            }
        }) { IsBackground = true, Name = "Flux wake" };
        watcher.Start();
        var opener = new Thread(() => Listen(user)) { IsBackground = true, Name = "Flux open" };
        opener.Start();
        app.Startup += (_, _) =>
        {
            app.Start(args.Contains("--background"));
            if (files.Length > 0)
            {
                App.OpenFiles(files);
            }
        };
        return app.Run();
    }

    static string PipeName(string user) => "Flux-open-" + user;

    // Gives the files to the running Flux, 1 path on each line.
    static void Hand(string user, IReadOnlyList<string> files)
    {
        try
        {
            using var pipe = new NamedPipeClientStream(".", PipeName(user), PipeDirection.Out, PipeOptions.CurrentUserOnly);
            pipe.Connect(3000);
            var data = Encoding.UTF8.GetBytes(string.Join("\n", files));
            pipe.Write(data);
        }
        catch (Exception e) when (e is IOException or TimeoutException or UnauthorizedAccessException)
        {
            // The running Flux does not listen. The window comes to the front.
        }
    }

    // Takes the files of each later start. Only the same Windows user can
    // connect to the pipe.
    static void Listen(string user)
    {
        while (true)
        {
            try
            {
                using var pipe = new NamedPipeServerStream(PipeName(user), PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.CurrentUserOnly);
                pipe.WaitForConnection();
                using var reader = new StreamReader(pipe, Encoding.UTF8);
                var files = reader.ReadToEnd().Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                    .Where(f => Path.IsPathFullyQualified(f) && (File.Exists(f) || Directory.Exists(f))).Take(500).ToArray();
                if (files.Length > 0)
                {
                    App.OpenFiles(files);
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                Thread.Sleep(1000);
            }
        }
    }
}
