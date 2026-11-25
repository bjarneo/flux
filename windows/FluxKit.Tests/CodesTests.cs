using System.Text.Json.Nodes;
using FluxKit;
using ZXing;
using ZXing.Common;

namespace FluxKit.Tests;

// CodesTests.swift and VisionScanTests.swift of the Mac app, with the
// decoder of ZXing.Net in the place of Vision.
public class CodesTests
{
    static ShareBody[] Bodies(CodeSheet sheet) => sheet.Actions.Select(a => a.Body).ToArray();

    [Fact]
    public void UrlOpensOrCopies()
    {
        var sheet = Codes.Sheet(new ScannedCode(CodeFormat.QrCode, "https://omarchy.org/flux", Url: "https://omarchy.org/flux"), "laptop");
        Assert.Equal(CodeKind.Url, sheet.Kind);
        Assert.Equal("QR code · Link", sheet.Title);
        Assert.Equal(["Open on laptop", "Copy on laptop"], sheet.Actions.Select(a => a.Verb));
        Assert.Equal(new ShareBody.OpenUrl("https://omarchy.org/flux"), sheet.Actions[0].Body);
        Assert.Equal(new ShareBody.Copy("https://omarchy.org/flux"), sheet.Actions[1].Body);
    }

    [Fact]
    public void RawUrlWithoutTypeIsALink()
    {
        Assert.Equal(CodeKind.Url, Codes.Kind(new ScannedCode(CodeFormat.DataMatrix, " http://192.168.1.5:8080/x ")));
        Assert.Equal("http://192.168.1.5:8080/x", Codes.Text(new ScannedCode(CodeFormat.DataMatrix, " http://192.168.1.5:8080/x ")));
    }

    [Fact]
    public void TextSavesOrCopies()
    {
        var sheet = Codes.Sheet(new ScannedCode(CodeFormat.Aztec, "Gate B14"), "pc");
        Assert.Equal(CodeKind.Text, sheet.Kind);
        Assert.Equal([new ShareBody.Save("Gate B14"), new ShareBody.Copy("Gate B14")], Bodies(sheet));
    }

    [Fact]
    public void ProductCodes()
    {
        Assert.Equal(CodeKind.Product, Codes.Kind(new ScannedCode(CodeFormat.Ean13, "7038010009457")));
        Assert.Equal(CodeKind.Product, Codes.Kind(new ScannedCode(CodeFormat.Code128, "978020137962", Product: true)));
        Assert.Equal(CodeKind.Text, Codes.Kind(new ScannedCode(CodeFormat.Code128, "PKG-0925")));
        Assert.Equal("UPC-A · Product code", Codes.Sheet(new ScannedCode(CodeFormat.UpcA, "036000291452"), "pc").Title);
    }

    [Fact]
    public void WifiBecomesReadable()
    {
        var code = new ScannedCode(CodeFormat.QrCode, "WIFI:S:home;T:WPA;P:secret;;", Wifi: new WifiInfo("home", "secret", "WPA"));
        Assert.Equal(CodeKind.Wifi, Codes.Kind(code));
        Assert.Equal("Wi-Fi network: home\nPassword: secret\nSecurity: WPA", Codes.Text(code));
        Assert.Equal(CodeKind.Wifi, Codes.Kind(new ScannedCode(CodeFormat.QrCode, "wifi:S:open;;")));
        Assert.Equal("Wi-Fi network: open", Codes.Text(new ScannedCode(CodeFormat.QrCode, "x", Wifi: new WifiInfo("open", "", ""))));
    }

    [Fact]
    public void ContactBecomesReadable()
    {
        var code = new ScannedCode(CodeFormat.QrCode, "BEGIN:VCARD\nFN:Dan Kim\nEND:VCARD",
            Contact: new ContactInfo("Dan Kim", ["+47 400 00 000"], ["dan@example.com"], "Basecamp"));
        Assert.Equal(CodeKind.Contact, Codes.Kind(code));
        Assert.Equal("Dan Kim\nBasecamp\n+47 400 00 000\ndan@example.com", Codes.Text(code));
        Assert.Equal("MECARD:N:Kim;;", Codes.Text(new ScannedCode(CodeFormat.QrCode, "MECARD:N:Kim;;")));
    }

