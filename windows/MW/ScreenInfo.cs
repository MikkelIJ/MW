using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows;

namespace MW;

public sealed class ScreenInfo
{
    public string Key { get; init; } = "";
    public string Label { get; init; } = "";
    public Rect Bounds { get; init; }       // device pixels in virtual-screen coords
    public bool IsPrimary { get; init; }

    public static List<ScreenInfo> All()
    {
        var list = new List<ScreenInfo>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr h, IntPtr _, ref RECT r, IntPtr _) =>
        {
            var mi = new MONITORINFOEX();
            mi.cbSize = Marshal.SizeOf<MONITORINFOEX>();
            if (GetMonitorInfo(h, ref mi))
            {
                var bounds = new Rect(mi.rcMonitor.left, mi.rcMonitor.top,
                                      mi.rcMonitor.right - mi.rcMonitor.left,
                                      mi.rcMonitor.bottom - mi.rcMonitor.top);
                var key = $"{mi.szDevice}@{(int)bounds.Width}x{(int)bounds.Height}";
                list.Add(new ScreenInfo
                {
                    Key = key,
                    Label = mi.szDevice + (((mi.dwFlags & MONITORINFOF_PRIMARY) != 0) ? " (primary)" : ""),
                    Bounds = bounds,
                    IsPrimary = (mi.dwFlags & MONITORINFOF_PRIMARY) != 0,
                });
            }
            return true;
        }, IntPtr.Zero);
        return list;
    }

    // P/Invoke
    private const int MONITORINFOF_PRIMARY = 1;
    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MONITORINFOEX
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public int dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szDevice;
    }
    private delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT lprcMonitor, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumProc lpfnEnum, IntPtr dwData);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX lpmi);
}
