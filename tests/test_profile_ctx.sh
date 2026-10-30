#!/bin/sh
# PROFILE ctx consistency and explicit --ctx-size/--parallel beating the profile (#15).
# Stub llama-server exits at once; no model is loaded.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/lib/common.sh"
T=$(mktemp -d)
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
  cp -R "$ROOT/scripts" "$ROOT/config" "$d/"
  awk -v match_kv="pick=default" -v fields="role file sha256" -f "$ROOT/scripts/lib/manifest.awk" \
    "$ROOT/config/models-manifest.json" > "$d/.cache/default-rows"
  while IFS=$tab read -r role f sha; do
    mkdir -p "$d/models/$role"
    echo "placeholder $f" > "$d/models/$role/$f"
    fingerprint "$d/models/$role/$f" > "$d/.cache/verified/$sha"
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
      sh scripts/serve.sh "$@" > "$d/out.txt" 2>&1 ) &
  echo $! >> "$T/pids"
  wait $! || true
}

# 1) moderate profile is internally consistent: parallel * per-slot <= ctx
sandbox "$T/mod"
run_serve "$T/mod" PROFILE=moderate
ctx=$(val "$T/mod/.cache/models-preset.effective.ini" coder ctx-size)
par=$(val "$T/mod/.cache/models-preset.effective.ini" coder parallel)
slot=$(val "$T/mod/.cache/models-preset.effective.ini" coder kv-unified-per-slot)
if [ -n "$ctx" ] && [ -n "$par" ] && [ -n "$slot" ] && [ $((par * slot)) -le "$ctx" ]; then
  ok "moderate consistent ctx=$ctx parallel=$par slot=$slot"
else
  bad "moderate inconsistent ctx=$ctx parallel=$par slot=$slot (product $((par * slot)))"
fi
# Was the old overcommit (24576 vs 2*16384); new moderate should be 32768/2/16384
if [ "$ctx" = 32768 ] && [ "$par" = 2 ] && [ "$slot" = 16384 ]; then
  ok "moderate values fixed to 32768 = 2*16384"
else
  bad "moderate unexpected values ctx=$ctx par=$par slot=$slot"
fi

# 2) lowram also consistent
sandbox "$T/low"
run_serve "$T/low" PROFILE=lowram
ctx=$(val "$T/low/.cache/models-preset.effective.ini" coder ctx-size)
par=$(val "$T/low/.cache/models-preset.effective.ini" coder parallel)
slot=$(val "$T/low/.cache/models-preset.effective.ini" coder kv-unified-per-slot)
if [ $((par * slot)) -le "$ctx" ]; then ok "lowram consistent ctx=$ctx par=$par slot=$slot"
else bad "lowram inconsistent ctx=$ctx par=$par slot=$slot"; fi

# 3) explicit --ctx-size beats profile
sandbox "$T/ex"
run_serve "$T/ex" PROFILE=moderate -- --ctx-size 65536
# serve.sh is invoked as: sh scripts/serve.sh "$@" with env PROFILE=...
# Fix: run_serve passes env then -- then args incorrectly. Redo below.

# Re-run with correct argv
sandbox "$T/ex2"
( cd "$T/ex2" && env PROFILE=moderate GGUF_HOME="$T/ex2" TOOLS_RUNTIME=host TOOLS="" MCP_CONFIG="" \
    LLAMA_SERVER="$T/llama-server" PORT=19992 \
    sh scripts/serve.sh --ctx-size 65536 > "$T/ex2/out.txt" 2>&1 ) || true
ctx=$(val "$T/ex2/.cache/models-preset.effective.ini" coder ctx-size)
par=$(val "$T/ex2/.cache/models-preset.effective.ini" coder parallel)
slot=$(val "$T/ex2/.cache/models-preset.effective.ini" coder kv-unified-per-slot)
if [ "$ctx" = 65536 ] && [ "$slot" = $((65536 / par)) ]; then
  ok "explicit --ctx-size 65536 beats moderate (slot=$slot parallel=$par)"
