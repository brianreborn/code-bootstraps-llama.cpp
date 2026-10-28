#!/bin/sh
# End-to-end user journey: behaves like a person on a fresh clone. One command installs and
# starts; nothing is copied or typed by hand. Pass/fail is on what a user sees, not on internals.
#
#   sh tests/e2e_user_journey.sh                 # fresh clone of this branch, build, start, check
#
# Settings (all optional):
#   E2E_REPO      repo to clone (default: this checkout's origin)    E2E_BRANCH (default: current branch)
#   E2E_WORK      work dir (default: a new temp dir, kept on failure)
#   E2E_LLAMA_SERVER  reuse an already built llama-server (default: start.sh builds the pinned
#                 source with patches/, the real first-run path; ~10-30 min)
#   E2E_MODEL_CACHE   dir or .gguf files holding the default chat model (matched by sha256) to
#                 skip its 1.1 GB download; other models always download live (background test)
#   FAMILIA_DIR   familia checkout for the proto-chat step (default: ../familia if present)
#   E2E_READY_TIMEOUT (3600)  E2E_DL_TIMEOUT (1800) seconds
# Isolation: its own GGUF_HOME, XDG_CONFIG_HOME (instance key), ports; your models, keys and
# running servers are not touched. Exit 0 only if every step passed.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REPO=${E2E_REPO:-$(git -C "$HERE" remote get-url origin)}
BRANCH=${E2E_BRANCH:-$(git -C "$HERE" rev-parse --abbrev-ref HEAD)}
W=${E2E_WORK:-$(mktemp -d /tmp/e2e-journey.XXXXXX)}
READY_MAX=${E2E_READY_TIMEOUT:-3600}; DL_MAX=${E2E_DL_TIMEOUT:-1800}
FAM=${FAMILIA_DIR:-$HERE/../familia}
mkdir -p "$W"; R=$W/repo; LOG=$W/start.log; RES=$W/results.txt; : > "$RES"
export GGUF_HOME=$W/gguf XDG_CONFIG_HOME=$W/xdg NO_BROWSER=1 STARTUP_RECOVER=0
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
export PORT=$(free_port) COCKPIT_PORT=$(free_port)
note() { printf '%s\n' "$*" >&2; }
step() { # step ID "what the user expects" pass|fail|skip "detail"
  printf '%s\t%s\t%s\t%s\n' "$1" "$3" "$2" "$4" >> "$RES"; note "[$3] $1 $2${4:+ — $4}"; }
SPID=""
start_app() { ( cd "$R" && exec setsid ./start.sh >> "$LOG" 2>&1 ) & SPID=$!; }
left_procs() { ps -eo pid=,args= | grep -F "$R/" | grep -v grep | grep -vE "e2e_user_journey|fetch-models" ; }
stop_app() { # like Ctrl-C in the terminal: INT to the launcher, then everything it started must go
  [ -n "$SPID" ] || return 0
  kill -INT -- "-$SPID" 2>/dev/null; i=0
  while [ "$i" -lt 60 ] && left_procs >/dev/null; do sleep 1; i=$((i + 1)); done
  STOP_LEFT=$(left_procs | head -n 3)
  [ -n "$STOP_LEFT" ] && { left_procs | awk '{print $1}' | xargs -r kill -KILL 2>/dev/null; }
  SPID=""; }
trap 'stop_app' EXIT INT TERM
wait_log() { # PATTERN SECONDS [FROM_LINE]: 0 when the start output shows PATTERN
  i=0; while [ "$i" -lt "$2" ]; do
    tail -n +"${3:-1}" "$LOG" 2>/dev/null | grep -qE "$1" && return 0
    if [ -n "$SPID" ] && ! kill -0 "$SPID" 2>/dev/null; then tail -n +"${3:-1}" "$LOG" | grep -qE "$1"; return; fi
    sleep 2; i=$((i + 2)); done; return 1; }
port_now() { cut -d' ' -f1 "$R/.cache/serve.ready" 2>/dev/null; }
key_now() { python3 - "$R" "$(port_now)" <<'PY'
import sys; sys.path.insert(0, sys.argv[1] + "/scripts/lib"); from snap import key_file_candidates
for f in key_file_candidates(sys.argv[2]):
    try:
        k = next((l.strip() for l in open(f) if l.strip() and not l.lstrip().startswith("#")), "")
        if k: print(k); break
    except OSError: pass
PY
}
chat() { # MODEL PROMPT -> prints reply (key from the instance key file, as any local client does)
  python3 - "http://127.0.0.1:$(port_now)" "$1" "$2" "$(key_now)" <<'PY'
import json, sys, urllib.request
url, model, prompt, key = sys.argv[1:5]
b = {"model": model, "messages": [{"role": "user", "content": prompt}], "max_tokens": 64, "temperature": 0}
r = urllib.request.Request(url + "/v1/chat/completions", json.dumps(b).encode(),
    {"Content-Type": "application/json", "Authorization": "Bearer " + key})
print(json.load(urllib.request.urlopen(r, timeout=900))["choices"][0]["message"]["content"].strip())
PY
}

