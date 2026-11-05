#!/usr/bin/env bash
# Builds the iPad app as a release archive and exports it for App Store Connect.
#
# Usage: scripts/archive-ipad.sh [--upload] [--unsigned]
#   (nothing)   archive + export an .ipa into dist/ipad/ (for Transporter, or to look at)
#   --upload    archive and send it straight to App Store Connect (needs the Apple ID signed in to Xcode)
#   --unsigned  archive without signing: checks that the release build works, produces nothing to upload
# Needs: xcodegen, Xcode 26, ThirdParty/occt-ios/SimplOCCT.xcframework (scripts/build-occt-ios.sh), and
# IPAD_TEAM_ID in scripts/release.local.env (the Apple developer Team ID; git-ignored like the other local settings).
# Bump CURRENT_PROJECT_VERSION in iPad/project.yml before every upload (App Store Connect refuses a build number twice).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$ROOT/scripts/release.local.env" ] && source "$ROOT/scripts/release.local.env"
MODE=export; SIGN=1
for a in "$@"; do case "$a" in --upload) MODE=upload ;; --unsigned) SIGN=0 ;; *) echo "unknown option $a" >&2; exit 2 ;; esac; done
[ -d "$ROOT/ThirdParty/occt-ios/SimplOCCT.xcframework" ] || { echo "Build OpenCASCADE for iOS first: scripts/build-occt-ios.sh" >&2; exit 1; }

OUT="$ROOT/dist/ipad"; ARCHIVE="$OUT/SimplMakerPad.xcarchive"
rm -rf "$OUT"; mkdir -p "$OUT"
(cd "$ROOT/iPad" && xcodegen generate >/dev/null)

if [ "$SIGN" = 0 ]; then
  xcodebuild archive -project "$ROOT/iPad/SimplMakerPad.xcodeproj" -scheme SimplMakerPad -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO
  echo "Unsigned archive builds: $ARCHIVE"
  exit 0
fi

: "${IPAD_TEAM_ID:?Set IPAD_TEAM_ID in scripts/release.local.env}"
xcodebuild archive -project "$ROOT/iPad/SimplMakerPad.xcodeproj" -scheme SimplMakerPad -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" DEVELOPMENT_TEAM="$IPAD_TEAM_ID" ONLY_ACTIVE_ARCH=NO -allowProvisioningUpdates

DEST=export; [ "$MODE" = upload ] && DEST=upload
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DEST</string>
  <key>teamID</key><string>$IPAD_TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT" -allowProvisioningUpdates
echo "Done: $OUT"
