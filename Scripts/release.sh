#!/bin/bash
#
# Cut a CLIP release: build → package (versioned, signed, zipped) → publish a
# GitHub Release → update the update manifest the kiosk/public apps poll.
#
# Every installed copy (kiosk + public) picks it up within ~10 min.
#
# Prereqs (one-time): `gh auth login`; a GitHub repo; the repo's raw
# appcast URL baked into builds as FEED_URL (see below).
#
# Usage:
#   MARKETING=1.1 BUILD=2 Scripts/release.sh
#
# Env:
#   MARKETING   marketing version (e.g. 1.1)            [required]
#   BUILD       integer build number, must increase      [required]
#   REPO        GitHub "owner/name" (default: git origin)
#   BRANCH      branch the appcast lives on (default: main)
#   NOTES       release notes string
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

: "${MARKETING:?set MARKETING, e.g. 1.1}"
: "${BUILD:?set BUILD, e.g. 2}"
BRANCH="${BRANCH:-main}"
NOTES="${NOTES:-Update $MARKETING}"

# Resolve REPO from the git remote if not given (owner/name).
REPO="${REPO:-$(git config --get remote.origin.url 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s/\.git$//')}"
[ -n "$REPO" ] || { echo "✗ set REPO=owner/name (no git origin found)"; exit 1; }

TAG="v$MARKETING"
ZIP="CLIP.zip"
RAW_FEED="https://raw.githubusercontent.com/$REPO/$BRANCH/appcast/latest.json"
ZIP_URL="https://github.com/$REPO/releases/download/$TAG/$ZIP"

echo "→ building release binary"
swift build -c release

echo "→ packaging CLIP.app (feed baked in) + $ZIP"
FEED_URL="$RAW_FEED" MARKETING="$MARKETING" BUILD="$BUILD" ZIP=1 Scripts/make-app.sh "$ROOT" >/dev/null
SHA=$(shasum -a 256 "$ROOT/$ZIP" | awk '{print $1}')
echo "  sha256 $SHA"

echo "→ writing appcast/latest.json"
cat > "$ROOT/appcast/latest.json" <<JSON
{
  "build": $BUILD,
  "version": "$MARKETING",
  "url": "$ZIP_URL",
  "sha256": "$SHA",
  "notes": "$NOTES"
}
JSON

echo "→ publishing GitHub Release $TAG"
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$ROOT/$ZIP" --clobber
else
  gh release create "$TAG" "$ROOT/$ZIP" --title "CLIP $MARKETING" --notes "$NOTES"
fi

echo "→ committing + pushing the manifest"
git add appcast/latest.json
git commit -m "release: $MARKETING (build $BUILD)" >/dev/null
git push origin "$BRANCH"

echo "✓ released $MARKETING (build $BUILD). Installs update within ~10 min."
echo "  feed: $RAW_FEED"
