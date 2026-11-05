#!/bin/sh
# Issue #35: interrupting start.sh (MODELS_BG=1) must stop the background model download.
# Builds the same tree start.sh does (async subshell -> downloader -> long-running child,
# SIGINT ignored as in a non-interactive sh), stops it with bgfetch_stop, and checks that
# no process from the tree is left and the .part file is kept for resume.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok - $1"; }
bad() { fail=$((fail + 1)); echo "not ok - $1"; }
cleanup() { [ -n "${bg:-}" ] && kill -KILL "$bg" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

mkdir -p "$T/.cache" "$T/models"
cat > "$T/fake-fetch.sh" <<'F'
#!/bin/sh
echo partial > "$1/models/m.gguf.part"
sleep 300
F
chmod +x "$T/fake-fetch.sh"
( "$T/fake-fetch.sh" "$T" > "$T/.cache/fetch-models.log" 2>&1; echo "fetch-models: done (exit $?)" >> "$T/.cache/fetch-models.log" ) </dev/null &
bg=$!
echo "$bg" > "$T/.cache/fetch-models.pid"
i=0; while [ ! -f "$T/models/m.gguf.part" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
# shellcheck source=../scripts/lib/bgfetch.sh
. "$ROOT/scripts/lib/bgfetch.sh"
tree=$(bgfetch_tree "$bg" | tr '\n' ' ')
n=$(printf '%s\n' $tree | grep -c . || true)
[ "$n" -ge 3 ] && ok "download tree found ($n processes)" || bad "download tree has $n processes: $tree"

# Ctrl-C alone does not reach it (the bug): SIGINT is ignored in the async subshell
kill -INT "$bg" 2>/dev/null || true; sleep 0.3
kill -0 "$bg" 2>/dev/null && ok "SIGINT alone leaves the background download running (reproduces #35)" || ok "SIGINT stopped it (shell honours INT here)"

( ROOT=$T; bgfetch_stop )
left=""
for p in $tree; do kill -0 "$p" 2>/dev/null && left="$left $p"; done
[ -z "$left" ] && ok "bgfetch_stop leaves no stray process" || bad "stray processes:$left"
[ ! -f "$T/.cache/fetch-models.pid" ] && ok "pid file removed" || bad "pid file still there"
[ -f "$T/models/m.gguf.part" ] && ok ".part kept for resume (curl -C -)" || bad ".part removed"
grep -q "fetch-models: stopped" "$T/.cache/fetch-models.log" && ok "log says stopped" || bad "log line missing"
( ROOT=$T; bgfetch_stop ) && ok "second stop is a no-op" || bad "second stop failed"
bg=""

# wiring
grep -q "trap 'bgfetch_stop; exit 130' INT" "$ROOT/start.sh" && ok "start.sh stops the download on INT" || bad "start.sh INT trap"
grep -q "trap 'bgfetch_stop; exit 143' TERM" "$ROOT/start.sh" && ok "start.sh stops the download on TERM" || bad "start.sh TERM trap"
grep -q 'trap serve_exit EXIT' "$ROOT/scripts/serve.sh" && grep -q 'bgfetch_stop "$FAMILIA_BG_FETCH_PID"' "$ROOT/scripts/serve.sh" \
  && ok "foreground serve.sh stops it on exit" || bad "serve.sh exit wiring"
grep -q 'unset FAMILIA_BG_FETCH_PID' "$ROOT/start.sh" && ok "detached modes keep the download with the server" || bad "detached handoff"

echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
