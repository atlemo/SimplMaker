#!/usr/bin/env bash
# Builds, signs, notarizes and packages a release, then updates the Sparkle appcast.
#   scripts/release.sh
# Everything lands in $RELEASES_DIR (default ~/SimplMakerReleases/v1):
# SimplMaker-<version>.zip for each release, appcast.xml, and old_updates/. scripts/publish.sh uploads that folder
# to simplmaker.com/updates/v1/. The v1 is permanent, whatever the version number: every copy ever released has that
# feed baked in, so all later versions, 1.x or not, go to it.
#
# Needs, once:
#   - a "Developer ID Application" certificate in the keychain (SIGN_IDENTITY picks one if there are several)
#   - notarytool credentials in the keychain:  xcrun notarytool store-credentials <name> …   (NOTARY_PROFILE)
#   - the Sparkle signing key in the keychain (generate_keys --account <name>; SPARKLE_ACCOUNT, default SimplMaker)
#   - scripts/release.local.env with those names (copy scripts/release.local.env.example; it is not in git)
# Before running: bump VERSION, commit, and optionally write release-notes/<version>.html (a fragment).
#
# The version in VERSION is the one released. The build number is the commit count, so every release
# needs a new commit; an existing archive for the same version is never overwritten.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
. "$ROOT/scripts/release-env.sh"

RELEASES_DIR="${RELEASES_DIR:-$HOME/SimplMakerReleases/v1}"
UPDATES_URL="${UPDATES_URL:-https://simplmaker.com/updates/v1}"
VERSION="$(tr -d '[:space:]' < VERSION)"
ARCHIVE="$RELEASES_DIR/SimplMaker-$VERSION.zip"
APP="$ROOT/dist/SimplMaker.app"

# A release comes from committed code, so the build number identifies exactly what shipped.
# Changes to tracked files count, and so do new files that go into the build; unrelated untracked folders (website/) do not.
DIRTY="$(git status --porcelain --untracked-files=no; git ls-files --others --exclude-standard -- Sources Tests Packaging scripts Package.swift Package.resolved VERSION SimplMaker.xcodeproj)"
if [ -n "$DIRTY" ] && [ "${ALLOW_DIRTY:-0}" != 1 ]; then
  echo "uncommitted changes: commit first (or ALLOW_DIRTY=1)" >&2; printf '%s\n' "$DIRTY" >&2; exit 1
fi
[ -s Packaging/sparkle-public-key.txt ] || { echo "Packaging/sparkle-public-key.txt is missing" >&2; exit 1; }
mkdir -p "$RELEASES_DIR"
[ ! -e "$ARCHIVE" ] || { echo "$ARCHIVE exists: bump VERSION, or delete it if it was never published" >&2; exit 1; }
xcrun --find notarytool >/dev/null
require_notary
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null \
  || { echo "notarytool profile '$NOTARY_PROFILE' not found or invalid" >&2; exit 1; }

echo "==> Building SimplMaker $VERSION (build $(git rev-list --count HEAD))"
scripts/bundle-app.sh --release --official

echo "==> Notarizing"
TMP="$(mktemp -d -t simplmaker-release)"
trap 'rm -rf "$TMP"' EXIT
ditto -c -k --keepParent "$APP" "$TMP/SimplMaker.zip"
xcrun notarytool submit "$TMP/SimplMaker.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "==> Packaging $ARCHIVE"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
NOTES="$ROOT/release-notes/$VERSION.html"
if [ -f "$NOTES" ]; then
  cp "$NOTES" "$RELEASES_DIR/SimplMaker-$VERSION.html"
else
  echo "note: no release-notes/$VERSION.html, so this update has no notes"
fi

echo "==> Updating the appcast"
"$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" "$RELEASES_DIR" \
  --account "$SPARKLE_ACCOUNT" \
  --download-url-prefix "$UPDATES_URL/" \
  --embed-release-notes \
  --link "https://simplmaker.com"

echo
echo "Release $VERSION is ready in $RELEASES_DIR"
echo "Next: test it, then scripts/publish.sh"
