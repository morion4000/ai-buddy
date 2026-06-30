#!/usr/bin/env bash
#
# Builds AI Buddy and packages it into a distributable .dmg.
#
#   ./make-dmg.sh                    # builds the app, then makes build/AI Buddy.dmg
#   SKIP_BUILD=1 ./make-dmg.sh       # reuse the existing build/AI Buddy.app
#   NOTARIZE=1 ./make-dmg.sh         # also notarize + staple the DMG (needs creds, see below)
#
# The DMG contains the .app plus an /Applications symlink, so users just drag
# AI Buddy onto Applications to install. If a Developer ID identity is found the
# DMG itself is signed too (helps Gatekeeper on the receiving Mac).
#
# Notarization (NOTARIZE=1) uploads the DMG to Apple so Gatekeeper trusts it on
# any Mac. It needs a stored credential profile (one-time):
#
#   xcrun notarytool store-credentials "AI Buddy" \
#     --apple-id you@example.com --team-id <TEAMID>
#
# Then set NOTARY_PROFILE to that profile name (defaults to "AI Buddy").
#
set -euo pipefail

APP_NAME="AI Buddy"
VOL_NAME="AI Buddy"

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
DMG="$BUILD/$APP_NAME.dmg"

if [[ "${SKIP_BUILD:-}" != "1" ]]; then
  echo "▸ Building app…"
  "$ROOT/build.sh"
fi

if [[ ! -d "$APP" ]]; then
  echo "✗ $APP not found — run ./build.sh first (or unset SKIP_BUILD)." >&2
  exit 1
fi

# Build the DMG by copying into a mounted read/write image, then converting to
# compressed. We deliberately avoid `hdiutil create -srcfolder`: that path
# snapshots the source folder and can intermittently capture an incomplete copy
# (empty bundle) when Spotlight is still indexing freshly written files —
# producing a tiny, broken DMG. Copying into the mounted volume writes through
# the normal filesystem, so the contents are always complete.
RW_DMG="$BUILD/.rw.dmg"
echo "▸ Creating read/write image…"
rm -f "$RW_DMG" "$DMG"
APP_KB="$(du -sk "$APP" | cut -f1)"
SIZE_MB=$(( APP_KB / 1024 + 20 ))   # app size + 20 MB slack
hdiutil create -volname "$VOL_NAME" -size "${SIZE_MB}m" -fs HFS+ -ov "$RW_DMG" >/dev/null

echo "▸ Copying app into image…"
ATTACH="$(hdiutil attach "$RW_DMG" -nobrowse -noverify -noautoopen)"
DEV="$(echo "$ATTACH" | awk '/\/Volumes\//{print $1; exit}')"
MP="$(echo "$ATTACH" | grep -o '/Volumes/.*' | head -1)"
ditto "$APP" "$MP/$APP_NAME.app"
ln -s /Applications "$MP/Applications"
sync
hdiutil detach "$DEV" >/dev/null

echo "▸ Converting to compressed DMG…"
hdiutil convert "$RW_DMG" -format UDZO -ov -o "$DMG" >/dev/null
rm -f "$RW_DMG"

echo "▸ Signing DMG…"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2}' | head -1)"
fi
if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" "$DMG"
  echo "  ✓ signed with '$SIGN_IDENTITY'"
else
  echo "  • no Developer ID Application identity found — DMG left unsigned"
fi

if [[ "${NOTARIZE:-}" == "1" ]]; then
  NOTARY_PROFILE="${NOTARY_PROFILE:-AI Buddy}"
  echo "▸ Notarizing with Apple (profile: '$NOTARY_PROFILE')…"
  if ! xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait; then
    echo "✗ Notarization failed." >&2
    echo "  Set up credentials once with:" >&2
    echo "    xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <email> --team-id <TEAMID>" >&2
    exit 1
  fi
  echo "▸ Stapling ticket…"
  xcrun stapler staple "$DMG"
  echo "  ✓ notarized & stapled"
fi

echo ""
echo "✓ Built: $DMG"
echo "  Size:  $(du -h "$DMG" | cut -f1)"
if [[ "${NOTARIZE:-}" != "1" ]]; then
  echo ""
  echo "  Not notarized — other Macs will warn on first launch. To notarize:"
  echo "    NOTARIZE=1 ./make-dmg.sh        (after storing a notarytool credential profile)"
fi
