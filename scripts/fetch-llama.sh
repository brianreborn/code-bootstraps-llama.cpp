#!/usr/bin/env bash
# Download the official llama.cpp release binaries pinned in config/llama-release.json,
# check their sha256 and unpack them into bin/llama-<tag>-<platform>-<variant>/.
#   scripts/fetch-llama.sh                     # this machine, CPU build (macOS arm64: Metal included)
#   scripts/fetch-llama.sh --variant vulkan    # or cuda-12 / cuda-13 where listed
#   scripts/fetch-llama.sh --platform linux-arm64 --variant cpu
#   scripts/fetch-llama.sh --print-platform    # show what this machine maps to
# On success the llama-server path is written to .cache/llama-server.path. If the
# binary cannot run here (missing system libraries, unlisted platform), the script
# exits 3; build from source instead (scripts/build-*.sh).
# Needs curl, tar, awk and sha256sum (or shasum); no Python.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/common.sh
. "$ROOT/scripts/lib/common.sh"
RELEASE="${RELEASE:-config/llama-release.json}"
platform=""; variant="${VARIANT:-cpu}"; print_only=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform) platform="${2:?}"; shift ;;
    --variant)  variant="${2:?}"; shift ;;
    --print-platform) print_only=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "fetch-llama.sh: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac; shift
done

detect_platform() {
  local os arch
  case "$(uname -m)" in x86_64|amd64) arch=x64 ;; aarch64|arm64) arch=arm64 ;; *) arch="$(uname -m)" ;; esac
  # a Terminal running under Rosetta reports x86_64 on Apple silicon: take the native build
  if [[ "$(uname -s)" == Darwin && "$arch" == x64 && "$(sysctl -n hw.optional.arm64 2>/dev/null)" == 1 ]]; then arch=arm64; fi
  case "$(uname -s)" in
    Linux)
      if [[ "$(uname -o 2>/dev/null)" == "Android" || "${PREFIX:-}" == *com.termux* ]]; then os=android; else os=linux; fi ;;
    Darwin) os=macos ;;
    MINGW*|MSYS*|CYGWIN*) os=windows ;;
    *) os="$(uname -s | tr '[:upper:]' '[:lower:]')" ;;
  esac
  echo "$os-$arch"
}
[[ -n "$platform" ]] || platform="$(detect_platform)"
if [[ "$print_only" == 1 ]]; then echo "$platform"; exit 0; fi

# progress bar on a terminal; in a log (stderr redirected) only errors, not hundreds of bar lines
progress=(--progress-bar); [[ -t 2 ]] || progress=(-sS)
field() {   # top-level "key": "value" of the release manifest
  awk -v k="$1" '{ line = $0; sub(/^[ \t]*/, "", line) }
    index(line, "\"" k "\":") == 1 { v = substr(line, length(k) + 4); sub(/^[ \t]*"/, "", v); sub(/",?[ \t]*$/, "", v); print v; exit }' "$RELEASE"
}
tag="$(field tag)"; base="$(field base_url)"
row="$(awk -v match_kv="platform=$platform variant=$variant" \
  -v fields="file sha256 extra_file extra_sha256 base_url" -f scripts/lib/manifest.awk "$RELEASE" | head -1)"
if [[ -z "$row" ]]; then
  echo "fetch-llama.sh: no $tag release binary for platform '$platform' variant '$variant' in $RELEASE." >&2
  echo "fetch-llama.sh: listed: $(awk -v match_kv= -v fields='platform variant' -f scripts/lib/manifest.awk "$RELEASE" | tr '\t' '/' | tr '\n' ' ')" >&2
  echo "fetch-llama.sh: build from source instead (scripts/build-*.sh)." >&2
  exit 3
fi
IFS=$'\t' read -r file sha extra extra_sha row_base <<< "$row"
# an asset with its own base_url is not an upstream ggml-org build (Android: see its note)
if [[ "$row_base" != "-" ]]; then
  base="$row_base"
  echo "fetch-llama.sh: $platform: using this repository's own build of $tag (not upstream's asset): $(awk -v match_kv="platform=$platform variant=$variant" -v fields=note -f scripts/lib/manifest.awk "$RELEASE" | head -1)" >&2
fi

