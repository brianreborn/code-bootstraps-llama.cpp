#!/usr/bin/env bash
# code-bootstraps-llama.cpp: start llama-server in router mode with the
# built-in tools, an optional tools isolate, MCP servers and an API key.
#
# Everything is configured through environment variables (defaults below).
# Extra arguments are passed to llama-server, except security-relevant ones (see below).
# Tuned for CPU-only 4-8 GB machines (Linux, Android/Termux, macOS).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
abspath() { case "$1" in /*) echo "$1" ;; *) echo "$ROOT/$1" ;; esac; }   # relative paths are relative to the repository

HOST="${HOST:-127.0.0.1}"                       # loopback only by default
PORT="${PORT:-9931}"                            # upstream's upcoming default port
MODELS_DIR="${MODELS_DIR:-$ROOT/models}"        # one subdirectory per role
MODELS_PRESET="${MODELS_PRESET:-$ROOT/config/models-preset.ini}"
PROFILE="${PROFILE:-auto}"                      # auto | default | lowram (auto: lowram on Android/Termux or < 6 GB RAM)
MODELS_MAX="${MODELS_MAX:-}"                    # models kept loaded at once (LRU); default 2, lowram 1
API_KEY_FILE="${API_KEY_FILE:-$ROOT/.secrets/api-keys}"
MCP_CONFIG="${MCP_CONFIG-$ROOT/config/mcp-servers.json}"   # set to "" to disable MCP
TOOLS="${TOOLS-read_file,file_glob_search,grep_search,exec_shell_command,write_file,edit_file,get_info}"
# TOOLS_RUNTIME: auto | host | podman:<image> | docker:<image> | podman-container:<id> | docker-container:<id> | ssh:<target>
TOOLS_RUNTIME="${TOOLS_RUNTIME:-auto}"
# python:3.12-slim multi-arch index, pinned by digest (2026-10-03); override to update
TOOLS_IMAGE="${TOOLS_IMAGE:-docker.io/library/python:3.12-slim@sha256:dddfd7e07f9d15aeeca61529320492139d21cac7f0070c00609243e51e4e0016}"
WORKDIR="${WORKDIR:-$ROOT/workspace}"           # project the agent may modify (mounted at /work in a container)
THREADS="${THREADS:-auto}"                      # generation threads: auto = physical cores (big cores on big.LITTLE)
THREADS_BATCH="${THREADS_BATCH:-auto}"          # prompt/batch threads: auto = logical CPUs (big cores on big.LITTLE)
GPU_LAYERS="${GPU_LAYERS:-auto}"                # -ngl: auto (with --fit on) offloads what fits to a usable GPU, else CPU
REPACK="${REPACK:-on}"                          # on = upstream default; off saves RAM on tight devices
LOAD_MODE="${LOAD_MODE:-auto}"                  # auto = mmap; mlock / mmap+mlock pin the model in RAM (needs RLIMIT_MEMLOCK)
# non-English users, see README "Languages":
#   LOCALE        auto (system locale) | en | ja | es | zh | ...
#   LANGUAGE_MODE native (default) | swap | interpret | off
#     native:    no extra or different model; the coder and general models work in the
#                user's language directly (agent.py asks for replies in that language)
#     swap:      replace the general role (and the coder with SWAP_CODER=1, not recommended)
#                by the language-native model of a [locale.<lang>.<role>] preset section
#     interpret: opt-in only: register the "language" slot (HY-MT1.5-1.8B, license NOT
#                valid in the EU/UK/South Korea); agent.py translates at the edges
#     English locales always behave as off.
LOCALE="${LOCALE:-auto}"
LANGUAGE_MODE="${LANGUAGE_MODE:-native}"
SWAP_CODER="${SWAP_CODER:-0}"
LANGUAGE_DIR="${LANGUAGE_DIR:-$ROOT/models-optional/language}"
LOG_FILE="${LOG_FILE:-}"

die() { echo "serve.sh: $*" >&2; exit 1; }
warn() { echo "serve.sh: WARNING: $*" >&2; }

# --- refuse pass-through args that would widen what the model instances can do.
# The router overlays its own CLI flags on EVERY preset (and copies them into the
# unauthenticated-by-default child instances), so tools/MCP/agent/key options must
# only come from this script.
for a in "$@"; do
  case "$a" in
    --tools|--tools=*|--tools-runtime|--tools-runtime=*|-ag|--agent|--no-agent|--mcp-*|\
    --ui-mcp-proxy*|--webui-mcp-proxy*|--no-ui-mcp-proxy|--no-webui-mcp-proxy|--api-key*|--models-preset*)
      die "argument '$a' is not allowed here; use the TOOLS / TOOLS_RUNTIME / MCP_CONFIG / API_KEY_FILE / MODELS_PRESET variables" ;;
  esac
done

# --- binary -----------------------------------------------------------------
BIN="${LLAMA_SERVER:-}"
if [[ -z "$BIN" ]]; then
  # own builds first, then the release binary scripts/fetch-llama.sh verified last
  rel=""; [[ -s "$ROOT/.cache/llama-server.path" ]] && rel="$(cat "$ROOT/.cache/llama-server.path")"
  for b in "$ROOT"/build-*/bin/llama-server "$ROOT"/build/bin/llama-server $rel; do
    [[ -x "$b" ]] && { BIN="$b"; break; }
  done
fi
[[ -n "$BIN" && -x "$BIN" ]] || die "llama-server not found: run scripts/fetch-llama.sh (release binaries) or scripts/build-*.sh, or set LLAMA_SERVER"
BIN="$(abspath "$BIN")"

# --- platform ---------------------------------------------------------------
OS="$(uname -s)"
IS_ANDROID=0
if [[ "$(uname -o 2>/dev/null)" == "Android" || "${PREFIX:-}" == *com.termux* || -n "${ANDROID_ROOT:-}" ]]; then IS_ANDROID=1; fi
mem_total_mb() {
  if [[ "$OS" == "Darwin" ]]; then echo $(( $(sysctl -n hw.memsize) / 1048576 ))
  elif [[ -r /proc/meminfo ]]; then awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo
  else echo 0; fi
}
MEM_MB="$(mem_total_mb)"

# --- CPU topology -----------------------------------------------------------
logical_cpus() {
  if [[ "$OS" == "Darwin" ]]; then sysctl -n hw.logicalcpu
  else nproc 2>/dev/null || getconf _NPROCESSORS_ONLN; fi
}
physical_cores() {   # unique (package, core) pairs; SMT siblings share a core_id
  if [[ "$OS" == "Darwin" ]]; then sysctl -n hw.physicalcpu; return; fi
  local n=0 d
  n=$(for d in /sys/devices/system/cpu/cpu[0-9]*/topology; do
        [[ -r "$d/core_id" ]] && echo "$(cat "$d/physical_package_id" 2>/dev/null || echo 0):$(cat "$d/core_id")"
      done | sort -u | wc -l)
  if [[ "$n" -gt 0 ]]; then echo "$n"; else logical_cpus; fi
}
# big.LITTLE (Android, arm64 Linux): count the "big" cores, i.e. those with at least
# 75% of the highest cpu_capacity (or, if the kernel does not export it, of the highest
# cpuinfo_max_freq). Little cores slow every op down to their pace, so they are left out.
# Prints nothing when the CPU is homogeneous or the sysfs files are unreadable.
big_cores() {
  local f vals
  for f in cpu_capacity cpufreq/cpuinfo_max_freq; do
    vals=$(cat /sys/devices/system/cpu/cpu[0-9]*/"$f" 2>/dev/null) || vals=""
    [[ -n "$vals" ]] || continue
    echo "$vals" | awk '{v[NR]=$1; if ($1>max) max=$1; if (min=="" || $1<min) min=$1}
      END { if (NR < 2 || min == max) exit; n=0; for (i in v) if (v[i] >= 0.75*max) n++; print n }'
    return
  done
}
BIG=""
if [[ "$IS_ANDROID" == 1 || "$(uname -m)" == aarch64 ]]; then BIG="$(big_cores)"; fi
if [[ "$THREADS" == "auto" ]]; then
  if [[ -n "$BIG" ]]; then THREADS="$BIG"; THREADS_SRC="big cores"; else THREADS="$(physical_cores)"; THREADS_SRC="physical cores"; fi
else THREADS_SRC="THREADS"; fi
if [[ "$THREADS_BATCH" == "auto" ]]; then
  if [[ -n "$BIG" ]]; then THREADS_BATCH="$BIG"; else THREADS_BATCH="$(logical_cpus)"; fi
fi

# --- profile ----------------------------------------------------------------
if [[ "$PROFILE" == "auto" ]]; then
  if [[ "$IS_ANDROID" == 1 ]] || { [[ "$MEM_MB" -gt 0 ]] && [[ "$MEM_MB" -lt 6144 ]]; }; then PROFILE=lowram; else PROFILE=default; fi
fi
case "$PROFILE" in
  default) MODELS_MAX="${MODELS_MAX:-2}"; OVERLAY="" ;;
  # one model at a time; the coder keeps 2 slots sharing a 16k pool
  lowram)  MODELS_MAX="${MODELS_MAX:-1}"
           OVERLAY="coder.parallel=2 coder.ctx-size=16384 coder.kv-unified-per-slot=16384 general.parallel=1 general.ctx-size=8192 decision.parallel=1 decision.ctx-size=4096 language.parallel=1 language.ctx-size=4096" ;;
  *) die "unknown PROFILE=$PROFILE (auto|default|lowram)" ;;
