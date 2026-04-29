#!/usr/bin/env bash
# Install MW (Mikkel's Workspace) from the latest GitHub release.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/MikkelIJ/MW/main/install.sh | bash
#
# Environment:
#   MW_VERSION   Specific tag to install (e.g. v0.2.0). Defaults to latest.
#   MW_DEST      Install destination directory. Defaults to /Applications.
#
set -euo pipefail

REPO="MikkelIJ/MW"
DEST="${MW_DEST:-/Applications}"
APP_NAME="MW.app"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "MW only runs on macOS." >&2
  exit 1
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }; }
need curl
need ditto
need shasum

API="https://api.github.com/repos/${REPO}"
if [[ -n "${MW_VERSION:-}" ]]; then
  TAG="$MW_VERSION"
else
  echo "→ Looking up latest release…"
  TAG=$(curl -fsSL "${API}/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)
  if [[ -z "$TAG" ]]; then
    echo "Could not determine latest release tag." >&2
    exit 1
  fi
fi
echo "→ Installing MW $TAG"

ZIP_URL="https://github.com/${REPO}/releases/download/${TAG}/MW.zip"
SHA_URL="https://github.com/${REPO}/releases/download/${TAG}/MW.zip.sha256"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "→ Downloading $ZIP_URL"
curl -fSL --progress-bar "$ZIP_URL" -o "$TMP/MW.zip"

echo "→ Verifying checksum"
if curl -fsSL "$SHA_URL" -o "$TMP/MW.zip.sha256" 2>/dev/null; then
  ( cd "$TMP" && shasum -a 256 -c MW.zip.sha256 )
else
  echo "  (no published checksum, skipping verification)"
fi

echo "→ Extracting"
ditto -x -k "$TMP/MW.zip" "$TMP"

if [[ ! -d "$TMP/$APP_NAME" ]]; then
  echo "Archive did not contain $APP_NAME" >&2
  exit 1
fi

# Remove quarantine so Gatekeeper won't refuse the ad-hoc signed bundle.
xattr -dr com.apple.quarantine "$TMP/$APP_NAME" 2>/dev/null || true

INSTALL_PATH="$DEST/$APP_NAME"
SUDO=""
if [[ ! -w "$DEST" ]]; then
  SUDO="sudo"
  echo "→ $DEST is not writable, will use sudo"
fi

if [[ -d "$INSTALL_PATH" ]]; then
  echo "→ Removing existing $INSTALL_PATH"
  $SUDO rm -rf "$INSTALL_PATH"
fi

echo "→ Installing to $INSTALL_PATH"
$SUDO ditto "$TMP/$APP_NAME" "$INSTALL_PATH"

echo "✓ Installed MW $TAG to $INSTALL_PATH"
echo "  Launch with: open \"$INSTALL_PATH\""
echo "  On first launch macOS will prompt for Accessibility permission."
