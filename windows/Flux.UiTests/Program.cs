using System.Reflection;
using System.Windows;

// Builds the window of Flux with sample computers, and opens each page, the
// settings, and the tray panel. A view that throws, or a text that does not
// show, fails the run. It runs only on Windows, in the Windows workflow.
static class Program
{
    [STAThread]
    static int Main()
    {
        new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        using var h = new Harness();
        var checks = typeof(Program).Assembly.GetTypes()
            .Where(t => t.Name.EndsWith("Checks", StringComparison.Ordinal) && t.GetMethod("Run", BindingFlags.Public | BindingFlags.Static) is not null)
            .OrderBy(t => t == typeof(ShellChecks) ? 0 : 1).ThenBy(t => t.Name, StringComparer.Ordinal);
        foreach (var type in checks)
        {
            try
            {
                type.GetMethod("Run")!.Invoke(null, [h]);
            }
            catch (TargetInvocationException e)
            {
                h.Fail(type.Name, e.InnerException ?? e);
            }
            h.Model.SetScope(null);
            h.Model.Go(Flux.Destination.Chat);
            Harness.Pump();
        }
        Console.WriteLine(h.Failures == 0 ? "PASS: the views of Flux" : $"{h.Failures} checks failed");
        return h.Failures == 0 ? 0 : 1;
    }
}
