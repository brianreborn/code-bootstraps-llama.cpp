#!/bin/sh
# Start llama-server in router mode. Extra arguments go to every role.
# /bin/sh. Settings are environment variables; see the assignments below.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
if [ -f "$ROOT/.cache/panel.env" ]; then . "$ROOT/.cache/panel.env"; fi
abspath() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s\n' "$ROOT/$1" ;; esac; }

HOST=${HOST:-127.0.0.1}
PORT=${PORT:-9931}
# MODELS_DIR, when set, replaces the models root. Unset: the shared GGUF store,
# then a checkout file of the same relative path (gguf_resolve).
MODELS_PRESET=${MODELS_PRESET:-$ROOT/config/models-preset.ini}
MANIFEST=${MANIFEST:-$ROOT/config/models-manifest.json}
PROFILE=${PROFILE:-auto}
MODELS_MAX=${MODELS_MAX:-}
CTX=${CTX:-}
CODER_CTX=${CODER_CTX:-$CTX}
GENERAL_CTX=${GENERAL_CTX:-$CTX}
PARALLEL=${PARALLEL:-}
API_KEY_FILE=${API_KEY_FILE:-$ROOT/.secrets/api-keys}
MCP_CONFIG=${MCP_CONFIG-$ROOT/config/mcp-servers.json}
TOOLS=${TOOLS-auto}
TOOLS_FULL="read_file,file_glob_search,grep_search,exec_shell_command,write_file,edit_file,get_info"
TOOLS_LEAN="read_file,write_file,edit_file,exec_shell_command"
TOOLS_RUNTIME=${TOOLS_RUNTIME:-auto}
TOOLS_IMAGE=${TOOLS_IMAGE:-docker.io/library/python:3.12-slim@sha256:dddfd7e07f9d15aeeca61529320492139d21cac7f0070c00609243e51e4e0016}
WORKDIR=${WORKDIR:-$ROOT/workspace}
THREADS=${THREADS:-auto}
THREADS_BATCH=${THREADS_BATCH:-auto}
GPU_LAYERS=${GPU_LAYERS:-auto}
REPACK=${REPACK:-on}
LOAD_MODE=${LOAD_MODE-}
LOCALE=${LOCALE:-auto}
LANGUAGE_MODE=${LANGUAGE_MODE:-native}
SWAP_CODER=${SWAP_CODER:-0}
# empty or off: leave the preset. on or auto: general and coder only (see the case below).
REASONING=${REASONING:-}
# LANGUAGE_DIR, when set, is the only interpreter directory. Unset: store, then checkout.
LOG_FILE=${LOG_FILE:-$ROOT/.cache/server.log}

. "$ROOT/scripts/lib/common.sh"
. "$ROOT/scripts/lib/i18n.sh"
. "$ROOT/scripts/lib/gpu.sh"
. "$ROOT/scripts/lib/bindhost.sh"

die() { echo "serve.sh: $*" >&2; exit 1; }
warn() { echo "serve.sh: WARNING: $*" >&2; }

ua_dir=$(mktemp -d)
ua_n=0
for a in "$@"; do
  case "$(arg_name "$a")" in
    --tools|--tools-runtime|-ag|--agent|--no-agent|--mcp-*|--ui-mcp-proxy|--webui-mcp-proxy|\
    --no-ui-mcp-proxy|--no-webui-mcp-proxy|--api-key|--api-key-file)
      echo "serve.sh: argument '$a' is not allowed here; use the TOOLS / TOOLS_RUNTIME / MCP_CONFIG / API_KEY_FILE variables" >&2
      exit 1 ;;
    -m|--model|-mu|--model-url|-dr|--docker-repo|-hf|-hfr|--hf-repo|-hff|--hf-file|-hfd|-hfrd|--hf-repo-draft|\
    -hfv|-hfrv|--hf-repo-v|-hffv|--hf-file-v|-mv|--model-vocoder|-md|--model-draft|--spec-draft-model|--spec-draft-hf|\
    --models-dir|--models-preset|--lora|--lora-scaled|--control-vector|--control-vector-scaled|\
    -mm|--mmproj|-mmu|--mmproj-url|-a|--alias|--path|--media-path|--embd-*-default|--fim-*-default|--fim-*-spec|--gpt-oss-*-default|--vision-*-default)
      echo "serve.sh: argument '$a' is not allowed here: the models come from config/models-manifest.json and MODELS_PRESET" >&2
      exit 1 ;;
    --host|--port|--reuse-port)
      echo "serve.sh: argument '$a' is not allowed here; set HOST= / PORT= instead" >&2
      exit 1 ;;
    --rpc)
      echo "serve.sh: argument '$a' is not allowed here" >&2
      exit 1 ;;
    --log-file|--log-disable|-lv|--verbosity|--log-verbosity)
      echo "serve.sh: argument '$a' is not allowed here; serve.sh reads LOG_FILE" >&2
      exit 1 ;;
  esac
  ua_n=$((ua_n + 1))
  printf '%s' "$a" > "$ua_dir/$ua_n"
done
if [ "$ua_n" -gt 0 ]; then
  echo "serve.sh: extra llama-server arguments apply to EVERY role (general, coder, decision)" >&2
fi

