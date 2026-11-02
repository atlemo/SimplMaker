# Sourced by the release scripts (needs $ROOT). Your own release settings live in scripts/release.local.env, which is
# not in git: the server you upload to, the SSH key you log in with, the keychain names of your signing credentials.
# Copy scripts/release.local.env.example to it and fill it in. RELEASE_ENV=<file> reads another file.
# Nothing in there is a password: the server login is an SSH key (the key file stays in ~/.ssh), and the notarization
# and update-signing credentials stay in the macOS keychain. Never put a password in this repository.
RELEASE_ENV="${RELEASE_ENV:-$ROOT/scripts/release.local.env}"
if [ -f "$RELEASE_ENV" ]; then . "$RELEASE_ENV"; fi

SFTP_USER="${SFTP_USER:-}"; SFTP_HOST="${SFTP_HOST:-}"; SFTP_KEY="${SFTP_KEY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-SimplMaker}"

require_sftp() {
  [ -n "$SFTP_USER" ] && [ -n "$SFTP_HOST" ] && [ -n "$SFTP_KEY" ] \
    || { echo "SFTP_USER, SFTP_HOST and SFTP_KEY are not set: see scripts/release.local.env.example" >&2; exit 1; }
  [ -r "$SFTP_KEY" ] || { echo "SSH key $SFTP_KEY not found" >&2; exit 1; }
}
require_notary() {
  [ -n "$NOTARY_PROFILE" ] || { echo "NOTARY_PROFILE is not set: see scripts/release.local.env.example" >&2; exit 1; }
}
