#!/bin/sh
# Shared GGUF store: default path, checkout fallback, cache-model refusal.
# No llama-server, no download, no pwsh.
#   sh tests/test_gguf_store.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/lib/common.sh"
T=$(mktemp -d)
fails=0
cleanup() { rm -rf "$T"; }
trap cleanup EXIT
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
tab=$(printf '\t')

got=$(
  HOME=$T/home
  unset XDG_DATA_HOME GGUF_HOME
  # shellcheck disable=SC1090
  . "$ROOT/scripts/lib/common.sh"
  gguf_home
)
if [ "$got" = "$T/home/.local/share/gguf" ]; then ok "default store is ~/.local/share/gguf"
else bad "default store: got '$got'"; fi

got=$(
  HOME=$T/home
  XDG_DATA_HOME=$T/xdg
  unset GGUF_HOME
  # shellcheck disable=SC1090
  . "$ROOT/scripts/lib/common.sh"
  gguf_home
)
if [ "$got" = "$T/xdg/gguf" ]; then ok "XDG_DATA_HOME/gguf"
else bad "XDG store: got '$got'"; fi

got=$(
  HOME=$T/home
  XDG_DATA_HOME=$T/xdg
  GGUF_HOME=$T/custom
  # shellcheck disable=SC1090
  . "$ROOT/scripts/lib/common.sh"
  gguf_home
)
if [ "$got" = "$T/custom" ]; then ok "GGUF_HOME overrides XDG and HOME"
else bad "GGUF_HOME: got '$got'"; fi

# --- resolver: store, checkout fallback, MODELS_DIR ---
REPO=$T/repo
STORE=$T/store
mkdir -p "$REPO/models/coder" "$STORE"
printf 'checkout\n' > "$REPO/models/coder/a.gguf"
resolve() {
  ROOT=$REPO
  GGUF_HOME=$STORE
  if [ -n "${1:-}" ]; then MODELS_DIR=$1; else unset MODELS_DIR; fi
  shift
  gguf_resolve "$1"
}
got=$(resolve "" "models/coder/a.gguf")
if [ "$got" = "$REPO/models/coder/a.gguf" ]; then ok "missing store file uses the checkout copy"
else bad "checkout fallback: got '$got'"; fi

mkdir -p "$STORE/models/coder"
printf 'store\n' > "$STORE/models/coder/a.gguf"
got=$(resolve "" "models/coder/a.gguf")
if [ "$got" = "$STORE/models/coder/a.gguf" ]; then ok "store file wins over the checkout copy"
else bad "store wins: got '$got'"; fi

mkdir -p "$REPO/models-optional/language"
printf 'hy\n' > "$REPO/models-optional/language/HY.gguf"
got=$(resolve "" "models-optional/language/HY.gguf")
if [ "$got" = "$REPO/models-optional/language/HY.gguf" ]; then ok "models-optional falls back to the checkout"
else bad "optional fallback: got '$got'"; fi

OTHER=$T/other
mkdir -p "$OTHER/coder"
printf 'other\n' > "$OTHER/coder/a.gguf"
got=$(resolve "$OTHER" "models/coder/a.gguf")
if [ "$got" = "$OTHER/coder/a.gguf" ]; then ok "MODELS_DIR replaces the models root"
else bad "MODELS_DIR: got '$got'"; fi
got=$(resolve "$OTHER" "models/coder/missing.gguf")
if [ "$got" = "$OTHER/coder/missing.gguf" ]; then ok "MODELS_DIR does not fall back to the checkout"
else bad "MODELS_DIR fallback: got '$got'"; fi

# --- cache-model ---
CM=$ROOT/scripts/cache-model.sh
SRC=$T/src
mkdir -p "$SRC" "$STORE/models/coder"
printf 'same-bytes\n' > "$SRC/same.gguf"
printf 'same-bytes\n' > "$STORE/models/coder/same.gguf"
before=$(stat -c '%i %Y %s' "$STORE/models/coder/same.gguf" 2>/dev/null || stat -f '%i %m %z' "$STORE/models/coder/same.gguf")
if GGUF_HOME=$STORE sh "$CM" "$SRC/same.gguf" models/coder/same.gguf > "$T/same.out" 2>&1; then
  after=$(stat -c '%i %Y %s' "$STORE/models/coder/same.gguf" 2>/dev/null || stat -f '%i %m %z' "$STORE/models/coder/same.gguf")
  if [ "$before" = "$after" ] && [ -f "$SRC/same.gguf" ] && cmp -s "$SRC/same.gguf" "$STORE/models/coder/same.gguf"; then
    ok "cache-model: same bytes, destination not rewritten"
  else
    bad "cache-model same bytes changed the destination or removed the source"
  fi
else
  bad "cache-model same bytes failed: $(cat "$T/same.out")"
fi

