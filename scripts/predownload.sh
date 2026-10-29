#!/bin/sh
# Fetch everything a source build + first start needs, up front, so the rest can run offline:
#   1. toolchain packages (download only, not installed: apt/dnf/pacman/brew/pkg cache)
#   2. the pinned llama.cpp source tarball (sha256-checked) -> .cache/predownload/
#      and, in a git checkout, the pinned submodule
#   3. the pinned web UI asset (sha256-checked)
#   4. the default models (scripts/fetch-models.sh: LFM3-1.7B and the other pick=default roles)
#   scripts/predownload.sh          SKIP_PACKAGES=1 / SKIP_MODELS=1 to leave a step out
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
. config/llama-pin.env
. scripts/lib/common.sh
. scripts/lib/prereqs.sh
D=$ROOT/.cache/predownload; mkdir -p "$D"
MK_TAG=predownload; . "$ROOT/lib/msg.mk"   # say

if [ "${SKIP_PACKAGES:-0}" != 1 ]; then
  pk=$(prereqs_packages)
  # only the selected backend's extra toolchain (scripts/lib/backend.sh)
  . scripts/lib/backend.sh; backend_detect || true
  case "$BACKEND:$(prereqs_platform)" in
    vulkan:linux-apt) pk="$pk libvulkan-dev glslc vulkan-tools" ;;
    vulkan:linux-dnf) pk="$pk vulkan-loader-devel glslc vulkan-tools" ;;
    vulkan:linux-pacman) pk="$pk vulkan-icd-loader vulkan-headers shaderc vulkan-tools" ;;
    vulkan:termux) pk="$pk vulkan-headers vulkan-loader-android shaderc" ;;
    cuda:*) say "CUDA toolkit: install it from NVIDIA (not pre-downloaded here)" ;;
  esac
  say "toolchain packages ($(prereqs_platform)): $pk"
  case "$(prereqs_platform)" in
    # shellcheck disable=SC2086
    linux-apt) sudo apt-get update && sudo apt-get install -y --download-only $pk ;;
    # shellcheck disable=SC2086
    linux-dnf) sudo dnf install -y --downloadonly $pk ;;
    # shellcheck disable=SC2086
    linux-pacman) sudo pacman -Sw --needed --noconfirm $pk ;;
    # shellcheck disable=SC2086
    macos) command -v brew >/dev/null 2>&1 && brew fetch $pk || say "Homebrew not found; install Xcode CLT + Homebrew, then: $(prereqs_install_hint)" ;;
    # shellcheck disable=SC2086
    termux) pkg update -y && apt-get install -y --download-only $pk ;;
    # shellcheck disable=SC2086
    freebsd) sudo pkg fetch -y -d $pk ;;
    *) say "unknown platform; install by hand: $pk" ;;
  esac || say "package download failed; install later with: $(prereqs_install_hint)"
fi

fetch_checked() { # url sha256 dest
  if [ -f "$3" ] && [ "$(sha256_of "$3")" = "$2" ]; then say "have $(basename "$3")"; return 0; fi
  curl -fL --retry 3 -o "$3.part" "$1"
  got=$(sha256_of "$3.part")
  [ "$got" = "$2" ] || { rm -f "$3.part"; say "sha256 mismatch for $1 (got $got, want $2)"; exit 1; }
  mv -f "$3.part" "$3"; say "fetched $(basename "$3") (sha256 ok)"
}
fetch_checked "$LLAMA_SRC_URL" "$LLAMA_SRC_SHA256" "$D/llama.cpp-$LLAMA_TAG.tar.gz"
fetch_checked "$LLAMA_UI_URL" "$LLAMA_UI_SHA256" "$D/llama-$LLAMA_TAG-ui.tar.gz"

if [ -e .git ] && command -v git >/dev/null 2>&1; then
  git submodule update --init llama.cpp || say "submodule fetch failed; the tarball will be used"
fi
if [ ! -f llama.cpp/CMakeLists.txt ]; then
  # archive install (no git checkout): unpack the pinned tarball as the source tree
  mkdir -p llama.cpp && tar -xzf "$D/llama.cpp-$LLAMA_TAG.tar.gz" -C llama.cpp --strip-components=1
  printf '%s %s\n' "$LLAMA_TAG" "$LLAMA_COMMIT" > llama.cpp/.cbl-source-tag
  say "unpacked llama.cpp $LLAMA_TAG into llama.cpp/"
fi
CHECK=1 scripts/apply-patches.sh "$ROOT/llama.cpp"

[ "${SKIP_MODELS:-0}" = 1 ] || scripts/fetch-models.sh
say "done: you can now build and start offline (start.sh)"
