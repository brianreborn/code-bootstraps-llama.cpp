#!/bin/sh
# Download the pinned llama.cpp release, check sha256, unpack into bin/.
#   scripts/fetch-llama.sh                       # this machine; Linux uses a GPU build when one is present
#   scripts/fetch-llama.sh --variant cpu         # force the CPU archive
#   scripts/fetch-llama.sh --variant vulkan      # or cuda-12 / cuda-13
#   scripts/fetch-llama.sh --print-platform
# Exit 3 when no asset fits. Needs curl, tar, awk, and sha256sum or shasum.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
. "$ROOT/scripts/lib/common.sh"
. "$ROOT/scripts/lib/gpu.sh"
RELEASE=${RELEASE:-config/llama-release.json}
platform=""
variant=${VARIANT:-auto}
print_only=0
while [ $# -gt 0 ]; do
  case "$1" in
    --platform) platform=${2:?}; shift ;;
    --variant) variant=${2:?}; shift ;;
    --print-platform) print_only=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "fetch-llama.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done

detect_platform() {
  case "$(uname -m)" in
    x86_64|amd64) arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) arch=$(uname -m) ;;
  esac
  if [ "$(uname -s)" = Darwin ] && [ "$arch" = x64 ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ]; then
    arch=arm64
  fi
  case "$(uname -s)" in
    Linux)
      case "${PREFIX:-}" in
        *com.termux*) os=android ;;
        *) os=linux ;;
      esac
      ;;
    Darwin) os=macos ;;
    MINGW*|MSYS*|CYGWIN*) os=windows ;;
    *) os=$(uname -s | tr '[:upper:]' '[:lower:]') ;;
  esac
  printf '%s\n' "$os-$arch"
}
[ -n "$platform" ] || platform=$(detect_platform)
if [ "$print_only" = 1 ]; then printf '%s\n' "$platform"; exit 0; fi

if [ "$variant" = auto ]; then
  variant=$(gpu_variant)
  echo "fetch-llama.sh: variant auto -> $variant" >&2
fi
mkdir -p .cache
printf '%s\n' "$variant" > .cache/llama-variant

if [ -t 2 ]; then curl_progress=--progress-bar; else curl_progress=-sS; fi
field() {
  awk -v k="$1" '{ line = $0; sub(/^[ \t]*/, "", line) }
    index(line, "\"" k "\":") == 1 { v = substr(line, length(k) + 4); sub(/^[ \t]*"/, "", v); sub(/",?[ \t]*$/, "", v); print v; exit }' "$RELEASE"
}
tag=$(field tag)
base=$(field base_url)
row=$(awk -v match_kv="platform=$platform variant=$variant" \
  -v fields="file sha256 extra_file extra_sha256 base_url" -f scripts/lib/manifest.awk "$RELEASE" | head -n 1)
if [ -z "$row" ]; then
  echo "fetch-llama.sh: no $tag release binary for platform '$platform' variant '$variant' in $RELEASE." >&2
  echo "fetch-llama.sh: build from source instead (scripts/build-*.sh)." >&2
  exit 3
fi
tab=$(printf '\t')
IFS=$tab read -r file sha extra extra_sha row_base <<EOF
$row
EOF
if [ "$row_base" != "-" ]; then
  base=$row_base
  echo "fetch-llama.sh: $platform: this repository's own build of $tag, not upstream's" >&2
fi

dest="bin/llama-$tag-$platform-$variant"
mkdir -p .cache/dl
fetch() {
  f=$1
  want=$2
  if [ -f ".cache/dl/$f" ] && [ "$(sha256_of ".cache/dl/$f")" = "$want" ]; then
    echo "fetch-llama.sh: $f already downloaded and verified" >&2
    return 0
  fi
  echo "fetch-llama.sh: $base$f" >&2
  curl -fL $curl_progress --proto '=https' --proto-redir '=https' --retry 3 -C - -o ".cache/dl/$f.part" "$base$f"
  got=$(sha256_of ".cache/dl/$f.part")
  if [ "$got" != "$want" ]; then
    mv -f ".cache/dl/$f.part" ".cache/dl/$f.bad"
    echo "fetch-llama.sh: sha256 mismatch for $f (got $got, want $want)" >&2
    exit 1
  fi
  mv ".cache/dl/$f.part" ".cache/dl/$f"
  echo "fetch-llama.sh: OK sha256 $f" >&2
}
UNPACK_TMP=""
trap 'if [ -n "$UNPACK_TMP" ]; then rm -rf "$UNPACK_TMP"; fi' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
unpack() {
  tmp=$(mktemp -d "$ROOT/.cache/unpack.XXXXXX")
  UNPACK_TMP=$tmp
  case "$1" in
    *.tar.gz) tar -xzf ".cache/dl/$1" -C "$tmp" ;;
    *.zip)
      if command -v unzip >/dev/null 2>&1; then unzip -q ".cache/dl/$1" -d "$tmp"
      else tar -xf ".cache/dl/$1" -C "$tmp"; fi
      ;;
  esac
  src=$tmp
  n=0
  top=""
  for e in "$tmp"/* "$tmp"/.[!.]*; do
    [ -e "$e" ] || [ -h "$e" ] || continue
    n=$((n + 1))
    top=$e
  done
  if [ "$n" -eq 1 ] && [ -d "$top" ]; then src=$top; fi
  for e in "$src"/* "$src"/.[!.]*; do
    [ -e "$e" ] || [ -h "$e" ] && mv -f "$e" "$dest"/
  done
  rm -rf "$tmp"
  UNPACK_TMP=""
}

fetch "$file" "$sha"
[ "$extra" = "-" ] || fetch "$extra" "$extra_sha"
stamp="$dest/.verified-$sha"
if [ ! -f "$stamp" ] || [ "$(tree_manifest "$dest")" != "$(cat "$stamp")" ]; then
  [ -f "$stamp" ] && echo "fetch-llama.sh: $dest changed since it was unpacked; unpacking again" >&2
  rm -rf "$dest"
  mkdir -p "$dest"
  unpack "$file"
  [ "$extra" = "-" ] || unpack "$extra"
  tree_manifest "$dest" > "$stamp"
fi
exe="$dest/llama-server"
[ -f "$exe.exe" ] && exe="$exe.exe"
[ -x "$exe" ] || { echo "fetch-llama.sh: $exe missing after unpacking" >&2; exit 1; }

if ! out=$("$exe" --version 2>&1); then
  echo "fetch-llama.sh: the release llama-server does not run on this machine:" >&2
  printf '%s\n' "$out" | head -n 5 >&2
  case "$out" in
    *[Ee]xec\ format\ error*|*[Cc]annot\ execute\ binary*|*[Bb]ad\ CPU\ type*)
      echo "fetch-llama.sh: it is built for $platform, and this machine is $(uname -sm) ($(detect_platform))." >&2
      ;;
    *)
      command -v ldd >/dev/null 2>&1 && ldd "$exe" 2>/dev/null | grep 'not found' >&2 || true
      echo "fetch-llama.sh: install the missing libraries or build from source." >&2
      ;;
  esac
  rm -rf "$dest"
  exit 3
fi
printf '%s\n' "$out" | awk 'tolower($0) ~ /version/ { print; exit }' | {
  read -r line || true
  echo "fetch-llama.sh: ${line:-ok} -> $exe" >&2
}
printf '%s\n' "$ROOT/$exe" > .cache/llama-server.path
printf '%s\n' "$ROOT/$exe"
