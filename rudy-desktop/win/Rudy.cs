// Rudy — a little walking robot for your desktop.
//
// Transparent, always-on-top, click-through window that walks the sprite
// from the portfolio site (anim/spritesheet.png) back and forth along the
// bottom of the primary screen.
//
// It does no networking, writes no files, installs nothing, needs no
// admin rights, and quits completely from the tray icon.
//
// Build: see build.ps1 (one csc call, .NET Framework 4.8, in-box on
// Windows 10/11). Nothing else is required.

using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace RudyDesktop
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            bool created;
            // One robot per desktop; a second launch just exits.
            using (var mutex = new Mutex(true, @"Local\RudyDesktopWalker", out created))
            {
                if (!created) return;

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new RudyForm());
            }
        }
    }

    internal sealed class RudyForm : Form
    {
        // ---------------------------------------------------------------
        //  Art / animation constants.
        //
        //  Spritesheet: 768 x 128, six 128 x 128 cells (spritesheetV2).
        //  Drawn content inside a cell spans x 11..115, y 8..118, and the
        //  silhouette already carries a 1 px pink outline, which is why this
        //  build does not add a rim of its own any more.
        //
        //  Insets are the worst case over all six frames and both facings,
        //  so the turn-around never clips him.
        //
        //  These mirror index.html (LEFT_TX / RIGHT_TX / 60 s crossing /
        //  6 fps walk cycle) — keep the two in sync.
        // ---------------------------------------------------------------
        private const int CELL = 128;
        private const int FRAME_COUNT = 6;
        private const double FRAME_FPS = 6.0;
        private const double CROSS_SECONDS = 60.0; // one full screen, one direction
        private const int INSET_L = 11;            // px from cell edge to drawn edge
        private const int INSET_R = 12;
        private const int PAD_BOTTOM = 9;          // sheet: drawn y ends at 118 of 128

        // Window extended styles.
        //
        // NB: no WS_EX_TRANSPARENT. That flag makes the whole window ignore
        // the mouse; without it, a layered window hit-tests by its own alpha,
        // so clicks land on Rudy's body and pass through the empty parts of
        // his cell. That is exactly the behaviour we want now that a click
        // pauses him and a double-click quits.
        private const int WS_EX_LAYERED = 0x00080000;
        private const int WS_EX_TOOLWINDOW = 0x00000080;
        private const int WS_EX_NOACTIVATE = 0x08000000;

        // Click handling. No deferred "was that a double-click?" timer: the
        // window class already has CS_DBLCLKS, so Windows does that detection
        // for us and sends WM_LBUTTONDBLCLK on the second press. Acting
        // immediately on both messages keeps single clicks instant and means
        // two quick presses can never cancel each other.
        private const int WM_LBUTTONDOWN = 0x0201;
        private const int WM_LBUTTONDBLCLK = 0x0203;
        private const int WM_NCLBUTTONDOWN = 0x00A1;
        private const int WM_NCLBUTTONDBLCLK = 0x00A3;

        private Bitmap sheet;
        private readonly Bitmap[,] frames = new Bitmap[2, FRAME_COUNT]; // [0] left, [1] right
        private int px = CELL;                 // sprite size in device pixels
        private Rectangle work;                // the screen band we walk along
        private double minX, maxX, winTop;
        private double x, dir = 1.0, speed;
        private int lastX = int.MinValue, lastFrame = -1;
        private double animTime;               // only advances while walking
        private int frame;
        private bool userPaused, sessionPaused;
        private readonly Stopwatch clock = Stopwatch.StartNew();
        private double lastTick;
        private System.Windows.Forms.Timer timer;
        private NotifyIcon tray;

        private bool IsPaused { get { return userPaused || sessionPaused; } }

        public RudyForm()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            TopMost = true;
            Text = "Rudy";
            MinimizeBox = false;
            MaximizeBox = false;
            ControlBox = false;
            SetStyle(ControlStyles.Opaque, true);

            // Force handle creation so the manifest's per-monitor-v2 DPI
            // setting is usable before we lay anything out.
            IntPtr handle = Handle;
            float scale = 1f;
            uint dpi = GetDpiForWindow(handle);
            if (dpi >= 96) scale = dpi / 96f;

            px = Math.Max(1, (int)Math.Round(CELL * scale));
            sheet = LoadSheet();
            BuildFrames();

            work = Screen.PrimaryScreen.WorkingArea; // sits above the taskbar
            minX = work.Left - INSET_L * scale;
            maxX = work.Right - (CELL - INSET_R) * scale;
            winTop = work.Bottom - (CELL - PAD_BOTTOM) * scale;
            speed = (maxX - minX) / CROSS_SECONDS;

            x = maxX; // start at the right edge, walking left (matches the site)
            dir = -1.0;

            Size = new Size(px, px);
            Location = new Point((int)x, (int)winTop);

            BuildTray();
            SystemEvents.SessionSwitch += OnSessionSwitch;

            timer = new System.Windows.Forms.Timer { Interval = 16 };
            timer.Tick += OnTick;
        }

        // A click pauses/resumes, a double-click quits. Both act immediately:
        // the second press of a double-click simply pauses him for the ~150 ms
        // before WM_LBUTTONDBLCLK arrives and closes him, which is invisible.
        protected override void WndProc(ref Message m)
        {
            switch (m.Msg)
            {
                case WM_LBUTTONDBLCLK:
                case WM_NCLBUTTONDBLCLK:
                    Close();
                    return;
                case WM_LBUTTONDOWN:
                case WM_NCLBUTTONDOWN:
                    TogglePause();
                    return; // swallow it: never start a window drag
            }
            base.WndProc(ref m);
        }

        private void TogglePause()
        {
            userPaused = !userPaused;
            if (!IsPaused) lastTick = clock.Elapsed.TotalSeconds;
            Push();
        }

        protected override bool ShowWithoutActivation
        {
            get { return true; }
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
                return cp;
            }
        }

        // Everything is painted through UpdateLayeredWindow (per-pixel
        // alpha); the window itself never paints.
        protected override void OnPaintBackground(PaintEventArgs e) { }
        protected override void OnPaint(PaintEventArgs e) { }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            lastTick = clock.Elapsed.TotalSeconds;
            frame = 0;
            Push();
            timer.Start();
        }

        // ---------------------------------------------------------------
        //  Art
        // ---------------------------------------------------------------

        private static Bitmap LoadSheet()
        {
            Assembly asm = Assembly.GetExecutingAssembly();
            using (Stream s = asm.GetManifestResourceStream("Rudy.sheet.png"))
            {
                if (s == null) throw new InvalidOperationException("spritesheet resource missing");
                using (var tmp = new Bitmap(s))
                {
                    // Copy so the stream can close (GDI+ keeps it alive).
                    return new Bitmap(tmp);
                }
            }
        }

        private void BuildFrames()
        {
            for (int i = 0; i < FRAME_COUNT; i++)
            {
                frames[0, i] = RenderFrame(i, false);
                frames[1, i] = RenderFrame(i, true);
            }
        }

        private Bitmap RenderFrame(int index, bool flip)
        {
            // Format32bppPArgb: GDI+ premultiplies for us, which is what
            // UpdateLayeredWindow's AC_SRC_ALPHA blend expects.
            var bmp = new Bitmap(px, px, PixelFormat.Format32bppPArgb);
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.Clear(Color.Transparent);
                g.CompositingMode = CompositingMode.SourceCopy;
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                if (flip)
                {
                    g.TranslateTransform(px, 0);
                    g.ScaleTransform(-1, 1);
                }
                g.DrawImage(
                    sheet,
                    new Rectangle(0, 0, px, px),
                    new Rectangle(index * CELL, 0, CELL, CELL),
                    GraphicsUnit.Pixel);
            }
            return bmp;
        }

        // ---------------------------------------------------------------
        //  Movement
        // ---------------------------------------------------------------

        private void OnTick(object sender, EventArgs e)
        {
            if (IsPaused) return;

            double now = clock.Elapsed.TotalSeconds;
            double dt = now - lastTick;
            lastTick = now;
            if (dt <= 0) return;
            if (dt > 0.05) dt = 0.05; // don't jump after a stall

            x += dir * speed * dt;
            if (x <= minX) { x = minX; dir = 1.0; }
            else if (x >= maxX) { x = maxX; dir = -1.0; }

            animTime += dt;
            frame = (int)(animTime * FRAME_FPS) % FRAME_COUNT;

            int ix = (int)Math.Round(x);
            if (ix == lastX && frame == lastFrame) return;

            Push();
        }

        private void Push()
        {
            int ix = (int)Math.Round(x);
            lastX = ix;
            lastFrame = frame;
            Blit(Handle, frames[dir > 0 ? 1 : 0, frame], ix, (int)Math.Round(winTop));
        }

        // ---------------------------------------------------------------
        //  Per-pixel-alpha layered window
        // ---------------------------------------------------------------

        private static void Blit(IntPtr hwnd, Bitmap bmp, int left, int top)
        {
            int w = bmp.Width, h = bmp.Height;
            IntPtr screenDc = GetDC(IntPtr.Zero);
            IntPtr memDc = CreateCompatibleDC(screenDc);
            IntPtr dib = IntPtr.Zero;
            IntPtr old = IntPtr.Zero;
            BitmapData data = null;

            try
            {
                var bi = new BITMAPINFO();
                bi.bmiHeader.biSize = Marshal.SizeOf(typeof(BITMAPINFOHEADER));
                bi.bmiHeader.biWidth = w;
                bi.bmiHeader.biHeight = -h; // top-down rows
                bi.bmiHeader.biPlanes = 1;
                bi.bmiHeader.biBitCount = 32;
                bi.bmiHeader.biCompression = 0; // BI_RGB

                IntPtr bits;
                dib = CreateDIBSection(screenDc, ref bi, 0, out bits, IntPtr.Zero, 0);
                if (dib == IntPtr.Zero) return;

                data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppPArgb);
                int rowBytes = w * 4;
                for (int y = 0; y < h; y++)
                {
                    CopyMemory(
                        IntPtr.Add(bits, y * rowBytes),
                        IntPtr.Add(data.Scan0, y * data.Stride),
                        (UIntPtr)(uint)rowBytes);
                }
                bmp.UnlockBits(data);
                data = null;

                old = SelectObject(memDc, dib);

                var size = new SIZE { cx = w, cy = h };
                var src = new POINT { x = 0, y = 0 };
                var dst = new POINT { x = left, y = top };
                var blend = new BLENDFUNCTION
                {
                    BlendOp = 0,                  // AC_SRC_OVER
                    BlendFlags = 0,
                    SourceConstantAlpha = 255,
                    AlphaFormat = 1               // AC_SRC_ALPHA
                };

                // ULW_ALPHA
                UpdateLayeredWindow(hwnd, screenDc, ref dst, ref size, memDc, ref src, 0, ref blend, 2);
            }
            finally
            {
                if (data != null) bmp.UnlockBits(data);
                if (old != IntPtr.Zero) SelectObject(memDc, old);
                if (dib != IntPtr.Zero) DeleteObject(dib);
                DeleteDC(memDc);
                ReleaseDC(IntPtr.Zero, screenDc);
            }
        }

        // ---------------------------------------------------------------
        //  Tray + lifecycle
        // ---------------------------------------------------------------

        private void BuildTray()
        {
            var menu = new ContextMenuStrip();
            menu.Items.Add("Quit Rudy", null, delegate { Close(); });

            tray = new NotifyIcon
            {
                Text = "Rudy",
                Icon = LoadIcon(),
                ContextMenuStrip = menu,
                Visible = true
            };
            tray.DoubleClick += delegate { Close(); };
        }

        private static Icon LoadIcon()
        {
            Assembly asm = Assembly.GetExecutingAssembly();
            using (Stream s = asm.GetManifestResourceStream("Rudy.icon.ico"))
            {
                if (s != null) return new Icon(s);
            }
            return SystemIcons.Application;
        }

        private void OnSessionSwitch(object sender, SessionSwitchEventArgs e)
        {
            // Lock / fast user switch: stop walking, like the site does when
            // the tab is hidden. Kept separate from the click pause so
            // unlocking does not resume a Rudy the user stopped.
            sessionPaused = e.Reason == SessionSwitchReason.SessionLock
                         || e.Reason == SessionSwitchReason.SessionLogoff
                         || e.Reason == SessionSwitchReason.ConsoleDisconnect;
            if (!IsPaused) lastTick = clock.Elapsed.TotalSeconds;
            Push();
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (timer != null) { timer.Stop(); timer.Dispose(); timer = null; }
            SystemEvents.SessionSwitch -= OnSessionSwitch;
            if (tray != null) { tray.Visible = false; tray.Dispose(); tray = null; }
            base.OnFormClosing(e);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                for (int i = 0; i < FRAME_COUNT; i++)
                {
                    if (frames[0, i] != null) frames[0, i].Dispose();
                    if (frames[1, i] != null) frames[1, i].Dispose();
                }
                if (sheet != null) { sheet.Dispose(); sheet = null; }
            }
            base.Dispose(disposing);
        }

        // ---------------------------------------------------------------
        //  Win32
        // ---------------------------------------------------------------

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT { public int x, y; }

        [StructLayout(LayoutKind.Sequential)]
        private struct SIZE { public int cx, cy; }

        [StructLayout(LayoutKind.Sequential)]
        private struct BLENDFUNCTION
        {
            public byte BlendOp;
            public byte BlendFlags;
            public byte SourceConstantAlpha;
            public byte AlphaFormat;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BITMAPINFOHEADER
        {
            public int biSize;
            public int biWidth;
            public int biHeight;
            public short biPlanes;
            public short biBitCount;
            public int biCompression;
            public int biSizeImage;
            public int biXPelsPerMeter;
            public int biYPelsPerMeter;
            public int biClrUsed;
            public int biClrImportant;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BITMAPINFO
        {
            public BITMAPINFOHEADER bmiHeader;
            public int bmiColors;
        }

        [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
        [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr hWnd);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UpdateLayeredWindow(
            IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize,
            IntPtr hdcSrc, ref POINT pptSrc, int crKey,
            ref BLENDFUNCTION pblend, int dwFlags);

        [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleDC(IntPtr hdc);
        [DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr hdc);
        [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
        [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr obj);

        [DllImport("gdi32.dll", SetLastError = true)]
        private static extern IntPtr CreateDIBSection(
            IntPtr hdc, ref BITMAPINFO pbmi, uint usage,
            out IntPtr ppvBits, IntPtr hSection, uint offset);

        [DllImport("kernel32.dll", EntryPoint = "RtlMoveMemory")]
        private static extern void CopyMemory(IntPtr dest, IntPtr src, UIntPtr count);
    }
}
