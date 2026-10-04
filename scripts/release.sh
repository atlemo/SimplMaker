#!/usr/bin/env bash
# Builds, signs, notarizes and packages a release, then updates the Sparkle appcast.
#   scripts/release.sh
# Everything lands in $RELEASES_DIR (default ~/SimplCADReleases/v<generation>, one folder per major version):
# SimplCAD-<version>.zip for each release, appcast.xml, and old_updates/. scripts/publish.sh uploads that folder
# to simplcad.com/updates/v<generation>/. The generation (major version sold) is LICENSE_GENERATION in
# Packaging/licensing.conf; VERSION must start with it (1.x.y for generation 1; 0.x.y betas count as 1).
#
# Needs, once:
#   - a "Developer ID Application" certificate in the keychain (SIGN_IDENTITY picks one if there are several)
#   - notarytool credentials:  xcrun notarytool store-credentials simplcad-notary …   (NOTARY_PROFILE)
#   - Packaging/licensing.conf (the Polar organization and buy link; see docs/LICENSING-SETUP.md)
#   - the Sparkle signing key in the keychain under the account SimplCAD (generate_keys --account SimplCAD)
# Before running: bump VERSION, commit, and optionally write release-notes/<version>.html (a fragment).
#
# The version in VERSION is the one released. The build number is the commit count, so every release
# needs a new commit; an existing archive for the same version is never overwritten.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
. "$ROOT/scripts/licensing-conf.sh"

RELEASES_DIR="${RELEASES_DIR:-$HOME/SimplCADReleases/v$LICENSE_GENERATION}"
NOTARY_PROFILE="${NOTARY_PROFILE:-simplcad-notary}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-SimplCAD}"
UPDATES_URL="${UPDATES_URL:-https://simplcad.com/updates/v$LICENSE_GENERATION}"
VERSION="$(tr -d '[:space:]' < VERSION)"
ARCHIVE="$RELEASES_DIR/SimplCAD-$VERSION.zip"
APP="$ROOT/dist/SimplCAD.app"

# A major version has its own keys and feed, so VERSION's major number must be the one being sold.
# (0.x versions are betas of major version 1.)
MAJOR="${VERSION%%.*}"
[ "$MAJOR" = "$LICENSE_GENERATION" ] || { [ "$MAJOR" = 0 ] && [ "$LICENSE_GENERATION" = 1 ]; } \
  || { echo "VERSION $VERSION does not belong to LICENSE_GENERATION $LICENSE_GENERATION (Packaging/licensing.conf)" >&2; exit 1; }
# A release comes from committed code, so the build number identifies exactly what shipped.
if [ -n "$(git status --porcelain)" ] && [ "${ALLOW_DIRTY:-0}" != 1 ]; then
  echo "uncommitted changes: commit first (or ALLOW_DIRTY=1)" >&2; exit 1
fi
[ -f Packaging/licensing.conf ] || [ "${ALLOW_UNLICENSED:-0}" = 1 ] \
  || { echo "Packaging/licensing.conf is missing, so the app would not ask for a license (ALLOW_UNLICENSED=1 to release anyway)" >&2; exit 1; }
[ -s Packaging/sparkle-public-key.txt ] || { echo "Packaging/sparkle-public-key.txt is missing" >&2; exit 1; }
mkdir -p "$RELEASES_DIR"
[ ! -e "$ARCHIVE" ] || { echo "$ARCHIVE exists: bump VERSION, or delete it if it was never published" >&2; exit 1; }
xcrun --find notarytool >/dev/null
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null \
  || { echo "notarytool profile '$NOTARY_PROFILE' not found or invalid" >&2; exit 1; }

echo "==> Building SimplCAD $VERSION (build $(git rev-list --count HEAD))"
scripts/bundle-app.sh --release

echo "==> Notarizing"
TMP="$(mktemp -d -t simplcad-release)"
trap 'rm -rf "$TMP"' EXIT
ditto -c -k --keepParent "$APP" "$TMP/SimplCAD.zip"
xcrun notarytool submit "$TMP/SimplCAD.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "==> Packaging $ARCHIVE"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
NOTES="$ROOT/release-notes/$VERSION.html"
if [ -f "$NOTES" ]; then
  cp "$NOTES" "$RELEASES_DIR/SimplCAD-$VERSION.html"
else
  echo "note: no release-notes/$VERSION.html, so this update has no notes"
fi

echo "==> Updating the appcast"
"$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" "$RELEASES_DIR" \
  --account "$SPARKLE_ACCOUNT" \
  --download-url-prefix "$UPDATES_URL/" \
  --embed-release-notes \
  --link "https://simplcad.com"

echo
echo "Release $VERSION is ready in $RELEASES_DIR"
echo "Next: test it, then scripts/publish.sh"
