using System.Runtime.InteropServices;

namespace Flux;

// The functions, the values, and the COM interfaces of Media Foundation
// that the H.264 decoder and the H.264 encoder use. A method that they do
// not call has no parameters, but it keeps its place in the table of the
// interface.
static class MF
{
    public const int Version = 0x00020070;
    public const int NotAccepting = unchecked((int)0xC00D36B5);
    public const int TypeNotSet = unchecked((int)0xC00D6D60);
    public const int StreamChange = unchecked((int)0xC00D6D61);
    public const int NeedMoreInput = unchecked((int)0xC00D6D72);
    public const int ProvidesSamples = 0x100;
    public const int CommandFlush = 0;
    public const int CommandDrain = 1;
    public const int BeginStreaming = 0x10000000;
    public const int EndStreaming = 0x10000001;
    public const int EndOfStream = 0x10000002;
    public const int StartOfStream = 0x10000003;
    public const int Progressive = 2;
    public const int MatrixBt709 = 1;
    public const int RangeFull = 1;
    public const int RangeLimited = 2;
    public const int PrimariesBt709 = 2;
    public const int TransferBt709 = 5;
    public const int ProfileMain = 77;
    public const int Level41 = 41;

    public static readonly Guid H264DecoderClass = new("62CE7E72-4C71-4d20-B15D-452831A87D9D");
    public static readonly Guid H264EncoderClass = new("6ca50344-051a-4ded-9779-a43305165e35");
    public static readonly Guid MajorType = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    public static readonly Guid Subtype = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    public static readonly Guid FrameSize = new("1652c33d-d6b2-4012-b834-72030849a37d");
    public static readonly Guid DefaultStride = new("644b4e48-1e02-4516-b0eb-c01ca9d49ac6");
    public static readonly Guid InterlaceMode = new("e2724bb8-e676-4806-b4b2-a8d6efb44ccd");
    public static readonly Guid MinimumDisplayAperture = new("d7388766-18fe-48c6-a177-ee894867c8c4");
    public static readonly Guid YuvMatrix = new("3e23d450-2c75-4d25-a00e-b91670d12327");
    public static readonly Guid NominalRange = new("c21b8ee5-b956-4071-8daf-325edf5cab11");
    public static readonly Guid VideoPrimaries = new("dbfbe4d7-0740-4ee0-8192-850ab0e21935");
    public static readonly Guid TransferFunction = new("5fb0fce9-be5c-4935-a811-ec838f8eed93");
    public static readonly Guid FrameRate = new("c459a2e8-3d2c-4e44-b132-fee5156c7bb0");
    public static readonly Guid PixelAspectRatio = new("c6376a1e-8d0a-4027-be45-6d9a0ad39bb6");
    public static readonly Guid AvgBitrate = new("20332624-fb0d-4d9e-bd0d-cbf6786c102e");
    public static readonly Guid Mpeg2Profile = new("ad76a80b-2d5c-4e0b-b375-64e520137036");
    public static readonly Guid Mpeg2Level = new("96f66574-11c5-4015-8666-bff516436da7");
    public static readonly Guid SequenceHeader = new("3c036de7-3ad0-4c9e-9216-ee6d6ac21cb3");
    public static readonly Guid CleanPoint = new("9cdf01d8-a0f0-43ba-b077-eaa06cbd728a");
    public static readonly Guid LowLatency = new("9c27891a-ed7a-40e1-88e8-b22727a024ee");
    public static readonly Guid Video = new("73646976-0000-0010-8000-00AA00389B71");
    public static readonly Guid H264 = new("34363248-0000-0010-8000-00AA00389B71");
    public static readonly Guid Nv12 = new("3231564E-0000-0010-8000-00AA00389B71");

    [DllImport("mfplat.dll", ExactSpelling = true)]
    public static extern int MFStartup(int version, int flags);

    [DllImport("mfplat.dll", ExactSpelling = true)]
    public static extern int MFShutdown();

    [DllImport("mfplat.dll", ExactSpelling = true)]
    public static extern int MFCreateMediaType(out IMFMediaType type);

    [DllImport("mfplat.dll", ExactSpelling = true)]
    public static extern int MFCreateSample(out IntPtr sample);

    [DllImport("mfplat.dll", ExactSpelling = true)]
    public static extern int MFCreateMemoryBuffer(int length, out IMFMediaBuffer buffer);
}

[StructLayout(LayoutKind.Sequential)]
struct OutputStreamInfo
{
    public int Flags;
    public int Size;
    public int Alignment;
}

[StructLayout(LayoutKind.Sequential)]
struct OutputDataBuffer
{
    public int StreamId;
    public IntPtr Sample;
    public int Status;
    public IntPtr Events;
}