else
  bad "explicit ctx not applied: ctx=$ctx par=$par slot=$slot"
  tail -20 "$T/ex2/out.txt" || true
fi

# 4) explicit PARALLEL=1 with CODER_CTX
sandbox "$T/p1"
( cd "$T/p1" && env PROFILE=moderate PARALLEL=1 CODER_CTX=64000 GGUF_HOME="$T/p1" TOOLS_RUNTIME=host TOOLS="" MCP_CONFIG="" \
    LLAMA_SERVER="$T/llama-server" PORT=19993 \
    sh scripts/serve.sh > "$T/p1/out.txt" 2>&1 ) || true
ctx=$(val "$T/p1/.cache/models-preset.effective.ini" coder ctx-size)
par=$(val "$T/p1/.cache/models-preset.effective.ini" coder parallel)
slot=$(val "$T/p1/.cache/models-preset.effective.ini" coder kv-unified-per-slot)
if [ "$ctx" = 64000 ] && [ "$par" = 1 ] && [ "$slot" = 64000 ]; then
  ok "CODER_CTX+PARALLEL=1 -> per-slot 64000"
else
  bad "env override: ctx=$ctx par=$par slot=$slot"
fi

# 5) inconsistent overlay fails loud (inject via broken PROFILE values using env after patching overlay is hard;
#    instead call check by forcing PARALLEL=2 CODER_CTX=10000 which would set slot=5000, product=10000 OK.
#    Force failure: manually craft by setting PARALLEL=4 CODER_CTX=10000 -> slot=2500, OK.
#    To test die path, temporarily use a profile-inconsistency by setting only PARALLEL without
#    adjusting when ov has huge per-slot — our code recomputes slot. So test the die by
#    invoking check via a tiny helper: PROFILE=default with no coder overlay then ov_set manually.
#    Simpler: grep that die message exists and unit-test via sh -c sourcing is heavy.
#    Inject overcommit by writing a wrapper that exports OVERLAY after profile — skip; covered by
#    moderate/lowram consistency + the die() string being present.
if grep -q 'profile inconsistent' "$ROOT/scripts/serve.sh"; then
  ok "fail-loud check_role_kv present"
else
  bad "check_role_kv die missing"
fi

# 6) Direct overcommit die: craft with PARALLEL high and tiny ctx via env — recomputed slot makes it consistent.
#    So invoke a one-off by patching EFFECTIVE path: call serve with PROFILE=moderate and
#    a fake ov by using CODER_CTX=24576 PARALLEL=2 — product equals ctx (slot=12288). OK.
#    To hit die, we need per-slot NOT recomputed: only when neither CODER_CTX nor PARALLEL set.
#    Break lowram temporarily is wrong. Unit-test die with:
sandbox "$T/die"
# Copy serve and replace moderate overlay with the OLD inconsistent values, then run PROFILE=moderate
sed 's/coder.ctx-size=32768/coder.ctx-size=24576/' "$ROOT/scripts/serve.sh" > "$T/die/scripts/serve.sh"
# scripts already copied in sandbox — overwrite
cp "$ROOT/scripts/serve.sh" "$T/die/scripts/serve.sh"
# inject old bad overlay
sed -i 's/coder.ctx-size=32768 coder.kv-unified-per-slot=16384/coder.ctx-size=24576 coder.kv-unified-per-slot=16384/' "$T/die/scripts/serve.sh"
set +e
( cd "$T/die" && env PROFILE=moderate GGUF_HOME="$T/die" TOOLS_RUNTIME=host TOOLS="" MCP_CONFIG="" \
    LLAMA_SERVER="$T/llama-server" PORT=19994 \
    sh scripts/serve.sh > "$T/die/out.txt" 2>&1 )
rc=$?
set -e
if [ "$rc" -ne 0 ] && grep -q 'profile inconsistent' "$T/die/out.txt"; then
  ok "inconsistent profile fails loud"
else
  bad "expected die on overcommit; rc=$rc"; tail -30 "$T/die/out.txt" || true
fi

if [ "$fails" -gt 0 ]; then echo "FAILED $fails"; exit 1; fi
echo "ALL OK"
