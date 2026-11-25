using System.ComponentModel;
using FluxKit;

namespace Flux;

// The battery of a computer.
public readonly record struct BatteryLevel(int Charge, bool Charging);

// The batteries of the computers, from the battery feature.
public static class Batteries
{
    // The model to watch for changes, or null without the feature.
    public static INotifyPropertyChanged? Model(AppModel model) => model.Core.Plugin<BatteryPlugin>()?.Model;

    public static BatteryLevel? Of(AppModel model, string deviceId) =>
        model.Core.Plugin<BatteryPlugin>()?.Model.Of(deviceId) is { } b ? new BatteryLevel(b.Charge, b.Charging) : null;
}

// The Inbox of the app: the items of all computers from FluxKit.Inbox, with
// the computers of the app model. Inbox.swift of the Mac app has the rules.
public static class Inbox
{
    // The number of items that need the user, on all computers.
    public static int NeedsYou(AppModel model) => FluxKit.Inbox.NeedsYou(model.InboxItems());
}
