#!/usr/bin/env bash
# Generates SimplCAD.xcodeproj from project.yml (needs XcodeGen: brew install xcodegen)
# and makes sure OpenCASCADE is built, then opens the project.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
command -v xcodegen >/dev/null || { echo "XcodeGen is missing: brew install xcodegen" >&2; exit 1; }
if [ ! -f ThirdParty/occt/lib/libSimplOCCT.a ]; then
  echo "OpenCASCADE isn't built yet; building it first (one time, ~10–20 min)…"
  scripts/build-occt.sh
fi
xcodegen generate --spec project.yml
[ "${1:-}" = "--no-open" ] || open SimplCAD.xcodeproj
