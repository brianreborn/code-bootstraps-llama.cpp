#!/bin/sh
# Download models and verify sha256 (config/models-manifest.json).
# Weights go to the shared store (GGUF_HOME, else $XDG_DATA_HOME/gguf or
# ~/.local/share/gguf): models/<role>/, models-optional/, models-inactive/.
# MODELS_DIR, when set, replaces the models root. A file already in this
# checkout is used in place and is not moved. A sha256 mismatch is renamed
# to *.bad and is not left as the live GGUF. Stamps stay in .cache/verified.
#   scripts/fetch-models.sh
#   scripts/fetch-models.sh --fallback|--step-up|--language|--language-small
#   scripts/fetch-models.sh --locale ja
#   scripts/fetch-models.sh --pick NAME
#   scripts/fetch-models.sh --role coder
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
MANIFEST=${MANIFEST:-config/models-manifest.json}
pick=default
role=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fallback) pick=fallback ;;
    --step-up) pick=step-up ;;
    --language) pick=language ;;
    --language-small) pick=language-small ;;
    --locale) pick=locale-${2:?--locale needs a language code}; shift ;;
    --pick) pick=${2:?--pick needs a name}; shift ;;
    --role) role=${2:?--role needs a name}; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "fetch-models.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done
. "$ROOT/scripts/lib/common.sh"
if [ -n "${MODELS_DIR:-}" ]; then
  case "$MODELS_DIR" in
    /*) ;;
    *) MODELS_DIR=$ROOT/$MODELS_DIR ;;
  esac
fi
if [ -t 2 ]; then curl_progress=--progress-bar; else curl_progress=-sS; fi
tab=$(printf '\t')
kv="pick=$pick"
[ -n "$role" ] && kv="$kv role=$role"
rows=$(mktemp)
awk -v match_kv="$kv" \
  -v fields="role repo revision file sha256 tested dir notice" -f "$ROOT/scripts/lib/manifest.awk" "$MANIFEST" > "$rows"
[ -s "$rows" ] || { echo "fetch-models.sh: no manifest entries for pick='$pick'" >&2; rm -f "$rows"; exit 1; }

while IFS=$tab read -r r repo rev file sha tested dir notice; do
  [ "$dir" = "-" ] && dir="models/$r"
  rel="$dir/$file"
  inactive_rel="models-inactive/${dir#*/}/$file"
  fresh=0
  [ "$tested" = yes ] || echo "fetch-models.sh: NOTE: $file is untested with this repo" >&2
  path=$(gguf_resolve "$rel")
  if [ -f "$path" ]; then
    echo "fetch-models.sh: $path exists"
  else
    inactive=$(gguf_resolve "$inactive_rel")
    dest=$(gguf_dest "$rel")
    if [ -f "$inactive" ] && gguf_is_managed "$inactive"; then
      [ "$notice" = "-" ] || echo "fetch-models.sh: LICENSE NOTICE: $notice" >&2
      echo "fetch-models.sh: restoring $inactive"
      mkdir -p "$(dirname "$dest")"
      mv "$inactive" "$dest"
      path=$dest
    elif [ -f "$inactive" ]; then
      # Checkout copies stay where they are. Restoring would move one.
      [ "$notice" = "-" ] || echo "fetch-models.sh: LICENSE NOTICE: $notice" >&2
      echo "fetch-models.sh: using checkout copy $inactive (not moved)"
      path=$inactive
    else
      [ "$notice" = "-" ] || echo "fetch-models.sh: LICENSE NOTICE: $notice" >&2
      url="https://huggingface.co/$repo/resolve/$rev/$file"
      echo "fetch-models.sh: $url -> $dest"
      mkdir -p "$(dirname "$dest")"
      curl -fL $curl_progress --proto '=https' --proto-redir '=https' --retry 3 -C - -o "$dest.part" "$url"
      got=$(sha256_of "$dest.part")
      if [ "$got" != "$sha" ]; then
        mv -f "$dest.part" "$dest.bad"
        echo "fetch-models.sh: sha256 mismatch for $file (got $got, want $sha)" >&2
        exit 1
      fi
      mv "$dest.part" "$dest"
      path=$dest
      fresh=1
    fi
  fi
  stamp=".cache/verified/$sha"
  if [ "$fresh" = 1 ]; then
    got=$sha
  elif [ "${FULL_VERIFY:-0}" != 1 ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$(fingerprint "$path")" ]; then
    got=$sha
    echo "fetch-models.sh: $file unchanged since its last sha256 check"
  else
    got=$(sha256_of "$path")
  fi
  if [ "$got" != "$sha" ]; then
    # Not left under the live name, including a bad checkout copy.
    mv -f "$path" "$path.bad"
    echo "fetch-models.sh: sha256 mismatch for existing $path (got $got)" >&2
    exit 1
  fi
  # Park siblings only inside the store (or MODELS_DIR). Never the checkout.
  if gguf_is_managed "$path"; then
    park_from=$(dirname "$path")
    park_to=$(gguf_dest "models-inactive/${dir#*/}")
    for other in "$park_from"/*.gguf; do
      [ -f "$other" ] || continue
      base=$(basename "$other")
      [ "$base" = "$file" ] && continue
      case "$base" in *mmproj*) continue ;; esac
      mkdir -p "$park_to"
      echo "fetch-models.sh: parking $other -> $park_to/"
      mv "$other" "$park_to/"
    done
  fi
  mkdir -p .cache/verified
  fingerprint "$path" > "$stamp"
  echo "fetch-models.sh: OK $r = $file"
done < "$rows"
rm -f "$rows"
echo "fetch-models.sh: done. Restart scripts/serve.sh (or start.sh) to serve a newly installed model."
