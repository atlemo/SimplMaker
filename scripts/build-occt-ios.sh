#!/usr/bin/env bash
# Builds the same minimal static OpenCASCADE as build-occt.sh, but for iOS / iPadOS (arm64), and merges it into
# one archive per SDK: ThirdParty/occt-ios/<sdk>/lib/libSimplOCCT.a. On iOS the kernel is always linked statically
# (an app cannot ship a user-replaceable dylib); the app is open source, so anyone can rebuild and re-sign it.
#
# Usage: scripts/build-occt-ios.sh [iphoneos|iphonesimulator|both]    (default: both)
# Env:   OCCT_TAG (default V8_0_1), JOBS (default: CPU count), IOS_MIN (default 18.0),
#        OCCT_VISUALIZATION=ON to build the Visualization module too (off by default: the kernel never uses it)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OCCT_TAG="${OCCT_TAG:-V8_0_1}"
SRC="$ROOT/.build-occt/src-$OCCT_TAG"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN)}"
IOS_MIN="${IOS_MIN:-18.0}"
VIS="${OCCT_VISUALIZATION:-OFF}"
WHICH="${1:-both}"

if [ ! -d "$SRC" ]; then
  git clone --depth 1 --branch "$OCCT_TAG" https://github.com/Open-Cascade-SAS/OCCT.git "$SRC"
fi

build_one() {
  local sdk="$1"
  local build="$ROOT/.build-occt/build-ios-$sdk-$OCCT_TAG"
  local prefix="$ROOT/ThirdParty/occt-ios/$sdk"
  local sysroot
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  # The simulator on Apple silicon is arm64 too; only the SDK (and the -target triple) differ.
  local triple_suffix=""
  [ "$sdk" = "iphonesimulator" ] && triple_suffix="-simulator"
  local flags="-target arm64-apple-ios${IOS_MIN}${triple_suffix}"

  cmake -S "$SRC" -B "$build" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_C_FLAGS="$flags" -DCMAKE_CXX_FLAGS="$flags" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_LIBRARY_TYPE=Static \
    -DBUILD_MODULE_FoundationClasses=ON \
    -DBUILD_MODULE_ModelingData=ON \
    -DBUILD_MODULE_ModelingAlgorithms=ON \
    -DBUILD_MODULE_Visualization="$VIS" \
    -DBUILD_MODULE_ApplicationFramework=ON \
    -DBUILD_MODULE_DataExchange=ON \
    -DBUILD_MODULE_Draw=OFF \
    -DBUILD_MODULE_DETools=OFF \
    -DBUILD_DOC_Overview=OFF \
    -DBUILD_SAMPLES_QT=OFF \
    -DUSE_FREETYPE=OFF -DUSE_OPENGL=OFF -DUSE_GLES2=OFF -DUSE_XLIB=OFF \
    -DUSE_TK=OFF -DUSE_TCL=OFF -DUSE_TBB=OFF -DUSE_VTK=OFF \
    -DUSE_FREEIMAGE=OFF -DUSE_FFMPEG=OFF -DUSE_OPENVR=OFF -DUSE_RAPIDJSON=OFF -DUSE_DRACO=OFF

  cmake --build "$build" --parallel "$JOBS"
  cmake --install "$build"

  local libdir out
  libdir="$(dirname "$(find "$prefix" -name 'libTKernel.a' | head -1)")"
  out="$prefix/lib/libSimplOCCT.a"
  rm -f "$out"
  libtool -static -o "$out" "$libdir"/libTK*.a
  echo "OCCT for $sdk installed to $prefix ($(du -h "$out" | cut -f1) merged archive)"
}

case "$WHICH" in
  iphoneos|iphonesimulator) build_one "$WHICH" ;;
  both) build_one iphoneos; build_one iphonesimulator ;;
  *) echo "usage: $0 [iphoneos|iphonesimulator|both]" >&2; exit 2 ;;
esac