printf 'left\n' > "$SRC/diff.gguf"
printf 'right\n' > "$STORE/models/coder/diff.gguf"
if GGUF_HOME=$STORE sh "$CM" "$SRC/diff.gguf" models/coder/diff.gguf > "$T/diff.out" 2>&1; then
  bad "cache-model overwrote a different file"
else
  if cmp -s "$SRC/diff.gguf" "$T/left-expect" 2>/dev/null; then
    :
  fi
  printf 'left\n' > "$T/left-expect"
  printf 'right\n' > "$T/right-expect"
  if cmp -s "$SRC/diff.gguf" "$T/left-expect" && cmp -s "$STORE/models/coder/diff.gguf" "$T/right-expect"; then
    ok "cache-model: refuses a different file and leaves both"
  else
    bad "cache-model refusal changed a file: $(cat "$T/diff.out")"
  fi
fi

printf 'moved\n' > "$SRC/new.gguf"
if GGUF_HOME=$STORE sh "$CM" "$SRC/new.gguf" models/coder/new.gguf > "$T/move.out" 2>&1 \
  && [ ! -e "$SRC/new.gguf" ] && cmp -s "$STORE/models/coder/new.gguf" "$T/moved-expect"; then
  :
fi
printf 'moved\n' > "$T/moved-expect"
if [ ! -e "$SRC/new.gguf" ] && [ -f "$STORE/models/coder/new.gguf" ] && cmp -s "$STORE/models/coder/new.gguf" "$T/moved-expect"; then
  ok "cache-model: moves a new file into the store"
else
  bad "cache-model move: $(cat "$T/move.out" 2>/dev/null || true)"
fi

# inferred layout, still only the named path
mkdir -p "$T/work/models-inactive/coder"
printf 'parked\n' > "$T/work/models-inactive/coder/old.gguf"
if GGUF_HOME=$STORE sh "$CM" "$T/work/models-inactive/coder/old.gguf" > "$T/infer.out" 2>&1 \
  && [ -f "$STORE/models-inactive/coder/old.gguf" ] && [ ! -e "$T/work/models-inactive/coder/old.gguf" ]; then
  ok "cache-model: layout taken from the named path"
else
  bad "cache-model infer: $(cat "$T/infer.out" 2>/dev/null || true)"
fi

# --- fetch-models: store destination, checkout left in place, bad sha not live ---
sb() {
  d=$1
  rm -rf "$d"
  mkdir -p "$d"
  cp -R "$ROOT/scripts" "$ROOT/config" "$d/"
}
mkdir -p "$T/stubs"
cat > "$T/stubs/curl" <<'EOF'
#!/bin/sh
out=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out=$a; fi
  prev=$a
done
[ -n "$out" ] || exit 2
printf 'downloaded\n' > "$out"
exit 0
EOF
cat > "$T/stubs/sha256sum" <<'EOF'
#!/bin/sh
printf '%s  %s\n' "$WANT_SHA" "$1"
EOF
chmod +x "$T/stubs/curl" "$T/stubs/sha256sum"
decision=$(awk -v match_kv="pick=default role=decision" -v fields="file sha256" \
  -f "$ROOT/scripts/lib/manifest.awk" "$ROOT/config/models-manifest.json")
