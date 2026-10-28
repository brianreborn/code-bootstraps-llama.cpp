# shellcheck shell=sh
# Pick ONE GPU backend for the build from the hardware (never two unless asked).
#   FAMILIA_BACKEND=auto(default)|cpu|cuda|vulkan|metal   (GPU=off|auto|cuda|vulkan|metal still works)
# Sets BACKEND, BACKEND_REASON and, for CUDA, CUDA_ARCH (detected compute capability only).
backend_detect() {
  bd_req=${FAMILIA_BACKEND:-${GPU:-auto}}
  [ "$bd_req" = off ] && bd_req=cpu
  CUDA_ARCH=""
  bd_nvcc=$(command -v nvcc 2>/dev/null || true)
  for c in "${CUDA_PATH:-}/bin/nvcc" "${CUDA_HOME:-}/bin/nvcc" /usr/local/cuda/bin/nvcc; do
    [ -z "$bd_nvcc" ] && [ -x "$c" ] && bd_nvcc=$c
  done
  NVCC=$bd_nvcc
  bd_nv_gpu=""
  command -v nvidia-smi >/dev/null 2>&1 && bd_nv_gpu=$(nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader 2>/dev/null | head -n 1 || true)
  bd_vk=0
  if command -v glslc >/dev/null 2>&1 && { pkg-config --exists vulkan 2>/dev/null || [ -n "${VULKAN_SDK:-}" ]; } \
     && command -v vulkaninfo >/dev/null 2>&1 && vulkaninfo --summary >/dev/null 2>&1; then bd_vk=1; fi
  bd_other_gpu=""
  command -v lspci >/dev/null 2>&1 && bd_other_gpu=$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | grep -viE 'nvidia' | head -n 1 || true)
  case "$bd_req" in
    cpu) BACKEND=cpu; BACKEND_REASON="requested" ;;
    metal) BACKEND=metal; BACKEND_REASON="requested" ;;
    cuda)
      [ -n "$bd_nvcc" ] || { echo "backend: cuda requested but nvcc not found (PATH, CUDA_PATH, CUDA_HOME)" >&2; return 1; }
      BACKEND=cuda; BACKEND_REASON="requested" ;;
    vulkan)
      [ "$bd_vk" = 1 ] || echo "backend: WARNING: vulkan requested but glslc/vulkan SDK/vulkaninfo not all found" >&2
      BACKEND=vulkan; BACKEND_REASON="requested" ;;
    auto)
      if [ "$(uname -s)" = Darwin ]; then BACKEND=metal; BACKEND_REASON="macOS"
      elif [ -n "$bd_nv_gpu" ] && [ -n "$bd_nvcc" ]; then BACKEND=cuda; BACKEND_REASON="NVIDIA GPU ($bd_nv_gpu) and CUDA toolkit ($bd_nvcc)"
      elif [ "$bd_vk" = 1 ] && { [ -n "$bd_other_gpu" ] || [ -n "$bd_nv_gpu" ]; }; then
        BACKEND=vulkan; BACKEND_REASON="GPU (${bd_other_gpu:-$bd_nv_gpu, no CUDA toolkit}) with Vulkan loader + glslc"
      else BACKEND=cpu; BACKEND_REASON="no NVIDIA GPU+CUDA toolkit and no usable Vulkan GPU+SDK"
      fi ;;
    *) echo "backend: unknown FAMILIA_BACKEND=$bd_req (auto|cpu|cuda|vulkan|metal)" >&2; return 1 ;;
  esac
  if [ "$BACKEND" = cuda ] && [ -n "$bd_nv_gpu" ]; then
    CUDA_ARCH=$(printf '%s\n' "$bd_nv_gpu" | awk -F', *' '{gsub(/\./,"",$2); print $2}')
  fi
  echo "backend: $BACKEND ($BACKEND_REASON)${CUDA_ARCH:+, CMAKE_CUDA_ARCHITECTURES=$CUDA_ARCH}" >&2
}
