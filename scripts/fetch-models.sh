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
#   scripts/fetch-models.sh --ask
# --ask lists manifest rows that already have a sha256, except the default
# general and coder files, and reads one name from stdin. It does not open a
# TTY. Empty or unknown input downloads nothing. The chosen file uses the
# download below and does not replace, move, or re-download that default pair.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
MANIFEST=${MANIFEST:-config/models-manifest.json}
pick=default
role=""
ask=0
while [ $# -gt 0 ]; do
  case "$1" in
    --fallback) pick=fallback ;;
    --step-up) pick=step-up ;;
    --language) pick=language ;;
    --language-small) pick=language-small ;;
    --locale) pick=locale-${2:?--locale needs a language code}; shift ;;
    --pick) pick=${2:?--pick needs a name}; shift ;;
    --role) role=${2:?--role needs a name}; shift ;;
    --ask) ask=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "fetch-models.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done
. "$ROOT/scripts/lib/common.sh"
# One listed extra. Sets pick and file_only. Exits 0 when nothing is chosen.
ask_one() {
  ask_all=$(mktemp)
  offers=$(mktemp)
  awk -v match_kv="" -v fields="pick role file sha256" -f "$ROOT/scripts/lib/manifest.awk" "$MANIFEST" > "$ask_all"
  : > "$offers"
  while IFS=$tab read -r p r f sha; do
    [ -n "$f" ] || continue
    if [ "$p" = default ] && [ "$r" = general ]; then def_general=$f; fi
    if [ "$p" = default ] && [ "$r" = coder ]; then def_coder=$f; fi
    case "$sha" in ""|-) continue ;; esac
    if [ "$p" = default ] && [ "$r" = general ]; then continue; fi
    if [ "$p" = default ] && [ "$r" = coder ]; then continue; fi
    printf '%s\t%s\t%s\n' "$p" "$r" "$f" >> "$offers"
  done < "$ask_all"
  if [ ! -s "$offers" ]; then
    echo "fetch-models.sh: no extra model with a sha256; no download" >&2
    exit 0
  fi
  echo "fetch-models.sh: extra models with a known sha256, other than the default general and coder." >&2
  echo "fetch-models.sh: an empty line downloads nothing." >&2
  while IFS=$tab read -r p r f; do
    echo "fetch-models.sh: offer $p/$f $r" >&2
  done < "$offers"
  printf 'fetch-models.sh: which extra model? ' >&2
  ans=""
  if ! IFS= read -r ans; then
    :
  fi
  ans=$(printf '%s' "$ans" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ -z "$ans" ]; then
    echo "fetch-models.sh: nothing chosen; no download" >&2
    exit 0
  fi
  # pick/file, or a pick or file name that matches exactly one offered row.
  sel_n=0
  sel_pick=""
  sel_file=""
  while IFS=$tab read -r p r f; do
    hit=0
    if [ "$ans" = "$p/$f" ]; then
      hit=1
    elif [ "$ans" = "$f" ]; then
      fc=0
      while IFS=$tab read -r p2 r2 f2; do
        [ "$f2" = "$ans" ] && fc=$((fc + 1))
      done < "$offers"
      [ "$fc" = 1 ] && hit=1
    elif [ "$ans" = "$p" ]; then
      pc=0
      while IFS=$tab read -r p2 r2 f2; do
        [ "$p2" = "$ans" ] && pc=$((pc + 1))
      done < "$offers"
      [ "$pc" = 1 ] && hit=1
    fi
    if [ "$hit" = 1 ]; then
      sel_n=$((sel_n + 1))
      sel_pick=$p
      sel_file=$f
    fi
  done < "$offers"
  if [ "$sel_n" != 1 ]; then
    echo "fetch-models.sh: '$ans' is not one listed extra; no download" >&2
    exit 0
  fi
  pick=$sel_pick
  file_only=$sel_file
  role=""
  keep_defaults=1
}
if [ -n "${MODELS_DIR:-}" ]; then
  case "$MODELS_DIR" in
    /*) ;;
    *) MODELS_DIR=$ROOT/$MODELS_DIR ;;
  esac
fi
if [ -t 2 ]; then curl_progress=--progress-bar; else curl_progress=-sS; fi
tab=$(printf '\t')
keep_defaults=0
file_only=""
def_general=""
def_coder=""
rows=""
ask_all=""
offers=""
cleanup() { rm -f "$rows" "$ask_all" "$offers"; }
trap cleanup EXIT
if [ "$ask" = 1 ]; then
  ask_one
fi
kv="pick=$pick"
[ -n "$role" ] && kv="$kv role=$role"
rows=$(mktemp)
awk -v match_kv="$kv" \
  -v fields="role repo revision file sha256 tested dir notice" -f "$ROOT/scripts/lib/manifest.awk" "$MANIFEST" > "$rows"
[ -s "$rows" ] || { echo "fetch-models.sh: no manifest entries for pick='$pick'" >&2; rm -f "$rows"; exit 1; }

while IFS=$tab read -r r repo rev file sha tested dir notice; do
  [ -n "$file_only" ] && [ "$file" != "$file_only" ] && continue
  case "$sha" in
    ""|-) echo "fetch-models.sh: $file has no sha256; not fetched" >&2; exit 1 ;;
  esac
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
      # --ask adds a file beside the defaults; do not park that pair.
      if [ "$keep_defaults" = 1 ] && { [ "$base" = "$def_general" ] || [ "$base" = "$def_coder" ]; }; then
        continue
      fi
      mkdir -p "$park_to"
      echo "fetch-models.sh: parking $other -> $park_to/"
      mv "$other" "$park_to/"
    done
  fi
  mkdir -p .cache/verified
  fingerprint "$path" > "$stamp"
  echo "fetch-models.sh: OK $r = $file"
done < "$rows"
echo "fetch-models.sh: done. Restart scripts/serve.sh (or start.sh) to serve a newly installed model."
