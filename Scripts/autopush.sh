#!/bin/bash
# Auto-commit + push any changes in the CLIP repo. Runs from launchd every few
# minutes so work is backed up to GitHub without Claude spending credits on it.
cd /Users/sergei/clip || exit 0
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# LaunchAgent env is bare (no DEVELOPER_DIR) — set it here or `swift build`
# fails against the default CLT (no macOS 26 SDK).
export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
[ -z "$(git status --porcelain)" ] && exit 0          # nothing to do
git add -A
git commit -q -m "auto: snapshot $(date '+%Y-%m-%d %H:%M')" 2>/dev/null

# Build gate: never push a tree that doesn't compile. Commit lands locally
# either way (nothing lost) — a failed build just skips the push.
if swift build >/dev/null 2>&1; then
    git push -q origin HEAD 2>/dev/null
else
    echo "$(date '+%Y-%m-%d %H:%M') autopush: swift build FAILED — committed locally, push skipped"
fi