esac

# --- language -------------------------------------------------------------------
# system locale -> primary language code (ja-JP, ja_JP.UTF-8 -> ja); C/POSIX/unset -> en
system_locale() {
  local l=""
  if [[ "$IS_ANDROID" == 1 ]] && command -v getprop >/dev/null 2>&1; then
    l="$(getprop persist.sys.locale 2>/dev/null || true)"
    [[ -n "$l" ]] || l="$(getprop ro.product.locale 2>/dev/null || true)"
  fi
  if [[ -z "$l" && "$OS" == "Darwin" ]]; then l="$(defaults read -g AppleLocale 2>/dev/null || true)"; fi
  [[ -n "$l" ]] || l="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
  echo "$l"
}
norm_lang() { local l="${1%%.*}"; l="${l%%@*}"; l="${l%%[-_]*}"; l="$(echo "$l" | tr '[:upper:]' '[:lower:]')"
  case "$l" in ""|c|posix) echo en ;; *) echo "$l" ;; esac; }
[[ "$LOCALE" == "auto" ]] && LOCALE_SRC="system: $(system_locale)" || LOCALE_SRC="LOCALE"
[[ "$LOCALE" == "auto" ]] && LANG_CODE="$(norm_lang "$(system_locale)")" || LANG_CODE="$(norm_lang "$LOCALE")"

