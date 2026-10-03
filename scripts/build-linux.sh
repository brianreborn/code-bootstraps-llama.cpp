#!/usr/bin/env bash
# Portable Release build of the pinned llama.cpp on Linux (x86_64, aarch64) or macOS.
#   scripts/build-linux.sh                 -> build-<os>-<arch>/bin/   (CPU only on Linux)
#   GPU=auto scripts/build-linux.sh        -> also build a GPU backend if the toolchain is found
# Env:
#   GPU     off (Linux default) | auto | vulkan | cuda | metal (macOS default)
#           auto: cuda if nvcc is on PATH, else vulkan if glslc + the vulkan pkg-config module exist
#           With GGML_BACKEND_DL=ON the GPU backend is a loadable module next to the CPU variants:
#           the same package uses the GPU when one is usable and falls back to the CPU otherwise.
#   JOBS (default: logical CPUs), BUILD_DIR, NATIVE=ON (tune for this CPU only), EXTRA_CMAKE_ARGS
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=../config/llama-pin.env
source config/llama-pin.env

[[ -f llama.cpp/CMakeLists.txt ]] || git submodule update --init --recursive
actual="$(git -C llama.cpp rev-parse HEAD)"
[[ "$actual" == "$LLAMA_COMMIT" ]] || echo "build-linux.sh: WARNING: llama.cpp is at $actual, pin is $LLAMA_TAG ($LLAMA_COMMIT)" >&2

ARCH="$(uname -m)"
OS="$(uname -s)"
if [[ "$OS" == "Darwin" ]]; then
  OSNAME=macos; JOBS="${JOBS:-$(sysctl -n hw.logicalcpu)}"; GPU="${GPU:-metal}"
else
  OSNAME=linux; JOBS="${JOBS:-$(nproc)}"; GPU="${GPU:-off}"
fi
BUILD_DIR="${BUILD_DIR:-build-$OSNAME-$ARCH}"
NATIVE="${NATIVE:-OFF}"

if [[ "$GPU" == "auto" ]]; then
  if [[ "$OS" == "Darwin" ]]; then GPU=metal
  elif command -v nvcc >/dev/null 2>&1; then GPU=cuda
  elif command -v glslc >/dev/null 2>&1 && pkg-config --exists vulkan 2>/dev/null; then GPU=vulkan
  else GPU=off; echo "build-linux.sh: GPU=auto found no CUDA (nvcc) or Vulkan (glslc + vulkan headers); CPU only" >&2
  fi
fi
echo "build-linux.sh: os=$OSNAME arch=$ARCH gpu=$GPU native=$NATIVE jobs=$JOBS dir=$BUILD_DIR" >&2

# pin the prebuilt web UI to the same release instead of falling back to "latest"
export HF_UI_VERSION="$LLAMA_TAG"

cmake_args=(
  -S llama.cpp -B "$BUILD_DIR"
  -DCMAKE_BUILD_TYPE=Release
  -DLLAMA_BUILD_NUMBER="$LLAMA_BUILD_NUMBER"
  -DGGML_NATIVE="$NATIVE"
)
if [[ "$NATIVE" == "OFF" && "$OSNAME" == "linux" ]]; then
  case "$ARCH" in
    # one package for every x86-64 / arm64 CPU: the best CPU backend (and the GPU backend,
    # if built) are loadable modules picked at runtime
    x86_64|amd64|aarch64|arm64) cmake_args+=(-DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON) ;;
  esac
fi
# (macOS: upstream does not support GGML_CPU_ALL_VARIANTS on Darwin; Metal is built in by default)
case "$GPU" in
  off)    [[ "$OS" == "Darwin" ]] && cmake_args+=(-DGGML_METAL=OFF) ;;
  metal)  cmake_args+=(-DGGML_METAL=ON) ;;
  vulkan) cmake_args+=(-DGGML_VULKAN=ON) ;;
  cuda)   cmake_args+=(-DGGML_CUDA=ON) ;;
  *) echo "build-linux.sh: unknown GPU=$GPU (off|auto|vulkan|cuda|metal)" >&2; exit 1 ;;
esac
command -v ninja >/dev/null 2>&1 && cmake_args+=(-G Ninja)
# shellcheck disable=SC2206
[[ -n "${EXTRA_CMAKE_ARGS:-}" ]] && cmake_args+=($EXTRA_CMAKE_ARGS)

cmake "${cmake_args[@]}"
cmake --build "$BUILD_DIR" --config Release -j "$JOBS"
"$BUILD_DIR/bin/llama-server" --version
