using System.Collections.Immutable;
using System.Reflection;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using Flux;
using FluxKit;
using static Harness;

// The keys of the text fields: the mic key, the clear key, and the expand
// key of the field of the chat of a computer, the agent reply, the type field of the touchpad
// and the remote desktop, and the search of All shortcuts. The checks put
// sample text in the fields, use the editors, and give sample words to the
// path of a dictation. No check starts the speech recognizer.
public static class FieldChecks
{
    public static void Run(Harness h)
    {
        h.ApplyDevices();
        Pump();
        Chat(h);
        Reply(h);
        Touchpad(h);
        Desktop(h);
        Shortcuts(h);
        Rules(h);
    }

    // The field of the chat of a computer: the mic key, the clear key, the
    // editor with Send, the insert rule, and the listening panel.
    static void Chat(Harness h)
    {
        var model = h.Model;
        model.OpenChat(new ChatKey.Computer(h.Paired.Id));
        Pump();
        if (h.Window.CurrentPage is not ChatsPage { Computer: { } chat })
        {
            h.Check(false, "the chat of the computer shows");
            return;
        }
        var dock = chat.Composer;
        var field = dock.Field;
        field.Text = "";
        Pump();
        h.Check(dock.Voice.Mic.IsVisible, "the field of Chat has the mic key");
        h.Check(Named(dock.Voice.Mic) == "Dictate", "the mic key of Chat reads Dictate");
        h.Check(Key(dock.Root, "Clear") is { IsVisible: false }, "the clear key of Chat hides while the field is empty");
        h.Check(Key(dock.Root, FieldKeys.ExpandHelp) is { IsVisible: true }, "the field of Chat has the expand key");
        h.Check(Shows(dock.Root, "Message omarchy-xps"), "the field of Chat names the computer in its hint");

        field.Text = "a note";
        Pump();
        h.Check(Key(dock.Root, "Clear") is { IsVisible: true }, "the clear key of Chat shows while the field has text");
        Click(dock.Root, "Clear");
        h.Check(field.Text.Length == 0, "the clear key empties the field of Chat");
        h.Check(Key(dock.Root, "Clear") is { IsVisible: false }, "the clear key of Chat hides again");

        // The editor changes the field at once, and its Send takes the way of Send in the dock.
        var sent = new List<string>();
        var sendText = ChatDock.SendText;
        ChatDock.SendText = (_, _, text) =>
        {
            sent.Add(text);
            return true;
        };
        try
        {
            var editor = dock.Editor();
            editor.Show();
            Pump();
            h.Check(editor.Title == "Text or link" && Shows(editor, "Text or link"), "the expand key of Chat opens the editor Text or link");
            h.Check(Key(editor, "Send") is { IsEnabled: false }, "Send of the editor waits for text");
            editor.Box.Text = "https://omarchy.org";
            Pump();
            h.Check(field.Text == "https://omarchy.org", "the editor changes the text of the field of Chat at once");
            h.Check(Key(editor, "Send") is { IsEnabled: true }, "Send of the editor takes a click while the text is there");
            Click(editor, "Send");
            h.Check(!editor.IsVisible, "Send closes the editor");
            h.Check(sent.SequenceEqual(["https://omarchy.org"]), "Send of the editor sends the text of the field");
            h.Check(field.Text.Length == 0, "the field of Chat empties after Send");
        }
        finally
        {
            ChatDock.SendText = sendText;
        }

        // A dictation puts its words at the end of a text that the app set.
        Keyboard.ClearFocus();
        field.Text = "Hello";
        dock.Voice.Spoken("world.");
        h.Check(field.Text == "Hello world.", $"the words of a dictation go at the end of the field of Chat, not \"{field.Text}\"");
        dock.Voice.Spoken("send it");
        h.Check(field.Text == "Hello world. Send it", $"the next words follow the last words and start a sentence, not \"{field.Text}\"");
        field.Text = "";
        Pump();

        // The listening panel takes the place of the field while this computer listens.
        var d = dock.Voice.Dictation;
        Set(d, nameof(Dictation.State), Dictation.Phase.Listening);
        Set(d, nameof(Dictation.Partial), "open the pull request");
        Pump();
        h.Check(Shows(dock.Root, "listening") && Shows(dock.Root, "open the pull request"), "the listening panel shows the state and the words");
        h.Check(!field.IsVisible && dock.Voice.Mic.IsVisible, "the panel hides the field and keeps the mic key");
        h.Check(Named(dock.Voice.Mic) == "Stop the dictation", "the mic key stops the dictation while this computer listens");
        h.Check(Key(dock.Root, "Cancel dictation") is not null && Key(dock.Root, "Dictation language") is not null,
            "the panel has the cancel key and the language");
        d.Cancel();
        Pump();
        h.Check(field.IsVisible && Named(dock.Voice.Mic) == "Dictate", "a cancel shows the field again");
        Set(d, nameof(Dictation.Error), Dictation.SpeechDenied);
        Pump();
        h.Check(Shows(dock.Root, Dictation.SpeechDenied) && Key(dock.Root, "Open Privacy Settings") is not null,
            "a dictation that Windows denies shows the privacy setting");
        Set(d, nameof(Dictation.Error), null);
        Pump();
    }

