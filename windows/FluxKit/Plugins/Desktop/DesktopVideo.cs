namespace FluxKit;

// The H.264 decoder and the view of the remote desktop. The Windows app
// implements it with Media Foundation. DesktopVideo calls it on the thread
// that reads the stream, so each call must return at once.
public interface IDesktopVideoOutput
{
    // Sets the SPS and the PPS of the stream, without start codes. It
    // returns false when the decoder refuses them.
    bool Configure(byte[] sps, byte[] pps);

    // True when the decoder takes more frames now. False while it is behind.
    bool IsReady { get; }

    // True after the decoder failed, for example after this computer slept.
    // A flush starts it again at the next key frame.
    bool NeedsFlush { get; }

    // Decodes 1 frame in Annex-B form with 4-byte start codes and shows it
    // at once, with no clock. key is true for a frame that the decoder can
    // start at. A key frame can carry its own SPS and PPS.
    void Decode(byte[] annexB, bool key);

    // Drops the frames that wait in the decoder. With clear, the view also
    // removes the picture that it shows.
    void Flush(bool clear);
}

// Shows the frames of the remote desktop on a video output. The frames
// arrive on a network thread, and the output can change on the UI thread,
// so a lock guards the state. When the decoder falls behind, the frames
// wait in no queue: the picture skips to the next key frame.
// DesktopVideo.swift of the Mac app has the same rules.
public sealed class DesktopVideo
{
    readonly Lock gate = new();
    IDesktopVideoOutput? output;
    // The SPS and the PPS that the stream uses now, or null before the
    // first config frame.
    (byte[] Sps, byte[] Pps)? sets;
    // True until a key frame starts the picture on the output.
    bool needKey = true;
    // The frames that the output had no room for since the last key frame.
    int dropped;

    // Shows the video on the output, or on no output. The next key frame
    // starts the picture.
    public void Attach(IDesktopVideoOutput? next)
    {
        lock (gate)
        {
            output = next;
            output?.Flush(false);
            if (output is not null && sets is { } s)
            {
                output.Configure(s.Sps, s.Pps);
            }
            needKey = true;
        }
    }

    // Takes the video from the output, when the video still shows on it. A
    // view that goes away calls it, so that the output of a new view that
    // took the video keeps it.
    public void Detach(IDesktopVideoOutput old)
    {
        lock (gate)
        {
            if (output != old)
            {
                return;
            }
            output = null;
            needKey = true;
        }
    }

    // True when the video shows on the output.
    internal bool Shows(IDesktopVideoOutput o)
    {
        lock (gate)
        {
            return output is not null && output == o;
        }
    }

    // The SPS and the PPS that the stream uses now.
    internal IReadOnlyList<byte[]> ParameterSets
    {
        get
        {
            lock (gate)
            {
                return sets is { } s ? [s.Sps, s.Pps] : [];
            }
        }
    }

    // Forgets the stream, so that the next stream starts clean.
    internal void Reset()
    {
        lock (gate)
        {
            sets = null;
            needKey = true;
            dropped = 0;
            output?.Flush(true);
        }
    }

    // Sets the SPS and the PPS of the stream. It returns false when they
    // are not valid or the decoder refuses them.
    internal bool Configure(byte[] sps, byte[] pps)
    {
        lock (gate)
        {
            if (sets is { } s && s.Sps.AsSpan().SequenceEqual(sps) && s.Pps.AsSpan().SequenceEqual(pps))
            {
                return true;
            }
            if (!Valid(sps, pps) || (output is not null && !output.Configure(sps, pps)))
            {
                return false;
            }
            sets = (sps, pps);
            needKey = true;
            return true;
        }
    }

    // Shows 1 frame in Annex-B form. The frames before the first key frame
    // do not show, because a decoder cannot start with them. A key frame
    // with its own SPS and PPS sets the format first, because VAAPI puts
    // other sets in its key frames than in the config frame.
    internal void Show(byte[] annexB, bool key)
    {
        if (key && DesktopH264.ParameterSets(annexB) is { } found)
        {
            Configure(found.Sps, found.Pps);
        }
        lock (gate)
        {
            if (output is null || sets is null)
            {
                return;
            }
            // An output that failed starts again at a key frame.
            if (output.NeedsFlush)
            {
                output.Flush(false);
                needKey = true;
            }
            if (!output.IsReady)
            {
                // The decoder is behind. A frame that is not a key frame
                // waits for none: the picture starts again at the next key
                // frame. A key frame replaces the frames in the queue.
                if (!key)
                {
                    dropped++;
                    needKey = true;
                    return;
                }
                output.Flush(false);
            }
            if (needKey && !key)
            {
                return;
            }
            output.Decode(annexB, key);
            if (key)
            {
                needKey = false;
                if (dropped > 0)
                {
                    FluxLog.Info("desktop", $"remote desktop: dropped {dropped} frames while the decoder was behind");
                    dropped = 0;
                }
            }
        }
    }

    // Checks the form of the parameter sets: an SPS with its NAL header, the
    // profile, the constraint flags, and the level, and a PPS with its NAL
    // header and data.
    internal static bool Valid(byte[] sps, byte[] pps) =>
        sps.Length >= 4 && pps.Length >= 2 && (sps[0] & 0x1F) == DesktopH264.NalSps && (pps[0] & 0x1F) == DesktopH264.NalPps;
}