[ComImport, Guid("bf94c121-5b05-4e6f-8000-ba598961414d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMFTransform
{
    void GetStreamLimits();
    void GetStreamCount();
    void GetStreamIDs();
    void GetInputStreamInfo();
    void GetOutputStreamInfo(int stream, out OutputStreamInfo info);
    void GetAttributes(out IMFAttributes attributes);
    void GetInputStreamAttributes();
    void GetOutputStreamAttributes();
    void DeleteInputStream();
    void AddInputStreams();
    void GetInputAvailableType();
    [PreserveSig]
    int GetOutputAvailableType(int stream, int index, out IMFMediaType? type);
    void SetInputType(int stream, IMFMediaType type, int flags);
    [PreserveSig]
    int SetOutputType(int stream, IMFMediaType type, int flags);
    void GetInputCurrentType();
    void GetOutputCurrentType(int stream, out IMFMediaType type);
    void GetInputStatus();
    void GetOutputStatus();
    void SetOutputBounds();
    void ProcessEvent();
    void ProcessMessage(int message, IntPtr param);
    [PreserveSig]
    int ProcessInput(int stream, IMFSample sample, int flags);
    [PreserveSig]
    int ProcessOutput(int flags, int count, ref OutputDataBuffer buffers, out int status);
}

[ComImport, Guid("2cd2d921-c447-44a7-a13c-4adabfc247e3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMFAttributes
{
    void GetItem();
    void GetItemType();
    void CompareItem();
    void Compare();
    void GetUINT32();
    void GetUINT64();
    void GetDouble();
    void GetGUID();
    void GetStringLength();
    void GetString();
    void GetAllocatedString();
    void GetBlobSize();
    void GetBlob();
    void GetAllocatedBlob();
    void GetUnknown();
    void SetItem();
    void DeleteItem();
    void DeleteAllItems();
    void SetUINT32(in Guid key, int value);
}

[ComImport, Guid("44ae0fa8-ea31-4109-8d2e-4cae4997c555"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMFMediaType
{
    void GetItem();
    void GetItemType();
    void CompareItem();
    void Compare();
    [PreserveSig]
    int GetUINT32(in Guid key, out int value);
    [PreserveSig]
    int GetUINT64(in Guid key, out long value);
    void GetDouble();
    [PreserveSig]
    int GetGUID(in Guid key, out Guid value);
    void GetStringLength();
    void GetString();
    void GetAllocatedString();
    [PreserveSig]
    int GetBlobSize(in Guid key, out int size);
    [PreserveSig]
    int GetBlob(in Guid key, [Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 2)] byte[] buffer, int size, out int written);
    void GetAllocatedBlob();
    void GetUnknown();
    void SetItem();
    void DeleteItem();
    void DeleteAllItems();
    void SetUINT32(in Guid key, int value);
    void SetUINT64(in Guid key, long value);
    void SetDouble();
    void SetGUID(in Guid key, in Guid value);
}

[ComImport, Guid("c40a00f2-b93a-4d80-ae8c-5a1c634f58e4"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMFSample
{
    void GetItem();
    void GetItemType();
    void CompareItem();
    void Compare();
    void GetUINT32();
    void GetUINT64();
    void GetDouble();
    void GetGUID();
    void GetStringLength();
    void GetString();
    void GetAllocatedString();
    void GetBlobSize();
    void GetBlob();
    void GetAllocatedBlob();
    void GetUnknown();
    void SetItem();
    void DeleteItem();
    void DeleteAllItems();
    void SetUINT32(in Guid key, int value);
    void SetUINT64();
    void SetDouble();
    void SetGUID();
    void SetString();
    void SetBlob();
    void SetUnknown();
    void LockStore();
    void UnlockStore();
    void GetCount();
    void GetItemByIndex();
    void CopyAllItems();
    void GetSampleFlags();
    void SetSampleFlags();
    void GetSampleTime();
    void SetSampleTime(long time);
    void GetSampleDuration();
    void SetSampleDuration(long duration);
    void GetBufferCount();
    void GetBufferByIndex();
    void ConvertToContiguousBuffer(out IMFMediaBuffer buffer);
    void AddBuffer(IMFMediaBuffer buffer);
}

[ComImport, Guid("045FA593-8799-42b8-BC8D-8968C6453507"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMFMediaBuffer
{
    void Lock(out IntPtr data, out int maxLength, out int currentLength);
    void Unlock();
    void GetCurrentLength(out int length);
    void SetCurrentLength(int length);
}

// The settings of an encoder that Media Foundation reaches through
// ICodecAPI, and the VARIANT that carries a value. The VARIANT has the size
// of 64-bit Windows. 32-bit Windows reads only the first 16 bytes.
static class CodecApi
{
    public static readonly Guid RateControlMode = new("1c0608e9-370c-4710-8a58-cb6181c42423");
    public static readonly Guid MeanBitRate = new("f7222374-2144-4815-b550-a37f8e12ee52");
    public static readonly Guid GopSize = new("95f31b26-95a4-41aa-9303-246a7fc6eef1");
    public static readonly Guid BPictureCount = new("8d390aac-dc5c-4200-b57f-814d04babab2");
    public static readonly Guid LowLatencyMode = new("9c27891a-ed7a-40e1-88e8-b22727a024ee");
    public static readonly Guid ForceKeyFrame = new("398c1b98-8353-475a-9ef2-8f265d260345");

    // eAVEncCommonRateControlMode_UnconstrainedVBR.
    public const uint UnconstrainedVbr = 2;

    public static Variant UInt32(uint value) => new() { Type = 19, Value = value };

    // VARIANT_TRUE is a 16-bit -1.
    public static Variant Bool(bool value) => new() { Type = 11, Value = value ? 0xFFFF : 0 };
}

[StructLayout(LayoutKind.Explicit, Size = 24)]
struct Variant
{
    [FieldOffset(0)]
    public ushort Type;
    [FieldOffset(8)]
    public long Value;
}

[ComImport, Guid("901db4c7-31ce-41a2-85dc-8fa0bf41b8da"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ICodecAPI
{
    void IsSupported();
    void IsModifiable();
    void GetParameterRange();
    void GetParameterValues();
    void GetDefaultValue();
    void GetValue();
    [PreserveSig]
    int SetValue(in Guid api, in Variant value);
}
