#!/usr/bin/env bash
# Builds a release SimplCAD.app into dist/ (ad-hoc signed, for local use / self-distribution).
# For distribution to other Macs, sign with a Developer ID and notarize:
#   codesign --force --options runtime --sign "Developer ID Application: …" dist/SimplCAD.app
#   xcrun notarytool submit … && xcrun stapler staple dist/SimplCAD.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release --product SimplCAD
BIN="$(swift build -c release --show-bin-path)/SimplCAD"
APP="$ROOT/dist/SimplCAD.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SimplCAD"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
