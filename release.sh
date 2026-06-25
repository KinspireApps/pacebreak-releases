#!/usr/bin/env bash
#
# release.sh — sign a PaceBreak DMG, update appcast.xml, and publish a GitHub release.
#
# Usage:
#   ./release.sh --version 1.1 --build 2 [--dmg path/to/PaceBreak.dmg] [--min-system 14.0]
#
# What it does:
#   1. Locates Sparkle's sign_update and signs the DMG with your Keychain EdDSA key.
#   2. Inserts a new <item> at the top of appcast.xml (with signature + length).
#   3. Creates GitHub Release vX.Y and uploads the DMG as an asset.
#   4. Commits and pushes appcast.xml.
#
# Requirements:
#   - Sparkle's sign_update on PATH, or set SIGN_UPDATE=/path/to/sign_update
#   - gh CLI authenticated (run: gh auth status)
#   - The EdDSA private key in the macOS Keychain (from Sparkle's generate_keys)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPCAST="$REPO_DIR/appcast.xml"
GH_REPO="KinspireApps/pacebreak-releases"
MARKER="<!-- NEW RELEASES INSERTED BELOW -->"
ITEM_FILE=""
MOUNT_POINT=""
MOUNTED_DMG=""

cleanup() {
  if [[ -n "$MOUNTED_DMG" && -n "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]] && rmdir "$MOUNT_POINT" 2>/dev/null || true
  [[ -n "$ITEM_FILE" ]] && rm -f "$ITEM_FILE"
  rm -f "$APPCAST.tmp"
}
trap cleanup EXIT

VERSION=""
BUILD=""
DMG="$REPO_DIR/PaceBreak.dmg"
MIN_SYSTEM="14.0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)    VERSION="$2"; shift 2;;
    --build)      BUILD="$2"; shift 2;;
    --dmg)        DMG="$2"; shift 2;;
    --min-system) MIN_SYSTEM="$2"; shift 2;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "Unknown argument: $1" >&2; exit 1;;
  esac
done

[[ -n "$VERSION" ]] || { echo "Missing --version (e.g. 1.1)" >&2; exit 1; }
[[ -n "$BUILD"   ]] || { echo "Missing --build (integer, e.g. 2)" >&2; exit 1; }
[[ -f "$DMG"     ]] || { echo "DMG not found: $DMG" >&2; exit 1; }
grep -q "$MARKER" "$APPCAST" || { echo "Marker not found in appcast.xml — cannot insert." >&2; exit 1; }

# --- Verify DMG bundle metadata ------------------------------------------
MOUNT_POINT="$(mktemp -d "${TMPDIR:-/tmp}/pacebreak-dmg.XXXXXX")"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT_POINT" >/dev/null
MOUNTED_DMG=1
INFO_PLIST="$(find "$MOUNT_POINT" -maxdepth 4 -path '*/Contents/Info.plist' -print -quit)"
[[ -n "$INFO_PLIST" ]] || { echo "Could not find an app Info.plist inside $DMG" >&2; exit 1; }

DMG_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
DMG_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"

[[ "$DMG_VERSION" == "$VERSION" ]] || {
  echo "Version mismatch: --version is $VERSION, but DMG contains $DMG_VERSION" >&2
  exit 1
}
[[ "$DMG_BUILD" == "$BUILD" ]] || {
  echo "Build mismatch: --build is $BUILD, but DMG contains $DMG_BUILD" >&2
  exit 1
}

hdiutil detach "$MOUNT_POINT" >/dev/null
MOUNTED_DMG=""
rmdir "$MOUNT_POINT" 2>/dev/null || true
MOUNT_POINT=""

# --- Locate sign_update ---------------------------------------------------
SIGN_UPDATE="${SIGN_UPDATE:-}"
[[ -z "$SIGN_UPDATE" ]] && SIGN_UPDATE="$(command -v sign_update 2>/dev/null || true)"
[[ -z "$SIGN_UPDATE" ]] && SIGN_UPDATE="$(find "$HOME/Library/Developer/Xcode/DerivedData" -name sign_update -type f 2>/dev/null | grep -v old_dsa_scripts | head -n1 || true)"
[[ -n "$SIGN_UPDATE" && -x "$SIGN_UPDATE" ]] || {
  echo "sign_update not found. Install Sparkle and/or set SIGN_UPDATE=/path/to/sign_update" >&2
  exit 1
}

# --- Compute metadata -----------------------------------------------------
TAG="v$VERSION"
LENGTH="$(stat -f%z "$DMG")"
PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
URL="https://github.com/$GH_REPO/releases/download/$TAG/PaceBreak.dmg"

# sign_update prints e.g.:  sparkle:edSignature="abc==" length="123"
SIGN_OUTPUT="$("$SIGN_UPDATE" "$DMG")"
ED_SIG="$(printf '%s' "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
[[ -n "$ED_SIG" ]] || { echo "Could not parse signature from sign_update output: $SIGN_OUTPUT" >&2; exit 1; }

# --- Build and insert the new <item> --------------------------------------
ITEM="        <item>
            <title>Version $VERSION</title>
            <pubDate>$PUBDATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
            <enclosure
                url=\"$URL\"
                sparkle:edSignature=\"$ED_SIG\"
                length=\"$LENGTH\"
                type=\"application/octet-stream\"/>
        </item>"

# Insert via a temp file: passing a multi-line string through `awk -v` breaks
# on macOS/BSD awk ("newline in string"), so awk reads the item with getline.
ITEM_FILE="$(mktemp)"
printf '%s\n' "$ITEM" > "$ITEM_FILE"

awk -v itemfile="$ITEM_FILE" -v marker="$MARKER" '
  { print }
  index($0, marker) {
    while ((getline line < itemfile) > 0) print line
    close(itemfile)
  }
' "$APPCAST" > "$APPCAST.tmp" && mv "$APPCAST.tmp" "$APPCAST"
echo "✓ appcast.xml updated for $TAG (length=$LENGTH)"

# --- Publish GitHub Release ----------------------------------------------
gh release create "$TAG" "$DMG" \
  --repo "$GH_REPO" \
  --title "PaceBreak $VERSION" \
  --notes "PaceBreak $VERSION"
echo "✓ GitHub release $TAG published with DMG asset"

# --- Commit appcast -------------------------------------------------------
git -C "$REPO_DIR" add appcast.xml
git -C "$REPO_DIR" commit -m "Release $TAG"
git -C "$REPO_DIR" push
echo "✓ appcast.xml committed and pushed"

# --- Trigger kinspiretech.com redeploy so the site shows the new version ---
# Create a Deploy Hook in Cloudflare Pages and expose its URL as
# PACEBREAK_SITE_DEPLOY_HOOK (e.g. in your shell profile). The website reads
# the latest version from the GitHub release at build time, so a rebuild is
# all that's needed. This step never fails the release.
if [[ -n "${PACEBREAK_SITE_DEPLOY_HOOK:-}" ]]; then
  if curl -fsS -X POST "$PACEBREAK_SITE_DEPLOY_HOOK" >/dev/null; then
    echo "✓ Triggered kinspiretech.com redeploy"
  else
    echo "⚠ Could not trigger website redeploy (release is unaffected)" >&2
  fi
else
  echo "ℹ Set PACEBREAK_SITE_DEPLOY_HOOK to auto-redeploy kinspiretech.com"
fi

echo
echo "Done. Users on Sparkle will now see PaceBreak $VERSION."
