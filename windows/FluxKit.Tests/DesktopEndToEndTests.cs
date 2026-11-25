using FluxKit;

namespace FluxKit.Tests;

// The remote desktop and the Omarchy panel against a headless fluxd. A
// headless fluxd shows no screen and runs no Hyprland action, so it answers
// each request with an error.
public class DesktopEndToEndTests
{
    [FluxdFact]
    public async Task HeadlessFluxdRefusesTheDesktop()
    {
        await using var fluxd = await Fluxd.StartAsync(34216, 34220);
        var desktop = new DesktopPlugin();
        var input = new RemoteInputPlugin();
        using var h = new ControlHarness(ControlHarness.Lan(fluxd, 34231, 34240), [desktop, input]);
        var computer = await h.PairAsync(fluxd);
        Assert.True(DesktopPlugin.Supported(computer));
        await Wait.UntilAsync(() => input.Model.Enabled(computer.Id) is not null, "flux.input from fluxd", fluxd);
        Assert.False(input.Model.IsDesktopOn(computer.Id));

        // The window does not start a stream while the computer shows no screen.
        var controller = await h.OnUi(() => new DesktopController(h.Core, desktop, input, computer));
        Assert.False(await h.OnUi(() => controller.Ready));
        await h.OnUi(controller.Start);
        Assert.Equal(DesktopPhase.Idle, (await h.OnUi(() => desktop.Model.Status)).Phase);

        // A start of the plugin goes out, and fluxd answers with its error.
        await fluxd.CliAsync("desktop", "on");
        desktop.Start(computer.Id, maxSize: 2560);
        await Wait.UntilAsync(() => desktop.Model.Status.Phase == DesktopPhase.Error, "the error of fluxd", fluxd);
        var status = desktop.Model.Status;
        Assert.Equal("the remote desktop is off in headless mode", status.Message);
        Assert.Equal(computer.Id, status.DeviceId);
        Assert.Contains("remote desktop: the remote desktop is off in headless mode", fluxd.Log);
        Assert.Equal(DesktopPhase.Error, (await h.OnUi(() => controller.Status))!.Phase);

        await h.OnUi(controller.Close);
    }

    [FluxdFact]
    public async Task HeadlessFluxdAnswersThePanelWithAnError()
    {
        await using var fluxd = await Fluxd.StartAsync(34116, 34120);
        var desktop = new DesktopPlugin();
        var answers = new PacketRecorder(PacketType.Shortcuts);
        using var h = new ControlHarness(ControlHarness.Lan(fluxd, 34131, 34140), [desktop, new RemoteInputPlugin(), answers]);
        var computer = await h.PairAsync(fluxd);
        Assert.True(DesktopPlugin.ShortcutsSupported(computer));

        Assert.True(desktop.Send(DesktopShortcuts.Request(), computer.Id));
        await Wait.UntilAsync(() => desktop.Model.ShortcutsOf(computer.Id) is { Loaded: true }, "the answer of fluxd", fluxd);
        var state = desktop.Model.ShortcutsOf(computer.Id)!;
        Assert.Equal("Remote input is off. Turn it on in the Flux window, or run: flux-cli input on", state.Error);
        Assert.Empty(state.Shortcuts);

        // With remote input on, the headless fluxd still has no input
        // backend, so an action gets the same error.
        await fluxd.CliAsync("input", "on");
        var before = answers.Packets.Count;
        Assert.True(desktop.Send(DesktopShortcuts.Workspace(3), computer.Id));
        await Wait.UntilAsync(() => answers.Packets.Count > before, "the answer to the action", fluxd);
        Assert.Equal(state.Error, answers.Packets.Last().String("error"));
    }
}
