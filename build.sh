#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-release}"
APP_NAME="SnapRegions"
DISPLAY_NAME="MW"
BUNDLE_ID="local.snapregions"

echo "→ Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
APP_DIR="build/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"

echo "→ Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$CONTENTS/Resources"
cp "$BIN_PATH" "$MACOS/$APP_NAME"

# Build AppIcon.icns from icon.png if present.
ICON_SRC="icon.png"
ICON_NAME="AppIcon"
if [[ -f "$ICON_SRC" ]]; then
  echo "→ Building $ICON_NAME.icns from $ICON_SRC"
  ICONSET_DIR="build/${ICON_NAME}.iconset"
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"
  for spec in \
    "16   icon_16x16.png" \
    "32   icon_16x16@2x.png" \
    "32   icon_32x32.png" \
    "64   icon_32x32@2x.png" \
    "128  icon_128x128.png" \
    "256  icon_128x128@2x.png" \
    "256  icon_256x256.png" \
    "512  icon_256x256@2x.png" \
    "512  icon_512x512.png" \
    "1024 icon_512x512@2x.png"
  do
    size="${spec%% *}"
    name="${spec##* }"
    sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET_DIR/$name" >/dev/null
  done
  iconutil -c icns "$ICONSET_DIR" -o "$CONTENTS/Resources/${ICON_NAME}.icns"
  cp "$ICON_SRC" "$CONTENTS/Resources/MenuBarIcon.png"
  ICON_PLIST_KEY="<key>CFBundleIconFile</key><string>${ICON_NAME}</string>"
else
  ICON_PLIST_KEY=""
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>${DISPLAY_NAME}</string>
  <key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  ${ICON_PLIST_KEY}
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# Ad-hoc sign so TCC (Accessibility) can identify the bundle stably.
codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "✓ Built $APP_DIR"
echo "  Run with: open $APP_DIR"
