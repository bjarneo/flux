using System.Runtime.InteropServices;
using Forms = System.Windows.Forms;
using Drawing = System.Drawing;

namespace Flux.Windows;

internal sealed class TrayIcon : IDisposable
{
    private readonly Forms.NotifyIcon icon;
    private readonly Forms.ContextMenuStrip menu = new();
    private readonly Drawing.Icon mark;
    private readonly Drawing.Font font = new("Consolas", 10);
    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr icon);
    public TrayIcon(Action show, Action exit)
    {
        using var bitmap = new Drawing.Bitmap(32, 32);
        using (var graphics = Drawing.Graphics.FromImage(bitmap)) {
            using var pen = new Drawing.Pen(Drawing.Color.FromArgb(192, 202, 245), 3);
            using var accent = new Drawing.SolidBrush(Drawing.Color.FromArgb(122, 162, 247));
            graphics.DrawRectangle(pen, 7, 7, 18, 18);
            graphics.FillRectangle(accent, 14, 2, 4, 28);
        }
        var handle = bitmap.GetHicon();
        try { using var native = Drawing.Icon.FromHandle(handle); mark = (Drawing.Icon)native.Clone(); }
        finally { DestroyIcon(handle); }
        menu.Font = font;
        menu.BackColor = Drawing.Color.FromArgb(22, 22, 30);
        menu.ForeColor = Drawing.Color.FromArgb(192, 202, 245);
        menu.Renderer = new Forms.ToolStripProfessionalRenderer(new Colors());
        menu.Items.Add("Open Flux", null, (_, _) => show());
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Exit Flux", null, (_, _) => exit());
        foreach (Forms.ToolStripItem item in menu.Items) item.ForeColor = menu.ForeColor;
        icon = new Forms.NotifyIcon { Text = "Flux · running in the background", Icon = mark,
            ContextMenuStrip = menu, Visible = true };
        icon.DoubleClick += (_, _) => show();
    }
    private sealed class Colors : Forms.ProfessionalColorTable
    {
        public override Drawing.Color ToolStripDropDownBackground => Drawing.Color.FromArgb(22,22,30);
        public override Drawing.Color ImageMarginGradientBegin => ToolStripDropDownBackground;
        public override Drawing.Color ImageMarginGradientMiddle => ToolStripDropDownBackground;
        public override Drawing.Color ImageMarginGradientEnd => ToolStripDropDownBackground;
        public override Drawing.Color MenuItemSelected => Drawing.Color.FromArgb(36,40,59);
        public override Drawing.Color MenuItemBorder => Drawing.Color.FromArgb(122,162,247);
        public override Drawing.Color MenuBorder => Drawing.Color.FromArgb(115,122,162);
    }
    public void Dispose() { icon.Visible = false; icon.Dispose(); menu.Dispose(); mark.Dispose(); font.Dispose(); }
}
