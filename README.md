# MW — Mikkel's Workspace

A tiny menu-bar app for snapping windows into custom-drawn regions across one or more displays. **macOS** only (Swift / AppKit).

`MW` stands for **Mikkel's Workspace**. It was made out of need and curiosity about how to build an app like this for macOS.

- Repository: <https://github.com/MikkelIJ/MW>
- Releases: <https://github.com/MikkelIJ/MW/releases>

## Install — macOS

### Homebrew (recommended)

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

## What it does
- Lives in the menu bar (no Dock icon, no main window).
- **Edit Regions for All Displays…** opens a translucent overlay; drag to draw rectangles, click an existing rectangle to delete, **Return** to save, **Esc** to cancel. Use **+** / **−** to adjust the grid size on the fly; the grid auto-fits each monitor as a perfect square cell sized from the main display.
- Press the configured hotkey (default **⌥Space**) anywhere to bring up the picker; click a region and the focused window snaps into it.
- Optional **instant snap** hotkeys jump the focused window straight to a numbered region without a picker. Region numbers are drawn inside each region in the editor and picker so you know which index is which.
- **Drag-to-snap** — grab any window's title bar and start dragging, then trigger the snap overlay one of these ways:
  - **Right-click** while dragging (mouse users). Each additional right-click cycles through overlapping regions under the cursor.
  - **Shift (⇧)** while dragging (trackpad users — macOS suppresses every multi-finger gesture during a one-finger drag at every layer accessible to apps; modifier keys are the only secondary input that survives, and ⌥ is reserved by macOS native window tiling). Each additional ⇧ press cycles.
  - Release the left mouse button while the overlay is up to drop the window into the highlighted region.
- Per-display profiles — regions are remembered for each monitor and reapplied when it reconnects.
- **About MW** menu item explains what the app is.

Regions are stored at `~/Library/Application Support/mikkelsworkspace/regions.json` as fractions of the screen, so they survive resolution changes.

## Build from source

Requires Xcode command-line tools (Swift 5.9+) on macOS 13+.

```sh
git clone https://github.com/MikkelIJ/MW.git
cd MW
./build.sh
open build/mikkelsworkspace.app
```

[.github/workflows/release.yml](.github/workflows/release.yml) builds and publishes `MW.zip` + `MW.zip.sha256` to a GitHub Release whenever a `v*` tag is pushed.

Cut a new release:

```sh
git tag v0.2.0
git push origin v0.2.0
```

Once the workflow finishes, the `install.sh` one-liner and the Homebrew cask pick up the new version automatically.

## Project layout
- [Sources/mikkelsworkspace/](Sources/mikkelsworkspace) — Swift sources (AppKit).
- [build.sh](build.sh) — macOS packaging script.
- [install.sh](install.sh) — release installer.
- [.github/workflows/](.github/workflows) — CI release pipeline.
- [Package.swift](Package.swift) — SwiftPM manifest.
- [tools/render-svg.swift](tools/render-svg.swift) — SVG → PNG rasterizer used by `build.sh`.
