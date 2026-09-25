#!/usr/bin/env bash
# Builds a minimal, static OpenCASCADE into ThirdParty/occt and merges all
# toolkits into a single archive (lib/libSimplOCCT.a), so the app links one
# library with no external dependencies (no Tcl/Tk, FreeType, TBB, OpenGL, VTK).
#
# Usage: scripts/build-occt.sh            (macOS arm64 or Linux)
# Env:   OCCT_TAG (default V8_0_1), JOBS (default: CPU count)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OCCT_TAG="${OCCT_TAG:-V8_0_1}"
SRC="$ROOT/.build-occt/src-$OCCT_TAG"
BUILD="$ROOT/.build-occt/build-$OCCT_TAG"
PREFIX="$ROOT/ThirdParty/occt"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN)}"

if [ ! -d "$SRC" ]; then
  git clone --depth 1 --branch "$OCCT_TAG" https://github.com/Open-Cascade-SAS/OCCT.git "$SRC"
fi

EXTRA=()
if [ "$(uname)" = "Darwin" ]; then
  EXTRA+=(-DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0)
fi

cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DBUILD_LIBRARY_TYPE=Static \
  -DBUILD_MODULE_FoundationClasses=ON \
  -DBUILD_MODULE_ModelingData=ON \
  -DBUILD_MODULE_ModelingAlgorithms=ON \
  -DBUILD_MODULE_Visualization=ON \
  -DBUILD_MODULE_ApplicationFramework=ON \
  -DBUILD_MODULE_DataExchange=ON \
  -DBUILD_MODULE_Draw=OFF \
  -DBUILD_MODULE_DETools=OFF \
  -DBUILD_DOC_Overview=OFF \
  -DBUILD_SAMPLES_QT=OFF \
  -DUSE_FREETYPE=OFF -DUSE_OPENGL=OFF -DUSE_GLES2=OFF -DUSE_XLIB=OFF \
  -DUSE_TK=OFF -DUSE_TCL=OFF -DUSE_TBB=OFF -DUSE_VTK=OFF \
  -DUSE_FREEIMAGE=OFF -DUSE_FFMPEG=OFF -DUSE_OPENVR=OFF -DUSE_RAPIDJSON=OFF -DUSE_DRACO=OFF \
  "${EXTRA[@]}"

cmake --build "$BUILD" --parallel "$JOBS"
cmake --install "$BUILD"

# Merge every toolkit archive into one, so link order never matters.
LIBDIR="$(dirname "$(find "$PREFIX" -name 'libTKernel.a' | head -1)")"
OUT="$PREFIX/lib/libSimplOCCT.a"
rm -f "$OUT"
if [ "$(uname)" = "Darwin" ]; then
  libtool -static -o "$OUT" "$LIBDIR"/libTK*.a
else
  { echo "CREATE $OUT"; for a in "$LIBDIR"/libTK*.a; do echo "ADDLIB $a"; done; echo SAVE; echo END; } | ar -M
fi
echo "OCCT installed to $PREFIX (headers: $(dirname "$(find "$PREFIX" -name Standard.hxx | head -1)"))"
