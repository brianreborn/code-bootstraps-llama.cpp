#!/usr/bin/env bash
# CPU Release build of the pinned llama.cpp inside Termux (Android, arm64). Normally not
# needed: start.sh downloads this repository's prebuilt Android build (see
# scripts/build-android-release.sh); this is the fallback. Takes 30-90 min on a phone.
# Prerequisites (once):  pkg install git clang cmake ninja
#   scripts/build-termux.sh          -> build-termux-<arch>/bin/llama-server
# Env: JOBS (default: 4, phones throttle and run out of RAM with more; JOBS=2 if clang gets
#      killed), BUILD_DIR, EXTRA_CMAKE_ARGS (a CMAKE_TOOLCHAIN_FILE there = cross build: the
#      final --version check is skipped)
#      GPU=off (default) | auto | vulkan   Vulkan, built as a loadable module (UNTESTED):
#           pkg install vulkan-headers vulkan-loader-android shaderc
#           ggml-vulkan needs Vulkan 1.2: older Mali/Adreno drivers (Android 10 and earlier,
#           e.g. Mali-G72) cannot run it; Samsung Xclipse (RDNA) is the one worth trying
#           auto: vulkan if glslc and the vulkan pkg-config module are found
#      ALLOW_UNPINNED=1 (build even if the llama.cpp submodule is not at the pinned commit)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=../config/llama-pin.env
source config/llama-pin.env

[[ -f llama.cpp/CMakeLists.txt ]] || git submodule update --init --recursive
for t in clang cmake git; do
  command -v "$t" >/dev/null 2>&1 || { echo "build-termux.sh: missing $t; run: pkg install git clang cmake ninja" >&2; exit 1; }
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
  # MCP all need it (CMakeLists.txt: LLAMA_SUBPROCESS_DEFAULT). Its posix_spawn path calls
  # posix_spawn_file_actions_addchdir_np, which bionic has only from API 34 (Android 14):
  # SUBPROCESS_SPAWN_VIA_FORK uses fork+chdir+exec instead.
  -DLLAMA_SUBPROCESS=ON
  -DCMAKE_C_FLAGS=-DSUBPROCESS_SPAWN_VIA_FORK=1 -DCMAKE_CXX_FLAGS=-DSUBPROCESS_SPAWN_VIA_FORK=1
  # Android's linker does not look next to the executable, and CMake's Android platform
  # ignores CMAKE_INSTALL_RPATH. \$ORIGIN: the backslash keeps the $ for the linker.
  '-DCMAKE_EXE_LINKER_FLAGS=-Wl,-rpath,\$ORIGIN' '-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-rpath,\$ORIGIN'
  '-DCMAKE_MODULE_LINKER_FLAGS=-Wl,-rpath,\$ORIGIN'
  -DGGML_NATIVE=OFF
  # Android arm64 CPU variants (dotprod, i8mm, sve2, ...) picked at runtime
  -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON
)
case "$GPU" in
  off) ;;
  vulkan) cmake_args+=(-DGGML_VULKAN=ON) ;;
  *) echo "build-termux.sh: unknown GPU=$GPU (off|auto|vulkan)" >&2; exit 1 ;;
esac
# Ninja: much faster on a phone (the \$ORIGIN quoting above works with make too)
if command -v ninja >/dev/null 2>&1; then cmake_args+=(-G Ninja)
else echo "build-termux.sh: ninja not found (pkg install ninja); using make" >&2; fi
# EXTRA_CMAKE_ARGS is split on whitespace only (no glob expansion)
if [[ -n "${EXTRA_CMAKE_ARGS:-}" ]]; then read -r -a extra_args <<< "$EXTRA_CMAKE_ARGS"; cmake_args+=("${extra_args[@]}"); fi

cmake "${cmake_args[@]}"
# llama-server only (it pulls in the CPU variant modules): 30-50% less work than every tool
cmake --build "$BUILD_DIR" --config Release -j "$JOBS" --target llama-server
if [[ "${EXTRA_CMAKE_ARGS:-}" == *CMAKE_TOOLCHAIN_FILE* ]]; then
  echo "build-termux.sh: cross build: $BUILD_DIR/bin/llama-server (not run here)" >&2
else "$BUILD_DIR/bin/llama-server" --version; fi