    [Fact]
    public void BodiesHaveTheFieldsOfAndroid()
    {
        Assert.True(JsonNode.DeepEquals(new JsonObject { ["url"] = "https://x.org" }, new ShareBody.OpenUrl("https://x.org").Fields));
        Assert.True(JsonNode.DeepEquals(new JsonObject { ["text"] = "a" }, new ShareBody.Copy("a").Fields));
        Assert.True(JsonNode.DeepEquals(new JsonObject { ["text"] = "a", ["scan"] = true }, new ShareBody.Save("a").Fields));
        Assert.Equal(PacketType.Share, new ShareBody.Save("a").Packet.Type);
    }

    [Fact]
    public void FileNames()
    {
        var t = new DateTime(2026, 9, 25, 10, 15, 0, DateTimeKind.Local);
        Assert.Equal("IMG_20260925_101500.jpg", CaptureNames.Photo(t));
        Assert.Equal("scan-20260925-101500.pdf", CaptureNames.Document(t));
        Assert.Equal("signature-20260925-101500.png", CaptureNames.Signature(t));
        Assert.Equal(CaptureNames.Photo(t), CaptureNames.Photo(t.ToUniversalTime()));
    }

    // Content that ML Kit reads on Android

    [Fact]
    public void WifiContent()
    {
        Assert.Equal(new WifiInfo("my;net", "p:w", "WPA"), CodeContent.Parse(CodeFormat.QrCode, "WIFI:T:WPA;S:my\\;net;P:p\\:w;;").Wifi);
        Assert.Equal(new WifiInfo("cafe", "", "open"), CodeContent.Parse(CodeFormat.QrCode, "WIFI:S:cafe;T:nopass;;").Wifi);
        Assert.Equal("WEP", CodeContent.Parse(CodeFormat.QrCode, "WIFI:S:old;T:WEP;P:k;;").Wifi?.Security);
        var code = CodeContent.Parse(CodeFormat.QrCode, "WIFI:S:home;T:WPA;P:secret;;");
        Assert.Equal("Wi-Fi network: home\nPassword: secret\nSecurity: WPA", Codes.Text(code));
    }

    [Fact]
    public void ContactContent()
    {
        var vcard = "BEGIN:VCARD\r\nVERSION:3.0\r\nN:Kim;Dan;;;\r\nTEL;TYPE=CELL:+47 400 00 000\r\nEMAIL:dan@example.com\r\nORG:Basecamp;Ops\r\nEND:VCARD";
        Assert.Equal(new ContactInfo("Dan Kim", ["+47 400 00 000"], ["dan@example.com"], "Basecamp"), CodeContent.Parse(CodeFormat.QrCode, vcard).Contact);
        Assert.Equal("Dan Kim", CodeContent.Parse(CodeFormat.QrCode, "BEGIN:VCARD\nFN:Dan Kim\nN:Kim;Daniel\nEND:VCARD").Contact?.Name);
        Assert.Equal(new ContactInfo("Dan Kim", ["123"], ["d@x.org"], ""), CodeContent.Parse(CodeFormat.QrCode, "MECARD:N:Kim,Dan;TEL:123;EMAIL:d@x.org;;").Contact);
    }

    [Fact]
    public void BookmarkAndPlainContent()
    {
        Assert.Equal("https://omarchy.org", CodeContent.Parse(CodeFormat.QrCode, "MEBKM:TITLE:Flux;URL:https://omarchy.org;;").Url);
        Assert.Equal(new ScannedCode(CodeFormat.Code128, "PKG-0925"), CodeContent.Parse(CodeFormat.Code128, "PKG-0925"));
    }

    // Only http and https links open on the computer, as fluxd opens only those.
    [Fact]
    public void BookmarkWithAnotherSchemeIsText()
    {
        var web = CodeContent.Parse(CodeFormat.QrCode, "MEBKM:TITLE:Flux;URL:https://omarchy.org;;");
        Assert.Equal(CodeKind.Url, Codes.Kind(web));
        Assert.Equal("https://omarchy.org", Codes.Text(web));
        foreach (var raw in new[] { "MEBKM:URL:ftp://x.org;;", "MEBKM:URL:file:///etc/passwd;;", "MEBKM:URL:javascript:alert(1);;" })
        {
            var code = CodeContent.Parse(CodeFormat.QrCode, raw);
            Assert.Equal(CodeKind.Text, Codes.Kind(code));
            Assert.Equal([new ShareBody.Save(raw), new ShareBody.Copy(raw)], Bodies(Codes.Sheet(code, "pc")));
        }
    }

