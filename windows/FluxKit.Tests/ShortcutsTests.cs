using System.Text.Json.Nodes;
using FluxKit;

namespace FluxKit.Tests;

// ShortcutsTests.swift of the Mac app.
public class ShortcutsTests
{
    static readonly DesktopShortcut Terminal = new("315", "SUPER RETURN", "Terminal");
    static readonly DesktopShortcut Browser = new("317", "SUPER SHIFT RETURN", "Browser");
    static readonly DesktopShortcut CloseWindow = new("68", "SUPER W", "Close window");

    static Packet Answer(string json) => new(PacketType.Shortcuts, JsonNode.Parse(json)!.AsObject());

    [Fact]
    public void Packets()
    {
        Assert.Equal(PacketType.Shortcuts, DesktopShortcuts.Request().Type);
        Assert.True(DesktopShortcuts.Request().Bool("request"));
        Assert.Empty(DesktopShortcuts.Refresh().Body);
        Assert.Equal("315", DesktopShortcuts.Run(Terminal).String("run"));
        Assert.Equal("close", DesktopShortcuts.Action(DesktopAction.Close).String("action"));
        Assert.Equal("nextWindow", DesktopShortcuts.Action(DesktopAction.NextWindow).String("action"));
        Assert.Equal("scratchpad", DesktopShortcuts.Action(DesktopAction.Scratchpad).String("action"));
        Assert.Equal(["close", "fullscreen", "float", "split", "scratchpad", "nextWindow", "nextWorkspace", "previousWorkspace"],
            Enum.GetValues<DesktopAction>().Select(DesktopShortcuts.ActionName));
        var ws = DesktopShortcuts.Workspace(3);
        Assert.Equal("workspace", ws.String("action"));
        Assert.Equal(3, ws.Int("workspace"));
        Assert.Equal("moveToWorkspace", DesktopShortcuts.MoveToWorkspace(10).String("action"));
        Assert.Equal(10, DesktopShortcuts.MoveToWorkspace(10).Int("workspace"));
        var swap = DesktopShortcuts.Swap(DesktopDirection.Left);
        Assert.Equal("swap", swap.String("action"));
        Assert.Equal("l", swap.String("direction"));
        Assert.Equal("u", DesktopShortcuts.Focus(DesktopDirection.Up).String("direction"));
        Assert.Equal("d", DesktopShortcuts.Focus(DesktopDirection.Down).String("direction"));
        Assert.Equal("r", DesktopShortcuts.Focus(DesktopDirection.Right).String("direction"));
        var focus = DesktopShortcuts.FocusWindow("0x5f6b3fd55b00");
        Assert.Equal("focusWindow", focus.String("action"));
        Assert.Equal("0x5f6b3fd55b00", focus.String("address"));
    }

    [Fact]
    public void MergeReadsTheWindowsAndKeepsThemForAnAnswerWithout()
    {
        var first = DesktopShortcuts.Merge(null, Answer("""
            {"workspaces": [{"id": 2, "windows": 2}], "active": 2, "windows": [
              {"address": "0x1", "workspace": 2, "app": "Ghostty", "class": "com.mitchellh.ghostty", "title": "t 0x1", "focused": true},
              {"address": "0x2", "workspace": 2, "class": "chromium", "title": "t 0x2", "focused": false},
              {"address": "0x3", "workspace": 5, "app": "Signal", "class": "signal", "title": "t 0x3"},
              {"address": "", "workspace": 2},
              {"address": "0x4"}]}
            """));
        Assert.Equal([
            new DesktopWindow("0x1", 2, "Ghostty", "com.mitchellh.ghostty", "t 0x1", true),
            new DesktopWindow("0x2", 2, "chromium", "chromium", "t 0x2", false),
        ], first.ActiveWindows);
        Assert.Equal(3, first.Windows?.Count);
        Assert.Equal(2, first.ActiveWindowCount);
        // A computer that is locked sends the workspaces without the windows.
        var locked = DesktopShortcuts.Merge(first, Answer("""{"workspaces": [], "active": 5}"""));
        Assert.Equal(["0x3"], locked.ActiveWindows.Select(w => w.Address));
        // An older computer sends no windows at all.
        var old = DesktopShortcuts.Merge(null, Answer("""{"active": 1, "workspaces": [{"id": 1, "windows": 4}]}"""));
        Assert.Null(old.Windows);
        Assert.Equal(4, old.ActiveWindowCount);
    }