BIN=${LLAMA_SERVER:-}
if [ -z "$BIN" ]; then
  rel=""
  [ -s "$ROOT/.cache/llama-server.path" ] && rel=$(cat "$ROOT/.cache/llama-server.path")
  for b in "$ROOT"/build-*/bin/llama-server "$ROOT"/build/bin/llama-server "$rel"; do
    [ -x "$b" ] && { BIN=$b; break; }
  done
fi
[ -n "$BIN" ] && [ -x "$BIN" ] || die "llama-server not found: run scripts/fetch-llama.sh or scripts/build-*.sh, or set LLAMA_SERVER"
BIN=$(abspath "$BIN")

OS=$(uname -s)
IS_ANDROID=0
case "${PREFIX:-}" in *com.termux*) IS_ANDROID=1 ;; esac
[ -n "${ANDROID_ROOT:-}" ] && IS_ANDROID=1

mem_total_mb() {
  if [ "$OS" = Darwin ]; then echo $(( $(sysctl -n hw.memsize) / 1048576 ))
  elif [ -r /proc/meminfo ]; then awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo
  else echo 0; fi
}
mem_avail_mb() {
  if [ -r /proc/meminfo ]; then awk '/^MemAvailable:/ {print int($2/1024); f=1} END {if (!f) print 0}' /proc/meminfo
  else echo 0; fi
}
MEM_MB=${MEM_TOTAL_MB:-$(mem_total_mb)}
AVAIL_MB=${MEM_AVAIL_MB:-$(mem_avail_mb)}
[ "$AVAIL_MB" -gt 0 ] || [ "$MEM_MB" -le 0 ] || AVAIL_MB=$((MEM_MB - 2048))

logical_cpus() {
  if [ "$OS" = Darwin ]; then sysctl -n hw.logicalcpu
  else getconf _NPROCESSORS_ONLN; fi
}
physical_cores() {
  if [ "$OS" = Darwin ]; then
    sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || sysctl -n hw.physicalcpu
    return
  fi
  n=$(
    for d in /sys/devices/system/cpu/cpu[0-9]*/topology; do
      if [ -r "$d/core_id" ]; then
        pkg=$(cat "$d/physical_package_id" 2>/dev/null || echo 0)
        echo "$pkg:$(cat "$d/core_id")"
      fi
    done | sort -u | wc -l
  )
  n=$(printf '%s' "$n" | tr -d ' ')
  if [ "$n" -gt 0 ]; then echo "$n"; else logical_cpus; fi
}

BIG=""
CPU_CAPS=""
if [ "$IS_ANDROID" = 1 ] || [ "$(uname -m)" = aarch64 ]; then
  BIG=$(big_cores || true)
  CPU_CAPS=$(cat /sys/devices/system/cpu/cpu[0-9]*/cpu_capacity 2>/dev/null | tr '\n' ' ' || true)
  if [ -n "$CPU_CAPS" ]; then CPU_CAPS="cpu_capacity $CPU_CAPS"
  else
    CPU_CAPS=$(cat /sys/devices/system/cpu/cpu[0-9]*/cpufreq/cpuinfo_max_freq 2>/dev/null | tr '\n' ' ' || true)
    CPU_CAPS=${CPU_CAPS:+max_freq $CPU_CAPS}
  fi
fi
if [ "$THREADS" = auto ]; then
  if [ -n "$BIG" ]; then THREADS=$BIG; THREADS_SRC="big cores"
  else THREADS=$(physical_cores); THREADS_SRC="physical cores"; fi
else THREADS_SRC=THREADS; fi
if [ "$THREADS_BATCH" = auto ]; then
  if [ -n "$BIG" ]; then THREADS_BATCH=$BIG; else THREADS_BATCH=$(logical_cpus); fi
fi

weak_cpu() {
  cores=${BIG:-$(physical_cores)}
  case "$cores" in
    ''|*[!0-9]*) ;;
    *) [ "$cores" -le 2 ] && { echo "$cores CPU cores"; return 0; } ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64|i?86)
      if [ -r /proc/cpuinfo ]; then
        awk '{for(i=1;i<=NF;i++) if($i=="avx2") found=1} END{exit !found}' /proc/cpuinfo || { echo "no AVX2"; return 0; }
      elif [ "$OS" = Darwin ]; then
        sysctl -n machdep.cpu.leaf7_features 2>/dev/null | tr ' ' '\n' | grep -i '^avx2$' >/dev/null || { echo "no AVX2"; return 0; }
      fi
      ;;
  esac
  return 1
}
WEAK=$(weak_cpu || true)
if [ "$PROFILE" = auto ]; then
  if [ "$MEM_MB" -gt 0 ] && [ "$MEM_MB" -lt 6900 ]; then PROFILE=lowram; PROFILE_WHY="auto: ${MEM_MB} MB RAM"
  elif [ "$AVAIL_MB" -gt 0 ] && [ "$AVAIL_MB" -lt 2048 ]; then PROFILE=lowram; PROFILE_WHY="auto: only ${AVAIL_MB} MB RAM free"
  elif [ "$IS_ANDROID" = 1 ]; then PROFILE=moderate; PROFILE_WHY="auto: Android, ${MEM_MB} MB RAM"
  elif [ "$AVAIL_MB" -gt 0 ] && [ "$AVAIL_MB" -lt 6500 ]; then PROFILE=moderate; PROFILE_WHY="auto: ${AVAIL_MB} MB RAM free"
  else PROFILE=default; PROFILE_WHY="auto: ${MEM_MB} MB RAM, ${AVAIL_MB} MB free"; fi
  if [ -n "$WEAK" ]; then
    warn "$(t "this CPU is slow; operations may take longer")"
  fi
