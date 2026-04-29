# MW — Mikkel's Workspace

A tiny macOS menu-bar app for snapping windows into custom-drawn regions across one or more displays.

`MW` stands for **Mikkel's Workspace**. It was made out of need and curiosity about how to build an app like this for macOS.

- Repository: <https://github.com/MikkelIJ/MW>
- Clone: `git clone https://github.com/MikkelIJ/MW.git`
- Releases: <https://github.com/MikkelIJ/MW/releases>

## Install

One-liner (downloads the latest release from this repo and installs to `/Applications`):

```sh
curl -fsSL https://raw.githubusercontent.com/MikkelIJ/MW/main/install.sh | bash
```

Pin to a specific version:

```sh
curl -fsSL https://raw.githubusercontent.com/MikkelIJ/MW/main/install.sh | MW_VERSION=v0.1.0 bash
```

Install somewhere other than `/Applications`:

```sh
curl -fsSL https://raw.githubusercontent.com/MikkelIJ/MW/main/install.sh | MW_DEST="$HOME/Applications" bash
```

The installer:
- Resolves the latest (or pinned) release tag from GitHub.
- Downloads `MW.zip` and verifies its SHA-256 checksum.
- Strips the macOS quarantine attribute (the build is ad-hoc signed, not notarized).
- Copies `MW.app` into the destination, replacing any existing copy.

After install:

```sh
open /Applications/MW.app
```

On first launch macOS will prompt for **Accessibility** permission (System Settings → Privacy & Security → Accessibility). This is required to move other apps' windows.

## What it does
- Lives in the menu bar (no Dock icon, no main window).
- **Edit Regions for All Displays…** opens a translucent overlay; drag to draw rectangles, click an existing rectangle to delete, **Return** to save, **Esc** to cancel.
- Press the configured hotkey (default **⌥Space**) anywhere to bring up the picker; click a region and the focused window snaps into it.
- Optional **instant snap** hotkeys jump the focused window straight to a numbered region without a picker.
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

The build script compiles with SwiftPM, assembles a `.app` bundle (display name `MW`, executable `mikkelsworkspace`), generates an `.icns` from `icon.png`, and ad-hoc signs the result.

## Releasing

Releases are produced by the GitHub Actions workflow at [.github/workflows/release.yml](.github/workflows/release.yml). It runs on a macOS runner whenever a `v*` tag is pushed (or via manual dispatch) and:

1. Builds the app with `./build.sh release`.
2. Renames the bundle to `MW.app` and stamps the tag's version into `Info.plist`.
3. Re-signs ad-hoc, zips the bundle as `MW.zip`, and computes `MW.zip.sha256`.
4. Creates a GitHub Release with auto-generated notes and uploads both files.

Cut a new release:

```sh
git tag v0.2.0
git push origin v0.2.0
```

Once the workflow finishes, the `install.sh` one-liner picks up the new version automatically.

## Project layout
- [Sources/mikkelsworkspace/](Sources/mikkelsworkspace) — Swift sources.
- [build.sh](build.sh) — packaging script.
- [install.sh](install.sh) — release installer.
- [.github/workflows/release.yml](.github/workflows/release.yml) — release pipeline.
- [Package.swift](Package.swift) — SwiftPM manifest.
