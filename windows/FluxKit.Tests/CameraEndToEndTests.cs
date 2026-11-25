using System.Text.Json.Nodes;
using FluxKit;

namespace FluxKit.Tests;

// What the camera modes send, against a headless fluxd: scanned text, a code
// action, a photo, a PDF of pages, and a signature. fluxd puts each in its
// folder. The tests use the ports 38100 to 38149 for the links.
public class CameraEndToEndTests
{
    [FluxdFact]
    public async Task TheCameraModesReachTheirFolders()
    {
        await using var fluxd = await Fluxd.StartAsync(38116, 38120);
        var share = new SharePlugin(new FakeSharePlatform());
        using var t = new TestCore(new LanConfig
        {
            UdpPort = 38131,
            PeerUdpPort = fluxd.UdpPort,
            FirstTcpPort = 38140,
            LastTcpPort = 38148,
            LoopbackOnly = true,
        }, [share]);
        var computer = await EndToEndTests.PairFromWindowsAsync(fluxd, t);
        var scanned = Path.Combine(fluxd.Root, "Documents", "flux", "scanned");
        var photos = Path.Combine(fluxd.Root, "Pictures", "flux");

        // Text mode saves the text in a file in the scan folder.
        Assert.True(share.SendScan("Invoice 0925\n\nTotal 12.40", computer.Id));
        await Wait.UntilAsync(() => Directory.Exists(scanned) && Directory.GetFiles(scanned).Any(f => File.ReadAllText(f).Contains("Total 12.40")),
            "the scanned text on fluxd", fluxd);

        // Save of a code does the same.
        Assert.True(t.Core.Send(new ShareBody.Save("Gate B14").Packet, computer.Id));
        await Wait.UntilAsync(() => Directory.GetFiles(scanned).Any(f => File.ReadAllText(f).Contains("Gate B14")), "the saved code on fluxd", fluxd);

        var folder = CoreTests.TempDir();
        try
        {
            // Photo mode sends a JPEG to the photo folder.
            var photo = Path.Combine(folder, "photo.jpg");
            var jpeg = CameraImagesTests.Jpeg(64, 48);
            await File.WriteAllBytesAsync(photo, jpeg);
            var photoName = CaptureNames.Photo(new DateTime(2026, 10, 15, 10, 15, 0, DateTimeKind.Local));
            await share.SendCaptureAsync(photo, photoName, new JsonObject { ["photo"] = true }, computer.Id);
            await Wait.UntilAsync(() => File.Exists(Path.Combine(photos, photoName)), "the photo on fluxd", fluxd);

            // Document mode sends a PDF to the scan folder.
            var pdf = Path.Combine(folder, "doc.pdf");
            await File.WriteAllBytesAsync(pdf, CameraImages.Pdf([jpeg, jpeg]));
            var pdfName = CaptureNames.Document(new DateTime(2026, 10, 15, 10, 15, 0, DateTimeKind.Local));
            await share.SendCaptureAsync(pdf, pdfName, new JsonObject { ["scan"] = true }, computer.Id);
            await Wait.UntilAsync(() => File.Exists(Path.Combine(scanned, pdfName)), "the PDF on fluxd", fluxd);
            Assert.StartsWith("%PDF-1.4", File.ReadAllText(Path.Combine(scanned, pdfName)));

            // Signature mode sends a PNG to the signature folder.
            var ink = new SignatureDrawing();
            ink.Add([new InkPoint(10, 10), new InkPoint(60, 30), new InkPoint(110, 10)]);
            var png = Path.Combine(folder, "signature.png");
            await File.WriteAllBytesAsync(png, CameraImages.Png(ink.Ink(120, 40)!, InkColor.Blue.Rgb()!.Value));
            var pngName = CaptureNames.Signature(new DateTime(2026, 10, 15, 10, 15, 0, DateTimeKind.Local));
            await share.SendCaptureAsync(png, pngName, new JsonObject { ["signature"] = true }, computer.Id);
            await Wait.UntilAsync(() => File.Exists(Path.Combine(photos, "signatures", pngName)), "the signature on fluxd", fluxd);
        }
        finally
        {
            Directory.Delete(folder, true);
        }
    }
}
