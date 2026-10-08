#!/usr/bin/env bash
# Builds the website (website/build.py) and uploads website/public/ to simplmaker.com over SFTP.
#   scripts/publish-site.sh            build, upload, then check what the web server serves
#   scripts/publish-site.sh --dry-run  build and show what would be uploaded
#   scripts/publish-site.sh --print-batch  print the sftp commands without connecting
#   scripts/publish-site.sh --protect      also put the whole site behind a password (HTTP Basic auth) for testing
#   scripts/publish-site.sh --unprotect    remove the password protection (nothing else is uploaded or deleted)
#
# --protect reads "user:password" from ~/.simplmaker-site-auth (SITE_AUTH_FILE), creates the file with a random
# password if it does not exist, uploads the hashed .htpasswd to the SFTP home (outside the web root) and a
# .htaccess to the web root BEFORE any page, and then checks the site with those credentials. /updates/ (Sparkle
# cannot answer a password prompt) and /t/ (the unlisted test-build links) stay open. Re-run with --protect on every
# publish while the site is protected; a publish without it leaves the protection in place.
#
# Only website/public/ is touched. /updates/ (Sparkle, scripts/publish.sh) and /download/SimplMaker.dmg (the disk image,
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
SITE_AUTH_FILE="${SITE_AUTH_FILE:-$HOME/.simplmaker-site-auth}"
# Absolute path of the SFTP home as Apache sees it (printed by sftp's pwd); the .htpasswd lives there, not in the web root.
HTPASSWD_PATH="${HTPASSWD_PATH:-/customers/2/a/0/account/users/sftp-user/.htpasswd-simplmaker}"
DRY=0; PRINT=0; PROTECT=0; UNPROTECT=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --print-batch) PRINT=1; DRY=1 ;;
    --protect) PROTECT=1 ;;
    --unprotect) UNPROTECT=1 ;;
    *) echo "unknown option $arg" >&2; exit 2 ;;
  esac
done

SFTP=(sftp -i "$SFTP_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20)
[ -r "$SFTP_KEY" ] || { echo "SSH key $SFTP_KEY not found" >&2; exit 1; }

if [ "$UNPROTECT" = 1 ]; then
  [ "$DRY" = 0 ] || { echo "--unprotect has nothing to print"; exit 0; }
  printf '%s\n' "-rm \"$REMOTE_ROOT/.htaccess\"" "-rm \"$REMOTE_ROOT/updates/.htaccess\"" "-rm \"$REMOTE_ROOT/t/.htaccess\"" \
    "-rm \"${HTPASSWD_PATH#/customers/2/a/0/account/users/sftp-user/}\"" |
    "${SFTP[@]}" -b - "$SFTP_USER@$SFTP_HOST" >/dev/null
  echo "Password protection removed from $SITE_URL"; exit 0
fi

CURL_AUTH=()
PROTECT_DIR=""
if [ "$PROTECT" = 1 ]; then
  if [ ! -s "$SITE_AUTH_FILE" ]; then
    ( umask 077; echo "preview:$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)" > "$SITE_AUTH_FILE" )
    echo "Created $SITE_AUTH_FILE with a random password."
  fi
  AUTH_LINE="$(head -n1 "$SITE_AUTH_FILE")"; AUTH_USER="${AUTH_LINE%%:*}"; AUTH_PASS="${AUTH_LINE#*:}"
  CURL_AUTH=(-u "$AUTH_USER:$AUTH_PASS")
  PROTECT_DIR="$(mktemp -d)"; trap 'rm -rf "$PROTECT_DIR"' EXIT
  htpasswd -nbB "$AUTH_USER" "$AUTH_PASS" > "$PROTECT_DIR/htpasswd"
  cat > "$PROTECT_DIR/htaccess" <<HT
# Test-phase password for the whole site (scripts/publish-site.sh --protect; remove with --unprotect).
AuthType Basic
AuthName "SimplMaker (preview)"
AuthUserFile $HTPASSWD_PATH
Require valid-user
<IfModule mod_headers.c>
  Header always set X-Robots-Tag "noindex, nofollow"
  Header always set Cache-Control "private, no-store"
</IfModule>
HT
  printf '# Left open on purpose: Sparkle/test-build downloads cannot answer a password prompt.\nRequire all granted\n' > "$PROTECT_DIR/open"
fi

python3 "$ROOT/website/build.py"
PUBLIC="$ROOT/website/public"
[ -s "$PUBLIC/index.html" ] || { echo "build produced no index.html" >&2; exit 1; }

# Everything in public/ except /updates/ and the disk image (the release scripts own those; the Download page itself is uploaded).
FILES=()
while IFS= read -r -d '' f; do FILES+=("$f"); done < <(
  cd "$PUBLIC" && find . -type f ! -name '.DS_Store' ! -path './updates/*' ! -name '*.dmg' -print0 | sort -z)
# Pages last (assets first), index.html at the very end.
ASSETS=(); PAGES=()
for f in "${FILES[@]}"; do
  case "$f" in ./index.html) ;; *.html|./sitemap.xml) PAGES+=("$f") ;; *) ASSETS+=("$f") ;; esac
done
PAGES+=("./index.html")
ORDER=("${ASSETS[@]}" "${PAGES[@]}")

echo "Server: $SFTP_USER@$SFTP_HOST:$REMOTE_ROOT"
echo "Files:  ${#ORDER[@]} (${#ASSETS[@]} assets, ${#PAGES[@]} pages)"
protect_batch() {
  echo "put \"$PROTECT_DIR/htpasswd\" \"${HTPASSWD_PATH#/customers/2/a/0/account/users/sftp-user/}\""
  echo "-mkdir \"$REMOTE_ROOT/updates\""
  echo "-mkdir \"$REMOTE_ROOT/t\""
  echo "put \"$PROTECT_DIR/open\" \"$REMOTE_ROOT/updates/.htaccess\""
  echo "put \"$PROTECT_DIR/open\" \"$REMOTE_ROOT/t/.htaccess\""
  echo "put \"$PROTECT_DIR/htaccess\" \"$REMOTE_ROOT/.htaccess\""
}
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

[ "$PRINT" = 0 ] || { [ "$PROTECT" = 0 ] || protect_batch; batch; exit 0; }
[ "$DRY" = 0 ] || exit 0

if [ "$PROTECT" = 1 ]; then
  echo "==> Password protection first"
  protect_batch | "${SFTP[@]}" -b - "$SFTP_USER@$SFTP_HOST" >/dev/null
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$SITE_URL/?nocache=$RANDOM$RANDOM" || true)"   # the host's cache may still hold the old page for /
  [ "$code" = 401 ] || { echo "Expected HTTP 401 without a password but got $code; not uploading the site." >&2; exit 1; }
  echo "  ok   $SITE_URL/ asks for a password"
fi
echo "==> Uploading"
batch | "${SFTP[@]}" -b - "$SFTP_USER@$SFTP_HOST" >/dev/null

echo "==> Checking $SITE_URL"
FAILED=0
for path in / /features/ /pricing/ /compare/ /download/ /css/style.css; do
  code="$(curl -s ${CURL_AUTH[@]+"${CURL_AUTH[@]}"} -o /dev/null -w '%{http_code}' --max-time 30 "$SITE_URL$path" || true)"
  if [ "$code" = 200 ]; then echo "  ok   $path"; else echo "  FAIL $path: HTTP $code (is HTTPS set up?)"; FAILED=1; fi
done
[ "$FAILED" = 0 ] || { echo "Uploaded, but the web server does not serve everything as expected." >&2; exit 1; }
echo "Published: $SITE_URL"
