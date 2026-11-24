#!/bin/sh
# PROFILE context defaults, host knobs, and precedence (CLI > env > panel.env > preset).
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
# Role sections inherit [*]; default monolithic leaves some keys only in the star section.
role_val() {
  v=$(val "$1" "$2" "$3")
  [ -n "$v" ] || v=$(val "$1" "*" "$3")
  printf "%s\n" "$v"
}
# Drop inherited ctx knobs so each case starts from the preset default.
run_serve() {
  d=$1; shift
  ( cd "$d" && exec env -u CODER_CTX -u GENERAL_CTX -u CTX_SIZE -u CTX -u PARALLEL \
      "$@" GGUF_HOME="$d" TOOLS_RUNTIME="host" TOOLS="" MCP_CONFIG="" \
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
write_panel() {
  # $1 dir, then KEY=value...
  d=$1; shift
  : > "$d/.cache/panel.env"
  for kv in "$@"; do
    printf ': "${%s:=%s}"\n' "${kv%%=*}" "${kv#*=}" >> "$d/.cache/panel.env"
  done
}
expect_ctx() {  # dir label coder general [parallel]
  d=$1; label=$2; want_c=$3; want_g=$4; want_p=${5-}
  ini="$d/.cache/models-preset.effective.ini"
  ctx=$(role_val "$ini" coder ctx-size)
  general=$(role_val "$ini" general ctx-size)
  par=$(role_val "$ini" coder parallel)
  slot=$(role_val "$ini" coder kv-unified-per-slot)
  if [ "$ctx" = "$want_c" ] && [ "$general" = "$want_g" ] && { [ -z "$want_p" ] || [ "$par" = "$want_p" ]; }; then
    ok "$label (coder=$ctx general=$general parallel=$par slot=$slot)"
  else
    bad "$label: coder=$ctx general=$general parallel=$par slot=$slot (want coder=$want_c general=$want_g${want_p:+ parallel=$want_p})"
    tail -20 "$d/out.txt" || true
  fi
}

# 1) suggested default is 16384, one slot, for default/moderate/lowram.
sandbox "$T/def"
run_serve "$T/def" PROFILE=default
expect_ctx "$T/def" "default suggested ctx" 16384 16384 1

sandbox "$T/mod"
run_serve "$T/mod" PROFILE=moderate
expect_ctx "$T/mod" "moderate suggested ctx" 16384 16384 1

sandbox "$T/low"
run_serve "$T/low" PROFILE=lowram
expect_ctx "$T/low" "lowram suggested ctx" 16384 16384 1

# 2) --ctx-size is a launcher knob: sets both roles, not a pass-through llama-server flag.
sandbox "$T/flag-both"
( cd "$T/flag-both" && exec env -u CODER_CTX -u GENERAL_CTX -u CTX_SIZE -u CTX \
    PROFILE=moderate GGUF_HOME="$T/flag-both" TOOLS_RUNTIME=host TOOLS="" MCP_CONFIG="" \
    LLAMA_SERVER="$T/llama-server" PORT=19992 \
    sh scripts/serve.sh --ctx-size 65536 > "$T/flag-both/out.txt" 2>&1 ) || true
expect_ctx "$T/flag-both" "--ctx-size 65536 sets both (larger than 16k)" 65536 65536 1
if grep -q -- '--ctx-size 65536' "$T/flag-both/out.txt"; then
  # banner/help may mention the flag; the child argv must not still carry it as a passthrough.
  if grep -E 'extra llama-server arguments|llama-server .*--ctx-size 65536' "$T/flag-both/out.txt" >/dev/null; then
    bad "--ctx-size was forwarded to llama-server"; tail -20 "$T/flag-both/out.txt" || true
  else
    ok "--ctx-size is consumed by the launcher"
  fi
else
  ok "--ctx-size is consumed by the launcher"
fi

# 3) role flags beat --ctx-size for that role only.
sandbox "$T/flag-role"
( cd "$T/flag-role" && exec env -u CODER_CTX -u GENERAL_CTX -u CTX_SIZE -u CTX \
    PROFILE=moderate GGUF_HOME="$T/flag-role" TOOLS_RUNTIME=host TOOLS="" MCP_CONFIG="" \
    LLAMA_SERVER="$T/llama-server" PORT=19993 \
    sh scripts/serve.sh --ctx-size 32768 --coder-ctx 40960 --general-ctx 8192 > "$T/flag-role/out.txt" 2>&1 ) || true
expect_ctx "$T/flag-role" "--coder-ctx/--general-ctx beat --ctx-size" 40960 8192 1

# 4) small env overrides below 16k remain accepted.
sandbox "$T/p1"
run_serve "$T/p1" PROFILE=moderate PARALLEL=1 CODER_CTX=8192 GENERAL_CTX=4096
expect_ctx "$T/p1" "CODER_CTX=8192 GENERAL_CTX=4096" 8192 4096 1

# 5) values above the model limit are capped only at n_ctx_train.
sandbox "$T/above"
run_serve "$T/above" PROFILE=moderate CODER_CTX=524288
ctx=$(val "$T/above/.cache/models-preset.effective.ini" coder ctx-size)
if [ "$ctx" = 262144 ] && grep -q 'model max; profile asked 524288' "$T/above/out.txt"; then
  ok "CODER_CTX=524288 is model-capped at 262144"
else
  bad "context above model limit not fitted: ctx=$ctx"; tail -20 "$T/above/out.txt" || true
fi

# 6) panel.env alone wins over the 16384 preset default.
sandbox "$T/panel"
write_panel "$T/panel" CODER_CTX=32768 GENERAL_CTX=8192
run_serve "$T/panel" PROFILE=default
expect_ctx "$T/panel" "panel.env role knobs" 32768 8192 1

sandbox "$T/panel-size"
write_panel "$T/panel-size" CTX_SIZE=24576
run_serve "$T/panel-size" PROFILE=default
expect_ctx "$T/panel-size" "panel.env CTX_SIZE sets both" 24576 24576 1

# 7) env beats panel.env (including env CTX_SIZE over panel CODER_CTX).
sandbox "$T/env-beats-panel"
write_panel "$T/env-beats-panel" CODER_CTX=8192 GENERAL_CTX=8192
run_serve "$T/env-beats-panel" PROFILE=default CODER_CTX=65536 GENERAL_CTX=32768
expect_ctx "$T/env-beats-panel" "env role knobs beat panel.env" 65536 32768 1

sandbox "$T/env-size-beats-panel"
write_panel "$T/env-size-beats-panel" CODER_CTX=8192 GENERAL_CTX=8192
run_serve "$T/env-size-beats-panel" PROFILE=default CTX_SIZE=32768
expect_ctx "$T/env-size-beats-panel" "env CTX_SIZE beats panel role knobs" 32768 32768 1

# 8) CLI flag beats env.
sandbox "$T/flag-beats-env"
( cd "$T/flag-beats-env" && exec env -u GENERAL_CTX -u CTX_SIZE -u CTX \
    PROFILE=default CODER_CTX=65536 GGUF_HOME="$T/flag-beats-env" TOOLS_RUNTIME=host TOOLS="" MCP_CONFIG="" \
    LLAMA_SERVER="$T/llama-server" PORT=19994 \
    sh scripts/serve.sh --coder-ctx 24576 --general-ctx 16384 > "$T/flag-beats-env/out.txt" 2>&1 ) || true
expect_ctx "$T/flag-beats-env" "CLI --coder-ctx beats env CODER_CTX" 24576 16384 1

if [ "$fails" -gt 0 ]; then echo "FAILED $fails"; exit 1; fi
echo "ALL OK"
