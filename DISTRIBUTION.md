# CLIP — distribution & exhibition runbook

Everything needed to ship CLIP, run it unattended at the show, and push silent
self-updates. Built for a **free Apple ID** (unsigned, ad-hoc signed) + GitHub
Releases + a Vercel landing page (Netlify was the original plan; `netlify.toml`
is still in the repo but is legacy — see step 2).

## 0. One-time setup
1. **GitHub repo** (must be **public** — raw appcast + release downloads need
   public access): create `github.com/<you>/clip`, then locally:
   ```sh
   git remote add origin git@github.com:<you>/clip.git
   git push -u origin main
   ```
2. Decide the **feed URL** (the manifest every app polls):
   `https://raw.githubusercontent.com/<you>/clip/main/appcast/latest.json`

## 1. Cut a release (build → publish → everyone updates)
```sh
export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"  # release.sh's swift build needs it
MARKETING=1.0 BUILD=1 Scripts/release.sh
```
This builds, packages `CLIP.app` (icon + fonts + feed URL baked in), zips it,
publishes a GitHub Release `v1.0`, writes `appcast/latest.json`
(build/version/url/sha256), and pushes. **Bump `BUILD` every release** — the
updater compares it. Installed copies (kiosk + public) update within ~10 min.

`.github/workflows/release.yml` is MANUAL-ONLY (workflow_dispatch) as of
2026-07-13: its old push trigger shipped mid-session autopush snapshots as
the public `releases/latest` dmg, and it writes an UNSIGNED latest.json
that builds ≥9045 refuse (updates are Ed25519-signed; the key lives only
in `~/.clip-release/` on the release machine). The one supported release
path is local `Scripts/release.sh` — it builds, signs the manifest, and
publishes the GitHub Release. If the workflow is ever revived, re-verify
`runs-on: macos-26` still resolves and that Actions isn't billing-blocked.

## 2. Landing page (`site/`)
One-viewport page (`site/index.html` + `style.css` + icon + fonts). Before
first deploy, fill in the two placeholders in `index.html`:
- `DOWNLOAD_URL_HERE` → `https://github.com/<you>/clip/releases/latest/download/CLIP-<ver>.zip`
- `SHORTCUT_URL_HERE` → your iCloud Shortcut share link (step 4)

**Live host is Vercel**, not Netlify: `cd site && npx vercel --prod`
(project `clip-umprum`, currently live at `clip-umprum.vercel.app`). The
`netlify.toml` at repo root is left over from an earlier plan (publish dir
`site`) and is unused — Netlify isn't the deploy target, don't reach for it
unless you're deliberately moving hosts.

## 3. Exhibition Mac mini (kiosk)
```sh
DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer" swift build -c release
FEED_URL="https://raw.githubusercontent.com/<you>/clip/main/appcast/latest.json" \
  MARKETING=1.0 BUILD=1 Scripts/make-app.sh
Scripts/install-kiosk.sh
```
Installs to `/Applications`, auto-starts at login, relaunches on crash, and
self-updates. Then finish (admin/GUI): `sudo pmset -a sleep 0 displaysleep 0`,
and System Settings ▸ Users & Groups ▸ Automatic login.

## 4. Send links from iPhone (existing Shortcut — no app)
CLIP watches an iCloud Drive folder (`SharedLinkInbox`); the **"Add to Canvas"**
Shortcut drops the shared URL there.
- On the Mac mini + your phone: sign into the **same iCloud account**.
- In CLIP: **File ▸ Set Shared-Links Folder…** → pick an iCloud Drive folder.
- Build the Shortcut: *Share Sheet → receives URLs → Save File to that folder*
  (text = the URL). Share it (Shortcut ▸ Share ▸ Copy iCloud Link) and put that
  link on the site.

## Notes / gotchas
- **Unsigned**: first launch of a downloaded copy = right-click → **Open** once.
- **Self-update swap** strips the quarantine xattr and relaunches via a
  detached helper; user data in `~/Library/Application Support/CLIP` is never
  touched. Test the full download→swap→relaunch loop **on the Mac mini** before
  the show.
- Dev builds (no `FEED_URL`) never self-update.
