#!/usr/bin/env bash
# Compiles the C kernel test against SimplKernel.cpp + the static OCCT and runs it.
# Works on Linux and macOS; needs scripts/build-occt.sh to have run first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OCCT="$ROOT/ThirdParty/occt"
OUT="$ROOT/.build/kernel-test"
mkdir -p "$OUT"
CXX="${CXX:-c++}"; CC="${CC:-cc}"
EXTRA_LIBS=(-lpthread -lm)
[ "$(uname)" = "Darwin" ] && EXTRA_LIBS+=(-framework Foundation -framework AppKit -framework IOKit) || EXTRA_LIBS+=(-ldl)
"$CXX" -std=c++17 -O1 -c "$ROOT/Sources/CKernel/SimplKernel.cpp" -I "$ROOT/Sources/CKernel/include" \
  -I "$OCCT/include/opencascade" -o "$OUT/SimplKernel.o"
"$CC" -std=c11 -O1 -c "$ROOT/Tests/KernelCTests/kernel_test.c" -I "$ROOT/Sources/CKernel/include" -o "$OUT/kernel_test.o"
"$CXX" "$OUT/kernel_test.o" "$OUT/SimplKernel.o" -L "$OCCT/lib" -lSimplOCCT "${EXTRA_LIBS[@]}" -o "$OUT/kernel_test"
"$OUT/kernel_test"
