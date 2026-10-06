#!/bin/sh
# Move named GGUF files into the shared store. Does not scan the home directory.
#   scripts/cache-model.sh FILE
#   scripts/cache-model.sh FILE models/<role>/FILE.gguf
# With one path, the layout is the models/, models-optional/ or models-inactive/
# suffix of that path. If the destination exists and differs, both files stay.
# The same bytes are a success and the destination is not rewritten.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/lib/common.sh"

usage() {
  echo "usage: cache-model.sh FILE [LAYOUT] ..." >&2
  echo "  LAYOUT is models/<role>/name.gguf, models-optional/..., or models-inactive/..." >&2
  exit 2
}

cache_layout() {
  cl_n=$1
  case "$cl_n" in
    *models-optional/*) printf 'models-optional/%s\n' "${cl_n#*models-optional/}"; return 0 ;;
    *models-inactive/*) printf 'models-inactive/%s\n' "${cl_n#*models-inactive/}"; return 0 ;;
    *models/*) printf 'models/%s\n' "${cl_n#*models/}"; return 0 ;;
  esac
  return 1
}

cache_one() {
  src=$1
  layout=$2
  [ -f "$src" ] || { echo "cache-model.sh: not a file: $src" >&2; return 1; }
  case "$layout" in
    models/*|models-optional/*|models-inactive/*) ;;
    *) echo "cache-model.sh: layout must start with models/, models-optional/, or models-inactive/: $layout" >&2; return 1 ;;
  esac
  case "$layout" in
    *.gguf) ;;
    *) echo "cache-model.sh: not a .gguf layout: $layout" >&2; return 1 ;;
  esac
  case "$layout" in
    *..*) echo "cache-model.sh: refusing layout with ..: $layout" >&2; return 1 ;;
  esac
  # Always the store. MODELS_DIR only overrides what serve and fetch read.
  dest="$(gguf_home)/$layout"
  if [ -e "$dest" ]; then
    if [ -f "$dest" ] && [ "$src" -ef "$dest" ]; then
      echo "cache-model.sh: already in the store: $dest"
      return 0
    fi
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
      echo "cache-model.sh: destination already has the same bytes: $dest"
      return 0
    fi
    echo "cache-model.sh: refusing to overwrite a different file: $dest" >&2
    return 1
  fi
  mkdir -p "$(dirname "$dest")"
  mv "$src" "$dest"
  echo "cache-model.sh: moved to $dest"
}

[ $# -gt 0 ] || usage
status=0
while [ $# -gt 0 ]; do
  src=$1
  shift
  layout=""
  if [ $# -gt 0 ]; then
    case "$1" in
      models/*|models-optional/*|models-inactive/*) layout=$1; shift ;;
    esac
  fi
  if [ -z "$layout" ]; then
    layout=$(cache_layout "$src") || {
      echo "cache-model.sh: cannot tell the store layout from '$src'; pass models/... explicitly" >&2
      status=1
      continue
    }
  fi
  cache_one "$src" "$layout" || status=1
done
exit "$status"
