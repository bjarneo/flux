using FluxKit;

namespace FluxKit.Tests;

// Remote input against a headless fluxd. A headless fluxd has no input
// backend and shows no screen, so it reports remote input and the remote
// desktop as off and ignores the input.
public class InputEndToEndTests
{
    [FluxdFact]
    public async Task FluxdTellsTheInputStateAndIgnoresInputWhileItIsOff()
    {
        await using var fluxd = await Fluxd.StartAsync(34016, 34020);
        var input = new RemoteInputPlugin();
        var recorder = new PacketRecorder(PacketType.Input);
        using var h = new ControlHarness(ControlHarness.Lan(fluxd, 34031, 34040), [input, recorder]);
        var computer = await h.PairAsync(fluxd);
        Assert.True(RemoteInputPlugin.Supported(computer));

        // After the pairing, fluxd tells the state once.
        await Wait.UntilAsync(() => input.Model.Enabled(computer.Id) is not null, "flux.input from fluxd", fluxd);
        Assert.Equal(new RemoteInputState(false, false, true), input.Model.States[computer.Id]);
        Assert.False(input.Model.IsOn(computer.Id));
        Assert.False(input.Model.IsDesktopOn(computer.Id));
        Assert.True(input.Model.CanRepeat(computer.Id));

        // A change of the setting sends the state again. The headless fluxd
        // still has no input backend.
        var before = recorder.Packets.Count;
        await fluxd.CliAsync("input", "on");
        await Wait.UntilAsync(() => recorder.Packets.Count > before, "flux.input after the setting changed", fluxd);
        Assert.False(recorder.Packets.Last().Bool("enabled"));
        Assert.True(recorder.Packets.Last().Bool("keyRepeat"));

        // The input goes out, and fluxd ignores it.
        Assert.True(input.Send(RemoteInput.Click(RemoteClick.Left), computer.Id));
        Assert.True(input.Send(RemoteInput.Keys(RemoteKey.Backspace, 3, default, repeat: true), computer.Id));
        await Wait.UntilAsync(() => fluxd.Log.Contains("ignored remote input, because remote_input is off"), "the refusal of fluxd", fluxd);
        Assert.False(input.Send(RemoteInput.Click(RemoteClick.Left), "not-a-device"));
    }

    [FluxdFact]
    public async Task TouchpadIsNotReadyWhileInputIsOff()
    {
        await using var fluxd = await Fluxd.StartAsync(34066, 34070);
        var input = new RemoteInputPlugin();
        using var h = new ControlHarness(ControlHarness.Lan(fluxd, 34081, 34090), [input, new DesktopPlugin()]);
        var computer = await h.PairAsync(fluxd);
        await Wait.UntilAsync(() => input.Model.Enabled(computer.Id) is not null, "flux.input from fluxd", fluxd);
        var pad = await h.OnUi(() => new TouchpadController(h.Core, input, computer));
        Assert.Equal(computer.Name, pad.Name);
        Assert.False(await h.OnUi(() => pad.Ready));
        Assert.True(await h.OnUi(() => pad.WorkspaceKeys));
        // The pad does not take the pointer while the computer refuses the input.
        Assert.False(await h.OnUi(pad.Capture));
        Assert.Equal(new RemotePress.Ignore(), await h.OnUi(() => pad.KeyDown(0x0D, default, "\r")));
        await h.OnUi(pad.Close);
    }
}
