#!/usr/bin/env bash
#
# Builds AI Buddy into a real .app bundle using swiftc (no Xcode project).
#
#   ./build.sh                       # auto-signs with your Developer ID (permissions persist)
#   SIGN_IDENTITY="My Cert" ./build.sh   # force a specific identity
#   (only falls back to ad-hoc if no codesigning identity exists — that resets permissions)
#
set -euo pipefail

APP_NAME="AI Buddy"
EXE="AIBuddy"
BUNDLE_ID="com.morion4000.gemini-dictation"

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

echo "▸ Cleaning previous build…"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

echo "▸ Compiling Swift sources…"
xcrun --sdk macosx swiftc \
  -swift-version 5 \
  -O \
  -target arm64-apple-macos26.0 \
  -framework AppKit -framework SwiftUI -framework AVFoundation \
  -o "$MACOS/$EXE" \
  "$ROOT/Sources/"*.swift

echo "▸ Assembling bundle…"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

echo "▸ Signing…"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
# When no identity is given, auto-detect a single stable one. Ad-hoc signatures
# change every rebuild, so macOS re-prompts for the keychain password and re-asks
# for permissions on each build; a stable identity keeps those grants sticky.
if [[ -z "$SIGN_IDENTITY" ]]; then
  AUTO_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"/{print $2}' | head -1)"
  if [[ -n "$AUTO_ID" ]]; then
    SIGN_IDENTITY="$AUTO_ID"
    echo "  • auto-detected signing identity: $SIGN_IDENTITY"
  fi
fi
if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --options runtime \
    --entitlements "$ROOT/entitlements.plist" \
    --identifier "$BUNDLE_ID" \
    --sign "$SIGN_IDENTITY" "$APP"
  echo "  ✓ signed with '$SIGN_IDENTITY' — keychain & permission grants persist across rebuilds"
else
  codesign --force --identifier "$BUNDLE_ID" --sign - "$APP"
  echo "  ✓ ad-hoc signed (no codesigning identity found; macOS may re-prompt for the keychain"
  echo "    password and re-ask for permissions after each rebuild)"
fi

echo ""
echo "✓ Built: $APP"
echo ""
echo "  Launch it:   open \"$APP\""
echo "  Or with logs: \"$MACOS/$EXE\""