    [Fact]
    public void SuperAndADigitSelectsAWorkspace()
    {
        var super = new RemoteMods(Super: true);
        Assert.Equal(3, DesktopShortcuts.ForDigit("3", super)?.Int("workspace"));
        Assert.Equal("workspace", DesktopShortcuts.ForDigit("3", super)?.String("action"));
        // 0 is workspace 10, as on the keyboard.
        Assert.Equal(10, DesktopShortcuts.ForDigit("0", super)?.Int("workspace"));
        var move = DesktopShortcuts.ForDigit("5", new RemoteMods(Shift: true, Super: true))!;
        Assert.Equal("moveToWorkspace", move.String("action"));
        Assert.Equal(5, move.Int("workspace"));
        Assert.Null(DesktopShortcuts.ForDigit("a", super));
        Assert.Null(DesktopShortcuts.ForDigit("12", super));
        Assert.Null(DesktopShortcuts.ForDigit("٣", super));
        Assert.Null(DesktopShortcuts.ForDigit("3", new RemoteMods(Ctrl: true)));
        Assert.Null(DesktopShortcuts.ForDigit("3", new RemoteMods(Alt: true, Super: true)));
    }

    [Fact]
    public void MergeKeepsTheListForAWorkspaceAnswer()
    {
        var first = DesktopShortcuts.Merge(null, Answer("""
            {"shortcuts": [{"ref": "315", "keys": "SUPER RETURN", "description": "Terminal"}, {"ref": "9"}],
             "workspaces": [{"id": 1, "windows": 2}, {"id": 3, "windows": 0}], "active": 1}
            """));
        Assert.True(first.Loaded);
        Assert.Equal([Terminal], first.Shortcuts);
        Assert.Equal([new DesktopWorkspace(1, 2), new DesktopWorkspace(3, 0)], first.Workspaces);
        Assert.Equal(1, first.Active);

        var next = DesktopShortcuts.Merge(first, Answer("""{"workspaces": [{"id": 4, "windows": 1}], "active": 4}"""));
        Assert.Equal([Terminal], next.Shortcuts);
        Assert.Equal(4, next.Active);

        var failed = DesktopShortcuts.Merge(next, Answer("""{"error": "Remote input is off"}"""));
        Assert.Equal("Remote input is off", failed.Error);
        Assert.Equal([Terminal], failed.Shortcuts);
        Assert.Null(DesktopShortcuts.Merge(failed, Answer("""{"active": 2}""")).Error);
        Assert.True(DesktopShortcuts.Merge(null, Answer("""{"error": "no"}""")).Loaded);
    }

    [Fact]
    public void PinsKeepTheirOrderAndSkipMissingShortcuts()
    {
        DesktopShortcut[] all = [CloseWindow, Terminal, Browser];
        Assert.Equal([Browser, Terminal], DesktopShortcuts.Pinned(all, ["Browser", "Music", "Terminal"]));
    }

    [Fact]
    public void SearchMatchesEachWord()
    {
        DesktopShortcut[] all = [CloseWindow, Terminal, Browser];
        Assert.Equal(all, DesktopShortcuts.Search(all, "  "));
        Assert.Equal([Browser], DesktopShortcuts.Search(all, "brow"));
        Assert.Equal([Browser], DesktopShortcuts.Search(all, "shift return"));
        Assert.Equal([CloseWindow, Browser], DesktopShortcuts.Search(all, "super w"));
        Assert.Equal("super shift return", DesktopShortcuts.KeysLabel("SUPER SHIFT RETURN"));
    }

    [Fact]
    public void PinsToggle()
    {
        var model = new DesktopModel();
        Assert.Equal(DesktopShortcuts.DefaultPins, model.Pins);
        model.TogglePin(Terminal);
        Assert.DoesNotContain("Terminal", model.Pins);
        model.TogglePin(Terminal);
        Assert.Equal("Terminal", model.Pins[^1]);
    }

    [Fact]
    public void PinsStayInTheSettings()
    {
        var dir = CoreTests.TempDir();
        var settings = new FluxSettings(Path.Combine(dir, "settings.json"));
        var model = new DesktopModel();
        model.Load(settings);
        Assert.Equal(DesktopShortcuts.DefaultPins, model.Pins);
        // A load does not save the default pins.
        Assert.Null(settings.Node(DesktopPlugin.PinsKey));
        model.TogglePin(Browser);
        var again = new DesktopModel();
        again.Load(new FluxSettings(Path.Combine(dir, "settings.json")));
        Assert.DoesNotContain("Browser", again.Pins);
        Assert.Equal(DesktopShortcuts.DefaultPins.Count - 1, again.Pins.Count);
        Directory.Delete(dir, true);
    }
}
