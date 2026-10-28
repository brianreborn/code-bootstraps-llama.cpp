#!/bin/sh
# REASONING overlay: empty and off leave the preset; on and auto set general and coder only.
# Uses a stub llama-server that exits at once, so no model is loaded.
#   sh tests/test_reasoning.sh
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
  cp -R "$ROOT/scripts" "$ROOT/config" "$ROOT/lib" "$d/"
  awk -v match_kv="pick=default" -v fields="role file sha256 chat_template_sha256" -f "$ROOT/scripts/lib/manifest.awk" \
    "$ROOT/config/models-manifest.json" > "$d/.cache/default-rows"
  while IFS=$tab read -r role f sha ctsha; do
    mkdir -p "$d/models/$role"
    echo "placeholder $f" > "$d/models/$role/$f"
    fingerprint "$d/models/$role/$f" >> "$d/.cache/verified/$sha"
    if [ "$ctsha" != "-" ]; then   # the repo chat template serve.sh requires (familia #51)
      echo "placeholder template" > "$d/models/$role/${f%.gguf}.chat-template.jinja"
      fingerprint "$d/models/$role/${f%.gguf}.chat-template.jinja" >> "$d/.cache/verified/$ctsha"
    fi
  done < "$d/.cache/default-rows"
}
place() {
  sha=$1
  path=$2
  d=$3
  mkdir -p "$(dirname "$path")" "$d/.cache/verified"
  echo "placeholder $sha" > "$path"
  fingerprint "$path" >> "$d/.cache/verified/$sha"
}

