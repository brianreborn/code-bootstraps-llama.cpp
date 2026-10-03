#!/usr/bin/env bash
# Portable Release build of the pinned llama.cpp on Linux (x86_64, aarch64) or macOS.
#   scripts/build-linux.sh                 -> build-<os>-<arch>/bin/   (CPU only on Linux)
#   GPU=auto scripts/build-linux.sh        -> also build a GPU backend if the toolchain is found
# Env:
#   GPU     off (Linux default) | auto | vulkan | cuda | metal (macOS default)
#           auto: cuda if nvcc is on PATH, else vulkan if glslc + the vulkan pkg-config module exist
#           With GGML_BACKEND_DL=ON the GPU backend is a loadable module next to the CPU variants:
#           the same package uses the GPU when one is usable and falls back to the CPU otherwise.
#           CUDA: nvcc is looked up on PATH, then $CUDA_HOME/bin and /usr/local/cuda/bin.
#   JOBS (default: logical CPUs), BUILD_DIR, NATIVE=ON (tune for this CPU only), EXTRA_CMAKE_ARGS,
#   ALLOW_UNPINNED=1 (build even if the llama.cpp submodule is not at the pinned commit)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=../config/llama-pin.env
source config/llama-pin.env

[[ -f llama.cpp/CMakeLists.txt ]] || git submodule update --init --recursive
actual="$(git -C llama.cpp rev-parse HEAD)"
if [[ "$actual" != "$LLAMA_COMMIT" ]]; then
  if [[ "${ALLOW_UNPINNED:-0}" == 1 ]]; then echo "build-linux.sh: WARNING: llama.cpp is at $actual, pin is $LLAMA_TAG ($LLAMA_COMMIT); ALLOW_UNPINNED=1" >&2
  else echo "build-linux.sh: llama.cpp is at $actual but the pin is $LLAMA_TAG ($LLAMA_COMMIT). Run: git submodule update --init (or set ALLOW_UNPINNED=1)" >&2; exit 1; fi
fi

ARCH="$(uname -m)"
OS="$(uname -s)"
if [[ "$OS" == "Darwin" ]]; then
  OSNAME=macos; JOBS="${JOBS:-$(sysctl -n hw.logicalcpu)}"; GPU="${GPU:-metal}"
else
  OSNAME=linux; JOBS="${JOBS:-$(nproc)}"; GPU="${GPU:-off}"
fi
BUILD_DIR="${BUILD_DIR:-build-$OSNAME-$ARCH}"
NATIVE="${NATIVE:-OFF}"

NVCC="$(command -v nvcc 2>/dev/null || true)"
for c in "${CUDA_HOME:-}/bin/nvcc" /usr/local/cuda/bin/nvcc; do
  [[ -z "$NVCC" && -x "$c" ]] && NVCC="$c"
done
if [[ "$GPU" == "auto" ]]; then
  if [[ "$OS" == "Darwin" ]]; then GPU=metal
  elif [[ -n "$NVCC" ]]; then GPU=cuda
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
elif [[ "$OSNAME" == "linux" && ( "$GPU" == "vulkan" || "$GPU" == "cuda" ) ]]; then
  # NATIVE=ON + GPU: still build the backends as modules (one native CPU module), so the
  # binaries start and fall back to the CPU when the GPU driver/runtime is missing
  cmake_args+=(-DGGML_BACKEND_DL=ON)
fi
# (macOS: upstream does not support GGML_CPU_ALL_VARIANTS on Darwin; Metal is built in by default)
case "$GPU" in
  off)    [[ "$OS" == "Darwin" ]] && cmake_args+=(-DGGML_METAL=OFF) ;;
  metal)  cmake_args+=(-DGGML_METAL=ON) ;;
  vulkan) cmake_args+=(-DGGML_VULKAN=ON) ;;
  cuda)   [[ -n "$NVCC" ]] || { echo "build-linux.sh: GPU=cuda but nvcc not found (PATH, \$CUDA_HOME/bin, /usr/local/cuda/bin)" >&2; exit 1; }
          cmake_args+=(-DGGML_CUDA=ON -DCMAKE_CUDA_COMPILER="$NVCC") ;;
  *) echo "build-linux.sh: unknown GPU=$GPU (off|auto|vulkan|cuda|metal)" >&2; exit 1 ;;
esac
command -v ninja >/dev/null 2>&1 && cmake_args+=(-G Ninja)
# EXTRA_CMAKE_ARGS is split on whitespace only (no glob expansion)
if [[ -n "${EXTRA_CMAKE_ARGS:-}" ]]; then read -r -a extra_args <<< "$EXTRA_CMAKE_ARGS"; cmake_args+=("${extra_args[@]}"); fi

cmake "${cmake_args[@]}"
cmake --build "$BUILD_DIR" --config Release -j "$JOBS"
"$BUILD_DIR/bin/llama-server" --version
