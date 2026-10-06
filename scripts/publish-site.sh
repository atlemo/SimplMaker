#!/usr/bin/env bash
# Builds the website (website/build.py) and uploads website/public/ to simplmaker.com over SFTP.
#   scripts/publish-site.sh            build, upload, then check what the web server serves
#   scripts/publish-site.sh --dry-run  build and show what would be uploaded
#   scripts/publish-site.sh --print-batch  print the sftp commands without connecting
#
# Only website/public/ is touched. /updates/ (Sparkle, scripts/publish.sh) and /download/ (the disk image,
# scripts/make-dmg.sh --upload-download) are never deleted or overwritten by a site upload. Files are uploaded
# under a temporary name and renamed, pages last,
# so a visitor never sees a page that points at assets that are not there yet. Files you delete from the site
# stay on the server until you remove them by hand: this script only adds and replaces.
#
# Settings (environment overrides): SFTP_USER, SFTP_HOST, SFTP_KEY, REMOTE_ROOT (relative to the SFTP home),
# SITE_URL.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SFTP_USER="${SFTP_USER:-sftp-user}"
SFTP_HOST="${SFTP_HOST:-ssh.example.com}"
SFTP_KEY="${SFTP_KEY:-$HOME/.ssh/simplcad_deploy}"
REMOTE_ROOT="${REMOTE_ROOT:-webroots/by-route/simplmaker.com_}"
SITE_URL="${SITE_URL:-https://simplmaker.com}"
DRY=0; PRINT=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --print-batch) PRINT=1; DRY=1 ;;
    *) echo "unknown option $arg" >&2; exit 2 ;;
  esac
done

python3 "$ROOT/website/build.py"
PUBLIC="$ROOT/website/public"
[ -s "$PUBLIC/index.html" ] || { echo "build produced no index.html" >&2; exit 1; }
[ -r "$SFTP_KEY" ] || { echo "SSH key $SFTP_KEY not found" >&2; exit 1; }

# Everything in public/ except the folders the release scripts own (build.py never creates them).
FILES=()
while IFS= read -r -d '' f; do FILES+=("$f"); done < <(
  cd "$PUBLIC" && find . -type f ! -name '.DS_Store' ! -path './updates/*' ! -path './download/*' -print0 | sort -z)
# Pages last (assets first), index.html at the very end.
ASSETS=(); PAGES=()
for f in "${FILES[@]}"; do
  case "$f" in ./index.html) ;; *.html|./sitemap.xml) PAGES+=("$f") ;; *) ASSETS+=("$f") ;; esac
done
PAGES+=("./index.html")
ORDER=("${ASSETS[@]}" "${PAGES[@]}")

echo "Server: $SFTP_USER@$SFTP_HOST:$REMOTE_ROOT"
echo "Files:  ${#ORDER[@]} (${#ASSETS[@]} assets, ${#PAGES[@]} pages)"
batch() {
  # Directories first (-mkdir ignores "already exists").
  (cd "$PUBLIC" && for f in "${ORDER[@]}"; do dirname "$f"; done | sort -u | sed 's|^\./||; s|^\.$||' | while read -r d; do
      [ -z "$d" ] || { p=""; IFS=/ read -ra parts <<< "$d"; for part in "${parts[@]}"; do p="$p$part"; echo "-mkdir \"$REMOTE_ROOT/$p\""; p="$p/"; done; }
    done | awk '!seen[$0]++')
  for f in "${ORDER[@]}"; do
    rel="${f#./}"
    echo "put \"$PUBLIC/$rel\" \"$REMOTE_ROOT/$rel.part\""
    echo "-rm \"$REMOTE_ROOT/$rel\""
    echo "rename \"$REMOTE_ROOT/$rel.part\" \"$REMOTE_ROOT/$rel\""
  done
}

[ "$PRINT" = 0 ] || { batch; exit 0; }
[ "$DRY" = 0 ] || exit 0

echo "==> Uploading"
batch | sftp -i "$SFTP_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20 -b - "$SFTP_USER@$SFTP_HOST" >/dev/null

echo "==> Checking $SITE_URL"
FAILED=0
for path in / /features/ /pricing/ /compare/ /download/ /css/style.css; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$SITE_URL$path" || true)"
  if [ "$code" = 200 ]; then echo "  ok   $path"; else echo "  FAIL $path: HTTP $code (is HTTPS set up?)"; FAILED=1; fi
done
[ "$FAILED" = 0 ] || { echo "Uploaded, but the web server does not serve everything as expected." >&2; exit 1; }
echo "Published: $SITE_URL"
