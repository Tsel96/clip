#!/bin/bash
# Auto-commit + push any changes in the CLIP repo. Runs from launchd every few
# minutes so work is backed up to GitHub without Claude spending credits on it.
cd /Users/sergei/clip || exit 0
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
[ -z "$(git status --porcelain)" ] && exit 0          # nothing to do
# Never auto-push main: pushes to main publish a release that every installed
# copy (incl. the exhibition kiosk) auto-installs. Snapshot work branches only.
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
case "$BRANCH" in main|master|HEAD) exit 0 ;; esac
git add -A
git commit -q -m "auto: snapshot $(date '+%Y-%m-%d %H:%M')" 2>/dev/null
git push -q origin "$BRANCH" 2>/dev/null
