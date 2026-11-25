using System.Buffers.Binary;

namespace FluxKit;

// The type of 1 audio sample in a capture buffer. All types are little-endian.
public enum AudioSampleType
{
    // Signed 16-bit integers.
    Int16,

    // Signed 24-bit integers in 3 bytes.
    Int24,

    // Signed 32-bit integers. A 24-bit sample in a 32-bit container, with
    // the bits at the top, reads the same.
    Int32,

    // 32-bit floats from -1 to 1, the mix format of WASAPI.
    Float32,

    // 64-bit floats from -1 to 1.
    Float64,
}

// The format of interleaved audio from a capture.
public readonly record struct AudioFormat(int SampleRate, int Channels, AudioSampleType Sample)
{
    // The format of the stream: 48 kHz mono s16le.
    public static readonly AudioFormat Stream = new(MicPackets.Rate, MicPackets.Channels, AudioSampleType.Int16);

    public int BytesPerSample => Sample switch
    {
        AudioSampleType.Int16 => 2,
        AudioSampleType.Int24 => 3,
        AudioSampleType.Int32 or AudioSampleType.Float32 => 4,
        AudioSampleType.Float64 => 8,
        _ => 0,
    };

    public int BytesPerFrame => BytesPerSample * Channels;
}

// Converts the audio of 1 capture format to the stream format: 48 kHz mono
// s16le. It mixes all channels into 1, instead of taking the first channel,
// and converts the rate with a cubic interpolation. It keeps the state of the
// interpolation from buffer to buffer, so that the joins make no clicks. A
// new format needs a new converter, see MicConvert.
public sealed class MicConverter
{
    // The highest rate that the converter takes.
    const int MaxRate = 384_000;

    // Input samples per output sample.
    readonly double step;

    // The mono samples that the next output samples need. While the rate
    // changes, it starts 1 sample before the place of the next output
    // sample.
    float[] pending = new float[1024];
    int count;

    // The place of the next output sample in pending, in input samples.
    double position;

    // It throws StreamException for a format that it cannot convert.
    public MicConverter(AudioFormat input)
    {
        if (input.SampleRate is <= 0 or > MaxRate || input.Channels is < 1 or > 32 || input.BytesPerSample == 0)
        {
            throw new StreamException($"Flux cannot convert {input.SampleRate} Hz audio with {input.Channels} channels");
        }
        Input = input;
        step = (double)input.SampleRate / MicPackets.Rate;
        // The first output sample needs 1 sample before it. Silence fills it.
        count = 1;
        position = 1;
    }

    public AudioFormat Input { get; }

    // Converts 1 buffer of interleaved frames. A part of a frame at the end
    // is ignored. While the rate changes, the converter keeps 2 samples for
    // the next buffer, so the output is up to 2 samples shorter than the
    // input time.
    public short[] Convert(ReadOnlySpan<byte> data)
    {
        var frames = data.Length / Input.BytesPerFrame;
        if (Input.SampleRate == MicPackets.Rate)
        {
            var direct = new short[frames];
            for (var i = 0; i < frames; i++)
            {
                direct[i] = Quantize(Mix(data, i));
            }
            return direct;
        }
        if (pending.Length < count + frames)
        {
            Array.Resize(ref pending, Math.Max(pending.Length * 2, count + frames));
        }
        for (var i = 0; i < frames; i++)
        {
            pending[count + i] = Mix(data, i);
        }
        count += frames;
        var output = new List<short>((int)(frames / step) + 2);
        while ((int)position + 2 < count)
        {
            var i = (int)position;
            var t = (float)(position - i);
            output.Add(Quantize(Cubic(pending[i - 1], pending[i], pending[i + 1], pending[i + 2], t)));
            position += step;
        }
        // Keep the sample before the next output sample and all after it.
        var keep = Math.Min((int)position - 1, count);
        Array.Copy(pending, keep, pending, 0, count - keep);
        count -= keep;
        position -= keep;
        return output.ToArray();
    }

    // The mean of the channels of frame i, from -1 to 1.
    float Mix(ReadOnlySpan<byte> data, int frame)
    {
        var size = Input.BytesPerSample;
        var offset = frame * Input.BytesPerFrame;
        var sum = 0.0;
        for (var c = 0; c < Input.Channels; c++)
        {
            sum += Read(data.Slice(offset + c * size, size));
        }
        return (float)(sum / Input.Channels);
    }

    double Read(ReadOnlySpan<byte> s) => Input.Sample switch
    {
        AudioSampleType.Int16 => BinaryPrimitives.ReadInt16LittleEndian(s) / 32768.0,
        AudioSampleType.Int24 => ((s[0] | s[1] << 8 | s[2] << 16) << 8 >> 8) / 8388608.0,
        AudioSampleType.Int32 => BinaryPrimitives.ReadInt32LittleEndian(s) / 2147483648.0,
        AudioSampleType.Float32 => BinaryPrimitives.ReadSingleLittleEndian(s),
        AudioSampleType.Float64 => BinaryPrimitives.ReadDoubleLittleEndian(s),
        _ => 0,
    };

    // The Catmull-Rom curve through x1 and x2 at t from 0 to 1.
    static float Cubic(float x0, float x1, float x2, float x3, float t)
    {
        var c1 = 0.5f * (x2 - x0);
        var c2 = x0 - 2.5f * x1 + 2f * x2 - 0.5f * x3;
        var c3 = 0.5f * (x3 - x0) + 1.5f * (x1 - x2);
        return ((c3 * t + c2) * t + c1) * t + x1;
    }

    // A sample from -1 to 1 as a 16-bit integer. A value that is not a
    // number is silence.
    static short Quantize(double v)
    {
        if (!double.IsFinite(v))
        {
            return 0;
        }
        return (short)Math.Round(Math.Clamp(v, -1, 1) * short.MaxValue);
    }
}

// Converts microphone audio to the stream format: 48 kHz mono s16le. The
// capture of the app gives buffers in the format of the device, such as the
// float mix format of WASAPI. MicConvert.swift of the Mac app has the same
// task.
public static class MicConvert
{
    // Converts 1 buffer. The converter carries the state from buffer to
    // buffer, and a buffer in a new format builds a new one. It throws
    // StreamException for a format that Flux cannot convert.
    public static short[] S16Mono48k(ReadOnlySpan<byte> data, AudioFormat format, ref MicConverter? converter)
    {
        if (converter is null || converter.Input != format)
        {
            converter = new MicConverter(format);
        }
        return converter.Convert(data);
    }
}
