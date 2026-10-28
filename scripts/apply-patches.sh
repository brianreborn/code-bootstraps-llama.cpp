#!/bin/sh
# Apply patches/*.patch in order to the llama.cpp source tree (default: ./llama.cpp).
#   scripts/apply-patches.sh [SRC_DIR]      CHECK=1: only verify that every patch applies
# Each patch becomes a local commit on branch "familia-patched" (based on the pinned commit),
# so the llama.cpp working tree is never left dirty and updates never trip over our own
# patches (familia #181 U10). Idempotent: an already-applied patch is skipped; one applied
# by an older version of this script (uncommitted) is committed in place.
# A source tree that is not a git checkout (unpacked tarball) gets plain `git apply`.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC=${1:-$ROOT/llama.cpp}
[ -f "$SRC/CMakeLists.txt" ] || { echo "apply-patches.sh: no llama.cpp source in $SRC" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "apply-patches.sh: git is required (git apply)" >&2; exit 1; }
# BASE=1: print the upstream commit under our familia patch commits (what the pin compares to).
if [ "${BASE:-0}" = 1 ]; then
  git -C "$SRC" log --first-parent --format='%H %s' HEAD | while read -r h subj; do
    case "$subj" in "familia: "*.patch) ;; *) echo "$h"; break ;; esac
  done
  exit 0
fi
G() { git -C "$SRC" -c user.name=familia -c user.email=familia@localhost -c commit.gpgsign=false "$@"; }
IS_GIT=0
[ "$(git -C "$SRC" rev-parse --show-toplevel 2>/dev/null || true)" = "$(CDPATH= cd -- "$SRC" && pwd -P)" ] && IS_GIT=1
if [ "$IS_GIT" = 1 ] && [ "${CHECK:-0}" != 1 ]; then
  cur=$(git -C "$SRC" symbolic-ref -q --short HEAD || true)
  if [ "$cur" != familia-patched ]; then
    G checkout -q -B familia-patched   # keeps any working-tree changes
  fi
fi
# Migrate a tree patched in place by an older version of this script: commit those edits once.
if [ "$IS_GIT" = 1 ] && [ "${CHECK:-0}" != 1 ]; then
  files=$(sed -n 's#^+++ b/##p' "$ROOT"/patches/*.patch 2>/dev/null | sort -u)
  if [ -n "$files" ] && ! (cd "$SRC" && git diff --quiet HEAD -- $files); then
    last=$(ls "$ROOT"/patches/*.patch | tail -n 1)
    if (cd "$SRC" && git apply --check -R "$last" 2>/dev/null); then
      (cd "$SRC" && git add -- $files) && G commit -q --no-verify -m "familia: patches applied in place (migrated).patch"
      echo "apply-patches.sh: committed in-place patches onto familia-patched" >&2
    fi
  fi
fi
for p in "$ROOT"/patches/*.patch; do
  [ -f "$p" ] || continue
  n=$(basename "$p")
  if (cd "$SRC" && git apply --check -R "$p" 2>/dev/null); then
    echo "apply-patches.sh: $n already applied" >&2
  elif (cd "$SRC" && git apply --check "$p"); then
    if [ "${CHECK:-0}" = 1 ]; then echo "apply-patches.sh: $n applies cleanly" >&2
    elif [ "$IS_GIT" = 1 ]; then
      (cd "$SRC" && git apply --index "$p") && G commit -q -m "familia: $n" --no-verify && echo "apply-patches.sh: applied $n (commit on familia-patched)" >&2
    else (cd "$SRC" && git apply "$p") && echo "apply-patches.sh: applied $n" >&2; fi
  else
    echo "apply-patches.sh: $n does not apply to $SRC (pin and patches out of sync)" >&2
    exit 1
  fi
done
