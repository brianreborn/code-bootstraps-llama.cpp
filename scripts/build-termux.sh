#!/usr/bin/env bash
# CPU Release build of the pinned llama.cpp inside Termux (Android, arm64).
# Prerequisites (once):  pkg install clang cmake git openssl
#   scripts/build-termux.sh          -> build-termux-<arch>/bin/
# Env: JOBS (default: 4, phones throttle and run out of RAM with more), BUILD_DIR, EXTRA_CMAKE_ARGS
#      GPU=off (default) | auto | vulkan   Vulkan for Adreno/Mali GPUs, built as a loadable module:
#           pkg install vulkan-headers vulkan-loader-android shaderc   (UNTESTED)
#           auto: vulkan if glslc and the vulkan pkg-config module are found
#      ALLOW_UNPINNED=1 (build even if the llama.cpp submodule is not at the pinned commit)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=../config/llama-pin.env
source config/llama-pin.env

[[ -f llama.cpp/CMakeLists.txt ]] || git submodule update --init --recursive
for t in clang cmake git; do
  command -v "$t" >/dev/null 2>&1 || { echo "build-termux.sh: missing $t; run: pkg install clang cmake git openssl" >&2; exit 1; }
done
actual="$(git -C llama.cpp rev-parse HEAD)"
if [[ "$actual" != "$LLAMA_COMMIT" ]]; then
  if [[ "${ALLOW_UNPINNED:-0}" == 1 ]]; then echo "build-termux.sh: WARNING: llama.cpp is at $actual, pin is $LLAMA_TAG ($LLAMA_COMMIT); ALLOW_UNPINNED=1" >&2
  else echo "build-termux.sh: llama.cpp is at $actual but the pin is $LLAMA_TAG ($LLAMA_COMMIT). Run: git submodule update --init (or set ALLOW_UNPINNED=1)" >&2; exit 1; fi
fi

ARCH="$(uname -m)"
BUILD_DIR="${BUILD_DIR:-build-termux-$ARCH}"
JOBS="${JOBS:-4}"
GPU="${GPU:-off}"
if [[ "$GPU" == "auto" ]]; then
  if command -v glslc >/dev/null 2>&1 && pkg-config --exists vulkan 2>/dev/null; then GPU=vulkan
  else GPU=off; echo "build-termux.sh: GPU=auto found no Vulkan toolchain (glslc + vulkan headers); CPU only" >&2; fi
fi
export HF_UI_VERSION="$LLAMA_TAG"

cmake_args=(
  -S llama.cpp -B "$BUILD_DIR"
  -DCMAKE_BUILD_TYPE=Release
  -DLLAMA_BUILD_NUMBER="$LLAMA_BUILD_NUMBER"
  -DLLAMA_BUILD_TESTS=OFF
  -DLLAMA_BUILD_EXAMPLES=OFF
  # upstream turns subprocess OFF on Android, but router mode, server tools and
  # MCP all need it (CMakeLists.txt: LLAMA_SUBPROCESS_DEFAULT)
  -DLLAMA_SUBPROCESS=ON
  -DGGML_NATIVE=OFF
  # Android arm64 CPU variants (dotprod, i8mm, sve2, ...) picked at runtime
  -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON
)
case "$GPU" in
  off) ;;
  vulkan) cmake_args+=(-DGGML_VULKAN=ON) ;;
  *) echo "build-termux.sh: unknown GPU=$GPU (off|auto|vulkan)" >&2; exit 1 ;;
esac
command -v ninja >/dev/null 2>&1 && cmake_args+=(-G Ninja)
# EXTRA_CMAKE_ARGS is split on whitespace only (no glob expansion)
if [[ -n "${EXTRA_CMAKE_ARGS:-}" ]]; then read -r -a extra_args <<< "$EXTRA_CMAKE_ARGS"; cmake_args+=("${extra_args[@]}"); fi

cmake "${cmake_args[@]}"
cmake --build "$BUILD_DIR" --config Release -j "$JOBS"
"$BUILD_DIR/bin/llama-server" --version
