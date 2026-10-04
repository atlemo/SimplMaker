#!/usr/bin/env bash
# Builds SimplCAD.app into dist/ (ad-hoc signed, for local use / self-distribution).
#   scripts/bundle-app.sh           release build
#   scripts/bundle-app.sh --debug   debug build (faster to build)
#   scripts/bundle-app.sh --release release build signed with a Developer ID (see below), ready to notarize
#   add --open to launch it afterwards
# The bundle's Info.plist declares the .simplcad document type, which the document features
# (Open Recent, autosave, versions) rely on; prefer this (or Xcode) over `swift run`.
#
# Version: Marketing version from VERSION, build number (CFBundleVersion, which Sparkle compares) from the
# number of commits; override with BUILD_NUMBER.
#
# Updates (Sparkle): the app only turns its updater on when the bundle names a feed and a public key.
#   Packaging/sparkle-public-key.txt   the public EdDSA key (from Sparkle's generate_keys), committed
#   SPARKLE_FEED_URL                   overrides the feed (default https://simplcad.com/updates/appcast.xml)
# Without the key file the bundle has no updater (no "Check for Updates…").
#
# --release signs with a Developer ID Application certificate: SIGN_IDENTITY, or the only one in the keychain.
# Then notarize and staple (scripts/release.sh):
#   xcrun notarytool submit … && xcrun stapler staple dist/SimplCAD.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG=release
OPEN=0
RELEASE=0
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    --release) RELEASE=1 ;;
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

# Version numbers.
PLIST="$APP/Contents/Info.plist"
plist_set() { /usr/libexec/PlistBuddy -c "Set :$1 $2" "$PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$PLIST"; }
plist_set CFBundleShortVersionString "$(tr -d '[:space:]' < "$ROOT/VERSION")"
plist_set CFBundleVersion "${BUILD_NUMBER:-$(git rev-list --count HEAD)}"

# Updater: Sparkle, embedded in Contents/Frameworks (the binary's rpath points there).
SPARKLE="$(find "$ROOT/.build/artifacts/sparkle" -type d -name Sparkle.framework -path '*macos*' | head -n 1)"
[ -n "$SPARKLE" ] || { echo "Sparkle.framework not found; run swift package resolve" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
# Not sandboxed, so Sparkle's XPC services go unused.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
# OpenCASCADE (LGPL-2.1) ships as a dylib the user can replace, not linked into the binary (see PLAN.md).
# The binary also carries the development rpath to ThirdParty/occt/lib; drop it, since the dylib is bundled.
OCCT_LIB="${OCCT_ROOT:-$ROOT/ThirdParty/occt}/lib"
[ -f "$OCCT_LIB/libSimplOCCT.dylib" ] || { echo "$OCCT_LIB/libSimplOCCT.dylib missing; run scripts/build-occt.sh" >&2; exit 1; }
cp "$OCCT_LIB/libSimplOCCT.dylib" "$APP/Contents/Frameworks/libSimplOCCT.dylib"
install_name_tool -delete_rpath "$OCCT_LIB" "$APP/Contents/MacOS/SimplCAD" 2>/dev/null  # (invalidates the signature; signed below)
KEY_FILE="$ROOT/Packaging/sparkle-public-key.txt"
if [ -s "$KEY_FILE" ]; then
  plist_set SUFeedURL "${SPARKLE_FEED_URL:-https://simplcad.com/updates/appcast.xml}"
  plist_set SUPublicEDKey "$(tr -d '[:space:]' < "$KEY_FILE")"
else
  echo "note: no Packaging/sparkle-public-key.txt, so this build has no updater"
fi
# The icon: compile the Icon Composer file (Liquid Glass layers + a flat .icns fallback) with actool;
# without Xcode's actool, fall back to the prebuilt .icns.
if xcrun --find actool >/dev/null 2>&1; then
  PARTIAL="$(mktemp -t simplcad-icon).plist"
  xcrun actool "$ROOT/Packaging/AppIcon.icon" --compile "$APP/Contents/Resources" --app-icon AppIcon \
    --platform macosx --target-device mac --minimum-deployment-target 26.0 \
    --output-partial-info-plist "$PARTIAL" --output-format human-readable-text --errors >/dev/null
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
  rm -f "$PARTIAL"
else
  cp "$ROOT/Packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
if [ "$RELEASE" = 1 ]; then
  IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1)}"
  [ -n "$IDENTITY" ] || { echo "no Developer ID Application certificate; set SIGN_IDENTITY" >&2; exit 1; }
  # Inside out: Sparkle's helpers, the frameworks and dylib, then the app. The hardened runtime and a timestamp are
  # what notarization requires.
  SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  for item in "$SPK/Autoupdate" "$SPK/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework" \
              "$APP/Contents/Frameworks/libSimplOCCT.dylib" "$APP"; do
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$item"
  done
  codesign --verify --deep --strict "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
echo "Built $APP"
[ "$OPEN" = 1 ] && open "$APP"
exit 0
