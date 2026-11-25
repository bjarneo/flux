namespace Flux;

// The 3 destinations of the sidebar, in order. Chats holds the list of chats
// in the sidebar and the open chat in the detail column.
public enum Destination
{
    Chat,
    Control,
    Computers,
}

public static class DestinationInfo
{
    public static string Title(this Destination d) => d switch
    {
        Destination.Chat => "Chats",
        Destination.Control => "Control",
        _ => "Computers",
    };

    public static string Glyph(this Destination d) => d switch
    {
        Destination.Chat => Icons.Chat,
        Destination.Control => Icons.Control,
        _ => Icons.Laptop,
    };
}

// A feature card that opens on a page of its own from Control.
public enum Card
{
    Share,
    Clipboard,
    Media,
    Commands,
    Mic,
    Stream,
}

public static class CardInfo
{
    public static string Title(this Card c) => c switch
    {
        Card.Share => "Text and links",
        Card.Clipboard => "Clipboard",
        Card.Media => "Media",
        Card.Commands => "Commands",
        Card.Mic => "Microphone",
        _ => "Webcam and screen mirror",
    };
}

// A page on top of a destination.
public abstract record Route
{
    // The pairing of a computer that is not paired.
    public sealed record Pairing(string DeviceId) : Route;

    // A feature card for a computer.
    public sealed record Feature(Card Card, string DeviceId) : Route;

    // The page of a paired computer, with its approval.
    public sealed record Computer(string DeviceId) : Route;
}

// A chat in the detail column of Chats: the chat of a paired computer, or
// the chat of a herdr agent on a paired computer.
public abstract record ChatKey(string DeviceId)
{
    public sealed record Computer(string DeviceId) : ChatKey(DeviceId);

    public sealed record Agent(string DeviceId, string Pane) : ChatKey(DeviceId);
}
