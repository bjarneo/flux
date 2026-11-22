namespace FluxKit;

// One button of a notification. A text input action passes the typed text to
// the handler.
public sealed record NotificationAction(string Id, string Title, bool TextInput = false);

// A system notification. A later post with the same ID replaces it.
public sealed record SystemNotification(string Id, string Category, string Title, string Body)
{
    // Values that come back to the handler of the category.
    public IReadOnlyDictionary<string, string> UserInfo { get; init; } = new Dictionary<string, string>();

    // False for a notification without a sound, for example the rest of a burst.
    public bool Sound { get; init; } = true;

    // A short line under the title, for example the app and the computer
    // that sent the notification, or null.
    public string? Subtitle { get; init; }

    // An image file that the notification shows, or null.
    public string? Image { get; init; }

    // The buttons of this notification, or null to use the buttons of its
    // category. A notification with its own buttons needs no category for
    // each set of labels.
    public IReadOnlyList<NotificationAction>? Actions { get; init; }
}

// Shows system notifications. The Windows app shows toasts. Tests record them.
public interface INotificationBackend
{
    void Show(SystemNotification notification, IReadOnlyList<NotificationAction> actions);
    void Remove(string id);
}

// The notifications of Flux. Features register a category with its actions
// and a handler, then post notifications in that category. Without a backend,
// each post does nothing. Notifier.swift of the Mac app has the same rules.
public sealed class Notifier
{
    // The action ID of a click on the notification itself.
    public const string DefaultAction = "default";

    public delegate void Handler(string actionId, IReadOnlyDictionary<string, string> userInfo, string? replyText);

    readonly Lock gate = new();
    readonly Dictionary<string, (IReadOnlyList<NotificationAction> Actions, Handler Handler)> categories = [];
    INotificationBackend? backend;

    public INotificationBackend? Backend
    {
        get
        {
            lock (gate)
            {
                return backend;
            }
        }
        set
        {
            lock (gate)
            {
                backend = value;
            }
        }
    }

    public void Register(string category, IReadOnlyList<NotificationAction> actions, Handler handler)
    {
        lock (gate)
        {
            categories[category] = (actions, handler);
        }
    }

    public void Post(SystemNotification notification)
    {
        IReadOnlyList<NotificationAction> actions;
        INotificationBackend? b;
        lock (gate)
        {
            actions = notification.Actions ?? (categories.TryGetValue(notification.Category, out var c) ? c.Actions : []);
            b = backend;
        }
        b?.Show(notification, actions);
    }

    public void Remove(string id) => Backend?.Remove(id);

    // The backend calls it after a click on the notification or one of its
    // buttons, with DefaultAction for the notification itself.
    public void Activate(string category, string actionId, IReadOnlyDictionary<string, string> userInfo, string? replyText = null)
    {
        Handler? handler;
        lock (gate)
        {
            handler = categories.TryGetValue(category, out var c) ? c.Handler : null;
        }
        handler?.Invoke(actionId, userInfo, replyText);
    }
}
