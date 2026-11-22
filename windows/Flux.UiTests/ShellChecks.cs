using System.Windows;
using System.Windows.Automation;
using Flux;
using FluxKit;
using static Harness;

// The shell: the pairing guide, the list of chats in the sidebar, the chat
// of a computer, Computers, the pairing pages, Control, the scope, the
// theme, the settings, and the tray panel.
public static class ShellChecks
{
    public static void Run(Harness h)
    {
        var window = h.Window;
        var model = h.Model;
        window.Show();
        Pump();
        h.Check(Shows(window, "Pair your Omarchy computer"), "Chats shows the pairing guide before the first pairing");
        h.Check(Shows(window, "flux-cli setup"), "the guide shows the setup command");
        h.Check(Shows(window.Chats, "Your chats show here after the first pairing."), "the list of chats waits for the first pairing");

        h.ApplyDevices();
        Pump();
        var chats = window.Chats;
        h.Check(Shows(chats, "omarchy-new asks to pair") && Shows(chats, "Compare the key"), "the list shows the pair request as a card");
        h.Check(Shows(chats, "1 need you · 1 of 2 online"), "the context line counts the request and the online computers");
        h.Check(Shows(chats, "Needs you") && Shows(chats, "Computers"), "the list shows its groups");
        h.Check(Shows(chats, "omarchy-xps") && Shows(chats, "omarchy-desk") && Shows(chats, "Not reachable"), "the list shows the paired computers");
        h.Check(Buttons(window).Any(b => AutomationProperties.GetName(b) == "Control") && Buttons(window).Any(b => AutomationProperties.GetName(b) == "Computers"),
            "the sidebar keeps Control and Computers");
        h.Check(window.CurrentPage is ChatsPage { Computer.DeviceId: var shown } && shown == h.Paired.Id, "Chats shows the chat of the online computer first");
        h.Check(Shows(window, "connected") && Shows(window, "Message omarchy-xps"), "the chat of the computer shows its link and the field");

        // The search keeps the chats that hold its text.
        chats.Search.Text = "desk";
        Pump();
        h.Check(Shows(chats, "omarchy-desk") && !Shows(chats, "omarchy-xps"), "the search keeps the computer whose name holds it");
        chats.Search.Text = "nothing like it";
        Pump();
        h.Check(Shows(chats, "No chat holds \"nothing like it\"."), "the search tells when no chat holds it");
        chats.Search.Text = "";
        Pump();

        // A click on a computer opens its chat.
        ClickStarting(chats, "omarchy-desk");
        h.Check(model.Chat == new ChatKey.Computer(h.Offline.Id), "a click on a computer opens its chat");
        h.Check(Shows(window, "omarchy-desk is not reachable"), "the chat of the offline computer tells that it is not reachable");
        h.Check(model.Scope == h.Offline.Id, "the chat of a computer takes the scope");
        model.OpenChat(new ChatKey.Computer(h.Paired.Id));
        Pump();

        model.Go(Destination.Computers);
        Pump();
        h.Check(Shows(window, "Paired") && Shows(window, "Available"), "Computers shows its groups");
        h.Check(Shows(window, "omarchy-xps") && Shows(window, "omarchy-lab"), "Computers lists the computers");
        h.Check(Shows(window, "1 of 2 online"), "Computers shows the online count");

        model.Push(new Route.Pairing(h.Asking.Id));
        Pump();
        h.Check(Shows(window, "omarchy-new wants to pair"), "the pairing page shows the request");
        h.Check(Shows(window, "5EE6 825F 974E D59A"), "the pairing page shows the key in groups");
        model.Back();
        model.Push(new Route.Computer(h.Paired.Id));
        Pump();
        h.Check(Shows(window, "Unpair omarchy-xps…"), "the computer page shows Unpair");

        model.Go(Destination.Control);
        Pump();
        h.Check(window.CurrentPage is ControlPage, "Control opens");

        model.SetScope(h.Paired.Id);
        Pump();
        h.Check(Buttons(window).Any(b => AutomationProperties.GetName(b) == "Scope: omarchy-xps"), "the scope menu names the computer in scope");
        model.SetScope(null);
        model.Go(Destination.Chat);
        Pump();

        var before = window.Background;
        Tn.Apply(ThemePalette.TokyoNightDay);
        Pump();
        h.Check(window.Background != before, "the window takes the light theme");
        Tn.Apply(ThemePalette.TokyoNight);

        var settings = new SettingsWindow(model);
        settings.Show();
        Pump();
        h.Check(Shows(settings, "Flux is on") && Shows(settings, "Open at login"), "the settings show General");
        h.Check(Shows(settings, "Computer: "), "the settings name the theme of the Computer choice");
        Click(settings, "Features");
        h.Check(Shows(settings, "Received files") && Shows(settings, "Sync clipboard"), "the settings show the features");
        settings.Close();

        var panel = new TrayPanel(model, () => { }, () => { }, () => { });
        panel.Toggle();
        Pump();
        h.Check(Shows(panel, "1 item needs you"), "the tray panel counts the request");
        h.Check(Shows(panel, "omarchy-xps"), "the tray panel lists the online computer");
        panel.Close();
    }
}