    [Fact]
    public void UpcAIsReported()
    {
        Assert.Equal(new ScannedCode(CodeFormat.UpcA, "036000291452"), CodeReader.Code(CodeFormat.Ean13, "0036000291452"));
        Assert.Equal(new ScannedCode(CodeFormat.Ean13, "7038010009457"), CodeReader.Code(CodeFormat.Ean13, "7038010009457"));
    }

    // The decoder

    // Draws a code of ZXing at scale pixels for each module, black on white,
    // with a white margin around it.
    internal static BgraImage Draw(BitMatrix matrix, int scale, int margin, int height = 0)
    {
        var rows = height > 0 ? height : matrix.Height * scale;
        var w = matrix.Width * scale + 2 * margin;
        var h = rows + 2 * margin;
        var pixels = new byte[w * h * 4];
        Array.Fill(pixels, (byte)255);
        for (var y = 0; y < rows; y++)
        {
            for (var x = 0; x < matrix.Width * scale; x++)
            {
                var module = height > 0 ? matrix[x / scale, 0] : matrix[x / scale, y / scale];
                if (!module)
                {
                    continue;
                }
                var at = ((y + margin) * w + x + margin) * 4;
                pixels[at] = pixels[at + 1] = pixels[at + 2] = 0;
            }
        }
        return new BgraImage(w, h, pixels);
    }

    internal static BgraImage QrImage(string text, int scale = 8) =>
        Draw(new ZXing.QrCode.QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, 0, 0), scale, 40);

    [Fact]
    public void ReadsAQrCodeFromAnImage()
    {
        var image = QrImage("https://example.com/flux-windows");
        var found = CodeReader.Read(image);
        var code = Assert.Single(found);
        Assert.Equal("https://example.com/flux-windows", code.Code.Raw);
        Assert.Equal(CodeFormat.QrCode, code.Code.Format);
        Assert.Equal(CodeKind.Url, Codes.Kind(code.Code));
        // The outline holds the code.
        Assert.Equal(4, code.Outline.Count);
        Assert.All(code.Outline, p => Assert.InRange(p.X, 0, 1));
        Assert.True(code.Outline[0].X < 0.25 && code.Outline[2].X > 0.75, "the outline spans the code");
        // A live frame finds it too.
        Assert.Equal("https://example.com/flux-windows", Assert.Single(CodeReader.Read(image, live: true)).Code.Raw);
    }

    [Fact]
    public void ReadsTheContentOfAWifiCode()
    {
        var code = Assert.Single(CodeReader.Read(QrImage("WIFI:S:home;T:WPA;P:secret;;"))).Code;
        Assert.Equal(new WifiInfo("home", "secret", "WPA"), code.Wifi);
        Assert.Equal("QR code · Wi-Fi network", Codes.Sheet(code, "pc").Title);
    }

    [Fact]
    public void ReadsAUpcABarcodeAsUpcA()
    {
        var matrix = new ZXing.OneD.UPCAWriter().encode("036000291452", BarcodeFormat.UPC_A, 0, 0);
        var code = Assert.Single(CodeReader.Read(Draw(matrix, 3, 30, 120))).Code;
        Assert.Equal(CodeFormat.UpcA, code.Format);
        Assert.Equal("036000291452", code.Raw);
        Assert.Equal(CodeKind.Product, Codes.Kind(code));
    }

    [Fact]
    public void AnImageWithoutACodeGivesNothing()
    {
        var pixels = new byte[200 * 100 * 4];
        Array.Fill(pixels, (byte)200);
        Assert.Empty(CodeReader.Read(new BgraImage(200, 100, pixels)));
        Assert.Empty(CodeReader.Read(new BgraImage(200, 100, pixels), live: true));
    }
}
