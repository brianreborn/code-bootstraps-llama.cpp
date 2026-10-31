#!/bin/sh
# Router children get ZERO tools: no built-in tool, tools runtime, MCP server or agent.
#  1. no section of config/models-preset.ini sets tools / MCP (the old "tools = get_info"
#     workaround injected get_info into every model's prompt)
#  2. patches/0003-router-child-no-tools.patch applies to the pinned source (when present)
#  3. serve.sh turns tools/MCP off for a llama-server without the patch marker, and keeps
#     them (router only) for one with it
#  4. live (REAL_LLAMA_SERVER=patched llama-server, TEST_GGUF=small model; else SKIP):
#     the router lists tools, a spawned child answers /tools "feature disabled", has no
#     LLAMA_ARG_TOOLS in its environment, and its prompt for a chat without tools has no get_info
#   sh tests/test_child_no_tools.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/lib/common.sh"
T=$(mktemp -d)
export XDG_CONFIG_HOME="$T/xdg"
: > "$T/pids"
fails=0
cleanup() {
  while IFS= read -r p; do [ -n "$p" ] && { kill -TERM -"$p" 2>/dev/null; kill -TERM "$p" 2>/dev/null; }; done < "$T/pids" || true
  rm -rf "$T"
}
trap cleanup EXIT
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
tab=$(printf '\t')

# 1
hits=$(grep -nE '^[[:space:]]*(tools|tools-runtime|mcp-servers-config|mcp-servers-json|ui-mcp-proxy|agent)[[:space:]]*=' "$ROOT/config/models-preset.ini" || true)
if [ -z "$hits" ]; then ok "models-preset.ini sets no tools / MCP / agent key in any section"
else bad "models-preset.ini sets tools or MCP: $hits"; fi
# 2
if [ -f "$ROOT/llama.cpp/CMakeLists.txt" ] && command -v git >/dev/null 2>&1; then
  if CHECK=1 sh "$ROOT/scripts/apply-patches.sh" 2>&1 | grep -qE "0003-router-child-no-tools.patch (applies cleanly|already applied)"; then
    ok "patches/0003 applies to the pinned llama.cpp source"
  else bad "patches/0003 does not apply: $(CHECK=1 sh "$ROOT/scripts/apply-patches.sh" 2>&1 | tail -n 2)"; fi
else echo "SKIP patch check (no llama.cpp source)"; fi
# 3
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
guard() {   # guard NAME MARKER(0|1): run serve.sh with a stub that records LLAMA_ARG_TOOLS*/MCP
  d=$T/$1; sandbox "$d"; mkdir -p "$d/stub"
  { echo '#!/bin/sh'
    [ "$2" = 1 ] && echo '# router-child-no-tools'
    echo 'case " $* " in *" --models-preset "*) env | grep -E "^LLAMA_ARG_(TOOLS|MCP)" > "$STUB_ENV" ;; esac'
    echo 'exit 0'; } > "$d/stub/llama-server"
  chmod +x "$d/stub/llama-server"; : > "$d/env.txt"
  ( cd "$d" && STUB_ENV="$d/env.txt" PORT=19$$ GGUF_HOME="$d" TOOLS=full TOOLS_RUNTIME=host LANGUAGE_MODE=off \
      LLAMA_SERVER="$d/stub/llama-server" sh scripts/serve.sh > "$d/out.txt" 2>&1 ) || true
}
guard unpatched 0
if ! grep -q LLAMA_ARG_TOOLS "$T/unpatched/env.txt" && ! grep -q LLAMA_ARG_MCP "$T/unpatched/env.txt" && grep -q "lacks patches/0003" "$T/unpatched/out.txt"; then
  ok "unpatched llama-server: tools and MCP switched off with a warning"
else bad "unpatched llama-server still got: $(cat "$T/unpatched/env.txt") $(tail -n 2 "$T/unpatched/out.txt")"; fi
guard patched 1
if grep -q "^LLAMA_ARG_TOOLS=" "$T/patched/env.txt"; then ok "patched llama-server: the router keeps TOOLS"
else bad "patched llama-server lost TOOLS: $(tail -n 3 "$T/patched/out.txt")"; fi
# 4
REAL=${REAL_LLAMA_SERVER:-}
[ -n "$REAL" ] || for c in "$ROOT"/build-*/bin/llama-server; do [ -x "$c" ] && { REAL=$c; break; }; done
GG=${TEST_GGUF:-}
# No /tmp fallback: a GGUF planted in a shared dir could be loaded. Only an explicit
# TEST_GGUF or a file under the user's own cache dir is used, and only if it is ours and not a symlink.
SMOKE=${XDG_CACHE_HOME:-$HOME/.cache}/code-bootstraps-llama.cpp/smoke
[ -n "$GG" ] || for g in "$SMOKE/tiny.gguf" "$SMOKE/lfm3.gguf"; do [ -f "$g" ] && { GG=$g; break; }; done
if [ -n "$GG" ]; then
  if [ -L "$GG" ] || [ ! -f "$GG" ] || [ ! -O "$GG" ]; then
    echo "SKIP live check: refusing $GG (missing, a symlink, or not owned by $(id -un))"; GG=""
  fi
