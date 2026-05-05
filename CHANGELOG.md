# Changelog

## v0.7.27 — 2026-05-05

### Changed
- Snap overlay now darkens every display that isn't the one you're
  currently targeting, so on multi-monitor setups it's immediately
  obvious which screen the snap will land on. Focus follows your
  cursor in both drag-mode and the keyboard/click picker; in the
  picker, focus starts on the screen that owns the active window.

## v0.7.26 — 2026-05-05

### Added
- New **Report a Bug…** menu item opens a form where you describe the
  problem, press **Start Recording** to capture debug logs while you
  reproduce it, then **Send Bug Report** to open a prefilled GitHub
  issue with the description, environment info, and the captured log
  slice. Recording leaves your existing debug-logging preference
  unchanged. If the captured log is too large to fit in the URL, the
  full report is copied to your clipboard so you can paste it into
  the issue body.

## v0.7.25 — 2026-05-05

### Added
- `brew install --cask mw` and `brew upgrade --cask mw` now print the
  release notes for the installed version as caveats, so you can see
  what changed without leaving the terminal. The release pipeline
  injects the matching `CHANGELOG.md` section into the cask on every
  tagged release.

## v0.7.24 — 2026-05-05

### Added
- `CHANGELOG.md` now drives the body of every GitHub Release — the
  release pipeline extracts the section matching the pushed tag and
  posts it as the release notes.
- Repository `.github/copilot-instructions.md` documents the release-notes
  workflow so every future change ships with a curated entry.

### Changed
- Homebrew cask is now pinned to a real version + `sha256` (was
  `:latest` / `:no_check`), so `brew upgrade --cask mw` shows
  `Upgrading mw 0.7.x -> 0.7.y` instead of treating every release as a
  reinstall. The release pipeline auto-bumps the cask on every tag.

## v0.7.23 — 2026-05-05

### Changed
- Drag-to-snap now uses **Shift (⇧)** as the trackpad trigger
  (previously `⌃`). Right-click still works for mouse users. Each
  Shift-press while dragging shows the overlay or cycles to the next
  overlapping region; the overlay stays up after release so you can
  drop without holding the key.

### Removed
- Internal listeners that produced no events mid-drag (gesture monitor,
  scroll-wheel handler, extra-mouse-button handler, control-key handler)
  were removed for ~185 fewer lines.

## v0.7.22 — 2026-05-05

### Changed
- Documented in code and README that two-finger trackpad tap during a
  drag cannot be detected — macOS's multitouch driver suppresses every
  multi-finger gesture below the lowest user-space event tap while a
  one-finger physical click is held.

## v0.7.21 — 2026-05-05

### Fixed
- Toggling **Debug Logging** off in the menu bar now actually closes
  the log viewer. The viewer is an in-app window backed by a file
  watcher (no polling); previous versions spawned Terminal.app, which
  couldn't be closed without an extra automation permission prompt.

## v0.7.20 — 2026-05-05

### Changed
- Drag-snap event tap is now hosted at the HID level
  (`.cghidEventTap`) for a brief diagnostic period; reverted in
  v0.7.22 once it was confirmed to make no difference.

## v0.7.19 — 2026-05-05

### Added
- Drag-snap monitor now also listens for trackpad gesture events
  (`beginGesture`/`magnify`/`swipe`/`smartMagnify`/`pressure`),
  scroll-wheel, and other mouse buttons during a drag (later trimmed
  in v0.7.23 to just the working triggers).

## v0.7.18 — 2026-05-05

### Changed
- Trackpad drag-snap trigger switched from **Option (⌥)** to
  **Control (⌃)** since macOS 15+ reserves ⌥ for native window tiling.
  Updated README to document the full drag-to-snap workflow.

## v0.7.17 — 2026-05-05

### Added
- **Option (⌥)** as a parallel drag-snap trigger for trackpad users
  (later moved to ⌃ in v0.7.18, then to ⇧ in v0.7.23).

## v0.7.16 — 2026-05-05

### Changed
- Drag-snap overlay now appears on right-mouse **release** (was: on
  press), so the gesture matches normal click feedback.

## v0.7.15 — 2026-05-05

### Changed
- Hold-right-button-to-show model: the overlay's region cycle index
  is preserved across show/hide so quickly tapping right cycles
  through overlapping regions even between presses.

## v0.7.14 — 2026-05-05

### Changed
- Snap overlay only appears after the first right-click during a
  drag (previously appeared as soon as the drag was confirmed).

## v0.7.13 — 2026-05-05

### Fixed
- Right-click during a window drag now reliably shows the overlay.
  The CGEventTap that watches for it is hosted on a dedicated
  background thread so AppKit's window-drag tracking loop on the
  main thread can never starve it.

## v0.7.12 — 2026-05-05

### Fixed
- Snap-region resize now follows the mouse exactly (was lagging due
  to repeatedly mutating the resize anchor each tick).

## v0.7.11 — 2026-05-05

### Added
- Editor and snap overlay use perfect square cells sized from the
  main display's grid setting; non-main monitors derive their column
  and row counts from that cell size.
- **Cells across main display** is now a single Preferences value.
- A live grid preview overlays the screen briefly when you change the
  value.
- **+** and **−** in the editor adjust the grid size on the fly.

## v0.7.10 — 2026-05-05

### Added
- Snap-region grid adapts to each monitor's size.
- Each region is numbered in the editor and picker overlays.
- Right-click while a window snaps cycles through overlapping regions
  under the cursor.