else
  PROFILE_WHY="PROFILE=$PROFILE"
  if [ -n "$WEAK" ] && [ "$PROFILE" != lowram ]; then
    warn "$(t "this CPU is slow for the chosen profile")"
  fi
fi
case "$PROFILE" in
  default) MODELS_MAX=${MODELS_MAX:-2}; RESIDENT=1; OVERLAY="decision.load-on-startup=true" ;;
  moderate)
    MODELS_MAX=${MODELS_MAX:-2}; RESIDENT=1
    OVERLAY="coder.parallel=2 coder.ctx-size=24576 coder.kv-unified-per-slot=16384 general.parallel=1 general.ctx-size=8192 decision.parallel=1 decision.ctx-size=4096 language.parallel=1 language.ctx-size=4096 decision.load-on-startup=true"
    ;;
  lowram)
    MODELS_MAX=${MODELS_MAX:-2}; RESIDENT=0
    OVERLAY="coder.parallel=2 coder.ctx-size=16384 coder.kv-unified-per-slot=16384 general.parallel=1 general.ctx-size=8192 decision.parallel=1 decision.ctx-size=4096 language.parallel=1 language.ctx-size=4096"
    ;;
  *) die "unknown PROFILE=$PROFILE (auto|lowram|moderate|default)" ;;
esac
num_ok() {
  case "$2" in
    ''|*[!0-9]*) die "$1=$2: want a whole number from $3 to $4" ;;
  esac
  if [ "$2" -lt "$3" ] || [ "$2" -gt "$4" ]; then die "$1=$2: want a whole number from $3 to $4"; fi
}
ov_set() {
  ov_o=""
  for ov_x in $OVERLAY; do
    [ "${ov_x%%=*}" = "$1" ] || ov_o="$ov_o$ov_x "
  done
  OVERLAY="${ov_o}$1=$2"
}
num_ok MODELS_MAX "$MODELS_MAX" 1 8
ROUTER_MAX=$((MODELS_MAX + RESIDENT))
TUNED=""
if [ -n "$CODER_CTX" ]; then num_ok CODER_CTX "$CODER_CTX" 2048 262144
  ov_set coder.ctx-size "$CODER_CTX"; ov_set coder.kv-unified-per-slot "$CODER_CTX"; TUNED="$TUNED CODER_CTX=$CODER_CTX"; fi
if [ -n "$GENERAL_CTX" ]; then num_ok GENERAL_CTX "$GENERAL_CTX" 2048 262144
  ov_set general.ctx-size "$GENERAL_CTX"; ov_set general.kv-unified-per-slot "$GENERAL_CTX"; TUNED="$TUNED GENERAL_CTX=$GENERAL_CTX"; fi
if [ -n "$PARALLEL" ]; then num_ok PARALLEL "$PARALLEL" 1 16; ov_set coder.parallel "$PARALLEL"; TUNED="$TUNED PARALLEL=$PARALLEL"; fi
# Language and decision stay as the preset wrote them. A locale section's reasoning = off
# would otherwise win over this overlay when that role is swapped in.
case "$REASONING" in
  ""|off) ;;
  on|auto)
    ov_set general.reasoning "$REASONING"
    ov_set coder.reasoning "$REASONING"
    ;;
  *) die "unknown REASONING=$REASONING (on|off|auto)" ;;
esac
# An untrusted Android app has RLIMIT_MEMLOCK of 64 KB. mmap+mlock fails
# immediately and locks nothing. Keep the preset's mmap+mlock on other hosts.
if [ "$IS_ANDROID" = 1 ] && [ -z "$LOAD_MODE" ]; then
  ov_set general.load-mode mmap
  ov_set coder.load-mode mmap
fi
if [ -n "$LOAD_MODE" ]; then
  ov_set general.load-mode "$LOAD_MODE"
  ov_set coder.load-mode "$LOAD_MODE"
  ov_set decision.load-mode "$LOAD_MODE"
fi
if [ "$TOOLS" = auto ]; then
  TOOLS=full
fi
TOOLS_SET=$TOOLS
case "$TOOLS" in
  full) TOOLS=$TOOLS_FULL ;;
  lean) TOOLS=$TOOLS_LEAN ;;
esac

system_locale() {
  sl=""
  if [ "$IS_ANDROID" = 1 ] && command -v getprop >/dev/null 2>&1; then
    sl=$(getprop persist.sys.locale 2>/dev/null || true)
    [ -n "$sl" ] || sl=$(getprop ro.product.locale 2>/dev/null || true)
  fi
  if [ -z "$sl" ] && [ "$OS" = Darwin ]; then sl=$(defaults read -g AppleLocale 2>/dev/null || true); fi
  [ -n "$sl" ] || sl=${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}
  printf '%s\n' "$sl"
}
if [ "$LOCALE" = auto ]; then
  LOCALE_SRC="system: $(system_locale)"
  LANG_CODE=$(norm_lang "$(system_locale)")
else
  LOCALE_SRC=LOCALE
  LANG_CODE=$(norm_lang "$LOCALE")
fi