    // The reply field of the agents window: the mic key, the clear key, and
    // the editor Write to.
    static void Reply(Harness h)
    {
        var herdr = h.Core.Plugin<HerdrPlugin>()!;
        var paired = h.Paired;
        var done = new HerdrAgent("w3:p1", "claude", AgentStatus.Done, "Fix the flaky test", "omarchy", "omarchy");
        herdr.Model.States = herdr.Model.States.SetItem(paired.Id, new HerdrState(true, true, [done], control: true));
        Pump();
        AgentsWindows.Show(h.Model, paired.Id, done.Pane);
        Pump();
        var agents = AgentsWindows.Open.GetValueOrDefault(paired.Id);
        var controls = agents?.View.Detail?.Controls;
        h.Check(controls is not null, "the agents window shows the reply field");
        if (agents is not null && controls is not null)
        {
            var field = controls.Field;
            field.Text = "";
            Pump();
            h.Check(controls.Voice.Mic.IsVisible, "the agent reply has the mic key");
            h.Check(Key(controls, "Clear") is { IsVisible: false }, "the clear key of the reply hides while the field is empty");
            h.Check(Key(controls, FieldKeys.ExpandHelp) is { IsVisible: true }, "the agent reply has the expand key");
            field.Text = "fix the test";
            Pump();
            h.Check(Key(controls, "Clear") is { IsVisible: true }, "the clear key of the reply shows while the field has text");
            Click(controls, "Clear");
            h.Check(field.Text.Length == 0, "the clear key empties the reply");

            var editor = controls.Editor();
            editor.Show();
            Pump();
            h.Check(editor.Title == "Write to claude", "the editor of the reply names the agent");
            editor.Box.Text = "Run the tests";
            Pump();
            h.Check(field.Text == "Run the tests", "the editor changes the reply at once");
            h.Check(Key(editor, "Send") is { IsEnabled: true }, "the editor of the reply has Send");
            // Send of a reply asks for Windows Hello, so the check closes the editor.
            editor.Close();

            Keyboard.ClearFocus();
            field.Text = "Fix the bug";
            controls.Voice.Spoken("then run the tests.");
            h.Check(field.Text == "Fix the bug then run the tests.", $"the words of a dictation go at the end of the reply, not \"{field.Text}\"");
            field.Text = "";
            agents.Close();
            Pump();
        }
        herdr.Model.States = ImmutableDictionary<string, HerdrState>.Empty;
        herdr.Model.Outputs = ImmutableDictionary<string, HerdrOutput>.Empty;
        Pump();
    }

