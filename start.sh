#!/usr/bin/env bash
# Click-and-go launcher (Linux, Android/Termux; macOS: start.command).
# 1. llama.cpp: the official release binary pinned in config/llama-release.json
#    (sha256-checked); if none fits this machine, build from source when a compiler exists.
# 2. models: the default set from config/models-manifest.json (sha256-checked).
# 3. scripts/serve.sh: router with tools, API key, effective preset.
# 4. opens the built-in web UI (its agent uses the server tools; it asks before each tool).
# Ctrl-C stops everything. Settings: PORT, VARIANT=cpu|vulkan|cuda-12|cuda-13,
# NO_BROWSER=1, BUILD=1 (always build), COPY_KEY=1 (API key to the clipboard), plus
# everything scripts/serve.sh reads (PROFILE=lowram, MODELS_MAX, TOOLS, ...).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
export PORT="${PORT:-9931}"
say() { echo "start: $*" >&2; }

missing=""
for t in curl tar awk; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || missing="$missing sha256sum"
if [[ -n "$missing" ]]; then
  say "missing tools:$missing"
  if [[ "${PREFIX:-}" == *com.termux* ]]; then say "install them with: pkg install$missing"; fi
  exit 1
fi

# a port anything listens on (another llama-server, a service that never answers HTTP, ...)
# counts as busy: bash connects to it with /dev/tcp (no curl timeout involved). The next
# free port is used; serve.sh prints the address it ends up listening on.
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
if port_busy "$PORT"; then
  p="$PORT"; for i in $(seq 1 20); do p=$((PORT + i)); port_busy "$p" || break; done
  port_busy "$p" && { say "ports $PORT-$p are all in use; set PORT="; exit 1; }
  say "port $PORT is in use, using $p"; export PORT="$p"
fi

# --- 1. llama-server ---------------------------------------------------------
if [[ -n "${LLAMA_SERVER:-}" ]]; then
  say "using LLAMA_SERVER=$LLAMA_SERVER"
elif [[ "${BUILD:-0}" != 1 ]] && LLAMA_SERVER="$(scripts/fetch-llama.sh --variant "${VARIANT:-cpu}")"; then
  :
else
  say "no usable release binary; building from source (needs git, cmake and a C++ compiler)"
  case "$(uname -s)" in
    Darwin) script=scripts/build-macos.sh ;;
    *) if [[ "${PREFIX:-}" == *com.termux* ]]; then script=scripts/build-termux.sh; else script=scripts/build-linux.sh; fi ;;
  esac
  command -v cmake >/dev/null 2>&1 || { say "cmake not found: install cmake and a C++ compiler, or use a platform listed in config/llama-release.json"; exit 1; }
  [[ -f llama.cpp/CMakeLists.txt ]] || git submodule update --init llama.cpp
  "$script"
  LLAMA_SERVER="$(ls -d "$ROOT"/build-*/bin/llama-server 2>/dev/null | head -1)"
  [[ -x "$LLAMA_SERVER" ]] || { say "build finished but llama-server was not found"; exit 1; }
fi
export LLAMA_SERVER

# --- 2. models -----------------------------------------------------------------
scripts/fetch-models.sh

# --- 4. open the web UI once the server answers ------------------------------------
# $1 = PID of this script, which becomes serve.sh with exec: stop waiting when it is gone.
# The key goes to curl on stdin (--config -), never on a command line other users can see.
open_ui() {
  local parent="$1" url="http://127.0.0.1:$PORT/?model=coder" key="" i ready=0
  for i in $(seq 1 600); do
    kill -0 "$parent" 2>/dev/null || return 0
    [[ -s .secrets/api-keys ]] && key="$(grep -v -e '^#' -e '^[[:space:]]*$' .secrets/api-keys | head -1)"
    if [[ -n "$key" ]] && printf 'header = "Authorization: Bearer %s"\n' "$key" |
         curl -sf -o /dev/null --max-time 2 --config - "http://127.0.0.1:$PORT/models"; then ready=1; break; fi
    sleep 1
  done
  [[ "$ready" == 1 ]] || return 0
  local copied=""
  if [[ "${COPY_KEY:-0}" == 1 ]]; then   # opt-in: clipboard managers keep a history
    if command -v pbcopy >/dev/null 2>&1; then printf %s "$key" | pbcopy && copied=1
    elif command -v termux-clipboard-set >/dev/null 2>&1; then printf %s "$key" | termux-clipboard-set && copied=1
    elif [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-copy >/dev/null 2>&1; then printf %s "$key" | wl-copy && copied=1
    elif [[ -n "${DISPLAY:-}" ]] && command -v xclip >/dev/null 2>&1; then printf %s "$key" | xclip -selection clipboard && copied=1
    fi
  fi
  {
    echo
    echo "  Web UI:  $url"
    echo "  API key: $key${copied:+   (copied to the clipboard)}"
    echo "           (stored in $ROOT/.secrets/api-keys)"
    echo "  The first time, the page shows \"Enter API Key\": paste the key there; the browser keeps it."
    echo "  Files the agent creates go to: ${WORKDIR:-$ROOT/workspace}"
    echo "  Stop with Ctrl-C."
    echo
  } >&2
  [[ "${NO_BROWSER:-0}" == 1 ]] && return 0
  if [[ "$(uname -s)" == Darwin ]]; then open "$url"
  elif command -v termux-open-url >/dev/null 2>&1; then termux-open-url "$url"
  elif [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 &
  else say "open $url in a browser"; fi
}
open_ui "$$" &

# --- 3. server (exec: Ctrl-C and kill reach serve.sh, which shuts down cleanly) ---------
exec scripts/serve.sh
