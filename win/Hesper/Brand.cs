using System.Drawing.Drawing2D;

namespace Hesper;

/// Hesper's colours (mac/App/Brand.swift) and its icon, drawn: a rounded square with the evening
/// star; a red dot while recording. Windows doesn't tint tray icons, so it's in colour.
static class Brand
{
    public static readonly Color DuskInk = ColorTranslator.FromHtml("#1B1F2E");
    public static readonly Color Horizon = ColorTranslator.FromHtml("#2E3550");
    public static readonly Color EveningStar = ColorTranslator.FromHtml("#F2B544");
    public static readonly Color Recording = ColorTranslator.FromHtml("#D93A3A");

    /// The icon at size × size pixels (drawn on a 100 × 100 grid).
    public static Bitmap Draw(int size, bool recording = false)
    {
        var bmp = new Bitmap(size, size);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.ScaleTransform(size / 100f, size / 100f);
        using (var square = Rounded(new RectangleF(0, 0, 100, 100), 22))
        using (var fill = new SolidBrush(Horizon))
            g.FillPath(fill, square);
        using (var star = Star())
        using (var fill = new SolidBrush(EveningStar))
            g.FillPath(fill, star);
        if (recording)
        {
            using var red = new SolidBrush(Recording);
            using var ring = new Pen(Horizon, 6);
            g.FillEllipse(red, 58, 58, 40, 40);
            g.DrawEllipse(ring, 58, 58, 40, 40);
        }
        return bmp;
    }

    public static Icon Icon(int size, bool recording = false)
    {
        using var bmp = Draw(size, recording);
        var handle = bmp.GetHicon();
        try { return (Icon)System.Drawing.Icon.FromHandle(handle).Clone(); }
        finally { DestroyIcon(handle); }
    }

    /// Hesper.ico (the exe's icon): 16 to 256 pixels, each a PNG inside the .ico.
    public static void WriteIco(string path)
    {
        int[] sizes = [16, 24, 32, 48, 64, 128, 256];
        var images = sizes.Select(s =>
        {
            using var bmp = Draw(s);
            using var ms = new MemoryStream();
            bmp.Save(ms, System.Drawing.Imaging.ImageFormat.Png);
            return ms.ToArray();
        }).ToList();
        using var w = new BinaryWriter(File.Create(path));
        w.Write((short)0); w.Write((short)1); w.Write((short)sizes.Length);
        var offset = 6 + 16 * sizes.Length;
        for (var i = 0; i < sizes.Length; i++)
        {
            w.Write((byte)(sizes[i] % 256)); w.Write((byte)(sizes[i] % 256));  // 256 is written as 0
            w.Write((byte)0); w.Write((byte)0); w.Write((short)1); w.Write((short)32);
            w.Write(images[i].Length); w.Write(offset);
            offset += images[i].Length;
        }
        foreach (var img in images) w.Write(img);
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern bool DestroyIcon(IntPtr handle);

    static GraphicsPath Rounded(RectangleF r, float radius)
    {
        var p = new GraphicsPath();
        var d = radius * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    /// M50 14 Q50 40 74 40 Q50 40 50 66 Q50 40 26 40 Q50 40 50 14 Z (quadratic curves, as cubic ones)
    static GraphicsPath Star()
    {
        var p = new GraphicsPath();
        var c = new PointF(50, 40);
        PointF[] tips = [new(50, 14), new(74, 40), new(50, 66), new(26, 40), new(50, 14)];
        for (var i = 0; i < 4; i++)
        {
            PointF a = tips[i], b = tips[i + 1];
            PointF Lerp(PointF from) => new(from.X + 2f / 3 * (c.X - from.X), from.Y + 2f / 3 * (c.Y - from.Y));
            p.AddBezier(a, Lerp(a), Lerp(b), b);
        }
        p.CloseFigure();
        return p;
    }
}
