# shellcheck shell=sh
# Which llama.cpp release variant can use a GPU on this machine.
# macOS Metal is inside the cpu asset. Android stays cpu.
# Prints: cpu | vulkan | cuda-12

gpu_variant() {
  case "$(uname -s)" in
    Darwin) printf '%s\n' cpu; return ;;
  esac
  case "${PREFIX:-}" in *com.termux*) printf '%s\n' cpu; return ;; esac
  [ -n "${ANDROID_ROOT:-}" ] && { printf '%s\n' cpu; return; }
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    printf '%s\n' cuda-12
    return
  fi
  if [ -e /dev/dri/renderD128 ]; then
    printf '%s\n' vulkan
    return
  fi
  printf '%s\n' cpu
}
