#!/usr/bin/env bash
# Click-and-go launcher (Linux, Android/Termux; macOS: start.command).
# 1. llama.cpp: the official release binary pinned in config/llama-release.json
#    (sha256-checked); if none fits this machine, build from source when a compiler exists.
# 2. models: the default set from config/models-manifest.json (sha256-checked).
# 3. scripts/serve.sh: router with tools, API key, effective preset.
# 4. opens the built-in web UI once serve.sh reports the server ready (its agent uses the server tools).
# Ctrl-C or closing the terminal stops everything. Settings: PORT, VARIANT=cpu|vulkan|cuda-12|cuda-13,
# NO_BROWSER=1, BUILD=1 (always build), COPY_KEY=1 (API key to the clipboard), plus
# everything scripts/serve.sh reads (PROFILE=lowram, MODELS_MAX, TOOLS, ...). Arguments go to
# serve.sh, i.e. to llama-server for every role (e.g. --ctx-size 8192; model flags are refused).
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

# --- 1. llama-server ---------------------------------------------------------
if [[ -n "${LLAMA_SERVER:-}" ]]; then
  say "using LLAMA_SERVER=$LLAMA_SERVER"
elif [[ "${BUILD:-0}" != 1 ]] && LLAMA_SERVER="$(scripts/fetch-llama.sh --variant "${VARIANT:-cpu}")"; then
  :
elif rc=$?; [[ "${BUILD:-0}" != 1 && "$rc" != 3 ]]; then
  # 3 = no release binary for this machine (or it does not run here); anything else is a
  # failed download or checksum, which a source build would not fix
  say "downloading llama.cpp failed (fetch-llama.sh exit $rc): check the internet connection and run start.sh again"
  exit 1
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
rc=0; scripts/fetch-models.sh || rc=$?
if [[ "$rc" == 6 || "$rc" == 7 ]]; then   # curl: could not resolve / connect
  say "cannot reach huggingface.co (offline, or a firewall/proxy blocks it): connect to the internet and run start.sh again; finished files are kept, a partial download resumes"
  exit 1
elif [[ "$rc" != 0 ]]; then exit "$rc"; fi

# a port anything listens on (another llama-server, a service that never answers HTTP, ...)
# counts as busy: only "connection refused" (curl exit 7) means free. The next free port is
# used; serve.sh prints the address it ends up listening on. Checked after the downloads,
# right before the server starts, so a port taken meanwhile is noticed too.
port_busy() {
  local rc=0; curl -s --max-time 1 "telnet://127.0.0.1:$1" </dev/null >/dev/null 2>&1 || rc=$?
  if [[ "$rc" == 1 ]]; then (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; return; fi   # a curl built without telnet
  [[ "$rc" != 7 ]]
}
if port_busy "$PORT"; then
  p="$PORT"; for i in $(seq 1 20); do p=$((PORT + i)); port_busy "$p" || break; done
  port_busy "$p" && { say "ports $PORT-$p are all in use; set PORT="; exit 1; }
  say "port $PORT is in use, using $p"; export PORT="$p"
fi

# --- 4. open the web UI once serve.sh reports it ready ---------------------------------
# $1 = PID of this script, which becomes serve.sh with exec: stop waiting when it is gone.
# serve.sh writes .cache/serve.ready ("<port> <pid>") once its own server answers on the port.
open_ui() {
  local parent="$1" port="" pid="" key="" i ready=0
  for i in $(seq 1 1200); do
    kill -0 "$parent" 2>/dev/null || return 0
    if [[ -s .cache/serve.ready ]]; then
      read -r port pid < .cache/serve.ready || true
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then ready=1; break; fi
    fi
    sleep 0.5
  done
  [[ "$ready" == 1 ]] || return 0
  local url="http://127.0.0.1:$port/?model=coder"
  key="$(grep -v -e '^#' -e '^[[:space:]]*$' .secrets/api-keys 2>/dev/null | head -1)"
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
    echo "  The first time, the page says \"Server Connection Error / Access denied\": that is expected."
    echo "  Click \"Enter API Key\", paste the key above and confirm; the browser keeps it."
    echo "  Files the agent creates go to: ${WORKDIR:-$ROOT/workspace}"
    echo "  Stop with Ctrl-C or by closing this terminal."
    echo
  } >&2
  [[ "${NO_BROWSER:-0}" == 1 ]] && return 0
  if [[ "$(uname -s)" == Darwin ]]; then open "$url"
  elif command -v termux-open-url >/dev/null 2>&1; then termux-open-url "$url"
  elif [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 &
  else say "open $url in a browser"; fi
}
rm -f .cache/serve.ready
open_ui "$$" &

# --- 3. server (exec: Ctrl-C and kill reach serve.sh, which shuts down cleanly) ---------
exec scripts/serve.sh "$@"
