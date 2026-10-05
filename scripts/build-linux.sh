#!/bin/sh
# Release build of the pinned llama.cpp on Linux or macOS.
#   scripts/build-linux.sh
#   GPU=auto scripts/build-linux.sh
# GPU: off (Linux default) | auto | vulkan | cuda | metal (macOS default)
# JOBS, BUILD_DIR, NATIVE=ON, EXTRA_CMAKE_ARGS, ALLOW_UNPINNED=1
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
. config/llama-pin.env

[ -f llama.cpp/CMakeLists.txt ] || git submodule update --init --recursive
actual=$(git -C llama.cpp rev-parse HEAD)
if [ "$actual" != "$LLAMA_COMMIT" ]; then
  if [ "${ALLOW_UNPINNED:-0}" = 1 ]; then
    echo "build-linux.sh: WARNING: llama.cpp is at $actual, pin is $LLAMA_TAG ($LLAMA_COMMIT); ALLOW_UNPINNED=1" >&2
  else
    echo "build-linux.sh: llama.cpp is at $actual but the pin is $LLAMA_TAG ($LLAMA_COMMIT). Run: git submodule update --init (or set ALLOW_UNPINNED=1)" >&2
    exit 1
  fi
fi

ARCH=$(uname -m)
OS=$(uname -s)
if [ "$OS" = Darwin ]; then
  OSNAME=macos
  JOBS=${JOBS:-$(sysctl -n hw.logicalcpu)}
  GPU=${GPU:-metal}
else
  OSNAME=linux
  JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN)}
  GPU=${GPU:-off}
fi
BUILD_DIR=${BUILD_DIR:-build-$OSNAME-$ARCH}
NATIVE=${NATIVE:-OFF}

NVCC=$(command -v nvcc 2>/dev/null || true)
for c in "${CUDA_HOME:-}/bin/nvcc" /usr/local/cuda/bin/nvcc; do
  [ -z "$NVCC" ] && [ -x "$c" ] && NVCC=$c
done
if [ "$GPU" = auto ]; then
  if [ "$OS" = Darwin ]; then GPU=metal
  elif [ -n "$NVCC" ]; then GPU=cuda
  elif command -v glslc >/dev/null 2>&1 && pkg-config --exists vulkan 2>/dev/null; then GPU=vulkan
  else GPU=off; echo "build-linux.sh: GPU=auto found no CUDA (nvcc) or Vulkan (glslc + vulkan headers); CPU only" >&2
  fi
fi
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
"$BUILD_DIR/bin/llama-server" --version