    // The type field of the touchpad: the mic key, the clear key, and the
    // draft editor with Type.
    static void Touchpad(Harness h)
    {
        var input = h.Core.Plugin<RemoteInputPlugin>()!;
        var paired = h.Paired;
        var controller = new TouchpadController(h.Core, input, paired);
        Computer(controller, paired);
        input.Model.Set(paired.Id, true, true, true);
        var w = new TouchpadWindow(controller, h.Core);
        w.Show();
        Pump();
        var keys = w.View.Keys;
        h.Check(keys.Voice.Mic.IsVisible, "the touchpad has the mic key");
        h.Check(Key(keys, "Clear") is { IsVisible: false }, "the clear key of the touchpad hides while the field is empty");
        h.Check(Key(keys, "Write a longer text") is { IsVisible: true }, "the type field of the touchpad has the expand key");
        keys.Field.Text = "wor";
        Pump();
        h.Check(Key(keys, "Clear") is { IsVisible: true }, "the clear key of the touchpad shows while the field has text");
        Click(keys, "Clear");
        h.Check(keys.Field.Text.Length == 0 && controller.FieldText.Length == 0, "the clear key empties the type field and sends no keys");
        // The computer types the words of a dictation, so the field stays empty.
        keys.Voice.Spoken("hello there");
        h.Check(keys.Field.Text.Length == 0, "the words of a dictation go to the computer, not to the type field");
        Draft(h, keys, controller, "the touchpad");
        w.Close();
        Pump();
    }

    // The keys of the remote desktop: the mic button in the bar, and the
    // type field with the mic key, the clear key, and the draft editor.
    static void Desktop(Harness h)
    {
        var input = h.Core.Plugin<RemoteInputPlugin>()!;
        var desktop = h.Core.Plugin<DesktopPlugin>()!;
        var paired = h.Paired;
        var controller = new DesktopController(h.Core, desktop, input, paired);
        Computer(controller, paired);
        // A minimized window does not start the stream, so the check needs no network.
        controller.Minimized = true;
        input.Model.Set(paired.Id, true, true, true);
        controller.Panel = DesktopPanel.Keys;
        var w = new RemoteDesktopWindow(h.Model, controller);
        w.Show();
        Pump();
        var keys = w.View.Keys;
        h.Check(Key(w, "Dictate on omarchy-xps") is not null, "the bar of the remote desktop has the mic button");
        h.Check(keys.IsVisible && keys.Voice.Mic.IsVisible, "the keys of the remote desktop have the mic key");
        h.Check(Key(keys, "Write a longer text") is { IsVisible: true }, "the type field of the remote desktop has the expand key");
        keys.Field.Text = "wor";
        Pump();
        h.Check(Key(keys, "Clear") is { IsVisible: true }, "the clear key of the remote desktop shows while the field has text");
        Click(keys, "Clear");
        h.Check(keys.Field.Text.Length == 0, "the clear key empties the type field of the remote desktop");
        Draft(h, keys, controller, "the remote desktop");
        w.Close();
        Pump();
        desktop.Model.Status = new DesktopStatus();
    }

    // The draft editor of a type field: the text goes to the draft at once,
    // the draft stops at the line limit, and Type types it and empties it.
    static void Draft(Harness h, RemoteKeysPanel keys, RemoteKeyTarget target, string where)
    {
        var editor = keys.TypeField.Editor();
        editor.Show();
        Pump();
        h.Check(editor.Title == "Type on omarchy-xps", $"the draft editor of {where} names the computer");
        h.Check(Shows(editor, "Each line break goes as Shift+Enter"), $"the draft editor of {where} tells how lines go");
        editor.Box.Text = string.Join("\n", Enumerable.Range(1, RemoteInput.MaxDraftLines + 5).Select(i => $"line {i}"));
        Pump();
        h.Check(target.Draft.Split('\n').Length == RemoteInput.MaxDraftLines, $"the draft of {where} stops at {RemoteInput.MaxDraftLines} lines");
        editor.Box.Text = "first line\nsecond line";
        Pump();
        h.Check(target.Draft == "first line\nsecond line", $"the draft editor of {where} changes the draft at once");
        h.Check(Key(editor, "Type") is { IsEnabled: true }, $"the draft editor of {where} has Type");
        Click(editor, "Type");
        h.Check(!editor.IsVisible && target.Draft.Length == 0, $"Type of {where} closes the editor and types the draft");
    }

