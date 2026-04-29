using System;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Input;

namespace MW;

[Flags]
public enum HotkeyMods : uint
{
    None  = 0,
    Alt   = 0x0001,
    Ctrl  = 0x0002,
    Shift = 0x0004,
    Win   = 0x0008,
}

public sealed class KeyCombo
{
    public HotkeyMods Mods { get; init; }
    public uint Vk { get; init; }

    public static readonly KeyCombo Default = new() { Mods = HotkeyMods.Alt, Vk = 0x20 /*VK_SPACE*/ };

    public override string ToString()
    {
        var s = "";
        if (Mods.HasFlag(HotkeyMods.Ctrl))  s += "Ctrl+";
        if (Mods.HasFlag(HotkeyMods.Alt))   s += "Alt+";
        if (Mods.HasFlag(HotkeyMods.Shift)) s += "Shift+";
        if (Mods.HasFlag(HotkeyMods.Win))   s += "Win+";
        s += KeyInterop.KeyFromVirtualKey((int)Vk).ToString();
        return s;
    }

    public static KeyCombo Load()
    {
        try
        {
            var path = System.IO.Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "mikkelsworkspace", "hotkey.json");
            if (!System.IO.File.Exists(path)) return Default;
            return JsonSerializer.Deserialize<KeyCombo>(System.IO.File.ReadAllText(path)) ?? Default;
        }
        catch { return Default; }
    }

    public void Save()
    {
        try
        {
            var dir = System.IO.Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "mikkelsworkspace");
            System.IO.Directory.CreateDirectory(dir);
            System.IO.File.WriteAllText(System.IO.Path.Combine(dir, "hotkey.json"),
                JsonSerializer.Serialize(this));
        }
        catch { }
    }
}

public sealed class HotkeyManager : IDisposable
{
    private const int WM_HOTKEY = 0x0312;
    private readonly System.Windows.Forms.NativeWindow _win;
    private int _id;
    private Action? _action;

    public HotkeyManager()
    {
        _win = new HotkeyWindow(msg => _action?.Invoke());
        ((HotkeyWindow)_win).CreateHandle(new System.Windows.Forms.CreateParams());
    }

    public bool Register(KeyCombo combo, Action action)
    {
        Unregister();
        _action = action;
        _id = 0xC0FE;
        return RegisterHotKey(_win.Handle, _id, (uint)combo.Mods, combo.Vk);
    }

    public void Unregister()
    {
        if (_id != 0) UnregisterHotKey(_win.Handle, _id);
        _id = 0;
        _action = null;
    }

    public void Dispose()
    {
        Unregister();
        _win.DestroyHandle();
    }

    private sealed class HotkeyWindow : System.Windows.Forms.NativeWindow
    {
        private readonly Action<int> _onHotkey;
        public HotkeyWindow(Action<int> onHotkey) { _onHotkey = onHotkey; }
        protected override void WndProc(ref System.Windows.Forms.Message m)
        {
            if (m.Msg == WM_HOTKEY) _onHotkey(m.WParam.ToInt32());
            base.WndProc(ref m);
        }
    }

    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}
