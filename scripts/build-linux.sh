#!/bin/sh
# Release build of the pinned llama.cpp on Linux, FreeBSD (native CPU build), or macOS.
#   scripts/build-linux.sh
#   GPU=auto scripts/build-linux.sh
# FAMILIA_BACKEND (or GPU): auto (default: detect, see scripts/lib/backend.sh) | cpu | cuda | vulkan | metal
# JOBS, BUILD_DIR, NATIVE=ON, EXTRA_CMAKE_ARGS, ALLOW_UNPINNED=1
# Android/Termux: uname is Linux, but this desktop build leaves BUILD_DIR without the
# $ORIGIN rpath / subprocess flags Termux needs; hand off to build-termux.sh so
# $BUILD_DIR/bin/llama-server (the post-build check) actually runs.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
case "${PREFIX:-}" in
  *com.termux*)
    echo "build-linux.sh: Termux detected; handing off to scripts/build-termux.sh (BUILD_DIR + $ORIGIN rpath)" >&2
    exec "$ROOT/scripts/build-termux.sh"
    ;;
esac
. config/llama-pin.env
. scripts/lib/prereqs.sh
prereqs_check build || exit 1

[ -f llama.cpp/CMakeLists.txt ] || git submodule update --init --recursive || scripts/predownload.sh
if [ -f llama.cpp/.cbl-source-tag ]; then actual=$(cut -d' ' -f2 llama.cpp/.cbl-source-tag)   # unpacked tarball (predownload.sh)
else actual=$(git -C llama.cpp rev-parse HEAD); fi
if [ "$actual" != "$LLAMA_COMMIT" ]; then
  if [ "${ALLOW_UNPINNED:-0}" = 1 ]; then
    echo "build-linux.sh: WARNING: llama.cpp is at $actual, pin is $LLAMA_TAG ($LLAMA_COMMIT); ALLOW_UNPINNED=1" >&2
  else
    echo "build-linux.sh: llama.cpp is at $actual but the pin is $LLAMA_TAG ($LLAMA_COMMIT). Run: git submodule update --init (or set ALLOW_UNPINNED=1)" >&2
    exit 1
  fi
fi

# our patches (patches/*.patch) on top of the pinned source, every build
scripts/apply-patches.sh "$ROOT/llama.cpp"

ARCH=$(uname -m)
OS=$(uname -s)
case "$OS" in
  Darwin)
    OSNAME=macos
    JOBS=${JOBS:-$(sysctl -n hw.logicalcpu)}
    ;;
  FreeBSD)
    OSNAME=freebsd
    JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || printf '%s\n' 2)}
    ;;
  Linux)
    OSNAME=linux
    JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || printf '%s\n' 2)}
    ;;
  *)
    echo "build-linux.sh: unsupported operating system: $OS" >&2
    exit 1
    ;;
esac
BUILD_DIR_OVERRIDE=${BUILD_DIR:-}
NATIVE=${NATIVE:-OFF}

. scripts/lib/backend.sh
backend_detect || exit 1
GPU=$BACKEND
[ "$GPU" = cpu ] && GPU=off
# one build dir per backend + tag, so switching backend or pin never mixes objects
BUILD_DIR=${BUILD_DIR_OVERRIDE:-build-$OSNAME-$ARCH-$BACKEND-$LLAMA_TAG}
echo "build-linux.sh: os=$OSNAME arch=$ARCH gpu=$GPU native=$NATIVE jobs=$JOBS dir=$BUILD_DIR" >&2
export HF_UI_VERSION="$LLAMA_TAG"

set -- \
  -S llama.cpp -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_BUILD_NUMBER="$LLAMA_BUILD_NUMBER" \
  -DGGML_NATIVE="$NATIVE"
if [ "$NATIVE" = OFF ] && [ "$OSNAME" = linux ]; then
  case "$ARCH" in
    x86_64|amd64|aarch64|arm64) set -- "$@" -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON ;;
  esac
elif [ "$OSNAME" = linux ] && { [ "$GPU" = vulkan ] || [ "$GPU" = cuda ]; }; then
  set -- "$@" -DGGML_BACKEND_DL=ON
fi
case "$GPU" in
  off) [ "$OS" = Darwin ] && set -- "$@" -DGGML_METAL=OFF ;;
  metal) set -- "$@" -DGGML_METAL=ON ;;
  vulkan) set -- "$@" -DGGML_VULKAN=ON ;;
  cuda)
    [ -n "$NVCC" ] || { echo "build-linux.sh: GPU=cuda but nvcc not found" >&2; exit 1; }
    set -- "$@" -DGGML_CUDA=ON -DCMAKE_CUDA_COMPILER="$NVCC"
    [ -z "$CUDA_ARCH" ] || set -- "$@" -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH"
    ;;
  *) echo "build-linux.sh: unknown GPU=$GPU (off|auto|vulkan|cuda|metal)" >&2; exit 1 ;;
esac
command -v ninja >/dev/null 2>&1 && set -- "$@" -G Ninja
if [ -n "${EXTRA_CMAKE_ARGS:-}" ]; then
  set -f
  # shellcheck disable=SC2086
  set -- "$@" $EXTRA_CMAKE_ARGS
  set +f
fi
cmake "$@"
cmake --build "$BUILD_DIR" --config Release -j "$JOBS"
case "$BUILD_DIR" in
  /*) BUILD_ABS=$BUILD_DIR ;;
  *) BUILD_ABS=$ROOT/$BUILD_DIR ;;
esac
# Sibling libggml-* (GGML_BACKEND_DL) must resolve; LD_LIBRARY_PATH covers hosts where RUNPATH is missing.
LD_LIBRARY_PATH="$BUILD_ABS/bin${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"   "$BUILD_ABS/bin/llama-server" --version
