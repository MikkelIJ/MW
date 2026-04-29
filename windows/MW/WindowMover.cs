using System;
using System.Runtime.InteropServices;
using System.Windows;

namespace MW;

internal static class WindowMover
{
    public static IntPtr GetForegroundWindowSafe()
    {
        var hwnd = GetForegroundWindow();
        // Skip our own windows (we just clicked one to dismiss the picker).
        if (hwnd == IntPtr.Zero) return IntPtr.Zero;
        var pid = 0u;
        GetWindowThreadProcessId(hwnd, out pid);
        if (pid == (uint)Environment.ProcessId) return IntPtr.Zero;
        return hwnd;
    }

    public static void MoveTo(IntPtr hwnd, Rect target)
    {
        // Restore from minimized/maximized so SetWindowPos sticks.
        if (IsZoomed(hwnd) || IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);

        // Subtract invisible "frame" margins so the visible bounds match the target.
        var dwm = new RECT();
        var ok = DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, out dwm,
                                       Marshal.SizeOf<RECT>()) == 0;
        var win = new RECT();
        GetWindowRect(hwnd, out win);

        int dx = ok ? (dwm.left - win.left) : 0;
        int dy = ok ? (dwm.top  - win.top)  : 0;
        int dw = ok ? ((win.right - win.left) - (dwm.right - dwm.left)) : 0;
        int dh = ok ? ((win.bottom - win.top) - (dwm.bottom - dwm.top)) : 0;

        int x = (int)target.X - dx;
        int y = (int)target.Y - dy;
        int w = (int)target.Width  + dw;
        int h = (int)target.Height + dh;

        SetWindowPos(hwnd, IntPtr.Zero, x, y, w, h,
            SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    }

    // P/Invoke
    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int left, top, right, bottom; }

    private const int SW_RESTORE = 9;
    private const uint SWP_NOZORDER = 0x0004;
    private const uint SWP_NOACTIVATE = 0x0010;
    private const uint SWP_SHOWWINDOW = 0x0040;
    private const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;

    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] private static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hAfter, int x, int y, int cx, int cy, uint flags);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT outRect, int attrSize);
}
