# Sourced by the build and release scripts (needs $ROOT): reads Packaging/licensing.conf.
#   conf_get KEY        the value of KEY= in the file, or nothing
#   LICENSE_GENERATION  the major version being sold (default 1). Each major version is a separate product with its
#                       own keys, its own trial and its own update feed (updates/v1/, updates/v2/, ...), so SimplMaker 1
#                       keeps working and keeps its updates when SimplMaker 2 comes out.
# LICENSING_CONF=<file> reads another file (a relative path is from the repo root), e.g. Packaging/licensing.sandbox.conf.
LICENSING_CONF="${LICENSING_CONF:-Packaging/licensing.conf}"
case "$LICENSING_CONF" in /*) ;; *) LICENSING_CONF="$ROOT/$LICENSING_CONF" ;; esac
conf_get() { if [ -f "$LICENSING_CONF" ]; then sed -n "s/^$1=//p" "$LICENSING_CONF" | tr -d '[:space:]' | head -n 1; fi; }
LICENSE_GENERATION="${LICENSE_GENERATION:-$(conf_get LICENSE_GENERATION)}"
LICENSE_GENERATION="${LICENSE_GENERATION:-1}"
