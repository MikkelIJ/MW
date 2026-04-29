using System;
using System.Windows;

namespace MW;

public partial class App : Application
{
    private TrayController? _tray;
    private HotkeyManager? _hotkeys;
    private RegionStore _store = new();
    private KeyCombo _hotkey = KeyCombo.Default;

    private void OnStartup(object sender, StartupEventArgs e)
    {
        _store.Load();
        _hotkey = KeyCombo.Load();

        _hotkeys = new HotkeyManager();
        if (!_hotkeys.Register(_hotkey, ShowPicker))
            MessageBox.Show($"Couldn't register hotkey {_hotkey}. Another app may be using it.",
                "MW", MessageBoxButton.OK, MessageBoxImage.Warning);

        _tray = new TrayController(
            onShowPicker: ShowPicker,
            onEditRegions: ShowEditor,
            onAbout: ShowAbout,
            onCheckUpdates: () => UpdateChecker.CheckAsync(showWhenUpToDate: true),
            onQuit: () => Shutdown());

        _ = UpdateChecker.CheckAsync(showWhenUpToDate: false);
    }

    private void OnExit(object sender, ExitEventArgs e)
    {
        _hotkeys?.Dispose();
        _tray?.Dispose();
    }

    private void ShowPicker()
    {
        var screens = ScreenInfo.All();
        var win = new PickerWindow(_store, screens, OnRegionPicked);
        win.Show();
    }

    private void OnRegionPicked(Region region)
    {
        var hwnd = WindowMover.GetForegroundWindowSafe();
        if (hwnd == IntPtr.Zero) return;
        WindowMover.MoveTo(hwnd, region.PixelRect);
    }

    private void ShowEditor()
    {
        var screens = ScreenInfo.All();
        var win = new EditorWindow(_store, screens);
        win.Show();
    }

    private void ShowAbout()
    {
        MessageBox.Show(
            "MW stands for Mikkel's Workspace.\n\n" +
            "It was made out of need and curiosity about how to build an app like this — first " +
            "for macOS, now for Windows.",
            "About MW", MessageBoxButton.OK, MessageBoxImage.Information);
    }
}
