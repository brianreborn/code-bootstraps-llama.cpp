#!/bin/sh
# PROFILE context defaults and explicit context overrides (#15).
# Stub llama-server exits at once; no model is loaded.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/lib/common.sh"
T=$(mktemp -d)
export XDG_CONFIG_HOME="$T/xdg"
fails=0
cleanup() {
  if [ -f "$T/pids" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      kill -TERM -"$p" 2>/dev/null || true
    done < "$T/pids"
  fi
  rm -rf "$T"
}
trap cleanup EXIT
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
: > "$T/pids"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$T/llama-server"
chmod +x "$T/llama-server"
tab=$(printf '\t')

sandbox() {
  d=$1
  mkdir -p "$d/.cache/verified"
  cp -R "$ROOT/scripts" "$ROOT/config" "$ROOT/lib" "$d/"
  awk -v match_kv="pick=default" -v fields="role file sha256 dir" -f "$ROOT/scripts/lib/manifest.awk" \
    "$ROOT/config/models-manifest.json" > "$d/.cache/default-rows"
  while IFS=$tab read -r role f sha dir; do
    [ "$dir" = "-" ] && dir="models/$role"
    mkdir -p "$d/$dir"
    [ -f "$d/$dir/$f" ] && continue
    echo "placeholder $f" > "$d/$dir/$f"
    fingerprint "$d/$dir/$f" >> "$d/.cache/verified/$sha"
  done < "$d/.cache/default-rows"
}
val() {
  awk -v sec="$2" -v key="$3" '
    /^\[/ { s = substr($0, 2, index($0, "]") - 2); next }
    s == sec && $0 ~ "^" key "[ \t]*=" {
      sub(/^[^=]*=[ \t]*/, ""); sub(/[ \t\r]+$/, ""); print; exit
    }
  ' "$1"
}
run_serve() {
  d=$1; shift
  ( cd "$d" && exec env "$@" GGUF_HOME="$d" TOOLS_RUNTIME=host TOOLS="" MCP_CONFIG="" \
      LLAMA_SERVER="$T/llama-server" PORT=19991 \
      sh scripts/serve.sh > "$d/out.txt" 2>&1 ) &
  echo $! >> "$T/pids"
  wait $! || true
  if [ ! -f "$d/.cache/models-preset.effective.ini" ]; then
    echo "FAIL serve did not write the effective preset for $d"
    cat "$d/out.txt" >&2
    fails=$((fails + 1))
  fi
}

# 1) the moderate profile preserves the default model's full documented context.
sandbox "$T/mod"
run_serve "$T/mod" PROFILE=moderate
ctx=$(val "$T/mod/.cache/models-preset.effective.ini" coder ctx-size)
par=$(val "$T/mod/.cache/models-preset.effective.ini" coder parallel)
if [ "$ctx" = 262144 ] && [ "$par" = 1 ]; then
  ok "moderate preserves full context ctx=$ctx parallel=$par"
else
  bad "moderate context/parallel unexpected: ctx=$ctx par=$par"
fi

# 2) lowram lowers residency and caching without shrinking request context.
sandbox "$T/low"
run_serve "$T/low" PROFILE=lowram
ctx=$(val "$T/low/.cache/models-preset.effective.ini" coder ctx-size)
par=$(val "$T/low/.cache/models-preset.effective.ini" coder parallel)
if [ "$ctx" = 262144 ] && [ "$par" = 1 ]; then ok "lowram preserves full context ctx=$ctx parallel=$par"
else bad "lowram context/parallel unexpected: ctx=$ctx par=$par"; fi

# 3) explicit --ctx-size beats profile
sandbox "$T/ex2"
( cd "$T/ex2" && env PROFILE=moderate GGUF_HOME="$T/ex2" TOOLS_RUNTIME=host TOOLS="" MCP_CONFIG="" \
    LLAMA_SERVER="$T/llama-server" PORT=19992 \
    sh scripts/serve.sh --ctx-size 65536 > "$T/ex2/out.txt" 2>&1 ) || true
ctx=$(val "$T/ex2/.cache/models-preset.effective.ini" coder ctx-size)
par=$(val "$T/ex2/.cache/models-preset.effective.ini" coder parallel)
if [ "$ctx" = 262144 ] && [ "$par" = 1 ] && grep -q -- '--ctx-size 65536' "$T/ex2/out.txt"; then
  ok "explicit --ctx-size 65536 is passed through to the server"
else
  bad "explicit --ctx-size not passed through: preset ctx=$ctx par=$par"
  tail -20 "$T/ex2/out.txt" || true
fi

# 4) small explicit contexts below the former arbitrary floors remain accepted.
sandbox "$T/p1"
( cd "$T/p1" && env PROFILE=moderate PARALLEL=1 CODER_CTX=8192 GENERAL_CTX=4096 GGUF_HOME="$T/p1" TOOLS_RUNTIME=host TOOLS="" MCP_CONFIG="" \
    LLAMA_SERVER="$T/llama-server" PORT=19993 \
    sh scripts/serve.sh > "$T/p1/out.txt" 2>&1 ) || true
ctx=$(val "$T/p1/.cache/models-preset.effective.ini" coder ctx-size)
par=$(val "$T/p1/.cache/models-preset.effective.ini" coder parallel)
slot=$(val "$T/p1/.cache/models-preset.effective.ini" coder kv-unified-per-slot)
general=$(val "$T/p1/.cache/models-preset.effective.ini" general ctx-size)
if [ "$ctx" = 8192 ] && [ "$par" = 1 ] && [ "$slot" = 8192 ] && [ "$general" = 4096 ]; then
  ok "CODER_CTX=8192 and GENERAL_CTX=4096 accepted below former floors"
else
  bad "small context override: coder=$ctx par=$par slot=$slot general=$general"
fi

# 5) overrides above the launcher range are accepted, then capped only by model metadata.
sandbox "$T/above"
( cd "$T/above" && env PROFILE=moderate CODER_CTX=524288 GGUF_HOME="$T/above" TOOLS_RUNTIME=host TOOLS="" MCP_CONFIG="" \
    LLAMA_SERVER="$T/llama-server" PORT=19994 \
    sh scripts/serve.sh > "$T/above/out.txt" 2>&1 ) || true
ctx=$(val "$T/above/.cache/models-preset.effective.ini" coder ctx-size)
if [ "$ctx" = 262144 ] && grep -q 'model max; profile asked 524288' "$T/above/out.txt"; then
  ok "context above former ceiling is model-capped at 262144"
else
  bad "context above former ceiling not fitted: ctx=$ctx"; tail -20 "$T/above/out.txt" || true
fi

if [ "$fails" -gt 0 ]; then echo "FAILED $fails"; exit 1; fi
echo "ALL OK"
