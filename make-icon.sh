#!/usr/bin/env bash
#
# Regenerates AppIcon.icns from Icon.svg. Run this after editing the SVG;
# the result is committed so build.sh doesn't depend on librsvg.
#
#   ./make-icon.sh
#
# Requires: rsvg-convert (brew install librsvg) and iconutil (ships with macOS).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SVG="$ROOT/Icon.svg"
ICNS="$ROOT/AppIcon.icns"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "✗ rsvg-convert not found. Install it with: brew install librsvg" >&2
  exit 1
fi

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

# Each macOS icon slot: <name> <pixel size>. @2x slots are the retina variants.
render() { rsvg-convert -w "$2" -h "$2" "$SVG" -o "$ICONSET/$1.png"; }
render icon_16x16        16
render icon_16x16@2x     32
render icon_32x32        32
render icon_32x32@2x     64
render icon_128x128     128
render icon_128x128@2x  256
render icon_256x256     256
render icon_256x256@2x  512
render icon_512x512     512
render icon_512x512@2x 1024

iconutil -c icns "$ICONSET" -o "$ICNS"
rm -rf "$(dirname "$ICONSET")"
echo "✓ Wrote $ICNS"
