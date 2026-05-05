# MW — Mikkel's Workspace

A tiny menu-bar / system-tray app for snapping windows into custom-drawn regions across one or more displays. Available for **macOS** (Swift / AppKit) and **Windows 11** (WPF / .NET 8).

`MW` stands for **Mikkel's Workspace**. It was made out of need and curiosity about how to build an app like this — first for macOS, then ported to Windows.

- Repository: <https://github.com/MikkelIJ/MW>
- Releases: <https://github.com/MikkelIJ/MW/releases>

## Install — macOS

### Homebrew (recommended)

```sh
brew install --cask MikkelIJ/mw/mw
```

If Homebrew can't find the tap automatically, add it once:

```sh
brew tap MikkelIJ/mw https://github.com/MikkelIJ/MW.git
brew install --cask mw
```

Update with `brew upgrade --cask mw`. Uninstall with `brew uninstall --cask mw`.

### One-liner script (no Homebrew)

```sh
curl -fsSL https://raw.githubusercontent.com/MikkelIJ/MW/main/install.sh | bash
```

Pin a version: `… | MW_VERSION=v0.1.0 bash`. Change destination: `… | MW_DEST="$HOME/Applications" bash`.

The installer downloads `MW.zip` from the latest GitHub release, verifies its SHA-256, strips the macOS quarantine attribute, and copies `MW.app` into `/Applications`.

On first launch macOS will prompt for **Accessibility** permission (System Settings → Privacy & Security → Accessibility) — required to move other apps' windows.

## Install — Windows 11

In an elevated-or-normal PowerShell:

```powershell
irm https://raw.githubusercontent.com/MikkelIJ/MW/main/install.ps1 | iex
```

Pin a version: `$env:MW_VERSION='v0.2.0'; irm … | iex`. Change destination: `$env:MW_DEST="$env:LOCALAPPDATA\MW"; irm … | iex` (default).

The installer downloads `MW-windows-x64.zip`, verifies its SHA-256, extracts to `%LOCALAPPDATA%\MW`, and creates a Start Menu shortcut. The published binary is a self-contained single-file `MW.exe` (no .NET install required).

The Windows build is **not** signed; SmartScreen may show a warning the first time you run it.

## What it does
- Lives in the menu bar (no Dock icon, no main window).
- **Edit Regions for All Displays…** opens a translucent overlay; drag to draw rectangles, click an existing rectangle to delete, **Return** to save, **Esc** to cancel. Use **+** / **−** to adjust the grid size on the fly; the grid auto-fits each monitor as a perfect square cell sized from the main display.
- Press the configured hotkey (default **⌥Space**) anywhere to bring up the picker; click a region and the focused window snaps into it.
- Optional **instant snap** hotkeys jump the focused window straight to a numbered region without a picker. Region numbers are drawn inside each region in the editor and picker so you know which index is which.
- **Drag-to-snap** — grab any window's title bar and start dragging, then trigger the snap overlay one of these ways:
  - **Right-click** while dragging (mouse users). Each additional right-click cycles through overlapping regions under the cursor.
  - **Two-finger swipe** while dragging (trackpad users). Each swipe cycles. *Two-finger tap does **not** work* — macOS's multitouch driver suppresses every multi-finger tap or click while a one-finger drag is in progress, at every layer accessible to apps.
  - **Control (⌃)** as a keyboard fallback (Option ⌥ is reserved by macOS native window tiling).
  - Release the left mouse button while the overlay is up to drop the window into the highlighted region.
- Per-display profiles — regions are remembered for each monitor and reapplied when it reconnects.
- **About MW** menu item explains what the app is.

Regions are stored at `~/Library/Application Support/mikkelsworkspace/regions.json` as fractions of the screen, so they survive resolution changes.

## Build from source

### macOS
Requires Xcode command-line tools (Swift 5.9+) on macOS 13+.

```sh
git clone https://github.com/MikkelIJ/MW.git
cd MW
./build.sh
open build/mikkelsworkspace.app
```

### Windows
Requires the .NET 8 SDK on Windows 10/11.

Two GitHub Actions workflows are triggered when a `v*` tag is pushed:

- [.github/workflows/release.yml](.github/workflows/release.yml) — macOS build (`MW.zip` + `MW.zip.sha256`).
- [.github/workflows/release-windows.yml](.github/workflows/release-windows.yml) — Windows build (`MW-windows-x64.zip` + `MW-windows-x64.zip.sha256`).

Both upload to the same GitHub Release.

Cut a new release:

```sh
git tag v0.2.0
git push origin v0.2.0
```

Once both workflows finish, the `install.sh` and `install.ps1` one-liners pick up the new version automatically.

## Project layout
- [Sources/mikkelsworkspace/](Sources/mikkelsworkspace) — macOS Swift sources (AppKit).
- [windows/MW/](windows/MW) — Windows WPF / .NET 8 app.
- [windows/MW.sln](windows/MW.sln) — Visual Studio solution.
- [build.sh](build.sh) — macOS packaging script.
- [install.sh](install.sh) / [install.ps1](install.ps1) — release installers.
- [.github/workflows/](.github/workflows) — CI release pipelines.
- [Package.swift](Package.swift) — SwiftPM manifest.
- [tools/render-svg.swift](tools/render-svg.swift) — SVG → PNG rasterizer used by `build.sh`.