    // The search of All shortcuts: the mic key, the clear key, no expand
    // key, and the search rule.
    static void Shortcuts(Harness h)
    {
        var input = h.Core.Plugin<RemoteInputPlugin>()!;
        var desktop = h.Core.Plugin<DesktopPlugin>()!;
        var paired = h.Paired;
        var controller = new DesktopController(h.Core, desktop, input, paired);
        Computer(controller, paired);
        desktop.Model.Shortcuts = desktop.Model.Shortcuts.SetItem(paired.Id, new DesktopShortcutsState
        {
            Loaded = true,
            Shortcuts = ValueList.From(new[]
            {
                new DesktopShortcut("t", "SUPER RETURN", "Terminal"),
                new DesktopShortcut("b", "SUPER SHIFT B", "Browser"),
            }),
        });
        Pump();
        var w = new AllShortcuts(h.Window, h.Core, controller);
        w.Show();
        Pump();
        h.Check(w.Voice.Mic.IsVisible, "the search of All shortcuts has the mic key");
        h.Check(Key(w, "Clear") is { IsVisible: false }, "the clear key of the search hides while the search is empty");
        h.Check(Key(w, FieldKeys.ExpandHelp) is null, "the search has no expand key");
        w.Search.Text = "browser";
        Pump();
        h.Check(Key(w, "Browser") is not null && Key(w, "Terminal") is null, "the search filters the shortcuts");
        h.Check(Key(w, "Clear") is { IsVisible: true }, "the clear key of the search shows while the search has text");
        // A dictation replaces the search and drops the period of the sentence.
        w.Voice.Spoken("Terminal.");
        Pump();
        h.Check(w.Search.Text == "Terminal", $"the words of a dictation replace the search, not \"{w.Search.Text}\"");
        h.Check(Key(w, "Terminal") is not null && Key(w, "Browser") is null, "the list follows the spoken search");
        Click(w, "Clear");
        h.Check(w.Search.Text.Length == 0 && Key(w, "Browser") is not null, "the clear key empties the search");
        w.Close();
        Pump();
        controller.Close();
        desktop.Model.Shortcuts = ImmutableDictionary<string, DesktopShortcutsState>.Empty;
    }

    // The insert rule without a view: the words go at the cursor, in place
    // of the selection, or at the end of the text.
    static void Rules(Harness h)
    {
        var field = new TextBox { Text = "there" };
        field.Select(0, 0);
        SpokenCursor.Place(field, "hello", true);
        h.Check(field.Text == "Hello there" && field.CaretIndex == 6, $"the words go at the cursor with a capital, not \"{field.Text}\"");
        SpokenCursor.Place(field, "my friend", false);
        h.Check(field.Text == "Hello there my friend", $"the words go at the end of the text, not \"{field.Text}\"");
        field.Select(6, 5);
        SpokenCursor.Place(field, "again", true);
        h.Check(field.Text == "Hello again my friend", $"the words take the place of the selection, not \"{field.Text}\"");
    }

    // The first button with the name that a screen reader reads, or null.
    static Button? Key(DependencyObject root, string name) =>
        Buttons(root).FirstOrDefault(b => AutomationProperties.GetName(b) == name);

    static string Named(DependencyObject e) => AutomationProperties.GetName(e);

    // A controller reads the computer from the core, which has no computers
    // in the checks, so the check gives it the sample computer.
    static void Computer(object controller, DeviceSnapshot device) =>
        controller.GetType().GetField("device", BindingFlags.NonPublic | BindingFlags.Instance)!.SetValue(controller, device);

    // Sets a property of a model that has a private setter.
    static void Set(object target, string property, object? value) => target.GetType().GetProperty(property)!.SetValue(target, value);
}
