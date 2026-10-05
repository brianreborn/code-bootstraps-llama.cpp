#!/bin/sh
# CPU Release build inside Termux. Normally start.sh downloads the prebuilt Android asset.
# GPU=off (default) | auto | vulkan. ALLOW_UNPINNED=1. JOBS (default 4).
set -eu
umask 022
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
. config/llama-pin.env
. scripts/lib/common.sh
. scripts/lib/ui-assets.sh

[ -f llama.cpp/CMakeLists.txt ] || git submodule update --init --recursive
for t in clang cmake git curl tar; do
  command -v "$t" >/dev/null 2>&1 || { echo "build-termux.sh: missing $t; run: pkg install git clang cmake ninja" >&2; exit 1; }
done
actual=$(git -C llama.cpp rev-parse HEAD)
if [ "$actual" != "$LLAMA_COMMIT" ]; then
  if [ "${ALLOW_UNPINNED:-0}" = 1 ]; then
    echo "build-termux.sh: WARNING: llama.cpp is at $actual, pin is $LLAMA_TAG ($LLAMA_COMMIT); ALLOW_UNPINNED=1" >&2
  else
    echo "build-termux.sh: llama.cpp is at $actual but the pin is $LLAMA_TAG ($LLAMA_COMMIT)." >&2
    exit 1
  fi
fi

ARCH=$(uname -m)
BUILD_DIR=${BUILD_DIR:-build-termux-$ARCH}
JOBS=${JOBS:-4}
GPU=${GPU:-off}
if [ "$GPU" = auto ]; then
  if command -v glslc >/dev/null 2>&1 && pkg-config --exists vulkan 2>/dev/null; then GPU=vulkan
  else GPU=off; echo "build-termux.sh: GPU=auto found no Vulkan toolchain; CPU only" >&2; fi
fi
trap 'rm -rf "$ROOT/llama.cpp/tools/ui/dist"' EXIT
provide_ui_assets "$ROOT" || { echo "build-termux.sh: could not provide the pinned web UI" >&2; exit 1; }

set -- \
  -S llama.cpp -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_BUILD_NUMBER="$LLAMA_BUILD_NUMBER" \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_USE_PREBUILT_UI=OFF -DBORINGSSL_VERSION="$BORINGSSL_COMMIT" \
  -DLLAMA_SUBPROCESS=ON \
  -DCMAKE_C_FLAGS=-DSUBPROCESS_SPAWN_VIA_FORK=1 -DCMAKE_CXX_FLAGS=-DSUBPROCESS_SPAWN_VIA_FORK=1 \
  '-DCMAKE_EXE_LINKER_FLAGS=-Wl,-rpath,\$ORIGIN' '-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-rpath,\$ORIGIN' \
  '-DCMAKE_MODULE_LINKER_FLAGS=-Wl,-rpath,\$ORIGIN' \
  -DGGML_NATIVE=OFF \
  -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON
case "$GPU" in
  off) ;;
  vulkan) set -- "$@" -DGGML_VULKAN=ON ;;
  *) echo "build-termux.sh: unknown GPU=$GPU (off|auto|vulkan)" >&2; exit 1 ;;
esac
if command -v ninja >/dev/null 2>&1; then set -- "$@" -G Ninja
else echo "build-termux.sh: ninja not found; using make" >&2; fi
if [ -n "${EXTRA_CMAKE_ARGS:-}" ]; then
  set -f
  # shellcheck disable=SC2086
  set -- "$@" $EXTRA_CMAKE_ARGS
  set +f
fi
cmake "$@"
# tee loses the build status; the rc file keeps it
( set +e
  cmake --build "$BUILD_DIR" --config Release -j "$JOBS" --target llama-server
  echo $? > "$BUILD_DIR/build-output.rc"
) | tee "$BUILD_DIR/build-output.log"
rc=$(cat "$BUILD_DIR/build-output.rc")
[ "$rc" = 0 ] || { echo "build-termux.sh: build failed" >&2; exit 1; }
if ! grep -q "UI: using pre-built assets from $ROOT/llama.cpp/tools/ui/dist" "$BUILD_DIR/build-output.log" &&
   ! grep -q "UI: assets unchanged" "$BUILD_DIR/build-output.log"; then
  echo "build-termux.sh: the build did not embed the pinned web UI" >&2
  exit 1
fi
case "${EXTRA_CMAKE_ARGS:-}" in
  *CMAKE_TOOLCHAIN_FILE*) echo "build-termux.sh: cross build: $BUILD_DIR/bin/llama-server (not run here)" >&2 ;;
  *) "$BUILD_DIR/bin/llama-server" --version ;;
esac
