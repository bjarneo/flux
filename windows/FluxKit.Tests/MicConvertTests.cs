using FluxKit;

namespace FluxKit.Tests;

// MicConvertTests.swift of the Mac app: the conversion of capture audio to
// 48 kHz mono s16le. WASAPI gives float audio in the format of the device.
public class MicConvertTests
{
    // Interleaved float audio with a 440 Hz sine of amplitude 0.5 on each
    // channel.
    static byte[] Sine(int frames, int rate = 44_100, int channels = 2, int start = 0, AudioSampleType type = AudioSampleType.Float32)
    {
        var format = new AudioFormat(rate, channels, type);
        var data = new byte[frames * format.BytesPerFrame];
        for (var i = 0; i < frames; i++)
        {
            var v = 0.5 * Math.Sin(2 * Math.PI * 440 * (start + i) / rate);
            for (var c = 0; c < channels; c++)
            {
                var at = data.AsSpan(i * format.BytesPerFrame + c * format.BytesPerSample);
                switch (type)
                {
                    case AudioSampleType.Float32:
                        BitConverter.TryWriteBytes(at, (float)v);
                        break;
                    case AudioSampleType.Float64:
                        BitConverter.TryWriteBytes(at, v);
                        break;
                    case AudioSampleType.Int16:
                        BitConverter.TryWriteBytes(at, (short)Math.Round(v * 32767));
                        break;
                    case AudioSampleType.Int32:
                        BitConverter.TryWriteBytes(at, (int)Math.Round(v * int.MaxValue));
                        break;
                    case AudioSampleType.Int24:
                        var s = (int)Math.Round(v * 8388607);
                        at[0] = (byte)s;
                        at[1] = (byte)(s >> 8);
                        at[2] = (byte)(s >> 16);
                        break;
                }
            }
        }
        return data;
    }

    static int Peak(IEnumerable<short> samples) => samples.Select(s => Math.Abs((int)s)).DefaultIfEmpty(0).Max();

    [Fact]
    public void Stereo44kBecomesMono48k()
    {
        MicConverter? converter = null;
        var output = new List<short>();
        const int chunk = 4410;
        for (var n = 0; n < 10; n++)
        {
            output.AddRange(MicConvert.S16Mono48k(Sine(chunk, start: n * chunk), new AudioFormat(44_100, 2, AudioSampleType.Float32), ref converter));
        }
        // 1 second at 44.1 kHz gives about 1 second at 48 kHz. The converter
        // holds back 2 frames.
        Assert.InRange(output.Count, 48_000 - 480, 48_000 + 480);
        // Both channels mix into 1 at the same level.
        Assert.InRange(Peak(output), 0.45 * 32767, 0.55 * 32767);
        Assert.Equal(new AudioFormat(44_100, 2, AudioSampleType.Float32), converter!.Input);
    }

    [Fact]
    public void FormatChangeRebuildsTheConverter()
    {
        MicConverter? converter = null;
        var stereo = new AudioFormat(44_100, 2, AudioSampleType.Float32);
        MicConvert.S16Mono48k(Sine(4410), stereo, ref converter);
        var first = converter;
        MicConvert.S16Mono48k(Sine(4410, start: 4410), stereo, ref converter);
        Assert.Same(first, converter); // the same format keeps the converter
        var output = new List<short>();
        var mono = new AudioFormat(48_000, 1, AudioSampleType.Float32);
        for (var n = 0; n < 10; n++)
        {
            output.AddRange(MicConvert.S16Mono48k(Sine(4800, rate: 48_000, channels: 1, start: n * 4800), mono, ref converter));
        }
        Assert.NotSame(first, converter); // a new format builds a new converter
        Assert.Equal(48_000, converter!.Input.SampleRate);
        Assert.Equal(48_000, output.Count); // the stream rate needs no rate change
    }

    [Theory]
    [InlineData(AudioSampleType.Int16)]
    [InlineData(AudioSampleType.Int24)]
    [InlineData(AudioSampleType.Int32)]
    [InlineData(AudioSampleType.Float64)]
    public void EachSampleTypeConverts(AudioSampleType type)
    {
        MicConverter? converter = null;
        var output = MicConvert.S16Mono48k(Sine(4800, rate: 48_000, channels: 2, type: type), new AudioFormat(48_000, 2, type), ref converter);
        Assert.Equal(4800, output.Length);
        Assert.InRange(Peak(output), 0.49 * 32767, 0.51 * 32767);
    }

    [Fact]
    public void A96kInputHalvesItsSamples()
    {
        MicConverter? converter = null;
        var output = MicConvert.S16Mono48k(Sine(9600, rate: 96_000, channels: 1), new AudioFormat(96_000, 1, AudioSampleType.Float32), ref converter);
        Assert.InRange(output.Length, 4796, 4800);
        Assert.InRange(Peak(output), 0.45 * 32767, 0.55 * 32767);
    }

    [Fact]
    public void JoinsOfBuffersMakeNoClicks()
    {
        // The same audio in 1 buffer and in many small buffers gives the same
        // samples, so the state goes from buffer to buffer. The place of each
        // sample adds up in another order, so a sample can differ by 1.
        var format = new AudioFormat(44_100, 1, AudioSampleType.Float32);
        var all = Sine(4410, channels: 1);
        MicConverter? one = null;
        var whole = MicConvert.S16Mono48k(all, format, ref one);
        MicConverter? many = null;
        var parts = new List<short>();
        for (var at = 0; at < all.Length; at += 4 * 37)
        {
            parts.AddRange(MicConvert.S16Mono48k(all.AsSpan(at, Math.Min(4 * 37, all.Length - at)), format, ref many));
        }
        Assert.Equal(whole.Length, parts.Count);
        Assert.All(whole.Zip(parts), p => Assert.InRange(p.First - p.Second, -1, 1));
    }

    [Fact]
    public void FullScaleAndBadValuesStayInRange()
    {
        var format = new AudioFormat(48_000, 1, AudioSampleType.Float32);
        var data = new byte[16];
        BitConverter.TryWriteBytes(data.AsSpan(0), 2f);
        BitConverter.TryWriteBytes(data.AsSpan(4), -2f);
        BitConverter.TryWriteBytes(data.AsSpan(8), float.NaN);
        BitConverter.TryWriteBytes(data.AsSpan(12), 1f);
        MicConverter? converter = null;
        Assert.Equal([short.MaxValue, -short.MaxValue, 0, short.MaxValue], MicConvert.S16Mono48k(data, format, ref converter));
        // A part of a frame at the end is ignored.
        Assert.Single(MicConvert.S16Mono48k(data.AsSpan(0, 6), format, ref converter));
    }

    [Fact]
    public void AFormatThatDoesNotConvertThrows()
    {
        MicConverter? converter = null;
        var e = Assert.Throws<StreamException>(() => MicConvert.S16Mono48k(new byte[4], new AudioFormat(48_000, 0, AudioSampleType.Float32), ref converter));
        Assert.Equal("Flux cannot convert 48000 Hz audio with 0 channels", e.Message);
        Assert.Throws<StreamException>(() => new MicConverter(new AudioFormat(48_000, 1, (AudioSampleType)99)));
    }
}