fi
if [ -z "$REAL" ] || [ -z "$GG" ] || ! command -v curl >/dev/null 2>&1; then
  echo "SKIP live check (set REAL_LLAMA_SERVER and TEST_GGUF)"
elif ! grep -aqs router-child-no-tools "$REAL" "$(dirname "$REAL")"/*.so* "$(dirname "$REAL")"/*.dll; then
  echo "SKIP live check ($REAL is not built with patches/0003)"
else
  printf 'version = 1\n[*]\nctx-size = 2048\n[t]\nmodel = %s\n' "$GG" > "$T/p.ini"
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  ( LLAMA_ARG_TOOLS=read_file,get_info,exec_shell_command LLAMA_ARG_MCP_SERVERS_JSON='{"mcpServers":{}}' \
      setsid "$REAL" --models-preset "$T/p.ini" --host 127.0.0.1 --port "$port" > "$T/router.log" 2>&1 ) &
  echo $! >> "$T/pids"
  i=0; while [ "$i" -lt 120 ] && ! curl -sf "http://127.0.0.1:$port/health" >/dev/null; do sleep 1; i=$((i + 1)); done
  rt=$(curl -s "http://127.0.0.1:$port/tools" | python3 -c 'import json,sys; print(",".join(sorted(t["tool"] for t in json.load(sys.stdin))))' 2>/dev/null || true)
  case ",$rt," in *,get_info,*) ok "router lists its tools ($rt)" ;; *) bad "router tools: '$rt'" ;; esac
  curl -s "http://127.0.0.1:$port/models/load" -H 'Content-Type: application/json' -d '{"model":"t"}' >/dev/null
  i=0; while [ "$i" -lt 300 ] && ! curl -s "http://127.0.0.1:$port/models" | grep -q '"loaded"'; do sleep 1; i=$((i + 1)); done
  cp=$(curl -s "http://127.0.0.1:$port/models" | python3 -c '
import json,sys
a=[m for m in json.load(sys.stdin)["data"] if m["id"]=="t"][0]["status"]["args"]; print(a[a.index("--port")+1])' 2>/dev/null || true)
  if [ -z "$cp" ]; then bad "child did not start: $(tail -n 3 "$T/router.log")"
  else
    code=$(curl -s -o "$T/ct" -w '%{http_code}' "http://127.0.0.1:$cp/tools")
    if [ "$code" != 200 ]; then ok "child /tools: HTTP $code $(head -c 80 "$T/ct") (zero tools)"
    else n=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$T/ct"); [ "$n" = 0 ] && ok "child /tools: empty list" || bad "child exposes $n tool(s): $(head -c 200 "$T/ct")"; fi
    cpid=$(ss -ltnpH "sport = :$cp" 2>/dev/null | grep -o 'pid=[0-9]*' | head -n 1 | cut -d= -f2)
    if [ -n "$cpid" ] && [ -r "/proc/$cpid/environ" ]; then
      if tr '\0' '\n' < "/proc/$cpid/environ" | grep -qE '^LLAMA_ARG_(TOOLS|MCP|AGENT|UI_MCP)'; then bad "child environment carries tool/MCP settings"
      else ok "child environment has no LLAMA_ARG_TOOLS* / MCP / agent"; fi
    fi
    curl -s "http://127.0.0.1:$cp/apply-template" -H 'Content-Type: application/json' \
      -d '{"messages":[{"role":"user","content":"hi"}]}' > "$T/tpl.json"
    if grep -q '"prompt"' "$T/tpl.json" && ! grep -q get_info "$T/tpl.json"; then ok "chat without tools: no get_info in the child prompt"
    else bad "child prompt: $(head -c 300 "$T/tpl.json")"; fi
  fi
fi
[ "$fails" = 0 ] && echo "all child-no-tools tests passed" || { echo "$fails failure(s)"; exit 1; }
