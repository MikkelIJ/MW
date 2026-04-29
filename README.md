# SnapRegions

A tiny macOS menu-bar app for snapping windows into custom-drawn regions.

## What it does
- Lives in the menu bar (no Dock icon, no main window).
- **Edit Regions…** opens a translucent overlay; drag to draw rectangles, click an existing rectangle to delete, **Return** to save, **Esc** to cancel.
- Press **⌥Space** anywhere to bring up the picker; click a region and the currently-focused window snaps into it.

## Build & run
Requires Xcode command-line tools (Swift 5.9+) on macOS 13+.

```sh
./build.sh
open build/SnapRegions.app
```

On first launch macOS will prompt to grant **Accessibility** access (System Settings → Privacy & Security → Accessibility). This is required to move other apps' windows.

Regions are stored at `~/Library/Application Support/SnapRegions/regions.json` as fractions of the main screen, so they survive resolution changes.

## Notes / limitations
- v1 targets the main display only.
- The hotkey is hard-coded to ⌥Space. Edit `registerHotkey()` in [Sources/SnapRegions/AppDelegate.swift](Sources/SnapRegions/AppDelegate.swift) to change it.
# MW