MODELS_PRESET=$(abspath "$MODELS_PRESET")
MANIFEST=$(abspath "$MANIFEST")
if [ -n "${MODELS_DIR:-}" ]; then MODELS_DIR=$(abspath "$MODELS_DIR"); fi
if [ -n "${LANGUAGE_DIR:-}" ]; then LANGUAGE_DIR=$(abspath "$LANGUAGE_DIR"); fi
[ -f "$MODELS_PRESET" ] || die "MODELS_PRESET=$MODELS_PRESET not found"
[ -f "$MANIFEST" ] || die "MANIFEST=$MANIFEST not found"
MODE=$LANGUAGE_MODE
case "$MODE" in
  auto) MODE=native ;;
  native|swap|interpret|off) ;;
  *) die "unknown LANGUAGE_MODE=$MODE (native|swap|interpret|off)" ;;
esac

tab=$(printf '\t')
manifest_rows() { awk -v match_kv="$1" -v fields="file sha256 dir" -f "$ROOT/scripts/lib/manifest.awk" "$MANIFEST"; }
manifest_sha() { manifest_rows "" | awk -F '\t' -v f="$1" '$1 == f { print $2; exit }'; }
verify_model() {
  vm_stamp="$ROOT/.cache/verified/$2"
  if [ "${FULL_VERIFY:-0}" != 1 ] && [ -f "$vm_stamp" ] && [ "$(cat "$vm_stamp")" = "$(fingerprint "$1")" ]; then return 0; fi
  echo "serve.sh: checking the sha256 of $1" >&2
  vm_got=$(sha256_of "$1")
  [ "$vm_got" = "$2" ] || die "sha256 mismatch for $1 (got $vm_got, want $2)"
  mkdir -p "$ROOT/.cache/verified"
  fingerprint "$1" > "$vm_stamp"
}
check_model() {
  cm_sha=$(manifest_sha "$(basename "$1")")
  if [ -n "$cm_sha" ]; then verify_model "$1" "$cm_sha"
  else warn "$2: $1 is not in $MANIFEST, so its sha256 is not checked"; fi
}
section_value() {
  sv=$(awk -v want="$1" -v key="$2" '/^\[/ { sec = substr($0, 2, index($0, "]") - 2); next }
        sec == want && $0 ~ ("^" key "[ \t]*=") { sub(/^[^=]*=[ \t]*/, ""); sub(/[ \t\r]+$/, ""); print; exit }' "$MODELS_PRESET")
  if [ -z "$sv" ] || [ "${sv#/}" != "$sv" ]; then printf '%s' "$sv"; return 0; fi
  case "$sv" in
    models/*|models-optional/*|models-inactive/*) gguf_resolve "$sv"; return ;;
  esac
  printf '%s' "$ROOT/$sv"
}
role_model() {
  rm_rows=$(mktemp)
  manifest_rows "role=$1" > "$rm_rows"
  f=$(section_value "$1" model)
  if [ -n "$f" ]; then
    [ -f "$f" ] || die "[$1] model = $f in $MODELS_PRESET: file not found"
    check_model "$f" "[$1] model"
    printf '%s' "$f"
    rm -f "$rm_rows"
    return 0
  fi
  while IFS=$tab read -r f sha dir; do
    [ "$dir" = "-" ] || continue
    rm_path=$(gguf_resolve "models/$1/$f")
    [ -f "$rm_path" ] || continue
    verify_model "$rm_path" "$sha"
    printf '%s' "$rm_path"
    rm -f "$rm_rows"
    return 0
  done < "$rm_rows"
  rm -f "$rm_rows"
  if [ -n "${MODELS_DIR:-}" ]; then
    die "no model for the $1 role in $MODELS_DIR/$1/"
  fi
  die "no model for the $1 role in $(gguf_home)/models/$1/ or $ROOT/models/$1/"
}
M_GENERAL=$(role_model general)
M_CODER=$(role_model coder)
M_DECISION=$(role_model decision)
for r in general coder decision; do
  case "$r" in
    general) m=$M_GENERAL ;;
    coder) m=$M_CODER ;;
    *) m=$M_DECISION ;;
  esac
  for g in "$(dirname "$m")"/*.gguf; do
    [ -f "$g" ] && [ "$g" != "$m" ] && echo "serve.sh: note: $g is ignored (the $r role serves $(basename "$m"))" >&2
  done
done

locale_model() {
  lm=$(section_value "locale.$LANG_CODE.$1" model)
  if [ -n "$lm" ] && [ -f "$lm" ]; then printf '%s' "$lm"; fi
  return 0
}
LANG_MODEL=""
SWAP_ROLES=""
if [ "$LANG_CODE" = en ] || [ "$MODE" = off ]; then MODE=off
else
  case "$MODE" in
    swap)
      [ -n "$(locale_model general)" ] || die "LANGUAGE_MODE=swap: no installed model for [locale.$LANG_CODE.general]"
      SWAP_ROLES=general
      check_model "$(locale_model general)" "[locale.$LANG_CODE.general] model"
      if [ "$SWAP_CODER" = 1 ]; then
        if [ -n "$(locale_model coder)" ]; then
          SWAP_ROLES="general coder"
          check_model "$(locale_model coder)" "[locale.$LANG_CODE.coder] model"
          warn "SWAP_CODER=1: the coder role now uses the locale model; it must emit tool calls"
        else warn "SWAP_CODER=1 but no installed [locale.$LANG_CODE.coder] model; coder unchanged"; fi
      fi
      ;;
    interpret)
      lm_rows=$(mktemp)
      manifest_rows "role=language" > "$lm_rows"
      while IFS=$tab read -r f sha _; do
        if [ -n "${LANGUAGE_DIR:-}" ]; then lm_path=$LANGUAGE_DIR/$f
        else lm_path=$(gguf_resolve "models-optional/language/$f"); fi
        [ -f "$lm_path" ] || continue
        verify_model "$lm_path" "$sha"
        LANG_MODEL=$lm_path
        break
      done < "$lm_rows"
      rm -f "$lm_rows"
      if [ -z "$LANG_MODEL" ]; then
        if [ -n "${LANGUAGE_DIR:-}" ]; then
          die "LANGUAGE_MODE=interpret: no interpreter model in $LANGUAGE_DIR"
        fi
        die "LANGUAGE_MODE=interpret: no interpreter model in $(gguf_home)/models-optional/language or $ROOT/models-optional/language"
      fi
      ;;
  esac
fi

mkdir -p "$ROOT/.cache"
EFFECTIVE_PRESET=$ROOT/.cache/models-preset.effective.ini
LOC_GENERAL=$(section_value "locale.$LANG_CODE.general" model)
LOC_CODER=$(section_value "locale.$LANG_CODE.coder" model)
awk -v overlay="$OVERLAY" -v lang="$LANG_CODE" -v swap="$SWAP_ROLES" -v root="$ROOT" \
    -v loc_general="$LOC_GENERAL" -v loc_coder="$LOC_CODER" \
    -v m_general="$M_GENERAL" -v m_coder="$M_CODER" -v m_decision="$M_DECISION" -v m_language="$LANG_MODEL" '
  function secname(line) { return substr(line, 2, index(line, "]") - 2) }
  function keyof(line,   k) { k = line; sub(/[ \t]*=.*/, "", k); return k }
  function valof(line,   v) { v = line; sub(/^[^=]*=[ \t]*/, "", v); return v }
  BEGIN { n = split(overlay, o, " "); for (i = 1; i <= n; i++) { split(o[i], kv, "="); ov[kv[1]] = kv[2]; ord[i] = kv[1] }
          ns = split(swap, sw, " "); for (i = 1; i <= ns; i++) swapped[sw[i]] = 1
          rm["general"] = m_general; rm["coder"] = m_coder; rm["decision"] = m_decision
          if (m_language != "") rm["language"] = m_language }
  FNR == NR { if ($0 ~ /^\[/) { s = secname($0); split(s, p, "."); cur = (p[1] == "locale" && p[2] == lang && (p[3] in swapped)) ? p[3] : "" ; next }
              if (cur != "" && $0 ~ /^[A-Za-z0-9_-]+[ \t]*=/) { k = keyof($0); v = valof($0)
                if (k == "reasoning" && ((cur ".reasoning") in ov)) next
                if (k == "model" && v !~ /^\//) {
                  if (cur == "general" && loc_general != "") v = loc_general
                  else if (cur == "coder" && loc_coder != "") v = loc_coder
                  else v = root "/" v
                }
                lk[cur "." k] = v; lord[cur, ++lc[cur]] = k }
              next }
  function flush(   i, k) {
    if (sec == "" || skip) return
    for (i = 1; i <= lc[sec]; i++) { k = lord[sec, i]; if (!((sec "." k) in seen)) print k " = " lk[sec "." k] }
    for (i = 1; i <= n; i++) { k = ord[i]; if (index(k, sec ".") == 1 && !(k in seen)) print substr(k, length(sec) + 2) " = " ov[k] }
    if ((sec in rm) && !((sec ".model") in seen) && !((sec ".model") in lk)) print "model = " rm[sec]
    if (sec == "general" && !((sec ".alias") in seen) && !((sec ".alias") in lk)) print "alias = chat"
    if (sec == "decision" && !((sec ".alias") in seen) && !((sec ".alias") in lk)) print "alias = route"
    if (sec == "language" && !((sec ".alias") in seen) && !((sec ".alias") in lk)) print "alias = translate"
  }
  /^\[.*\]/ { flush(); sec = secname($0); had[sec] = 1; skip = (sec ~ /^locale\./) || (sec == "language" && m_language == ""); if (!skip) print; next }
  skip { next }
  /^[A-Za-z0-9_-]+[ \t]*=/ { k = keyof($0); key = sec "." k
    if (key in lk) { print k " = " lk[key]; seen[key] = 1; next }
    if (key in ov) { print k " = " ov[key]; seen[key] = 1; next }
    if (k == "model" && (sec in rm)) { print "model = " rm[sec]; seen[key] = 1; next }
    if (k ~ /^(model|mmproj)$|-(file|config|dir|path)$/) { v = valof($0); if (v != "" && v !~ /^\//) { print k " = " root "/" v; next } } }
  { print }
  END { flush(); split("general coder decision language", rr, " ")
        for (i = 1; i <= 4; i++) if ((rr[i] in rm) && !(rr[i] in had)) {
          print ""; print "[" rr[i] "]"; print "model = " rm[rr[i]]
          if (rr[i] == "general") print "alias = chat"
          if (rr[i] == "decision") print "alias = route"
          if (rr[i] == "language") print "alias = translate"
        } }
' "$MODELS_PRESET" "$MODELS_PRESET" > "$EFFECTIVE_PRESET"
printf '{"locale": "%s", "mode": "%s", "swapped": "%s"}\n' "$LANG_CODE" "$MODE" "$SWAP_ROLES" > "$ROOT/.cache/language.json"

case "$HOST" in
  127.0.0.1|localhost|::1) ;;
  *) warn "$(t "the chosen host is not loopback; keep the API key secret")" ;;
esac

mkdir -p "$(dirname "$API_KEY_FILE")"
chmod 700 "$(dirname "$API_KEY_FILE")"
if [ ! -s "$API_KEY_FILE" ]; then
  ( umask 077
    { echo "# llama-server API key(s), one per line"; od -An -tx1 -N24 /dev/urandom | tr -d ' \n'; echo; } > "$API_KEY_FILE" )
  echo "serve.sh: $(t "generated an API key")" >&2
fi
chmod 600 "$API_KEY_FILE"
API_KEYS=$(grep -v -e '^#' -e '^[[:space:]]*$' "$API_KEY_FILE" | tr -d ' \r' | tr '\n' ',' | sed 's/,$//')
[ -n "$API_KEYS" ] || die "no key in $API_KEY_FILE"

if [ -n "$MCP_CONFIG" ] && [ "$MCP_CONFIG" = "$ROOT/config/mcp-servers.json" ] && ! command -v python3 >/dev/null 2>&1; then
  warn "$(t "python3 is missing; the bundled example MCP server will not run, but MCP stays active for any other configured servers")"
fi

mkdir -p "$WORKDIR"
WORKDIR=$(cd "$WORKDIR" && pwd)
CONTAINER_ID=""
ENGINE=""
je() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
start_container() {
  ENGINE=$1
  userns=""
  if [ "$1" = podman ]; then
    rootless=$("$1" info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)
    case "$rootless" in true|True) userns=--userns=keep-id ;; esac
  fi
  if [ -n "$userns" ]; then
    CONTAINER_ID=$("$ENGINE" run -d --rm "$userns" -v "$WORKDIR:/work" -w /work "$TOOLS_IMAGE" sleep infinity) || return 1
  else
    CONTAINER_ID=$("$ENGINE" run -d --rm -v "$WORKDIR:/work" -w /work "$TOOLS_IMAGE" sleep infinity) || return 1
  fi
  RUNTIME_ARG=$ENGINE-container:$CONTAINER_ID
  TOOL_CWD=/work
  sc_err=$(mktemp)
  if ! ( cd / && "$ENGINE" exec -w /work "$CONTAINER_ID" sh -c 'test -d / && test -d /work && test "$(pwd)" = /work' ) 2>"$sc_err"; then
    echo "serve.sh: $(t "the tools container could not be started")" >&2
    echo "serve.sh: /work is $WORKDIR" >&2
    cat "$sc_err" >&2
    "$ENGINE" exec -w / "$CONTAINER_ID" pwd >&2 || true
    rm -f "$sc_err"
    return 1
  fi
  rm -f "$sc_err"
  echo "serve.sh: /work is $WORKDIR" >&2
}
cleanup() {
  if [ -n "${RECOVER_PID:-}" ]; then kill "$RECOVER_PID" 2>/dev/null || true; fi
  if [ -n "$CONTAINER_ID" ]; then "$ENGINE" rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true; fi
  if [ -n "${SERVER_PID:-}" ] && [ -f "$ROOT/.cache/serve.ready" ] && [ "$(cut -d' ' -f2 "$ROOT/.cache/serve.ready" 2>/dev/null)" = "$SERVER_PID" ]; then
    rm -f "$ROOT/.cache/serve.ready"
  fi
  if [ -n "${LLAMA_CACHE_DIR:-}" ]; then rm -rf "$LLAMA_CACHE_DIR"; fi
  if [ "${TERMUX_WAKE_LOCKED:-0}" = 1 ] && command -v termux-wake-unlock >/dev/null 2>&1; then
    termux-wake-unlock >/dev/null 2>&1 || true
  fi
  rm -rf "$ua_dir"
}
trap cleanup EXIT
# start.sh takes this lock and then execs serve.sh. A direct serve.sh must
# take it too, or Android freezes the server once Termux is in the background.
if [ "$IS_ANDROID" = 1 ] && [ "${TERMUX_WAKE_LOCKED:-0}" != 1 ] \
  && command -v termux-wake-lock >/dev/null 2>&1; then
  termux-wake-lock >/dev/null 2>&1 && TERMUX_WAKE_LOCKED=1 || true
fi

RUNTIME_ARG=""
TOOL_CWD=$WORKDIR
case "$TOOLS_RUNTIME" in
  auto)
    if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
      start_container podman || die "$(t "the tools container could not be started")"
    elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      start_container docker || die "$(t "the tools container could not be started")"
    else
      echo "serve.sh: $(t "no container engine found, so tools run on this computer as your user")" >&2
      echo "serve.sh: $(t "They start in the project directory but can reach other files you can read.")" >&2
      echo "serve.sh: $(t "lean tools are fewer; an empty TOOLS list turns them off; a container keeps them inside it")" >&2
    fi
    ;;
  host) warn "TOOLS_RUNTIME=host: tools run on the host with this user's permissions" ;;
  podman:*|docker:*)
    TOOLS_IMAGE=${TOOLS_RUNTIME#*:}
    start_container "${TOOLS_RUNTIME%%:*}" || die "$(t "the tools container could not be started")"
    ;;
  *) RUNTIME_ARG=$TOOLS_RUNTIME; TOOL_CWD="" ;;