note "e2e: work dir $W (log $LOG)"
# 1. fresh clone + one command
if git clone -q --branch "$BRANCH" "$REPO" "$R" 2>>"$W/clone.log"; then :; else step clone "fresh clone of $BRANCH" fail "see $W/clone.log"; cat "$RES"; exit 1; fi
if [ -n "${E2E_LLAMA_SERVER:-}" ]; then export LLAMA_SERVER=$E2E_LLAMA_SERVER
else (cd "$R" && git submodule update --init --depth 1 -q) 2>>"$W/clone.log"; fi
if [ -n "${E2E_MODEL_CACHE:-}" ]; then
  want=$(awk -v match_kv="pick=default role=general" -v fields="file sha256" -f "$R/scripts/lib/manifest.awk" "$R/config/models-manifest.json" | head -n 1)
  for g in $E2E_MODEL_CACHE "$E2E_MODEL_CACHE"/*.gguf; do
    [ -f "$g" ] || continue
    [ "$(sha256sum "$g" | cut -d' ' -f1)" = "${want#*	}" ] || continue
    mkdir -p "$GGUF_HOME/models/general"; ln -sf "$(readlink -f "$g")" "$GGUF_HOME/models/general/${want%%	*}"; note "e2e: default chat model from cache $g"; break
  done
fi
t0=$(date +%s); start_app
if wait_log "serve.sh: listening on http://" "$READY_MAX"; then step install-start "one command (./start.sh) installs and starts, no manual step" pass "ready in $(( $(date +%s) - t0 ))s"
else step install-start "one command (./start.sh) installs and starts" fail "not ready after $(( $(date +%s) - t0 ))s; last: $(grep -v '^  |' "$LOG" | tail -n 2 | tr '\n' ' ')"; cat "$RES"; exit 1; fi
grep -q "^  | " "$LOG" && step live-log "llama-server output shows live while it starts" pass "" || step live-log "llama-server output shows live while it starts" fail "no '  | ' lines"

# 2. chat with the auto key
rep=$(chat general "Reply with one word: PONG" 2>&1); rc=$?
[ "$rc" = 0 ] && [ -n "$rep" ] && step chat "chat reply via the API (key found automatically)" pass "reply: $(printf '%s' "$rep" | head -c 60)" \
  || step chat "chat reply via the API" fail "$(printf '%s' "$rep" | tail -n 1 | head -c 200)"

# 3. coder tool-call round trip through the bundled agent (no URL / key flags)
mkdir -p "$W/ws"; echo "the code word is ZEBRA-4417" > "$W/ws/secret.txt"
out=$(cd "$R" && timeout 900 python3 scripts/agent.py --cwd "$W/ws" --json-log "$W/agent.jsonl" --max-steps 6 \
      "Use the read_file tool to read secret.txt, then answer with the code word it contains." 2>&1); rc=$?
if printf '%s' "$out" | grep -q "ZEBRA-4417"; then step coder-tools "coder reads a file with a tool and answers from it" pass ""
elif grep -q '"tool' "$W/agent.jsonl" 2>/dev/null; then step coder-tools "coder tool-call round trip" fail "a tool ran but the answer lacks the code word: $(printf '%s' "$out" | tail -n 1 | head -c 150)"
else step coder-tools "coder tool-call round trip" fail "no tool call (rc=$rc): $(printf '%s' "$out" | tail -n 2 | tr '\n' ' ' | head -c 200)"; fi

# 4. cockpit: launched by start.sh, live logs, no key prompt
cu=$(grep -o 'cockpit[^:]*: http://[^ ]*' "$LOG" | tail -n 1 | sed 's/.*: //')
if [ -z "$cu" ]; then step cockpit "start.sh launches the cockpit and prints its URL" fail "no cockpit URL in the start output"
else
  page=$(curl -s --max-time 5 "$cu"); logs=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${cu}logs")
  live=$(curl -s -N --max-time 4 "${cu}stream?log=router" | grep -c '^data:')
  api=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${cu}api/models")
  if [ "$logs" = 200 ] && [ "$api" = 200 ] && [ "${live:-0}" -gt 0 ] && ! printf '%s' "$page" | grep -q 'prompt('; then
    step cockpit "cockpit opens with live logs, server status, no key prompt" pass "$cu ($live live lines)"
  else step cockpit "cockpit opens with live logs and no key prompt" fail "logs=$logs api=$api live=$live prompt=$(printf '%s' "$page" | grep -c 'prompt(')"; fi
fi

# 5. router children expose no tools
cp=$(grep -oE 'name=general on port [0-9]+' "$R/.cache/server.log" | tail -n 1 | sed 's/.* //')
if [ -z "$cp" ]; then step child-no-tools "chat model instances have no tools" fail "no general child port in the server log"
else
  tc=$(printf 'header = "Authorization: Bearer %s"\n' "$(key_now)" | curl -s -K - -o "$W/tools.json" -w '%{http_code}' --max-time 5 "http://127.0.0.1:$cp/tools")
  if [ "$tc" = 403 ] || [ "$tc" = 404 ] || { [ "$tc" = 200 ] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if not (d if isinstance(d,list) else d.get("data") or d.get("tools")) else 1)' "$W/tools.json"; }; then
    step child-no-tools "chat model instances have no tools" pass "child :$cp /tools -> HTTP $tc"
  else step child-no-tools "chat model instances have no tools" fail "child :$cp /tools -> HTTP $tc $(head -c 150 "$W/tools.json")"; fi
fi

# 6. background download hot-adds
if grep -q "still downloading" "$LOG"; then
  if wait_log "hot-add: the decision role" "$DL_MAX"; then
    rep=$(chat decision "Say OK" 2>&1) && step hot-add "a model downloaded in the background becomes usable without a restart" pass "decision: $(printf '%s' "$rep" | head -c 40)" \
      || step hot-add "background model usable without restart" fail "hot-add said, but chat failed: $(printf '%s' "$rep" | tail -n 1 | head -c 150)"
  else step hot-add "background download finishes and hot-adds" fail "no hot-add in ${DL_MAX}s; download log: $(tail -c 200 "$R/.cache/fetch-models.log" 2>/dev/null | tr '\r\n' '  ')"; fi
else step hot-add "background download hot-adds" skip "nothing was left to download in the background"; fi

# 7. recovery from the cockpit: change SIZING, retry in place
if [ -n "$cu" ]; then
  from=$(($(wc -l < "$LOG") + 1)); old=$(cat "$R/.cache/serve.ready" 2>/dev/null)
  curl -s --max-time 5 -H 'Content-Type: application/json' -d '{"SIZING":"distributed","ACTION":"retry"}' "${cu}recover" >/dev/null
  if wait_log "sizing=distributed" 120 "$from" && wait_log "serve.sh: listening on http://" "$READY_MAX" "$from" && [ "$(cat "$R/.cache/serve.ready")" != "$old" ] \
     && rep=$(chat general "Reply with one word: OK" 2>&1); then
    step recovery "change a setting in the cockpit and retry without restarting everything" pass "now SIZING=distributed, chat works"
  else step recovery "cockpit change + retry" fail "$(tail -n +"$from" "$LOG" | grep 'serve.sh' | tail -n 2 | tr '\n' ' ' | head -c 200)"; fi
else step recovery "cockpit change + retry" skip "no cockpit"; fi

# 8. restart keeps the same key
k1=$(key_now); p1=$(port_now); stop_app
[ -z "$STOP_LEFT" ] && step stop "Ctrl-C stops llama-server, its children and the cockpit" pass "" \
  || step stop "Ctrl-C stops everything it started" fail "still running after 60s: $(printf '%s' "$STOP_LEFT" | cut -c1-90 | tr '\n' ';')"
from=$(($(wc -l < "$LOG") + 1)); start_app
if wait_log "serve.sh: listening on http://" "$READY_MAX" "$from"; then
  c=$(printf 'header = "Authorization: Bearer %s"\n' "$k1" | curl -s -K - -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$(port_now)/v1/models")
  [ "$c" = 200 ] && step same-key "after a restart, clients keep working with the same key" pass "port $p1 -> $(port_now)" || step same-key "same key after restart" fail "old key -> HTTP $c"
else step same-key "same key after restart" fail "second start not ready"; fi

# 9. familia proto-chat connects
if [ -f "$FAM/scripts/proto_chat.sh" ]; then
  out=$(printf 'Say hello in one word\n\n' | FAMILIA_NO_TTY=1 timeout 900 sh "$FAM/scripts/proto_chat.sh" --url "http://127.0.0.1:$(port_now)" --no-start 2>&1); rc=$?
  if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "endpoint http://127.0.0.1:$(port_now)" && [ "$(printf '%s' "$out" | grep -vc '^proto-chat:')" -gt 0 ]; then
    step proto-chat "familia proto-chat connects and replies (no key or port typed)" pass ""
  else step proto-chat "familia proto-chat connects and replies" fail "rc=$rc: $(printf '%s' "$out" | tail -n 2 | tr '\n' ' ' | head -c 200)"; fi
else step proto-chat "familia proto-chat" skip "no familia checkout at $FAM (set FAMILIA_DIR)"; fi
stop_app

p=$(grep -c '	pass	' "$RES"); f=$(grep -c '	fail	' "$RES"); s=$(grep -c '	skip	' "$RES")
echo; echo "================ USER JOURNEY: $p passed, $f failed, $s skipped ================"
awk -F '\t' '{ printf "  %-5s %-15s %s%s\n", toupper($2), $1, $3, ($4 != "" ? "\n        " $4 : "") }' "$RES"
echo "  details: $LOG, $RES"
[ "$f" = 0 ] && { [ -n "${E2E_WORK:-}" ] || rm -rf "$W"; exit 0; } || exit 1
