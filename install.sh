#!/bin/sh
# Fetch this repository, unpack, then run start.sh.
# Profile defaults, including MODELS_MAX=2, live in scripts/serve.sh after unpack.
#   curl -fsSL https://raw.githubusercontent.com/brianreborn/code-bootstraps-llama.cpp/main/install.sh | sh
# EXPECTED_SHA256 or INSTALL_SHA256, when set, must match the archive or it is
# not unpacked. An empty digest still installs. Tests set INSTALL_URL,
# INSTALL_PREFIX, and INSTALL_NO_START=1. A second run unpacks again only when
# the archive digest changes. Termux exports PREFIX as its usr directory.
# INSTALL_PREFIX, or ~/code-bootstraps-llama.cpp, is used there so the installer
# does not unpack over the Termux prefix.
set -eu
EXPECTED_SHA256=""
URL=${INSTALL_URL:-https://github.com/brianreborn/code-bootstraps-llama.cpp/archive/refs/heads/main.tar.gz}
SHA=${INSTALL_SHA256:-$EXPECTED_SHA256}
if [ -n "${INSTALL_PREFIX:-}" ]; then
  PREFIX=$INSTALL_PREFIX
else
  case "${PREFIX:-}" in
    *com.termux*) PREFIX=$HOME/code-bootstraps-llama.cpp ;;
    "") PREFIX=$HOME/code-bootstraps-llama.cpp ;;
  esac
fi

die() { echo "install.sh: $*" >&2; exit 1; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else cksum -a sha256 "$1" | awk 'NR==1 { print $NF; exit }'; fi
}

stamp_matches() {
  [ -n "$1" ] || return 1
  [ -f "$PREFIX/.cache/install.sha256" ] || return 1
  [ "$(tr -d '[:space:]' < "$PREFIX/.cache/install.sha256")" = "$1" ] || return 1
  [ -f "$PREFIX/start.sh" ]
}

if [ -n "$SHA" ]; then
  SHA=$(printf '%s' "$SHA" | tr 'A-F' 'a-f')
  case "$SHA" in
    *[!0-9A-Fa-f]*) die "sha256 is not hex" ;;
  esac
  [ "$(printf '%s' "$SHA" | wc -c | tr -d ' ')" = 64 ] || die "sha256 must be 64 hex characters"
fi
case "$URL" in
  https://*) ;;
  file://*) ;;
  *) die "refusing $URL (https only, or file:// for a local test)" ;;
esac
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v tar >/dev/null 2>&1 || die "tar is required"

if [ -n "$SHA" ] && stamp_matches "$SHA"; then
  echo "install.sh: $PREFIX already matches this archive" >&2
else
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  arc=$tmp/src.tar.gz
  case "$URL" in
    https://*) curl -fL --proto '=https' --proto-redir '=https' --retry 3 -o "$arc" "$URL" ;;
    file://*) curl -fsSL -o "$arc" "$URL" ;;
  esac
  got=$(sha256_of "$arc")
  if [ -n "$SHA" ] && [ "$got" != "$SHA" ]; then
    die "sha256 mismatch (got $got, want $SHA). Not unpacked."
  fi
  if stamp_matches "$got"; then
    echo "install.sh: $PREFIX already matches this archive" >&2
  else
    tar -xzf "$arc" -C "$tmp"
    top=""
    for d in "$tmp"/*; do
      [ -d "$d" ] || continue
      [ -n "$top" ] && die "archive has more than one top directory"
      top=$d
    done
    [ -n "$top" ] || die "archive has no top directory"
    [ -f "$top/start.sh" ] || die "archive has no start.sh"
    mkdir -p "$PREFIX"
    tar -C "$top" -cf - . | tar -C "$PREFIX" -xf -
    mkdir -p "$PREFIX/.cache"
    printf '%s\n' "$got" > "$PREFIX/.cache/install.sha256"
    echo "install.sh: installed into $PREFIX" >&2
  fi
  trap - EXIT
  rm -rf "$tmp"
fi

# start.sh asks for memlock once. Ask here only when this run will not start,
# and record the stamp so the later start does not ask again.
if [ "${INSTALL_NO_START:-0}" = 1 ]; then
  if [ "${INSTALL_RAISE:-0}" = 1 ]; then
    if sh "$PREFIX/scripts/raise.sh"; then
      mkdir -p "$PREFIX/.cache"
      printf '%s\n' ok > "$PREFIX/.cache/raise.stamp"
    else
      echo "install.sh: raise.sh did not grant memlock. Start later with RAISE=1." >&2
    fi
  fi
  exit 0
fi
if [ "${INSTALL_RAISE:-0}" = 1 ]; then
  export RAISE=1
fi
exec /bin/sh "$PREFIX/start.sh"