esac
if [ -n "$CONTAINER_ID" ]; then
  printf '{"runtime":"%s","cwd":"/work","mount":"%s"}\n' "$(je "$RUNTIME_ARG")" "$(je "$WORKDIR")" > "$ROOT/.cache/tools.json"
elif [ -n "$RUNTIME_ARG" ]; then
  printf '{"runtime":"%s","cwd":"","mount":""}\n' "$(je "$RUNTIME_ARG")" > "$ROOT/.cache/tools.json"
else
  printf '{"runtime":"host","cwd":"%s","mount":""}\n' "$(je "$WORKDIR")" > "$ROOT/.cache/tools.json"
fi

env_dump=$(mktemp)
printenv > "$env_dump" || true
while IFS= read -r ev; do
  ev_name=${ev%%=*}
  case "$ev_name" in
    LLAMA_ARG_*|LLAMA_API_KEY|LLAMA_APP_CMD|LLAMA_SERVER_ROUTER_PORT|LLAMA_SERVER_CHILD_MODE|\
    LLAMA_SERVER_SLOTS_DEBUG|LLAMA_SERVER_SLOTS_N_DIFF|LLAMA_MEDIA_MARKER|LLAMA_TRACE|LLAMA_CACHE|HF_ENDPOINT|MODEL_ENDPOINT)
      unset "$ev_name" || true
      ;;
  esac