dest="bin/llama-$tag-$platform-$variant"
mkdir -p .cache/dl
fetch() {   # $1 file, $2 sha256
  local f="$1" want="$2" got
  if [[ -f ".cache/dl/$f" && "$(sha256_of ".cache/dl/$f")" == "$want" ]]; then echo "fetch-llama.sh: $f already downloaded and verified" >&2; return 0; fi
  echo "fetch-llama.sh: $base$f" >&2
  # -C -: an interrupted download resumes (the sha256 check below catches a bad resume)
  curl -fL "${progress[@]}" --proto '=https' --proto-redir '=https' --retry 3 -C - -o ".cache/dl/$f.part" "$base$f"
  got="$(sha256_of ".cache/dl/$f.part")"
  if [[ "$got" != "$want" ]]; then
    mv -f ".cache/dl/$f.part" ".cache/dl/$f.bad"
    echo "fetch-llama.sh: sha256 mismatch for $f (got $got, want $want); kept as .cache/dl/$f.bad" >&2; exit 1
  fi
  mv ".cache/dl/$f.part" ".cache/dl/$f"
  echo "fetch-llama.sh: OK sha256 $f" >&2
}
UNPACK_TMP=""
trap 'if [[ -n "$UNPACK_TMP" ]]; then rm -rf "$UNPACK_TMP"; fi' EXIT   # interrupted unpack: no .cache/unpack.* left
trap 'exit 130' INT; trap 'exit 143' TERM HUP
unpack() {   # $1 archive -> $dest (top-level directory stripped); mv keeps the .so symlinks
  local tmp; tmp="$(mktemp -d "$ROOT/.cache/unpack.XXXXXX")"; UNPACK_TMP="$tmp"
  case "$1" in
    *.tar.gz) tar -xzf ".cache/dl/$1" -C "$tmp" ;;
    *.zip) if command -v unzip >/dev/null 2>&1; then unzip -q ".cache/dl/$1" -d "$tmp"; else tar -xf ".cache/dl/$1" -C "$tmp"; fi ;;
  esac
  local top src e; top="$(find "$tmp" -mindepth 1 -maxdepth 1)"
  if [[ "$(echo "$top" | wc -l)" -eq 1 && -d "$top" ]]; then src="$top"; else src="$tmp"; fi
  for e in "$src"/* "$src"/.[!.]*; do [[ -e "$e" || -L "$e" ]] && mv -f "$e" "$dest"/; done
  rm -rf "$tmp"; UNPACK_TMP=""
}

fetch "$file" "$sha"
[[ "$extra" == "-" ]] || fetch "$extra" "$extra_sha"
# the stamp lists every unpacked file (size, sha256) and symlink (target); a missing or changed
# file makes the archive unpack again
stamp="$dest/.verified-$sha"
if [[ ! -f "$stamp" || "$(tree_manifest "$dest")" != "$(cat "$stamp")" ]]; then
  [[ -f "$stamp" ]] && echo "fetch-llama.sh: $dest changed since it was unpacked; unpacking again" >&2
  rm -rf "$dest"; mkdir -p "$dest"
  unpack "$file"
  [[ "$extra" == "-" ]] || unpack "$extra"
  tree_manifest "$dest" > "$stamp"
fi
exe="$dest/llama-server"; [[ -f "$exe.exe" ]] && exe="$exe.exe"
[[ -x "$exe" ]] || { echo "fetch-llama.sh: $exe missing after unpacking" >&2; exit 1; }

# can it run here? (glibc / libgomp / libssl versions, wrong architecture, ...)
if ! out="$("$exe" --version 2>&1)"; then
  echo "fetch-llama.sh: the release llama-server does not run on this machine:" >&2
  echo "$out" | head -5 >&2
  command -v ldd >/dev/null 2>&1 && ldd "$exe" 2>/dev/null | grep 'not found' >&2 || true
  echo "fetch-llama.sh: install the missing libraries (see the note in $RELEASE) or build from source (scripts/build-*.sh)." >&2
  rm -rf "$dest"   # never leave a binary that cannot run where serve.sh would find it
  exit 3
fi
echo "fetch-llama.sh: $(echo "$out" | grep -m1 -i version) -> $exe" >&2
echo "$ROOT/$exe" > .cache/llama-server.path
echo "$ROOT/$exe"
