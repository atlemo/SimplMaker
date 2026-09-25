#!/usr/bin/env bash
# Builds SimplCAD.app into dist/ (ad-hoc signed, for local use / self-distribution).
#   scripts/bundle-app.sh           release build
#   scripts/bundle-app.sh --debug   debug build (faster to build)
#   add --open to launch it afterwards
# The bundle's Info.plist declares the .simplcad document type, which the document features
# (Open Recent, autosave, versions) rely on; prefer this (or Xcode) over `swift run`.
#
# For distribution to other Macs, sign with a Developer ID and notarize:
#   codesign --force --options runtime --sign "Developer ID Application: …" dist/SimplCAD.app
#   xcrun notarytool submit … && xcrun stapler staple dist/SimplCAD.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG=release
OPEN=0
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    --open) OPEN=1 ;;
    *) echo "unknown option $arg" >&2; exit 2 ;;
  esac
done
swift build -c "$CONFIG" --product SimplCAD
BIN="$(swift build -c "$CONFIG" --show-bin-path)/SimplCAD"
APP="$ROOT/dist/SimplCAD.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SimplCAD"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"
[ "$OPEN" = 1 ] && open "$APP"
exit 0