done < "$env_dump"
rm -f "$env_dump"
export LLAMA_API_KEY="$API_KEYS"
for d in "$ROOT"/.cache/llama-cache "$ROOT"/.cache/llama-cache.*; do
  [ -e "$d" ] || [ -h "$d" ] || continue
  owner=${d#"$ROOT"/.cache/llama-cache.}
  owner=${owner%%.*}
  case "$owner" in
    ''|*[!0-9]*) rm -rf "$d" ;;
    *)
      if [ "$d" = "$ROOT/.cache/llama-cache" ] || ! kill -0 "$owner" 2>/dev/null; then rm -rf "$d"; fi
      ;;
  esac
done
LLAMA_CACHE_DIR=$(mktemp -d "$ROOT/.cache/llama-cache.$$.XXXXXX") || die "cannot create a cache directory"
export LLAMA_CACHE="$LLAMA_CACHE_DIR"
export LLAMA_ARG_OFFLINE=1
export MODEL_ENDPOINT="https://offline.invalid/"
[ -n "$TOOLS" ] && export LLAMA_ARG_TOOLS="$TOOLS"
[ -n "$RUNTIME_ARG" ] && export LLAMA_ARG_TOOLS_RUNTIME="$RUNTIME_ARG"
if [ -n "$MCP_CONFIG" ]; then
  root_json=$(printf '%s' "$ROOT" | sed -e 's/[\\"]/\\&/g')
  sed "s|@ROOT@|$root_json|g" "$(abspath "$MCP_CONFIG")" > "$ROOT/.cache/mcp-servers.effective.json"
  export LLAMA_ARG_MCP_SERVERS_CONFIG="$ROOT/.cache/mcp-servers.effective.json"
