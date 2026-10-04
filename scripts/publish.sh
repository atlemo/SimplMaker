#!/usr/bin/env bash
# Uploads the releases in $RELEASES_DIR (made by scripts/release.sh) to simplmaker.com/updates/v<generation> over SFTP.
#   scripts/publish.sh            upload, then check what the web server serves
#   scripts/publish.sh --dry-run  show what would be uploaded
#
# Order matters: archives go up first, appcast.xml last, so a client never reads an appcast that names
# a file which is not there yet. Archives are immutable (one per version), so ones already on the
# server are skipped. Login is by SSH key; no password is stored or typed.
#
# Settings (environment overrides): defaults are the one.com account for simplmaker.com.
#   SFTP_USER, SFTP_HOST, SFTP_KEY, REMOTE_DIR (relative to the SFTP home), UPDATES_URL, RELEASES_DIR
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/licensing-conf.sh"

RELEASES_DIR="${RELEASES_DIR:-$HOME/SimplMakerReleases/v$LICENSE_GENERATION}"
SFTP_USER="${SFTP_USER:-sftp-user}"
SFTP_HOST="${SFTP_HOST:-ssh.example.com}"
SFTP_KEY="${SFTP_KEY:-$HOME/.ssh/simplcad_deploy}"
REMOTE_DIR="${REMOTE_DIR:-webroots/by-route/simplmaker.com_/updates/v$LICENSE_GENERATION}"
UPDATES_URL="${UPDATES_URL:-https://simplmaker.com/updates/v$LICENSE_GENERATION}"
DRY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    *) echo "unknown option $arg" >&2; exit 2 ;;
  esac
done

[ -s "$RELEASES_DIR/appcast.xml" ] || { echo "no appcast.xml in $RELEASES_DIR: run scripts/release.sh first" >&2; exit 1; }
[ -r "$SFTP_KEY" ] || { echo "SSH key $SFTP_KEY not found" >&2; exit 1; }

SFTP=(sftp -i "$SFTP_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20)
TARGET="$SFTP_USER@$SFTP_HOST"
sftp_batch() { "${SFTP[@]}" -b - "$TARGET"; }

# What is on the server now (the folder may not exist yet).
REMOTE_LIST="$(printf -- '-mkdir %s\n-mkdir %s\nls -1 %s\n' "$(dirname "$REMOTE_DIR")" "$REMOTE_DIR" "$REMOTE_DIR" | sftp_batch 2>/dev/null \
  | grep -v '^sftp>' | sed 's|.*/||' || true)"

# Archives the server does not have yet. Everything generate_appcast writes next to the appcast counts:
# zips, and delta files between versions. Release notes are embedded in the appcast, and old_updates/
# stays local.
NEW=()
while IFS= read -r -d '' file; do
  name="$(basename "$file")"
  if ! printf '%s\n' "$REMOTE_LIST" | grep -qxF "$name"; then NEW+=("$file"); fi
done < <(find "$RELEASES_DIR" -maxdepth 1 -type f \( -name '*.zip' -o -name '*.delta' \) -print0)

echo "Server: $TARGET:$REMOTE_DIR"
if [ ${#NEW[@]} -gt 0 ]; then
  printf 'New archives: %s\n' "$(printf '%s ' "${NEW[@]##*/}")"
else
  echo "New archives: none"
fi
echo "appcast.xml: will be replaced"
[ "$DRY" = 0 ] || exit 0

echo "==> Uploading"
{
  # Each archive goes up under a temporary name, then is renamed, so it is never half there when it appears.
  for file in ${NEW[@]+"${NEW[@]}"}; do
    name="$(basename "$file")"
    echo "put \"$file\" \"$REMOTE_DIR/$name.part\""
    echo "rename \"$REMOTE_DIR/$name.part\" \"$REMOTE_DIR/$name\""
  done
  # The appcast last. sftp's rename will not overwrite, so the old one is removed just before.
  echo "put \"$RELEASES_DIR/appcast.xml\" \"$REMOTE_DIR/appcast.xml.part\""
  echo "-rm \"$REMOTE_DIR/appcast.xml\""
  echo "rename \"$REMOTE_DIR/appcast.xml.part\" \"$REMOTE_DIR/appcast.xml\""
} | sftp_batch

echo "==> Checking $UPDATES_URL"
FAILED=0
check() {  # name, expected size
  local name="$1" want="$2" got
  got="$(curl -fsSIL --max-time 30 "$UPDATES_URL/$name" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:"{n=$2} END{print n}')" || got=""
  if [ -z "$got" ]; then echo "  FAIL $name: not served at $UPDATES_URL/$name (is HTTPS set up?)"; FAILED=1
  elif [ "$got" != "$want" ]; then echo "  FAIL $name: $got bytes served, $want expected"; FAILED=1
  else echo "  ok   $name ($got bytes)"; fi
}
for file in ${NEW[@]+"${NEW[@]}"}; do check "$(basename "$file")" "$(stat -f %z "$file")"; done
check appcast.xml "$(stat -f %z "$RELEASES_DIR/appcast.xml")"
[ "$FAILED" = 0 ] || { echo "Uploaded, but the web server does not serve the files as expected." >&2; exit 1; }
echo "Published. Feed: $UPDATES_URL/appcast.xml"
