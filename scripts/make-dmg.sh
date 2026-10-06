#!/usr/bin/env bash
# Builds a signed, notarized, stapled DMG of dist/SimplMaker.app, for people who download the app by hand.
#   scripts/make-dmg.sh                    build the DMG
#   scripts/make-dmg.sh --upload-test      ...then upload it to a hidden, unguessable URL on simplmaker.com
#   scripts/make-dmg.sh --upload-download  ...then publish it as https://simplmaker.com/download/SimplMaker.dmg
#   scripts/make-dmg.sh --no-notarize      skip notarization (a quick local check only; testers get a Gatekeeper warning)
#
# Run scripts/release.sh first: it builds, notarizes and staples dist/SimplMaker.app, and this script packs that
# app. The DMG goes in $DMG_DIR (default ~/SimplMakerReleases/dmg), deliberately NOT in the Sparkle releases
# folder, because generate_appcast would pick a .dmg up as an update archive.
# Needs: create-dmg (brew install create-dmg) and the notarytool profile and Developer ID certificate release.sh needs.
# The DMG contains only the app and an Applications shortcut; it is built from a clean staging folder.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NOTARY_PROFILE="${NOTARY_PROFILE:-simplcad-notary}"
DMG_DIR="${DMG_DIR:-$HOME/SimplMakerReleases/dmg}"
SFTP_USER="${SFTP_USER:-sftp-user}"
SFTP_HOST="${SFTP_HOST:-ssh.example.com}"
SFTP_KEY="${SFTP_KEY:-$HOME/.ssh/simplcad_deploy}"
WEB_ROOT="${WEB_ROOT:-webroots/by-route/simplmaker.com_}"
SITE_URL="${SITE_URL:-https://simplmaker.com}"
VERSION="$(tr -d '[:space:]' < VERSION)"
APP="$ROOT/dist/SimplMaker.app"
DMG="$DMG_DIR/SimplMaker-$VERSION.dmg"

NOTARIZE=1 UPLOAD=""
for arg in "$@"; do
  case "$arg" in
    --no-notarize) NOTARIZE=0 ;;
    --upload-test) UPLOAD=test ;;
    --upload-download) UPLOAD=download ;;
    *) echo "unknown option $arg" >&2; exit 2 ;;
  esac
done
[ -z "$UPLOAD" ] || [ "$NOTARIZE" = 1 ] || { echo "refusing to upload a DMG that is not notarized" >&2; exit 2; }

command -v create-dmg >/dev/null || { echo "create-dmg not found: brew install create-dmg" >&2; exit 1; }
[ -d "$APP" ] || { echo "$APP not found: run scripts/release.sh first" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
# The app inside must itself be notarized and stapled, so it also passes Gatekeeper once dragged out of the DMG.
if [ "$NOTARIZE" = 1 ]; then
  xcrun stapler validate "$APP" >/dev/null 2>&1 \
    || { echo "$APP is not notarized and stapled: run scripts/release.sh first (or use --no-notarize)" >&2; exit 1; }
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null \
    || { echo "notarytool profile '$NOTARY_PROFILE' not found or invalid" >&2; exit 1; }
fi
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1)}"
[ -n "$IDENTITY" ] || { echo "no Developer ID Application certificate; set SIGN_IDENTITY" >&2; exit 1; }

mkdir -p "$DMG_DIR"
rm -f "$DMG"
TMP="$(mktemp -d -t simplmaker-dmg)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Building $DMG"
ditto "$APP" "$TMP/SimplMaker.app"   # ditto keeps the signature and the stapled ticket intact
create-dmg --volname "SimplMaker" --window-size 600 400 --icon-size 100 \
  --icon "SimplMaker.app" 150 190 --app-drop-link 450 190 \
  --codesign "$IDENTITY" "$DMG" "$TMP" >/dev/null
# create-dmg once packed the whole current folder when its source path was wrong; a real DMG is about the app's size.
SIZE="$(stat -f %z "$DMG")"
[ "$SIZE" -lt 300000000 ] || { echo "DMG is $SIZE bytes, far more than the app: wrong contents?" >&2; rm -f "$DMG"; exit 1; }
codesign --verify "$DMG"

if [ "$NOTARIZE" = 1 ]; then
  echo "==> Notarizing"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi
echo "DMG ready: $DMG ($(( SIZE / 1000000 )) MB)"

[ -n "$UPLOAD" ] || exit 0
[ -r "$SFTP_KEY" ] || { echo "SSH key $SFTP_KEY not found" >&2; exit 1; }
SFTP=(sftp -i "$SFTP_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20)
if [ "$UPLOAD" = test ]; then
  # An unguessable folder, never linked. The empty index.html stops the folder being listed.
  DIR="t/$(openssl rand -hex 12)"; NAME="SimplMaker-$VERSION.dmg"
  : > "$TMP/index.html"
else
  DIR="download"; NAME="SimplMaker.dmg"
fi
echo "==> Uploading to $SITE_URL/$DIR/$NAME"
{
  echo "-mkdir $WEB_ROOT/$(dirname "$DIR")"
  echo "-mkdir $WEB_ROOT/$DIR"
  [ "$UPLOAD" != test ] || echo "put \"$TMP/index.html\" \"$WEB_ROOT/$DIR/index.html\""
  # Upload under a temporary name and rename, so a download never sees a half-written file.
  echo "put \"$DMG\" \"$WEB_ROOT/$DIR/$NAME.part\""
  echo "-rm \"$WEB_ROOT/$DIR/$NAME\""
  echo "rename \"$WEB_ROOT/$DIR/$NAME.part\" \"$WEB_ROOT/$DIR/$NAME\""
} | "${SFTP[@]}" -b - "$SFTP_USER@$SFTP_HOST" >/dev/null
GOT="$(curl -fsSIL --max-time 30 "$SITE_URL/$DIR/$NAME" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:"{n=$2} END{print n}')" || GOT=""
[ "$GOT" = "$SIZE" ] || { echo "Uploaded, but the server serves '${GOT:-nothing}' bytes, $SIZE expected" >&2; exit 1; }
echo "Published and checked: $SITE_URL/$DIR/$NAME"
