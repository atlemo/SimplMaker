#!/usr/bin/env bash
# Turns screen recordings into the web clips the site expects.
#   brew install ffmpeg            (once)
#   website/make-clips.sh          convert everything in website/clips-raw/
#   website/make-clips.sh parameters hero    convert only those
#
# Put each recording in website/clips-raw/ named after its clip: hero.mov, parameters.mov, sketch.mov, extrude.mov,
# finish.mov, timeline.mov, export.mov, mac.mov (see SHOTLIST.md). Any format ffmpeg reads works.
# Output goes to website/src/static/video/<name>.mp4 / .webm / .jpg (poster): silent, 1280 px wide, 30 fps,
# faststart so playback begins before the download ends. Aim for 1 to 3 MB per clip.
# The width is 1280 unless you set WIDTH (a large, detail-heavy clip such as the full-window parameters recording
# wants its native width), and SRC picks a differently named recording for a single clip:
#   WIDTH=1728 CRF=20 SRC=parameters_16_9 website/make-clips.sh parameters
# CRF (x264, default 25; the webm gets CRF+9) trades size for sharpness, lower is sharper.
# The height always follows the recording, so the clip keeps its native aspect ratio.
set -euo pipefail
cd "$(dirname "$0")"
command -v ffmpeg >/dev/null || { echo "ffmpeg not found: brew install ffmpeg" >&2; exit 1; }
OUT=src/static/video
mkdir -p "$OUT"

if [ $# -gt 0 ]; then NAMES=("$@"); else
  NAMES=(); for f in clips-raw/*; do [ -f "$f" ] && [ "$(basename "$f")" != .gitignore ] && NAMES+=("$(basename "${f%.*}")"); done
fi
[ ${#NAMES[@]} -gt 0 ] || { echo "nothing in website/clips-raw/" >&2; exit 1; }

for name in "${NAMES[@]}"; do
  src="$(ls clips-raw/"${SRC:-$name}".* 2>/dev/null | head -n 1 || true)"
  [ -n "$src" ] || { echo "no recording for $name in clips-raw/" >&2; continue; }
  echo "==> $name ($src)"
  VF="scale=${WIDTH:-1280}:-2:flags=lanczos,fps=30,format=yuv420p"
  ffmpeg -y -loglevel error -i "$src" -an -vf "$VF" -c:v libx264 -preset slow -crf "${CRF:-25}" -movflags +faststart "$OUT/$name.mp4"
  ffmpeg -y -loglevel error -i "$src" -an -vf "$VF" -c:v libvpx-vp9 -crf "$((${CRF:-25} + 9))" -b:v 0 -row-mt 1 "$OUT/$name.webm"
  ffmpeg -y -loglevel error -ss 1 -i "$src" -frames:v 1 -vf "scale=${WIDTH:-1280}:-2:flags=lanczos" -q:v 4 "$OUT/$name.jpg"
  ls -lh "$OUT/$name".mp4 "$OUT/$name".webm "$OUT/$name".jpg | awk '{print "   " $5 "  " $9}'
done
echo "Now: python3 website/build.py, and look at the page."
