#!/usr/bin/env bash
# Builds SimplMaker.app into dist/ (ad-hoc signed, for local use / self-distribution).
#   scripts/bundle-app.sh           release build
#   scripts/bundle-app.sh --debug   debug build (faster to build)
#   scripts/bundle-app.sh --release release build signed with a Developer ID (see below), ready to notarize
#   add --licensed to make a debug build ask for a license too (see Licensing below); without it a development
#   build never does, so your own copy does not lock after 14 days
#   add --open to launch it afterwards
#   add --without-ai to leave the AI mode out. Every build has it by default (the AI interface: a local MCP server, Settings > AI,
#   the stdio relay in Contents/Helpers); it is off until the user turns it on. The Info.plist key SCAIEnabled, which this script
#   writes, says which. Without the mode, a build neither contains the relay nor can be made to start the server
#   (see Sources/SimplMaker/AI/AIFeature.swift).
# The bundle's Info.plist declares the .simplmaker document type, which the document features
# (Open Recent, autosave, versions) rely on; prefer this (or Xcode) over `swift run`.
#
# Version: Marketing version from VERSION, build number (CFBundleVersion, which Sparkle compares) from the
# number of commits; override with BUILD_NUMBER.
#
# Updates (Sparkle): the app only turns its updater on when the bundle names a feed and a public key.
#   Packaging/sparkle-public-key.txt   the public EdDSA key (from Sparkle's generate_keys), committed
#   SPARKLE_FEED_URL                   overrides the feed (default https://simplmaker.com/updates/v<generation>/appcast.xml)
# Without the key file the bundle has no updater (no "Check for Updates…").
#
# Licensing: the 14-day trial and license keys (Polar) are enforced only when the bundle names an organization:
# --release builds always do, other builds only with --licensed (or LICENSE=1).
#   Packaging/licensing.conf           POLAR_ORGANIZATION_ID, BUY_URL, POLAR_BENEFIT_ID, LICENSE_GENERATION
#                                      (copy licensing.conf.example); one product and one feed per major version
#   LICENSING_CONF=Packaging/licensing.sandbox.conf scripts/bundle-app.sh --debug --licensed
#                                      tests against Polar's sandbox with another file (leave it out of git)
# Without it the build is not license-enforced (development builds). --release refuses to build without it,
# unless ALLOW_UNLICENSED=1.
#
# --release signs with a Developer ID Application certificate: SIGN_IDENTITY, or the only one in the keychain.
# Then notarize and staple (scripts/release.sh):
#   xcrun notarytool submit … && xcrun stapler staple dist/SimplMaker.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
. "$ROOT/scripts/licensing-conf.sh"
CONFIG=release
OPEN=0
RELEASE=0
WITHOUT_AI="${WITHOUT_AI:-0}"
ENFORCE="${LICENSE:-0}"
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    --release) RELEASE=1 ;;
    --licensed) ENFORCE=1 ;;
    --open) OPEN=1 ;;
    --without-ai) WITHOUT_AI=1 ;;
    *) echo "unknown option $arg" >&2; exit 2 ;;
  esac