fi

LISTEN_HOST=$(bind_hosts "$HOST")
PROBE_HOST=$(probe_host_of "$HOST")
PROBE_URL_HOST=$(url_host "$PROBE_HOST")
SLOT_DIR=$ROOT/.cache/slot-dumps
mkdir -p "$SLOT_DIR"
chmod 700 "$SLOT_DIR" 2>/dev/null || true
set -- \
  --host "$LISTEN_HOST" --port "$PORT" \
  --models-preset "$EFFECTIVE_PRESET" \
  --models-max "$ROUTER_MAX" \
  --slot-save-path "$SLOT_DIR/" \
  --threads "$THREADS" --threads-batch "$THREADS_BATCH" \
  --n-gpu-layers "$GPU_LAYERS" --fit on
[ -n "$LOAD_MODE" ] && set -- "$@" --load-mode "$LOAD_MODE"
[ "$REPACK" = off ] && set -- "$@" --no-repack
LOG_FILE=$(abspath "$LOG_FILE")
set -- "$@" --log-file "$LOG_FILE"
j=1
while [ "$j" -le "$ua_n" ]; do
  set -- "$@" "$(cat "$ua_dir/$j")"
  j=$((j + 1))
done

echo "serve.sh: $BIN $*" >&2
echo "serve.sh: env LLAMA_API_KEY=<from $API_KEY_FILE> LLAMA_ARG_TOOLS=${LLAMA_ARG_TOOLS:-} LLAMA_ARG_TOOLS_RUNTIME=${LLAMA_ARG_TOOLS_RUNTIME:-}" >&2
resident_note=""
[ "$RESIDENT" = 1 ] && resident_note=" + decision kept loaded"
{
  printf '  Profile: %s (%s): %s general/coder model(s) loaded%s%s\n' \
    "$PROFILE" "$PROFILE_WHY" "$MODELS_MAX" "$resident_note" "${TUNED:+; set:$TUNED}"
  echo '  Change:  PROFILE=lowram|moderate|default, or MODELS_MAX CTX CODER_CTX GENERAL_CTX PARALLEL THREADS TOOLS (README "Light tuning")'
} > "$ROOT/.cache/profile.txt"
echo "serve.sh: profile=$PROFILE ($PROFILE_WHY; RAM ${MEM_MB} MB, ${AVAIL_MB} MB free, android=$IS_ANDROID) models-max=$ROUTER_MAX tools=$TOOLS_SET threads=$THREADS ($THREADS_SRC) threads-batch=$THREADS_BATCH gpu-layers=$GPU_LAYERS repack=$REPACK load-mode=$LOAD_MODE" >&2
echo "serve.sh: models: general=$M_GENERAL coder=$M_CODER decision=$M_DECISION" >&2
echo "serve.sh: language: locale=$LANG_CODE ($LOCALE_SRC) mode=$MODE${SWAP_ROLES:+ swapped=[$SWAP_ROLES]}${LANG_MODEL:+ language-slot=$LANG_MODEL}" >&2
echo "serve.sh: tools cwd for clients (x-tool-cwd): ${TOOL_CWD:-<runtime default>}" >&2
want_gpu=$(gpu_variant)
case "$BIN" in
  *-cpu/*|*-cpu/llama-server)
    if [ "$want_gpu" != cpu ]; then
      warn "$(t "this binary is CPU-only and a GPU is present; set VARIANT and start again")"
    fi
    ;;
esac

if [ -n "$CONTAINER_ID" ]; then SERVER_CWD=/; else SERVER_CWD=$WORKDIR; fi
SERVE_PID=$$
READY_FILE=$ROOT/.cache/serve.ready
rm -f "$READY_FILE" "$LOG_FILE"
if command -v setsid >/dev/null 2>&1; then
  ( cd "$SERVER_CWD" && exec setsid "$BIN" "$@" ) &
else
  ( cd "$SERVER_CWD" && exec "$BIN" "$@" ) &
fi
SERVER_PID=$!
RECOVER_PID=""
if command -v python3 >/dev/null 2>&1; then
  RECOVER_URL="http://$PROBE_URL_HOST:$PORT" API_KEY_FILE="$API_KEY_FILE" \
    python3 "$ROOT/scripts/recover.py" >>"$ROOT/.cache/recover.log" 2>&1 &
  RECOVER_PID=$!
fi

said_listening() {
  [ -f "$LOG_FILE" ] && grep -F "listening on http://" "$LOG_FILE" 2>/dev/null | grep -E ":$PORT([^0-9]|\$)" >/dev/null
}
listener_is_ours() {
  [ "$IS_ANDROID" = 1 ] && return 2
  if command -v ss >/dev/null 2>&1; then
    ss -ltnpH "sport = :$PORT" 2>/dev/null | grep -q "pid=$SERVER_PID," && return 0
    if [ -n "$(ss -ltnH "sport = :$PORT" 2>/dev/null)" ] && ss -ltnpH 2>/dev/null | grep -q 'pid='; then return 1; fi
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -a -p "$SERVER_PID" -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && return 0
    return 1
  fi
  return 2
}
if command -v curl >/dev/null 2>&1; then
  ( i=1
    while [ "$i" -le 600 ]; do
      kill -0 "$SERVER_PID" 2>/dev/null || exit 0
      if said_listening && curl -s -o /dev/null --max-time 2 "http://$PROBE_URL_HOST:$PORT/health"; then
        owner=0
        listener_is_ours || owner=$?
        if [ "$owner" = 1 ]; then
          warn "port $PORT answers, but not from this server (pid $SERVER_PID)"
          exit 0
        fi
        kill -0 "$SERVER_PID" 2>/dev/null || exit 0
        printf '%s %s\n' "$PORT" "$SERVER_PID" > "$READY_FILE.tmp" && mv -f "$READY_FILE.tmp" "$READY_FILE"
        echo "serve.sh: listening on http://$PROBE_URL_HOST:$PORT (pid $SERVER_PID)" >&2
        pubs=$(public_hosts "$HOST")
        if [ -n "$pubs" ]; then
          printf '%s\n' "$pubs" | while IFS= read -r h; do
            [ -n "$h" ] || continue
            echo "serve.sh: also on http://$(url_host "$h"):$PORT" >&2
          done
          echo "serve.sh: $(t "Other machines can use these addresses. The API key is sent as plain HTTP.")" >&2
        else
          case ",$(bind_hosts "$HOST")," in
            *,0.0.0.0,*|*,::,*)
              echo "serve.sh: $(t "Other machines can connect to this machine on this port. The API key is sent as plain HTTP.")" >&2
              ;;
          esac
        fi
        exit 0
      fi
      sleep 1
      i=$((i + 1))
    done
  ) &
fi
forward() { trap '' INT TERM HUP; kill "-$1" "$SERVER_PID" 2>/dev/null || true; }
trap 'forward INT' INT
trap 'forward TERM' TERM
trap 'forward TERM' HUP
( trap '' INT TERM HUP
  while kill -0 "$SERVE_PID" 2>/dev/null && kill -0 "$SERVER_PID" 2>/dev/null; do
    st=$(ps -o state= -p "$SERVE_PID" 2>/dev/null || true)
    case "$st" in *Z*) break ;; esac
    sleep 2
  done
  kill -0 "$SERVER_PID" 2>/dev/null && kill -TERM "-$SERVER_PID" 2>/dev/null
  exit 0
) </dev/null >/dev/null 2>&1 &
status=0
while :; do
  wait "$SERVER_PID" && status=0 || status=$?
  kill -0 "$SERVER_PID" 2>/dev/null || break
done
exit "$status"