nkey() {
  awk -v sec="$2" -v key="$3" '
    /^\[/ { s = substr($0, 2, index($0, "]") - 2); next }
    s == sec && $0 ~ "^" key "[ \t]*=" { n++ }
    END { print n + 0 }
  ' "$1"
}
val() {
  awk -v sec="$2" -v key="$3" '
    /^\[/ { s = substr($0, 2, index($0, "]") - 2); next }
    s == sec && $0 ~ "^" key "[ \t]*=" {
      sub(/^[^=]*=[ \t]*/, ""); sub(/[ \t\r]+$/, ""); print; exit
    }
  ' "$1"
}

src=$ROOT/config/models-preset.ini
if [ "$(nkey "$src" coder reasoning)" = 1 ] && [ "$(val "$src" coder reasoning)" = off ] \
  && [ "$(nkey "$src" language reasoning)" = 1 ] && [ "$(val "$src" language reasoning)" = off ] \
  && [ "$(nkey "$src" locale.ja.general reasoning)" = 1 ] && [ "$(val "$src" locale.ja.general reasoning)" = off ] \
  && [ "$(nkey "$src" locale.ja.coder reasoning)" = 1 ] && [ "$(val "$src" locale.ja.coder reasoning)" = off ] \
  && [ "$(nkey "$src" general reasoning)" = 1 ] && [ "$(val "$src" general reasoning)" = off ] && [ "$(nkey "$src" decision reasoning)" = 0 ]; then
  ok "committed preset keeps reasoning off (general, coder, language, locale; a per-role toggle)"
else
  bad "committed preset reasoning keys changed"
fi

cat > "$T/launch.py" <<'PY'
import os, signal, subprocess, sys, time
d, port, binpath, out = sys.argv[1:5]
env = os.environ.copy()
env.pop("REASONING", None)
env.update({
    "PORT": port,
    "PROFILE": "lowram",
    "TOOLS_RUNTIME": "host",
    "TOOLS": "",
    "MCP_CONFIG": "",
    "LOCALE": "en",
    "LANGUAGE_MODE": "off",
    "LLAMA_SERVER": binpath,
    # Sandbox is the store, so a real ~/.local/share/gguf is not read.
    "GGUF_HOME": d,
})
for item in sys.argv[5:]:
    k, v = item.split("=", 1)
    env[k] = v
log = open(out, "w")
p = subprocess.Popen(["sh", "scripts/serve.sh"], cwd=d, env=env, stdout=log, stderr=subprocess.STDOUT,
                     start_new_session=True)
with open(os.environ["PIDFILE"], "a") as f:
    f.write(str(p.pid) + "\n")
ini = os.path.join(d, ".cache", "models-preset.effective.ini")
deadline = time.time() + 40
while time.time() < deadline:
    if p.poll() is not None:
        break
    if os.path.isfile(ini) and os.path.getsize(ini) > 0:
        # preset is written before the server is exec'd; let the stub exit too
        time.sleep(0.2)
        if p.poll() is not None:
            break
    time.sleep(0.05)
if p.poll() is None:
    try:
        os.killpg(p.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.wait(timeout=5)
else:
    try:
        os.killpg(p.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
sys.exit(0)
PY

launch() {
  name=$1
  shift
  d=$T/$name
  rm -rf "$d"
  sandbox "$d"
  if [ "${1:-}" = --no-template ]; then
    shift
    rm -f "$d"/models/*/*.chat-template.jinja
  fi
  if [ "${1:-}" = --language ]; then
    shift
    place 4383ac0c3c8e476de98ff979c2a3f069f8c4fb385e7860cf2d28da896cc477c7 \
      "$d/models-optional/language/HY-MT1.5-1.8B-Q4_K_M.gguf" "$d"
  fi
  if [ "${1:-}" = --locale ]; then
    shift
    place fc3404fe7aa1f9dce8ff88d348308606c73eb6dfbf7c920148fe7a722bf105dc \
      "$d/models-optional/locale/ja/Qwen3.5-0.8B-Japanese-SFT-v2-Q4_K_M.gguf" "$d"
  fi
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  PIDFILE=$T/pids python3 "$T/launch.py" "$d" "$port" "$T/llama-server" "$d/out.txt" "$@"
  printf '%s\n' "$d"
}

expect_off() {
  ini=$1/.cache/models-preset.effective.ini
  name=$2
  if [ ! -f "$ini" ]; then bad "$name: no effective preset: $(tail -n 5 "$1/out.txt")"; return; fi
  if [ "$(nkey "$ini" general reasoning)" = 1 ] && [ "$(val "$ini" general reasoning)" = off ] && [ "$(nkey "$ini" coder reasoning)" = 1 ] \
    && [ "$(val "$ini" coder reasoning)" = off ] && [ "$(nkey "$ini" decision reasoning)" = 0 ] \
    && [ "$(nkey "$ini" language reasoning)" = 0 ] \
    && ! grep -E 'reasoning[ \t]*=[ \t]*(on|auto)' "$ini" >/dev/null; then
    ok "$name: no reasoning overlay"
  else
    bad "$name: preset changed: $(grep reasoning "$ini" || true)"
  fi
}

expect_mode() {
  ini=$1/.cache/models-preset.effective.ini
  name=$2
  mode=$3
  lang_off=$4
  if [ ! -f "$ini" ]; then bad "$name: no effective preset: $(tail -n 8 "$1/out.txt")"; return; fi
  lang_n=$(nkey "$ini" language reasoning)
  lang_v=$(val "$ini" language reasoning)
  if [ "$lang_off" = yes ]; then
    lang_ok=0
    [ "$lang_n" = 1 ] && [ "$lang_v" = off ] && lang_ok=1
  else
    lang_ok=0
    [ "$lang_n" = 0 ] && lang_ok=1
  fi
  if [ "$lang_ok" = 1 ] && [ "$(nkey "$ini" general reasoning)" = 1 ] && [ "$(val "$ini" general reasoning)" = "$mode" ] \
    && [ "$(nkey "$ini" coder reasoning)" = 1 ] && [ "$(val "$ini" coder reasoning)" = "$mode" ] \
    && [ "$(nkey "$ini" decision reasoning)" = 0 ] \
    && [ "$(nkey "$ini" locale.ja.general reasoning)" = 0 ] && [ "$(nkey "$ini" locale.ja.coder reasoning)" = 0 ]; then
    ok "$name: general and coder reasoning=$mode, decision and language stay off"
  else
    bad "$name: got general=$(val "$ini" general reasoning) coder=$(val "$ini" coder reasoning) decision=$(nkey "$ini" decision reasoning) language=$lang_n:$lang_v"
    grep -n reasoning "$ini" || true
  fi
}

d=$(launch unset)
expect_off "$d" "REASONING unset"
d=$(launch off REASONING=off)
expect_off "$d" "REASONING=off"
d=$(launch on REASONING=on)
expect_mode "$d" "REASONING=on" on no
d=$(launch auto REASONING=auto)
expect_mode "$d" "REASONING=auto" auto no
d=$(launch interpret --language REASONING=on LANGUAGE_MODE=interpret LOCALE=ja)
expect_mode "$d" "interpret + REASONING=on" on yes
d=$(launch swap --locale REASONING=on LANGUAGE_MODE=swap LOCALE=ja SWAP_CODER=1)
expect_mode "$d" "swap + REASONING=on" on no
role_mode() {   # dir name general-mode coder-mode
  ini=$1/.cache/models-preset.effective.ini
  if [ -f "$ini" ] && [ "$(nkey "$ini" general reasoning)" = 1 ] && [ "$(val "$ini" general reasoning)" = "$3" ] \
    && [ "$(nkey "$ini" coder reasoning)" = 1 ] && [ "$(val "$ini" coder reasoning)" = "$4" ]; then
    ok "$2: general=$3 coder=$4"
  else
    bad "$2: got general=$(val "$ini" general reasoning) coder=$(val "$ini" coder reasoning) $(tail -n 3 "$1/out.txt")"
  fi
}
d=$(launch gen-only REASONING_GENERAL=on)
role_mode "$d" "REASONING_GENERAL=on" on off
d=$(launch coder-only REASONING_CODER=auto)
role_mode "$d" "REASONING_CODER=auto" off auto
d=$(launch role-wins REASONING=on REASONING_CODER=off)
role_mode "$d" "REASONING=on REASONING_CODER=off" on off
d=$(launch bad-role REASONING_CODER=maybe)
if [ ! -f "$d/.cache/models-preset.effective.ini" ] && grep -q "unknown REASONING=maybe for coder" "$d/out.txt"; then
  ok "REASONING_CODER=maybe is refused"
else
  bad "REASONING_CODER=maybe not refused: $(tail -n 3 "$d/out.txt")"
fi
d=$(launch bad REASONING=yes)
if [ -f "$d/.cache/models-preset.effective.ini" ]; then
  bad "REASONING=yes wrote a preset"
elif grep -q "unknown REASONING" "$d/out.txt"; then
  ok "REASONING=yes is refused"
else
  bad "REASONING=yes: $(tail -n 5 "$d/out.txt")"
fi

# SIZING: both layouts on every host; monolithic is the default.
sz_of() {
  ini=$1/.cache/models-preset.effective.ini
  if [ ! -f "$ini" ]; then echo "MISSING"; return; fi
  printf '%s %s %s\n' "$(cat "$1/.cache/sizing" 2>/dev/null)" "$(val "$ini" coder ctx-size)" "$(val "$ini" coder parallel)"
}
d=$(launch sz-default PROFILE=default SIZING=)
got=$(sz_of "$d")
case "$got" in "monolithic 131072 "*) ok "SIZING unset is monolithic (coder ctx 131072)" ;; *) bad "SIZING unset: got '$got' $(tail -n 5 "$d/out.txt")" ;; esac
d=$(launch sz-dist PROFILE=default SIZING=distributed)
got=$(sz_of "$d")
if [ "$got" = "distributed 32768 4" ]; then ok "SIZING=distributed: coder 32768 tokens, 4 sessions"
else bad "SIZING=distributed: got '$got' $(tail -n 5 "$d/out.txt")"; fi
d=$(launch sz-dist-ctx PROFILE=default SIZING=distributed CODER_CTX=8192)
got=$(sz_of "$d")
if [ "$got" = "distributed 8192 4" ]; then ok "SIZING=distributed accepts CODER_CTX=8192"
else bad "SIZING=distributed CODER_CTX=8192: got '$got' $(tail -n 5 "$d/out.txt")"; fi
d=$(launch sz-mono-ctx PROFILE=default SIZING=monolithic CODER_CTX=8192)
if [ ! -f "$d/.cache/models-preset.effective.ini" ] && grep -q "CODER_CTX" "$d/out.txt"; then ok "SIZING=monolithic refuses CODER_CTX=8192 (min 32768)"
else bad "SIZING=monolithic CODER_CTX=8192 not refused: $(tail -n 3 "$d/out.txt")"; fi
d=$(launch sz-bad SIZING=huge)
if [ ! -f "$d/.cache/models-preset.effective.ini" ] && grep -q "unknown SIZING=huge" "$d/out.txt"; then ok "SIZING=huge is refused"
else bad "SIZING=huge not refused: $(tail -n 3 "$d/out.txt")"; fi

# Android cannot hold mlock. Other hosts keep the preset unless LOAD_MODE is set.
load_of() {
  ini=$1/.cache/models-preset.effective.ini
  if [ ! -f "$ini" ]; then echo "MISSING"; return; fi
  printf '%s %s %s %s\n' "$(val "$ini" general load-mode)" "$(val "$ini" coder load-mode)" \
    "$(nkey "$ini" decision load-mode)" "$(val "$ini" decision load-mode)"
}
d=$(launch linux-lock LOAD_MODE= PREFIX= ANDROID_ROOT=)
got=$(load_of "$d")
if [ "$got" = "mmap+mlock mmap+mlock 0 " ]; then
  ok "Linux LOAD_MODE unset keeps preset mlock on general and coder"
else
  bad "Linux LOAD_MODE unset: got '$got' $(tail -n 5 "$d/out.txt")"
fi
d=$(launch android-mmap LOAD_MODE= PREFIX=/data/data/com.termux/files/usr ANDROID_ROOT=)
got=$(load_of "$d")
ini=$d/.cache/models-preset.effective.ini
if [ "$got" = "mmap mmap 0 " ] && [ -f "$ini" ] && ! grep -q 'mmap+mlock' "$ini"; then
  ok "Android LOAD_MODE unset does not request mlock"
else
  bad "Android LOAD_MODE unset: got '$got' $(tail -n 8 "$d/out.txt")"
fi
d=$(launch android-explicit LOAD_MODE=mmap+mlock PREFIX=/data/data/com.termux/files/usr ANDROID_ROOT=)
got=$(load_of "$d")
if [ "$got" = "mmap+mlock mmap+mlock 1 mmap+mlock" ]; then
  ok "Android LOAD_MODE=mmap+mlock still requests mlock"
else
  bad "Android LOAD_MODE=mmap+mlock: got '$got' $(tail -n 8 "$d/out.txt")"
fi

# familia #51: only a default whose manifest row has chat_template_sha256 gets chat-template-file.
# The LFM3 default (#26) has none, so neither role gets one.
ini="$d/.cache/models-preset.effective.ini"
if cut -f4 "$d/.cache/default-rows" | grep -qv '^-$'; then
  echo "test_reasoning: SKIP chat-template checks (a default now has a repo chat template; update this test)"
elif [ "$(nkey "$ini" general chat-template-file)" = 0 ] && [ "$(nkey "$ini" coder chat-template-file)" = 0 ]; then
  ok "LFM3 default: no repo chat-template-file for general or coder"
else
  bad "chat-template-file: general '$(val "$ini" general chat-template-file)', coder $(nkey "$ini" coder chat-template-file)"
fi

if [ "$fails" -eq 0 ]; then echo "all reasoning overlay tests passed"
else echo "$fails failed"; exit 1; fi
