#!/usr/bin/env bash
# code-bootstraps-llama.cpp: start llama-server in router mode with the
# built-in tools, an optional tools isolate, MCP servers and an API key.
#
# Everything is configured through environment variables (defaults below).
# DRAFT: tuned for CPU-only 4-8 GB machines (Linux, Termux, macOS).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

HOST="${HOST:-127.0.0.1}"                       # loopback only by default
PORT="${PORT:-9931}"                            # upstream's upcoming default port
MODELS_DIR="${MODELS_DIR:-$ROOT/models}"        # one subdirectory per role
MODELS_PRESET="${MODELS_PRESET:-$ROOT/config/models-preset.ini}"
MODELS_MAX="${MODELS_MAX:-2}"                   # models kept loaded at once (LRU eviction)
API_KEY_FILE="${API_KEY_FILE:-$ROOT/.secrets/api-keys}"
MCP_CONFIG="${MCP_CONFIG:-$ROOT/config/mcp-servers.json}"   # set to "" to disable MCP
TOOLS="${TOOLS:-read_file,file_glob_search,grep_search,exec_shell_command,write_file,edit_file,get_info}"
# TOOLS_RUNTIME: auto | host | podman:<image> | docker:<image> | podman-container:<id> | docker-container:<id> | ssh:<target>
TOOLS_RUNTIME="${TOOLS_RUNTIME:-auto}"
TOOLS_IMAGE="${TOOLS_IMAGE:-docker.io/library/python:3.12-slim}"
WORKDIR="${WORKDIR:-$ROOT/workspace}"           # project the agent may modify (mounted at /work in a container)
THREADS="${THREADS:-auto}"                      # generation threads: auto = physical cores
THREADS_BATCH="${THREADS_BATCH:-auto}"          # prompt/batch threads: auto = logical CPUs
GPU_LAYERS="${GPU_LAYERS:-auto}"                # -ngl: auto (with --fit on) offloads what fits to a usable GPU, else CPU
REPACK="${REPACK:-on}"                          # on = upstream default (no slowdown measured); off saves RAM on tight devices
LOAD_MODE="${LOAD_MODE:-auto}"                  # auto = mmap; mlock / mmap+mlock pin the model in RAM (needs RLIMIT_MEMLOCK)
LOG_FILE="${LOG_FILE:-}"

die() { echo "serve.sh: $*" >&2; exit 1; }
warn() { echo "serve.sh: WARNING: $*" >&2; }

# --- binary -----------------------------------------------------------------
BIN="${LLAMA_SERVER:-}"
if [[ -z "$BIN" ]]; then
  for b in "$ROOT"/build-*/bin/llama-server "$ROOT"/build/bin/llama-server; do
    [[ -x "$b" ]] && { BIN="$b"; break; }
  done
fi
[[ -n "$BIN" && -x "$BIN" ]] || die "llama-server not found; build first (scripts/build-*.sh) or set LLAMA_SERVER"

# --- CPU topology ------------------------------------------------------------
logical_cpus() {
  if [[ "$(uname -s)" == "Darwin" ]]; then sysctl -n hw.logicalcpu
  else nproc 2>/dev/null || getconf _NPROCESSORS_ONLN; fi
}
physical_cores() {   # unique (package, core) pairs; SMT siblings share a core_id
  if [[ "$(uname -s)" == "Darwin" ]]; then sysctl -n hw.physicalcpu; return; fi
  local n=0 d
  n=$(for d in /sys/devices/system/cpu/cpu[0-9]*/topology; do
        [[ -r "$d/core_id" ]] && echo "$(cat "$d/physical_package_id" 2>/dev/null || echo 0):$(cat "$d/core_id")"
      done | sort -u | wc -l)
  if [[ "$n" -gt 0 ]]; then echo "$n"; else logical_cpus; fi
}
[[ "$THREADS" == "auto" ]] && THREADS="$(physical_cores)"
[[ "$THREADS_BATCH" == "auto" ]] && THREADS_BATCH="$(logical_cpus)"

# --- host binding -----------------------------------------------------------
case "$HOST" in
  127.0.0.1|localhost|::1) ;;
  *) warn "HOST=$HOST is not loopback: the tools can read/write files and run commands; keep the API key secret" ;;
esac

# --- API key (generated on first run, never committed: .secrets/ is git-ignored)
if [[ ! -s "$API_KEY_FILE" ]]; then
  mkdir -p "$(dirname "$API_KEY_FILE")"
  ( umask 077
    { echo "# llama-server API key(s), one per line"; od -An -tx1 -N24 /dev/urandom | tr -d ' \n'; echo; } > "$API_KEY_FILE" )
  echo "serve.sh: generated API key in $API_KEY_FILE" >&2
fi

# --- tools runtime (isolation) ----------------------------------------------
mkdir -p "$WORKDIR"
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

# --- arguments --------------------------------------------------------------
args=(
  --host "$HOST" --port "$PORT"
  --api-key-file "$API_KEY_FILE"
  --models-dir "$MODELS_DIR"
  --models-preset "$MODELS_PRESET"
  --models-max "$MODELS_MAX"
)
# Tools, tools runtime and MCP are given to the router through the environment,
# NOT as CLI flags: the router copies its CLI flags into every model instance it
# spawns, and those instances listen on 127.0.0.1 ports WITHOUT the API key
# (the key is a router-only option). config/models-preset.ini overrides these
# for the instances (tools = get_info, empty MCP config), so the real tools are
# only reachable through the authenticated router.
unset LLAMA_ARG_TOOLS LLAMA_ARG_TOOLS_RUNTIME LLAMA_ARG_MCP_SERVERS_CONFIG
[[ -n "$TOOLS" ]]        && export LLAMA_ARG_TOOLS="$TOOLS"
[[ -n "$RUNTIME_ARG" ]]  && export LLAMA_ARG_TOOLS_RUNTIME="$RUNTIME_ARG"
[[ -n "$MCP_CONFIG" ]]   && export LLAMA_ARG_MCP_SERVERS_CONFIG="$MCP_CONFIG"
# hardware: these CLI flags are copied by the router into every model instance
args+=(--threads "$THREADS" --threads-batch "$THREADS_BATCH")
args+=(--n-gpu-layers "$GPU_LAYERS" --fit on)
args+=(--load-mode "$LOAD_MODE")
[[ "$REPACK" == "off" ]] && args+=(--no-repack)
[[ -n "$LOG_FILE" ]]     && args+=(--log-file "$LOG_FILE")

echo "serve.sh: $BIN ${args[*]}" >&2
echo "serve.sh: env LLAMA_ARG_TOOLS=${LLAMA_ARG_TOOLS:-} LLAMA_ARG_TOOLS_RUNTIME=${LLAMA_ARG_TOOLS_RUNTIME:-} LLAMA_ARG_MCP_SERVERS_CONFIG=${LLAMA_ARG_MCP_SERVERS_CONFIG:-}" >&2
echo "serve.sh: cpu: threads=$THREADS (physical cores) threads-batch=$THREADS_BATCH (logical CPUs), gpu-layers=$GPU_LAYERS, repack=$REPACK, load-mode=$LOAD_MODE" >&2
echo "serve.sh: tools cwd for clients (x-tool-cwd): ${TOOL_CWD:-<runtime default>}" >&2
"$BIN" "${args[@]}" "$@" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; cleanup' INT TERM
wait "$SERVER_PID"
