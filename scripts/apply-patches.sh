#!/bin/sh
# Apply patches/*.patch in order to the llama.cpp source tree (default: ./llama.cpp).
#   scripts/apply-patches.sh [SRC_DIR]      CHECK=1: only verify that every patch applies
# Idempotent: a patch that is already applied (reverse-applies cleanly) is skipped.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC=${1:-$ROOT/llama.cpp}
[ -f "$SRC/CMakeLists.txt" ] || { echo "apply-patches.sh: no llama.cpp source in $SRC" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "apply-patches.sh: git is required (git apply)" >&2; exit 1; }
for p in "$ROOT"/patches/*.patch; do
  [ -f "$p" ] || continue
  n=$(basename "$p")
  if (cd "$SRC" && git apply --check -R "$p" 2>/dev/null); then
    echo "apply-patches.sh: $n already applied" >&2
  elif (cd "$SRC" && git apply --check "$p"); then
    if [ "${CHECK:-0}" = 1 ]; then echo "apply-patches.sh: $n applies cleanly" >&2
    else (cd "$SRC" && git apply "$p") && echo "apply-patches.sh: applied $n" >&2; fi
  else
    echo "apply-patches.sh: $n does not apply to $SRC (pin and patches out of sync)" >&2
    exit 1
  fi
done
