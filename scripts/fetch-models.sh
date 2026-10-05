#!/bin/sh
# Download models and verify sha256 (config/models-manifest.json).
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
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "fetch-models.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done
. "$ROOT/scripts/lib/common.sh"
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
  inactive="models-inactive/${dir#*/}"
  mkdir -p "$dir"
  fresh=0
  [ "$tested" = yes ] || echo "fetch-models.sh: NOTE: $file is untested with this repo" >&2
  if [ -f "$dir/$file" ]; then
    echo "fetch-models.sh: $dir/$file exists"
  elif [ -f "$inactive/$file" ]; then
    [ "$notice" = "-" ] || echo "fetch-models.sh: LICENSE NOTICE: $notice" >&2
    echo "fetch-models.sh: restoring $inactive/$file"
    mv "$inactive/$file" "$dir/"
  else
    [ "$notice" = "-" ] || echo "fetch-models.sh: LICENSE NOTICE: $notice" >&2
    url="https://huggingface.co/$repo/resolve/$rev/$file"
    echo "fetch-models.sh: $url -> $dir/$file"
    curl -fL $curl_progress --proto '=https' --proto-redir '=https' --retry 3 -C - -o "$dir/$file.part" "$url"
    got=$(sha256_of "$dir/$file.part")
    if [ "$got" != "$sha" ]; then
      mv -f "$dir/$file.part" "$dir/$file.bad"
      echo "fetch-models.sh: sha256 mismatch for $file (got $got, want $sha)" >&2
      exit 1
    fi
    mv "$dir/$file.part" "$dir/$file"
    fresh=1
  fi
  stamp=".cache/verified/$sha"
  if [ "$fresh" = 1 ]; then
    got=$sha
  elif [ "${FULL_VERIFY:-0}" != 1 ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$(fingerprint "$dir/$file")" ]; then
    got=$sha
    echo "fetch-models.sh: $file unchanged since its last sha256 check"
  else
    got=$(sha256_of "$dir/$file")
  fi
  if [ "$got" != "$sha" ]; then
    mv -f "$dir/$file" "$dir/$file.bad"
    echo "fetch-models.sh: sha256 mismatch for existing $dir/$file (got $got)" >&2
    exit 1
  fi
  for other in "$dir"/*.gguf; do
    [ -f "$other" ] || continue
    base=$(basename "$other")
    [ "$base" = "$file" ] && continue
    case "$base" in *mmproj*) continue ;; esac
    mkdir -p "$inactive"
    echo "fetch-models.sh: parking $other -> $inactive/"
    mv "$other" "$inactive/"
  done
  mkdir -p .cache/verified
  fingerprint "$dir/$file" > "$stamp"
  echo "fetch-models.sh: OK $r = $file"
done < "$rows"
rm -f "$rows"
echo "fetch-models.sh: done. Restart scripts/serve.sh (or start.sh) to serve a newly installed model."