dec_file=${decision%%"$tab"*}
dec_sha=${decision#*"$tab"}

sb "$T/fetch-ok"
if PATH="$T/stubs:$PATH" GGUF_HOME=$T/fetch-store WANT_SHA=$dec_sha \
    sh "$T/fetch-ok/scripts/fetch-models.sh" --role decision > "$T/fetch-ok.out" 2>&1 \
  && [ -f "$T/fetch-store/models/decision/$dec_file" ] \
  && [ ! -e "$T/fetch-ok/models/decision/$dec_file" ] \
  && [ ! -e "$T/fetch-store/models/decision/$dec_file.part" ]; then
  ok "fetch-models downloads into the store"
else
  bad "fetch-models store dest: $(tail -n 8 "$T/fetch-ok.out")"
fi

sb "$T/fetch-bad"
if PATH="$T/stubs:$PATH" GGUF_HOME=$T/fetch-bad-store WANT_SHA=0000000000000000000000000000000000000000000000000000000000000000 \
    sh "$T/fetch-bad/scripts/fetch-models.sh" --role decision > "$T/fetch-bad.out" 2>&1; then
  bad "fetch-models accepted a sha256 mismatch"
else
  if [ ! -e "$T/fetch-bad-store/models/decision/$dec_file" ] \
    && [ -f "$T/fetch-bad-store/models/decision/$dec_file.bad" ] \
    && [ ! -e "$T/fetch-bad-store/models/decision/$dec_file.part" ]; then
    ok "fetch-models: mismatch is not the live GGUF"
  else
    bad "fetch-models mismatch left a live file: $(tail -n 8 "$T/fetch-bad.out")"
  fi
fi

sb "$T/fetch-co"
mkdir -p "$T/fetch-co/models/decision"
printf 'already\n' > "$T/fetch-co/models/decision/$dec_file"
co_before=$(stat -c '%i' "$T/fetch-co/models/decision/$dec_file" 2>/dev/null || stat -f '%i' "$T/fetch-co/models/decision/$dec_file")
if PATH="$T/stubs:$PATH" GGUF_HOME=$T/fetch-co-store WANT_SHA=$dec_sha \
    sh "$T/fetch-co/scripts/fetch-models.sh" --role decision > "$T/fetch-co.out" 2>&1 \
  && [ ! -e "$T/fetch-co-store/models/decision/$dec_file" ]; then
  co_after=$(stat -c '%i' "$T/fetch-co/models/decision/$dec_file" 2>/dev/null || stat -f '%i' "$T/fetch-co/models/decision/$dec_file")
  if [ "$co_before" = "$co_after" ]; then ok "fetch-models leaves a checkout copy in place"
  else bad "fetch-models moved the checkout copy"; fi
else
  bad "fetch-models checkout: $(tail -n 8 "$T/fetch-co.out")"
fi

# --- serve.sh chooses the store, else the checkout, else MODELS_DIR ---
printf '%s\n' '#!/bin/sh' 'exit 0' > "$T/llama-server"
chmod +x "$T/llama-server" "$CM"
model_of() {
  awk -v sec="$2" '
    /^\[/ { s = substr($0, 2, index($0, "]") - 2); next }
    s == sec && $0 ~ /^model[ \t]*=/ { sub(/^[^=]*=[ \t]*/, ""); sub(/[ \t\r]+$/, ""); print; exit }
  ' "$1"
}
place_defaults() {
  base=$1
  stamp_root=$2
  awk -v match_kv="pick=default" -v fields="role file sha256" -f "$ROOT/scripts/lib/manifest.awk" \
    "$ROOT/config/models-manifest.json" > "$T/default-rows"
  while IFS=$tab read -r role f sha; do
    mkdir -p "$base/$role" "$stamp_root/.cache/verified"
    echo "placeholder $f" > "$base/$role/$f"
    fingerprint "$base/$role/$f" > "$stamp_root/.cache/verified/$sha"
  done < "$T/default-rows"
}
run_serve() {
  d=$1
  shift
  : > "$d/out.txt"
  timeout 40 env "$@" PORT=19931 PROFILE=lowram TOOLS_RUNTIME=host TOOLS= MCP_CONFIG= \
    LOCALE=en LANGUAGE_MODE=off LLAMA_SERVER="$T/llama-server" \
    sh "$d/scripts/serve.sh" > "$d/out.txt" 2>&1 || return $?
}

sb "$T/srv-co"
place_defaults "$T/srv-co/models" "$T/srv-co"
mkdir -p "$T/srv-co-store"
if run_serve "$T/srv-co" GGUF_HOME="$T/srv-co-store"; then
  coder=$(model_of "$T/srv-co/.cache/models-preset.effective.ini" coder)
  if [ "$coder" = "$T/srv-co/models/coder/Qwen3.5-2B-Q4_K_M.gguf" ]; then
    ok "serve uses the checkout copy when the store has no file"
  else
    bad "serve checkout path: '$coder'"
  fi
else
  bad "serve checkout fallback did not start: $(tail -n 12 "$T/srv-co/out.txt")"
fi

sb "$T/srv-store"
place_defaults "$T/srv-store/models" "$T/srv-store"
# Stamps must describe the store files, which are the ones serve opens.
place_defaults "$T/srv-store-home/models" "$T/srv-store"
if run_serve "$T/srv-store" GGUF_HOME="$T/srv-store-home"; then
  coder=$(model_of "$T/srv-store/.cache/models-preset.effective.ini" coder)
  if [ "$coder" = "$T/srv-store-home/models/coder/Qwen3.5-2B-Q4_K_M.gguf" ]; then
    ok "serve prefers the store over the checkout"
  else
    bad "serve store path: '$coder'"
  fi
else
  bad "serve store did not start: $(tail -n 12 "$T/srv-store/out.txt")"
fi

sb "$T/srv-md"
place_defaults "$T/srv-md/models" "$T/srv-md"
mkdir -p "$T/srv-md-other"
if run_serve "$T/srv-md" GGUF_HOME="$T/empty-store" MODELS_DIR="$T/srv-md-other"; then
  bad "serve used a checkout model even though MODELS_DIR was set"
else
  if grep -q "no model for the general role in $T/srv-md-other/general/" "$T/srv-md/out.txt"; then
    ok "MODELS_DIR does not fall back when serve looks up a role"
  else
    bad "MODELS_DIR serve: $(tail -n 8 "$T/srv-md/out.txt")"
  fi
fi

if [ "$fails" -eq 0 ]; then echo "all gguf store tests passed"
else echo "$fails failed"; exit 1; fi