# model file named by "model = ..." in a [locale.<lang>.<role>] section, if installed
locale_model() {   # $1 = role
  local f
  f="$(awk -v want="locale.$LANG_CODE.$1" '/^\[/ { sec = substr($0, 2, index($0, "]") - 2); next }
        sec == want && /^model[ \t]*=/ { sub(/^model[ \t]*=[ \t]*/, ""); print; exit }' "$MODELS_PRESET")"
  [[ -n "$f" ]] || return 0
  [[ "$f" == /* ]] || f="$ROOT/$f"
  [[ -f "$f" ]] && echo "$f"
  return 0
}
LANG_MODEL=""; SWAP_ROLES=""; MODE="$LANGUAGE_MODE"
if [[ "$LANG_CODE" == "en" || "$MODE" == "off" ]]; then MODE=off
else
  swap_ok=""; [[ -n "$(locale_model general)" ]] && swap_ok=1
  lang_file=""; for g in "$LANGUAGE_DIR"/*.gguf; do [[ -f "$g" ]] && { lang_file="$g"; break; }; done
  case "$MODE" in
    native) ;;
    swap) [[ -n "$swap_ok" ]] || die "LANGUAGE_MODE=swap: no installed model for [locale.$LANG_CODE.general] (scripts/fetch-models.sh --locale $LANG_CODE)" ;;
    interpret) [[ -n "$lang_file" ]] || die "LANGUAGE_MODE=interpret: no .gguf in $LANGUAGE_DIR (scripts/fetch-models.sh --language)" ;;
    *) die "unknown LANGUAGE_MODE=$MODE (native|swap|interpret|off)" ;;
  esac
  if [[ "$MODE" == swap ]]; then
    SWAP_ROLES="general"
    if [[ "$SWAP_CODER" == 1 ]]; then
      if [[ -n "$(locale_model coder)" ]]; then SWAP_ROLES="general coder"
        warn "SWAP_CODER=1: the coder role now uses the locale model; it must emit tool calls (the ja model made 0 in 12 agent runs, see README Languages)"
      else warn "SWAP_CODER=1 but no installed [locale.$LANG_CODE.coder] model; coder unchanged"; fi
    fi
  fi
  [[ "$MODE" == interpret ]] && LANG_MODEL="$lang_file"
fi

# effective preset = config/models-preset.ini with:
#  - the PROFILE overlay applied,
#  - [locale.*] sections removed; for swapped roles their keys (model, sampling) merged into [<role>],
#  - [language] removed unless interpret mode (then its model path added).
# The router loads a model only when a request names it, and only agent.py asks for
# "language", so with the section removed it can never load.
mkdir -p "$ROOT/.cache"
EFFECTIVE_PRESET="$ROOT/.cache/models-preset.effective.ini"
awk -v overlay="$OVERLAY" -v langmodel="$LANG_MODEL" -v lang="$LANG_CODE" -v swap="$SWAP_ROLES" -v root="$ROOT" '
  function secname(line) { return substr(line, 2, index(line, "]") - 2) }
  function keyof(line,   k) { k = line; sub(/[ \t]*=.*/, "", k); return k }
  function valof(line,   v) { v = line; sub(/^[^=]*=[ \t]*/, "", v); return v }
  BEGIN { n = split(overlay, o, " "); for (i = 1; i <= n; i++) { split(o[i], kv, "="); ov[kv[1]] = kv[2]; ord[i] = kv[1] }
          ns = split(swap, sw, " "); for (i = 1; i <= ns; i++) swapped[sw[i]] = 1 }
  # pass 1: collect the keys of [locale.<lang>.<role>] for swapped roles
  FNR == NR { if ($0 ~ /^\[/) { s = secname($0); split(s, p, "."); cur = (p[1] == "locale" && p[2] == lang && (p[3] in swapped)) ? p[3] : "" ; next }
              if (cur != "" && $0 ~ /^[A-Za-z0-9_-]+[ \t]*=/) { k = keyof($0); v = valof($0)
                if (k == "model" && v !~ /^\//) v = root "/" v
                lk[cur "." k] = v; lord[cur, ++lc[cur]] = k }
              next }
  function flush(   i, k) {
    if (sec == "" || skip) return
    for (i = 1; i <= lc[sec]; i++) { k = lord[sec, i]; if (!((sec "." k) in seen)) print k " = " lk[sec "." k] }
    for (i = 1; i <= n; i++) { k = ord[i]; if (index(k, sec ".") == 1 && !(k in seen)) print substr(k, length(sec) + 2) " = " ov[k] }
    if (sec == "language" && langmodel != "") print "model = " langmodel
  }
  /^\[.*\]/ { flush(); sec = secname($0); skip = (sec ~ /^locale\./) || (sec == "language" && langmodel == ""); if (!skip) print; next }
  skip { next }
  /^[A-Za-z0-9_-]+[ \t]*=/ { k = keyof($0); key = sec "." k
    if (key in lk) { print k " = " lk[key]; seen[key] = 1; next }
    if (key in ov) { print k " = " ov[key]; seen[key] = 1; next }
    # path-valued keys: relative to the repository (the server runs in WORKDIR)
    if (k ~ /^(model|mmproj)$|-(file|config|dir|path)$/) { v = valof($0); if (v != "" && v !~ /^\//) { print k " = " root "/" v; next } } }
  { print }
  END { flush() }
' "$MODELS_PRESET" "$MODELS_PRESET" > "$EFFECTIVE_PRESET"
# for scripts/agent.py: what the server was started with
printf '{"locale": "%s", "mode": "%s", "swapped": "%s"}\n' "$LANG_CODE" "$MODE" "$SWAP_ROLES" > "$ROOT/.cache/language.json"

# --- host binding -----------------------------------------------------------
case "$HOST" in
  127.0.0.1|localhost|::1) ;;
  *) warn "HOST=$HOST is not loopback: the tools can read/write files and run commands; keep the API key secret" ;;
esac

# --- API key (generated on first run, never committed: .secrets/ is git-ignored)
mkdir -p "$(dirname "$API_KEY_FILE")"; chmod 700 "$(dirname "$API_KEY_FILE")"
if [[ ! -s "$API_KEY_FILE" ]]; then
  ( umask 077
    { echo "# llama-server API key(s), one per line"; od -An -tx1 -N24 /dev/urandom | tr -d ' \n'; echo; } > "$API_KEY_FILE" )
  echo "serve.sh: generated API key in $API_KEY_FILE" >&2
fi
chmod 600 "$API_KEY_FILE"
API_KEYS="$(grep -v -e '^#' -e '^[[:space:]]*$' "$API_KEY_FILE" | tr -d ' \r' | tr '\n' ',' | sed 's/,$//')"
[[ -n "$API_KEYS" ]] || die "no key in $API_KEY_FILE"

# --- MCP: the example server is a Python script; without Python, run without it
if [[ -n "$MCP_CONFIG" && "$MCP_CONFIG" == "$ROOT/config/mcp-servers.json" ]] && ! command -v python3 >/dev/null 2>&1; then
  warn "python3 not found: MCP servers from $MCP_CONFIG disabled (the built-in tools still work)"
  MCP_CONFIG=""
fi

# --- tools runtime (isolation) ----------------------------------------------
mkdir -p "$WORKDIR"; WORKDIR="$(cd "$WORKDIR" && pwd)"
CONTAINER_ID=""; ENGINE=""
start_container() {   # $1 = podman|docker
  ENGINE="$1"
  CONTAINER_ID="$("$ENGINE" run -d --rm -v "$WORKDIR:/work" -w /work "$TOOLS_IMAGE" sleep infinity)" || return 1
  RUNTIME_ARG="$ENGINE-container:$CONTAINER_ID"
  TOOL_CWD="/work"
}
cleanup() { if [[ -n "$CONTAINER_ID" ]]; then "$ENGINE" rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT

RUNTIME_ARG=""; TOOL_CWD="$WORKDIR"
case "$TOOLS_RUNTIME" in
  auto)
    if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1 && start_container podman; then :
    elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && start_container docker; then :
    else
      warn "no working podman/docker: tools run on the HOST with this user's permissions."
      warn "  The model can read, write and execute anything this account can (absolute paths are not confined to $WORKDIR)."
      warn "  Set TOOLS=\"\" to disable tools, or install podman/docker for container isolation."
    fi ;;
  host) warn "TOOLS_RUNTIME=host: tools run on the host with this user's permissions" ;;
  podman:*|docker:*)
    # mount WORKDIR so the agent edits the real project instead of the image's own filesystem
    TOOLS_IMAGE="${TOOLS_RUNTIME#*:}"; start_container "${TOOLS_RUNTIME%%:*}" || die "could not start $TOOLS_RUNTIME" ;;
  *) RUNTIME_ARG="$TOOLS_RUNTIME"; TOOL_CWD="" ;;   # *-container:<id>, ssh:<target>: passed through as is
