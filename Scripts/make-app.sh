#!/bin/bash
#
# Wrap the built `swift build` binary into a real CLIP.app bundle: app icon,
# ONY Semimono fonts, version stamp, the self-update feed URL, an ad-hoc code
# signature, and (optionally) a distributable .zip.
#
# On macOS 26 (Tahoe) the system masks the icon to the squircle and applies
# the Liquid Glass material automatically to the bundled .icns.
#
# Usage:
#   swift build -c release
#   Scripts/make-app.sh                          # → ./CLIP.app  (dev: no feed, no update)
#   MARKETING=1.2 BUILD=14 Scripts/make-app.sh    # stamp version (BUILD must increase per release)
#   FEED_URL="https://raw.githubusercontent.com/<user>/clip/main/appcast/latest.json" \
#     MARKETING=1.2 BUILD=14 ZIP=1 Scripts/make-app.sh /Applications
#
# Env:
#   CONFIG    build config dir under .build (default: release)
#   MARKETING marketing version string  (default 1.0)
#   BUILD     integer build number       (default 1) — the updater compares this
#   FEED_URL  update manifest URL; omit/empty ⇒ this build never self-updates (dev)
#   ZIP=1     also emit CLIP-<MARKETING>.zip next to the .app (for GitHub Releases)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
BIN="$ROOT/.build/$CONFIG/CLIP"
ICON="$ROOT/AppIcon/AppIcon.icns"
MARKETING="${MARKETING:-1.0}"
BUILD="${BUILD:-1}"
FEED_URL="${FEED_URL:-}"

DEST_DIR="${1:-$ROOT}"
APP="$DEST_DIR/CLIP.app"
PB=/usr/libexec/PlistBuddy

[ -f "$BIN" ]  || { echo "✗ no binary at $BIN — run: swift build -c $CONFIG"; exit 1; }
[ -f "$ICON" ] || { echo "✗ no icon at $ICON"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN"  "$APP/Contents/MacOS/CLIP"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

# Bundle the ONY Semimono fonts so Font.custom resolves them on any machine.
if [ -d "$ROOT/Fonts" ]; then
  mkdir -p "$APP/Contents/Resources/Fonts"
  cp "$ROOT/Fonts/"*.otf "$APP/Contents/Resources/Fonts/" 2>/dev/null || true
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>CLIP</string>
  <key>CFBundleDisplayName</key><string>CLIP</string>
  <key>CFBundleExecutable</key><string>CLIP</string>
  <key>CFBundleIdentifier</key><string>com.clip.app</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Stamp version + (optional) update feed URL.
"$PB" -c "Set :CFBundleShortVersionString $MARKETING" "$APP/Contents/Info.plist"
"$PB" -c "Set :CFBundleVersion $BUILD"                 "$APP/Contents/Info.plist"
if [ -n "$FEED_URL" ]; then
  "$PB" -c "Add :CLIPFeedURL string $FEED_URL" "$APP/Contents/Info.plist" 2>/dev/null \
    || "$PB" -c "Set :CLIPFeedURL $FEED_URL" "$APP/Contents/Info.plist"
fi

# Ad-hoc sign: a stable signature so the app launches cleanly and survives the
# in-place self-update swap. Still "unsigned" to Gatekeeper (no Developer ID).
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

# Nudge LaunchServices + the icon cache so Finder/Dock pick up the new icon.
/usr/bin/touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true

echo "✓ built $APP  (v$MARKETING build $BUILD${FEED_URL:+, feed set})"

# Distributable archive for GitHub Releases.
if [ "${ZIP:-}" = "1" ]; then
  ZIP_PATH="$DEST_DIR/CLIP-$MARKETING.zip"
  rm -f "$ZIP_PATH"
  ( cd "$DEST_DIR" && /usr/bin/ditto -c -k --keepParent "CLIP.app" "$ZIP_PATH" )
  echo "✓ zipped $ZIP_PATH"
  echo "  sha256: $(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
fi
