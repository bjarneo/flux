namespace FluxKit;

// The UI state of the microphone stream. MicModel.swift of the Mac app has
// the same fields.
public sealed class MicModel : Model
{
    StreamStatus status = StreamStatus.None;
    float level;
    ValueList<MicInput> inputs = ValueList<MicInput>.Empty;
    string input = "";
    MicPermission permission = MicPermission.Undetermined;

    // The phase of the stream, its computer, and its message or error.
    public StreamStatus Status
    {
        get => status;
        internal set => Set(ref status, value);
    }

    // The peak input level, from 0 to 1, about 15 times per second while
    // the stream is live.
    public float Level
    {
        get => level;
        internal set => Set(ref level, value);
    }

    // The audio inputs of this computer.
    public ValueList<MicInput> Inputs
    {
        get => inputs;
        internal set => Set(ref inputs, value);
    }

    // The chosen input ID. Empty means the default input of Windows.
    // MicPlugin.SelectInput changes it.
    public string Input
    {
        get => input;
        internal set => Set(ref input, value);
    }

    public MicPermission Permission
    {
        get => permission;
        internal set => Set(ref permission, value);
    }
}