esac

# --- environment ------------------------------------------------------------
# Only the LLAMA_* variables set below reach llama-server: anything inherited
# (LLAMA_ARG_MCP_SERVERS_JSON, LLAMA_ARG_AGENT, LLAMA_ARG_UI_MCP_PROXY, ...) is cleared,
# because the router and every child instance read them.
while IFS= read -r v; do
  case "$v" in LLAMA_ARG_*|LLAMA_API_KEY) unset "$v" ;; esac
done < <(compgen -e)
# The key goes through the environment (not --api-key-file) so the child instances
# inherit it too: they listen on random 127.0.0.1 ports and now answer 401 without it.
# The router forwards the client's Authorization header to them.
export LLAMA_API_KEY="$API_KEYS"
# Tools, tools runtime and MCP go to the router through the environment, NOT as CLI
# flags (the router copies its CLI flags into every child). config/models-preset.ini
# overrides them for the children (tools = get_info, empty MCP config).
[[ -n "$TOOLS" ]]        && export LLAMA_ARG_TOOLS="$TOOLS"
[[ -n "$RUNTIME_ARG" ]]  && export LLAMA_ARG_TOOLS_RUNTIME="$RUNTIME_ARG"
if [[ -n "$MCP_CONFIG" ]]; then
  # @ROOT@ in the MCP config = this repository (the server itself runs in WORKDIR)
  root_json="$(printf '%s' "$ROOT" | sed -e 's/[\\"]/\\&/g' -e 's/[\\|&]/\\&/g')"
  sed "s|@ROOT@|$root_json|g" "$(abspath "$MCP_CONFIG")" > "$ROOT/.cache/mcp-servers.effective.json"
  export LLAMA_ARG_MCP_SERVERS_CONFIG="$ROOT/.cache/mcp-servers.effective.json"
