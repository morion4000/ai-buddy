#!/usr/bin/env bash
#
# Builds AI Buddy and packages it into a distributable .dmg.
#
#   ./make-dmg.sh                    # builds the app, then makes build/AI Buddy.dmg
#   SKIP_BUILD=1 ./make-dmg.sh       # reuse the existing build/AI Buddy.app
#   NOTARIZE=1 ./make-dmg.sh         # also notarize + staple the DMG (needs creds, see below)
#   NOTARIZE=1 RELEASE=1 ./make-dmg.sh   # …and publish it to the auto-update feed
#
# RELEASE=1 feeds the in-app auto-updater: it uploads the DMG plus an
# appcast.json to the updates.claudete.co R2 bucket (the same one Claudete
# publishes to), which installed apps poll daily. R2 credentials are sourced
# from .env.notarize here or, failing that, from ../claudete/.env.notarize.
# Every public build should ship through it (and be notarized, or the update
# will fail Gatekeeper on users' Macs).
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

if [[ "${RELEASE:-}" == "1" ]]; then
  if [[ "${NOTARIZE:-}" != "1" ]]; then
    echo "✗ Refusing to publish an un-notarized DMG — rerun with NOTARIZE=1 RELEASE=1." >&2
    exit 1
  fi

  # R2 credentials: local .env.notarize wins, else borrow Claudete's.
  ENV_FILE=""
  for candidate in "$ROOT/.env.notarize" "$ROOT/../claudete/.env.notarize"; do
    [[ -f "$candidate" ]] && ENV_FILE="$candidate" && break
  done
  if [[ -z "$ENV_FILE" ]]; then
    echo "✗ No .env.notarize with R2 credentials found (looked in this repo and ../claudete)." >&2
    exit 1
  fi
  set -a; source "$ENV_FILE"; set +a
  : "${CF_ACCOUNT_ID:?missing in $ENV_FILE}" "${CF_ACCESS_KEY_ID:?missing in $ENV_FILE}" \
    "${CF_SECRET_ACCESS_KEY:?missing in $ENV_FILE}" "${R2_BUCKET:?missing in $ENV_FILE}"

  VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$ROOT/Info.plist")"
  DMG_NAME="AI-Buddy-$VERSION.dmg"
  FEED_BASE="https://updates.claudete.co/ai-buddy"
  R2_BASE="https://$CF_ACCOUNT_ID.r2.cloudflarestorage.com/$R2_BUCKET/ai-buddy"

  # Refuse to overwrite a published version: the DMG name is immutable-cached,
  # so re-releasing the same version would serve stale bits to some users.
  # The cache-buster keeps this probe's 404 from being edge-cached on the real
  # URL (Cloudflare holds negative hits for hours) and served after the upload.
  if curl -sf -o /dev/null -I "$FEED_BASE/$DMG_NAME?precheck=$(date +%s)"; then
    echo "✗ $DMG_NAME is already published — bump the version in Info.plist first." >&2
    exit 1
  fi

  echo "▸ Publishing $DMG_NAME to the update feed…"
  r2_put() {  # r2_put <local-file> <remote-name> <content-type> <cache-control>
    curl -sfS --aws-sigv4 "aws:amz:auto:s3" \
      --user "$CF_ACCESS_KEY_ID:$CF_SECRET_ACCESS_KEY" \
      -T "$1" -H "Content-Type: $3" -H "Cache-Control: $4" \
      "$R2_BASE/$2"
  }
  r2_put "$DMG" "$DMG_NAME" "application/x-apple-diskimage" "public, max-age=31536000, immutable"

  # Stable alias for the website download button — always the newest build, so
  # marketing pages never need touching on release. Mutable, so never cached.
  r2_put "$DMG" "AI-Buddy.dmg" "application/x-apple-diskimage" "no-cache, max-age=0, must-revalidate"

  # The appcast is the mutable pointer the app polls — never edge-cache it stale.
  APPCAST="$BUILD/appcast.json"
  NOTES="${RELEASE_NOTES:-}"
  python3 - "$VERSION" "$FEED_BASE/$DMG_NAME" "$NOTES" > "$APPCAST" <<'EOF'
import json, sys
print(json.dumps({"version": sys.argv[1], "url": sys.argv[2], "notes": sys.argv[3]}, indent=2))
EOF
  r2_put "$APPCAST" "appcast.json" "application/json" "no-cache, max-age=0, must-revalidate"

  # The pricing table the app's cost estimate refreshes from — republished with
  # every release so repo edits to pricing.json reach installed apps.
  r2_put "$ROOT/pricing.json" "pricing.json" "application/json" "no-cache, max-age=0, must-revalidate"

  echo "  ✓ feed live: $FEED_BASE/appcast.json → $VERSION"
  echo "    installed apps will offer the update on their next daily check"

  # Mirror the release on GitHub — tag the exact commit this build came from
  # and attach the DMG — so every published version is traceable in history.
  echo "▸ Tagging v$VERSION and creating the GitHub release…"
  if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
    echo "  ! working tree has uncommitted changes — tagging HEAD anyway, but the"
    echo "    tag may not match the built app. Commit before releasing next time."
  fi
  if git -C "$ROOT" rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "  • tag v$VERSION already exists — leaving it as-is"
  else
    git -C "$ROOT" tag "v$VERSION"
    git -C "$ROOT" push origin "v$VERSION"
  fi
  GH_ASSET="$BUILD/AI-Buddy-$VERSION.dmg"
  cp "$DMG" "$GH_ASSET"
  if gh release view "v$VERSION" -R "$(git -C "$ROOT" remote get-url origin)" >/dev/null 2>&1; then
    echo "  • GitHub release v$VERSION already exists — leaving it as-is"
  else
    NOTES_ARGS=(--generate-notes)
    [[ -n "${RELEASE_NOTES:-}" ]] && NOTES_ARGS=(--notes "$RELEASE_NOTES")
    gh release create "v$VERSION" "$GH_ASSET" --title "$APP_NAME $VERSION" "${NOTES_ARGS[@]}"
    echo "  ✓ github release v$VERSION created"
  fi
  rm -f "$GH_ASSET"
fi

echo ""
echo "✓ Built: $DMG"
echo "  Size:  $(du -h "$DMG" | cut -f1)"
if [[ "${NOTARIZE:-}" != "1" ]]; then
  echo ""
  echo "  Not notarized — other Macs will warn on first launch. To notarize:"
  echo "    NOTARIZE=1 ./make-dmg.sh        (after storing a notarytool credential profile)"
fi
