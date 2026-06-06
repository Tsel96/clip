#!/bin/bash
#
# Set up the exhibition Mac mini as a CLIP kiosk:
#   • install CLIP.app into /Applications
#   • install + load a LaunchAgent that auto-starts CLIP at login and
#     relaunches it if it ever quits/crashes (and after a self-update swap)
#   • print the one-time energy / auto-login steps that need admin or the GUI
#
# Usage:
#   swift build -c release
#   FEED_URL="https://raw.githubusercontent.com/<user>/clip/main/appcast/latest.json" \
#     MARKETING=1.0 BUILD=1 Scripts/make-app.sh        # build ./CLIP.app with the feed
#   Scripts/install-kiosk.sh                            # install + load the kiosk agent
#
# Re-run any time to update the installed app + reload the agent.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_APP="${1:-$ROOT/CLIP.app}"
DEST_APP="/Applications/CLIP.app"
AGENT_SRC="$ROOT/LaunchAgents/com.clip.app.plist"
AGENT_DST="$HOME/Library/LaunchAgents/com.clip.app.plist"
LABEL="com.clip.app"

[ -d "$SRC_APP" ]   || { echo "✗ no app at $SRC_APP — build it with Scripts/make-app.sh"; exit 1; }
[ -f "$AGENT_SRC" ] || { echo "✗ missing $AGENT_SRC"; exit 1; }

echo "→ installing $SRC_APP → $DEST_APP"
# Unload first so we're not copying over a running, launchd-managed app.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
sleep 1
rm -rf "$DEST_APP"
/usr/bin/ditto "$SRC_APP" "$DEST_APP"
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true

echo "→ installing LaunchAgent → $AGENT_DST"
mkdir -p "$HOME/Library/LaunchAgents"
cp "$AGENT_SRC" "$AGENT_DST"

echo "→ loading LaunchAgent (auto-start + auto-relaunch)"
launchctl bootstrap "gui/$UID" "$AGENT_DST"
launchctl enable "gui/$UID/$LABEL" 2>/dev/null || true
launchctl kickstart "gui/$UID/$LABEL" 2>/dev/null || true

cat <<'NOTE'

✓ CLIP kiosk installed.
  • Auto-starts at login and relaunches itself if it quits/crashes.
  • The app self-updates from its feed within ~10 minutes of a new release.

One-time settings to finish the kiosk (need admin / the GUI):
  1. Never sleep (display + system):
       sudo pmset -a sleep 0 displaysleep 0 disksleep 0
  2. Auto-login the exhibition account:
       System Settings ▸ Users & Groups ▸ Automatically log in as …
  3. (Optional) hide the Dock / disable screensaver for a clean booth.

To remove later:
     launchctl bootout gui/$UID/com.clip.app
     rm -f ~/Library/LaunchAgents/com.clip.app.plist
NOTE