fi

# --- arguments --------------------------------------------------------------
args=(
  --host "$HOST" --port "$PORT"
  --models-dir "$(abspath "$MODELS_DIR")"
  --models-preset "$EFFECTIVE_PRESET"
  --models-max "$MODELS_MAX"
)
# hardware: these CLI flags are copied by the router into every model instance
args+=(--threads "$THREADS" --threads-batch "$THREADS_BATCH")
args+=(--n-gpu-layers "$GPU_LAYERS" --fit on)
args+=(--load-mode "$LOAD_MODE")
[[ "$REPACK" == "off" ]] && args+=(--no-repack)
[[ -n "$LOG_FILE" ]]     && args+=(--log-file "$(abspath "$LOG_FILE")")

echo "serve.sh: $BIN ${args[*]} $*" >&2
echo "serve.sh: env LLAMA_API_KEY=<from $API_KEY_FILE> LLAMA_ARG_TOOLS=${LLAMA_ARG_TOOLS:-} LLAMA_ARG_TOOLS_RUNTIME=${LLAMA_ARG_TOOLS_RUNTIME:-} LLAMA_ARG_MCP_SERVERS_CONFIG=${LLAMA_ARG_MCP_SERVERS_CONFIG:-}" >&2
echo "serve.sh: profile=$PROFILE (RAM ${MEM_MB} MB, android=$IS_ANDROID) models-max=$MODELS_MAX threads=$THREADS ($THREADS_SRC) threads-batch=$THREADS_BATCH gpu-layers=$GPU_LAYERS repack=$REPACK load-mode=$LOAD_MODE" >&2
echo "serve.sh: language: locale=$LANG_CODE ($LOCALE_SRC) mode=$MODE${SWAP_ROLES:+ swapped=[$SWAP_ROLES]}${LANG_MODEL:+ language-slot=$LANG_MODEL}" >&2
echo "serve.sh: tools cwd for clients (x-tool-cwd): ${TOOL_CWD:-<runtime default>}" >&2

# Start the server in its own process group (job control on), so a terminal Ctrl-C
# reaches only this script, which forwards exactly one signal. Two SIGINTs would make
# llama-server skip its clean shutdown.
# The server runs in WORKDIR: with the host runtime that is the default tool directory
# the web UI and agent.py start from (not this repository).
set -m
( cd "$WORKDIR" && exec "$BIN" "${args[@]}" "$@" ) &
SERVER_PID=$!
set +m
forward() { trap '' INT TERM; kill "-$1" "$SERVER_PID" 2>/dev/null || true; }
trap 'forward INT' INT
trap 'forward TERM' TERM
status=0
while :; do
  wait "$SERVER_PID" && status=0 || status=$?
  kill -0 "$SERVER_PID" 2>/dev/null || break   # wait returns early when a trap fires
done
exit "$status"
