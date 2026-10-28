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
# Run modes (familia #51; the full run stays the default):
#   --dry-run       no network, no writes: print each row's file, size, sha256,
#                   license, chat template and present/would-download status.
#   --damp-run      fetch only the small pieces (pinned chat templates); list the
#                   weights it skips with their size and sha256.
#   --max-file-mb N damp-run size cap for a small piece (default 50).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
MANIFEST=${MANIFEST:-config/models-manifest.json}
pick=default
role=""
ask=0
mode=full
max_mb=50
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
    --dry-run) mode=dry ;;
    --damp-run) mode=damp ;;
    --max-file-mb) max_mb=${2:?--max-file-mb needs a number}; shift ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
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
  -v fields="role repo revision file sha256 tested dir notice chat_template_repo chat_template_revision chat_template_path chat_template_sha256 bytes license" \
  -f "$ROOT/scripts/lib/manifest.awk" "$MANIFEST" > "$rows"
[ -s "$rows" ] || { echo "fetch-models.sh: no manifest entries for pick='$pick'" >&2; rm -f "$rows"; exit 1; }

# fetch_template GGUF_PATH REPO REV PATH SHA: the repo chat template the model must be served with
# (its GGUF's differs; familia #51) as <model>.chat-template.jinja, pinned and sha256-checked.
# PATH "X.json:key" is the template stored as key of X.json (needs python3).
fetch_template() {
  ft_dest="${1%.gguf}.chat-template.jinja"
  if [ -f "$ft_dest" ] && [ "$(sha256_of "$ft_dest")" = "$5" ]; then
    echo "fetch-models.sh: chat template $ft_dest OK"
    mkdir -p .cache/verified; stamp_add ".cache/verified/$5" "$ft_dest"; return 0
  fi
  case "$4" in
    *:*) ft_file=${4%%:*}; ft_key=${4#*:} ;;
    *) ft_file=$4; ft_key="" ;;
  esac
  ft_url="https://huggingface.co/$2/resolve/$3/$ft_file"
  echo "fetch-models.sh: chat template $ft_url -> $ft_dest"
  curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 -o "$ft_dest.part" "$ft_url" ||
    { echo "fetch-models.sh: could not fetch the chat template $ft_url" >&2; exit 1; }
  if [ -n "$ft_key" ]; then
    command -v python3 >/dev/null 2>&1 ||
      { echo "fetch-models.sh: the chat template of $(basename "$1") is $ft_key in $ft_file; extracting it needs python3" >&2; exit 1; }
    python3 -c 'import json,sys; t=json.load(open(sys.argv[1],encoding="utf-8"))[sys.argv[2]]; open(sys.argv[3],"w",encoding="utf-8",newline="").write(t)' \
      "$ft_dest.part" "$ft_key" "$ft_dest.tmpl" && mv -f "$ft_dest.tmpl" "$ft_dest.part"
  fi
  ft_got=$(sha256_of "$ft_dest.part")
  if [ "$ft_got" != "$5" ]; then
    mv -f "$ft_dest.part" "$ft_dest.bad"
    echo "fetch-models.sh: chat template sha256 mismatch for $(basename "$1") (got $ft_got, want $5)" >&2
    exit 1
  fi
  mv -f "$ft_dest.part" "$ft_dest"
  mkdir -p .cache/verified; stamp_add ".cache/verified/$5" "$ft_dest"
}

damp_skipped=0
damp_bytes=0
while IFS=$tab read -r r repo rev file sha tested dir notice ct_repo ct_rev ct_path ct_sha bytes lic; do
  [ -n "$file_only" ] && [ "$file" != "$file_only" ] && continue
  [ "$dir" = "-" ] && dir="models/$r"
  rel="$dir/$file"
  if [ "$mode" != full ]; then
    # dry/damp: never a weight download. Unknown values are printed as unknown.
    [ "$bytes" = "-" ] && bytes=unknown
    [ "$lic" = "-" ] && lic=unknown
    case "$sha" in ""|-) sha=unknown ;; esac
    path=$(gguf_resolve "$rel")
    if [ -f "$path" ]; then st=present
    elif [ "$mode" = dry ]; then st="would download (full run)"
    else st="skipped weight (damp)"; damp_skipped=$((damp_skipped + 1))
      case "$bytes" in unknown) ;; *) damp_bytes=$((damp_bytes + bytes)) ;; esac
    fi
    echo "fetch-models.sh: $mode-run: $r $repo@$rev $file bytes=$bytes sha256=$sha license=$lic: $st"
    [ "$notice" = "-" ] || echo "fetch-models.sh: LICENSE NOTICE: $notice" >&2
    if [ "$ct_sha" != "-" ]; then
      if [ "$mode" = dry ]; then
        tp="${path%.gguf}.chat-template.jinja"
        if [ -f "$tp" ]; then tst=present; else tst="would download"; fi
        echo "fetch-models.sh: dry-run:   chat template $ct_repo@$ct_rev $ct_path sha256=$ct_sha: $tst"
      else
        # the template is a few KB; it sits next to where the model goes
        [ -f "$path" ] || path=$(gguf_dest "$rel")
        mkdir -p "$(dirname "$path")"
        fetch_template "$path" "$ct_repo" "$ct_rev" "$ct_path" "$ct_sha"
      fi
    fi
    continue
  fi
  case "$sha" in
    ""|-) echo "fetch-models.sh: $file has no sha256; not fetched" >&2; exit 1 ;;
  esac
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
  elif [ "${FULL_VERIFY:-0}" != 1 ] && stamp_ok "$stamp" "$path"; then
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
    # A role served from another role's folder (coder on the general file): a model in the
    # role's own folder would win at serve time, so park it too (e.g. an old --fallback coder).
    if [ "$dir" != "models/$r" ]; then
      own=$(gguf_dest "models/$r")
      for other in "$own"/*.gguf; do
        [ -f "$other" ] || continue
        base=$(basename "$other")
        case "$base" in *mmproj*) continue ;; esac
        if [ "$keep_defaults" = 1 ] && { [ "$base" = "$def_general" ] || [ "$base" = "$def_coder" ]; }; then
          continue
        fi
        mkdir -p "$(gguf_dest "models-inactive/$r")"
        echo "fetch-models.sh: parking $other -> models-inactive/$r/"
        mv "$other" "$(gguf_dest "models-inactive/$r")/"
      done
    fi
  fi
  mkdir -p .cache/verified
  stamp_add "$stamp" "$path"
  if [ "$ct_sha" != "-" ] && [ -n "$ct_sha" ]; then
    fetch_template "$path" "$ct_repo" "$ct_rev" "$ct_path" "$ct_sha"
  fi
  echo "fetch-models.sh: OK $r = $file"
done < "$rows"
case "$mode" in
  dry) echo "fetch-models.sh: dry run: nothing downloaded or written"; exit 0 ;;
  damp) echo "fetch-models.sh: damp run: $damp_skipped weight file(s) skipped ($((damp_bytes / 1000000)) MB); small pieces capped at $max_mb MB; run without --damp-run to download them"; exit 0 ;;
esac
echo "fetch-models.sh: done. Restart scripts/serve.sh (or start.sh) to serve a newly installed model."