done
# The AI mode: in every build unless left out.
AI_ENABLED=1
[ "$WITHOUT_AI" != 1 ] || AI_ENABLED=0
# SwiftPM writes the deployment target into the binary as its SDK version too, and macOS draws an app that says it
# was built with the macOS 15 SDK the old way on every system: the short pre-26 toolbar, the old window greys.
# Record the SDK actually used, so macOS 26 and later draw it as a current app; the deployment target stays as it is.
MIN_MACOS="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$ROOT/Packaging/Info.plist")"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
LINK_SDK=(-Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_MACOS" -Xlinker "$SDK_VERSION")
swift build -c "$CONFIG" --product SimplMaker "${LINK_SDK[@]}"
[ "$AI_ENABLED" != 1 ] || swift build -c "$CONFIG" --product simplmaker-mcp "${LINK_SDK[@]}"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/SimplMaker"
APP="$ROOT/dist/SimplMaker.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SimplMaker"
if [ "$AI_ENABLED" = 1 ]; then
  # The stdio relay for AI clients that start servers as programs (Claude Desktop); Settings > AI points them at it.
  mkdir -p "$APP/Contents/Helpers"
  cp "$BIN_DIR/simplmaker-mcp" "$APP/Contents/Helpers/simplmaker-mcp"
fi
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"

# Version numbers.
PLIST="$APP/Contents/Info.plist"
plist_set() { /usr/libexec/PlistBuddy -c "Set :$1 $2" "$PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$PLIST"; }
plist_set CFBundleShortVersionString "$(tr -d '[:space:]' < "$ROOT/VERSION")"
plist_set CFBundleVersion "${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
# The AI mode (a real boolean, which the app reads as such).
/usr/libexec/PlistBuddy -c "Delete :SCAIEnabled" "$PLIST" 2>/dev/null || true
if [ "$AI_ENABLED" = 1 ]; then
  /usr/libexec/PlistBuddy -c "Add :SCAIEnabled bool true" "$PLIST"
else
  /usr/libexec/PlistBuddy -c "Add :SCAIEnabled bool false" "$PLIST"
  echo "note: this build has no AI mode (--without-ai)"
fi

# Licensing configuration.
POLAR_ORGANIZATION_ID="$(conf_get POLAR_ORGANIZATION_ID)"
BUY_URL="$(conf_get BUY_URL)"
POLAR_BENEFIT_ID="$(conf_get POLAR_BENEFIT_ID)"
POLAR_API_BASE="${POLAR_API_BASE:-$(conf_get POLAR_API_BASE)}"
[ "$RELEASE" != 1 ] || ENFORCE=1
if [ "$ENFORCE" != 1 ]; then
  echo "note: development build, not license-enforced (--licensed to test the trial and keys)"
elif [ -n "$POLAR_ORGANIZATION_ID" ] && [ -n "$BUY_URL" ]; then
  # Without the product id a key of any SimplMaker major version would be accepted.
  if [ -z "$POLAR_BENEFIT_ID" ] && [ "$RELEASE" = 1 ] && [ "${ALLOW_UNLICENSED:-0}" != 1 ]; then
    echo "Packaging/licensing.conf has no POLAR_BENEFIT_ID: a key for any major version would unlock this one" >&2
    exit 1
  fi
  plist_set SCPolarOrganizationID "$POLAR_ORGANIZATION_ID"
  plist_set SCBuyURL "$BUY_URL"
  plist_set SCLicenseGeneration "$LICENSE_GENERATION"
  [ -z "$POLAR_BENEFIT_ID" ] || plist_set SCPolarBenefitID "$POLAR_BENEFIT_ID"
  if [ -n "${POLAR_API_BASE:-}" ]; then
    # Polar's sandbox, for testing. A release must talk to the real API.
    [ "$RELEASE" != 1 ] || { echo "POLAR_API_BASE is set (a sandbox); a release must use the real Polar API" >&2; exit 1; }
    plist_set SCPolarAPIBase "$POLAR_API_BASE"
  fi
elif [ "$RELEASE" = 1 ] && [ "${ALLOW_UNLICENSED:-0}" != 1 ]; then
  echo "no licensing.conf: a release would not ask for a license (ALLOW_UNLICENSED=1 to build one anyway)" >&2
  exit 1
else
  echo "note: no licensing configuration ($LICENSING_CONF), so this build is not license-enforced"
fi

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
install_name_tool -delete_rpath "$OCCT_LIB" "$APP/Contents/MacOS/SimplMaker" 2>/dev/null  # (invalidates the signature; signed below)
KEY_FILE="$ROOT/Packaging/sparkle-public-key.txt"
if [ -s "$KEY_FILE" ]; then
  plist_set SUFeedURL "${SPARKLE_FEED_URL:-https://simplmaker.com/updates/v$LICENSE_GENERATION/appcast.xml}"
  plist_set SUPublicEDKey "$(tr -d '[:space:]' < "$KEY_FILE")"
else
  echo "note: no Packaging/sparkle-public-key.txt, so this build has no updater"
fi
# The icon: compile the Icon Composer file (Liquid Glass layers + a flat .icns fallback) with actool;
# without Xcode's actool, fall back to the prebuilt .icns.
if xcrun --find actool >/dev/null 2>&1; then
  PARTIAL="$(mktemp -t simplmaker-icon).plist"
  xcrun actool "$ROOT/Packaging/AppIcon.icon" --compile "$APP/Contents/Resources" --app-icon AppIcon \
    --platform macosx --target-device mac --minimum-deployment-target 15.0 \
    --output-partial-info-plist "$PARTIAL" --output-format human-readable-text --errors >/dev/null
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
  rm -f "$PARTIAL"
else
  cp "$ROOT/Packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
# The .simplmaker document icon: a flat page-shaped .icns (Icon Composer would force the app-icon squircle).
cp "$ROOT/Packaging/DocIcon.icns" "$APP/Contents/Resources/DocIcon.icns"
if [ "$RELEASE" = 1 ]; then
  IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1)}"
  [ -n "$IDENTITY" ] || { echo "no Developer ID Application certificate; set SIGN_IDENTITY" >&2; exit 1; }
  # Inside out: Sparkle's helpers, the frameworks and dylib, then the app. The hardened runtime and a timestamp are
  # what notarization requires.
  SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  SIGN_ITEMS=("$SPK/Autoupdate" "$SPK/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework" "$APP/Contents/Frameworks/libSimplOCCT.dylib")
  [ ! -f "$APP/Contents/Helpers/simplmaker-mcp" ] || SIGN_ITEMS+=("$APP/Contents/Helpers/simplmaker-mcp")
  for item in "${SIGN_ITEMS[@]}" "$APP"; do
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$item"
  done
  codesign --verify --deep --strict "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
echo "Built $APP"
[ "$OPEN" = 1 ] && open "$APP"
exit 0
