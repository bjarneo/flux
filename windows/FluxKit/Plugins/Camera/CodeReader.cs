using ZXing;

namespace FluxKit;

// A code that the reader found, with its outline in normalized coordinates
// of the image.
public sealed record FoundCode(ScannedCode Code, ValueList<ScanPoint> Outline);

// Reads QR codes and barcodes with ZXing.Net. Windows has no decoder for
// them. VisionScan.swift of the Mac app reads them with Vision. The decoder
// runs at once, so callers run it off the UI thread.
public static class CodeReader
{
    static readonly IList<BarcodeFormat> Formats =
    [
        BarcodeFormat.QR_CODE, BarcodeFormat.DATA_MATRIX, BarcodeFormat.PDF_417, BarcodeFormat.AZTEC,
        BarcodeFormat.EAN_13, BarcodeFormat.EAN_8, BarcodeFormat.UPC_A, BarcodeFormat.UPC_E,
        BarcodeFormat.CODE_128, BarcodeFormat.CODE_39, BarcodeFormat.CODE_93, BarcodeFormat.CODABAR, BarcodeFormat.ITF,
    ];

    // Returns the codes with a value in an upright image. A live frame reads
    // faster and finds fewer codes. A still image also tries the image
    // turned and with inverted colors.
    public static IReadOnlyList<FoundCode> Read(BgraImage image, bool live = false)
    {
        var reader = new BarcodeReaderGeneric
        {
            AutoRotate = !live,
            Options =
            {
                TryHarder = !live,
                TryInverted = !live,
                PossibleFormats = Formats,
            },
        };
        var source = new RGBLuminanceSource(image.Pixels, image.Width, image.Height, RGBLuminanceSource.BitmapFormat.BGRA32);
        var results = live
            ? reader.Decode(source) is { } one ? [one] : []
            : reader.DecodeMultiple(source) ?? [];
        return results
            .Where(r => !string.IsNullOrEmpty(r.Text))
            .Select(r => new FoundCode(Code(Format(r.BarcodeFormat), r.Text), Outline(r.ResultPoints, image.Width, image.Height)))
            .ToArray();
    }

    // Converts a decoded code to the model that Codes classifies. A reader
    // that sees UPC-A as EAN-13 gives a leading 0, which ML Kit and the Mac
    // report as UPC-A.
    public static ScannedCode Code(CodeFormat format, string raw)
    {
        if (format == CodeFormat.Ean13 && raw.Length == 13 && raw.StartsWith('0'))
        {
            return CodeContent.Parse(CodeFormat.UpcA, raw[1..]);
        }
        return CodeContent.Parse(format, raw);
    }

    internal static CodeFormat Format(BarcodeFormat f) => f switch
    {
        BarcodeFormat.QR_CODE => CodeFormat.QrCode,
        BarcodeFormat.DATA_MATRIX => CodeFormat.DataMatrix,
        BarcodeFormat.PDF_417 => CodeFormat.Pdf417,
        BarcodeFormat.AZTEC => CodeFormat.Aztec,
        BarcodeFormat.EAN_13 => CodeFormat.Ean13,
        BarcodeFormat.EAN_8 => CodeFormat.Ean8,
        BarcodeFormat.UPC_A => CodeFormat.UpcA,
        BarcodeFormat.UPC_E => CodeFormat.UpcE,
        BarcodeFormat.CODE_128 => CodeFormat.Code128,
        BarcodeFormat.CODE_39 => CodeFormat.Code39,
        BarcodeFormat.CODE_93 => CodeFormat.Code93,
        BarcodeFormat.CODABAR => CodeFormat.Codabar,
        BarcodeFormat.ITF => CodeFormat.Itf,
        _ => CodeFormat.Unknown,
    };

    // The outline of a code: the box of the points that the decoder found,
    // with a margin. The points of a QR code are the centers of its finder
    // patterns, so the margin reaches the corners of the code.
    static ValueList<ScanPoint> Outline(ResultPoint[]? points, int w, int h)
    {
        if (points is not { Length: > 0 })
        {
            return ValueList<ScanPoint>.Empty;
        }
        var left = points.Min(p => p.X);
        var right = points.Max(p => p.X);
        var top = points.Min(p => p.Y);
        var bottom = points.Max(p => p.Y);
        var pad = Math.Max(right - left, bottom - top) * 0.12f + 4;
        var x0 = Math.Max(0, left - pad) / w;
        var x1 = Math.Min(w, right + pad) / w;
        var y0 = Math.Max(0, top - pad) / h;
        var y1 = Math.Min(h, bottom + pad) / h;
        return ValueList.From(new[] { new ScanPoint(x0, y0), new ScanPoint(x1, y0), new ScanPoint(x1, y1), new ScanPoint(x0, y1) });
    }
}
