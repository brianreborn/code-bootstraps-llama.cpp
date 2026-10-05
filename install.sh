#!/bin/sh
# Fetch this repository, check sha256, unpack, then run start.sh.
#   curl -fsSL https://raw.githubusercontent.com/brianreborn/code-bootstraps-llama.cpp/main/install.sh | sh
# The digest of a GitHub archive cannot live only inside that archive.
# EXPECTED_SHA256 stays empty until a published archive is hashed. Until then the
# script refuses to download. Tests set INSTALL_URL, INSTALL_SHA256, PREFIX, and
# INSTALL_NO_START=1. A second run unpacks again only when the digest changes.
# Termux exports PREFIX as its usr directory. INSTALL_PREFIX, or ~/code-bootstraps-llama.cpp,
# is used there so the installer does not unpack over the Termux prefix.
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

[ -n "$SHA" ] || die "no sha256 is published for this installer yet. Set INSTALL_SHA256, or fill EXPECTED_SHA256 after a release archive is hashed."
case "$SHA" in
  *[!0-9A-Fa-f]*) die "sha256 is not hex" ;;
esac
[ "$(printf '%s' "$SHA" | wc -c | tr -d ' ')" = 64 ] || die "sha256 must be 64 hex characters"
case "$URL" in
  https://*) ;;
  file://*) ;;
  *) die "refusing $URL (https only, or file:// for a local test)" ;;
esac
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v tar >/dev/null 2>&1 || die "tar is required"

if [ -f "$PREFIX/.cache/install.sha256" ] && [ "$(tr -d '[:space:]' < "$PREFIX/.cache/install.sha256")" = "$SHA" ] && [ -f "$PREFIX/start.sh" ]; then
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
  [ "$got" = "$SHA" ] || die "sha256 mismatch (got $got, want $SHA). Not unpacked."
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
  printf '%s\n' "$SHA" > "$PREFIX/.cache/install.sha256"
  echo "install.sh: installed into $PREFIX" >&2
  trap - EXIT
  rm -rf "$tmp"
fi

if [ "${INSTALL_NO_START:-0}" = 1 ]; then exit 0; fi
exec /bin/sh "$PREFIX/start.sh"
