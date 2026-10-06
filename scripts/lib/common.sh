# shellcheck shell=sh
# Shared helpers sourced by the /bin/sh scripts. No bash, no `local`.

# "<size> <mtime> <ctime> <inode>" of a verified model (.cache/verified/<sha256>).
# ctime cannot be set back by touch -d or cp -p (those set mtime), so a same-size
# rewrite still shows. FULL_VERIFY=1 re-hashes anyway.
fingerprint() {
  stat -c '%s %Y %Z %i' -L "$1" 2>/dev/null || stat -L -f '%z %m %c %i' "$1"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else cksum -a sha256 "$1" | awk 'NR==1 { print $NF; exit }'; fi
}

# One line per file ("f <size> <sha256> <path>") or symlink ("l <target> <path>").
tree_manifest() {
  ( cd "$1" && find . \( -type f -o -type l \) ! -name '.verified-*' | LC_ALL=C sort | while IFS= read -r p; do
      if [ -h "$p" ]; then printf 'l %s %s\n' "$(readlink "$p")" "${p#./}"
      else printf 'f %s %s %s\n' "$(stat -c %s "$p" 2>/dev/null || stat -f %z "$p")" "$(sha256_of "$p")" "${p#./}"; fi
    done )
}

# Same paths as tree_manifest, without reading bytes. A warm start compares this
# to the stamp from the last good sha256 and hashes only when it differs.
# One stat(1) covers the tree where -c works; elsewhere, fingerprint() per file.
tree_fingerprint() {
  tf_dir=$1
  if stat -c '%s' "$tf_dir" >/dev/null 2>&1; then
    ( cd "$tf_dir" && find . \( -type f -o -type l \) ! -name '.verified-*' -exec stat -c '%s %Y %Z %i %n' {} + | LC_ALL=C sort )
    return
  fi
  ( cd "$tf_dir" && find . \( -type f -o -type l \) ! -name '.verified-*' | LC_ALL=C sort | while IFS= read -r p; do
      if [ -h "$p" ]; then printf 'l %s %s\n' "$(readlink "$p")" "${p#./}"
      else printf 'f %s %s\n' "$(fingerprint "$p")" "${p#./}"; fi
    done )
}

# "--Models_Dir=x" -> "--models-dir"
arg_name() {
  an=${1%%=*}
  printf '%s' "$an" | tr '_' '-' | tr '[:upper:]' '[:lower:]'
}

# Shared weight store so every checkout can use the same GGUF files.
# GGUF_HOME wins; otherwise ${XDG_DATA_HOME:-$HOME/.local/share}/gguf.
gguf_home() {
  if [ -n "${GGUF_HOME:-}" ]; then
    printf '%s\n' "${GGUF_HOME%/}"
    return
  fi
  printf '%s/gguf\n' "${XDG_DATA_HOME:-$HOME/.local/share}"
}

# Where a layout-relative path is created. models/<rest> honors MODELS_DIR
# (the models root, as before). models-optional/ and models-inactive/ stay
# in the store. ROOT must be set. Does not create the path.
gguf_dest() {
  gd_rel=$1
  gd_rel=${gd_rel#/}
  case "$gd_rel" in
    models/*)
      if [ -n "${MODELS_DIR:-}" ]; then
        gd_rest=${gd_rel#models/}
        case "$MODELS_DIR" in
          /*) printf '%s/%s\n' "${MODELS_DIR%/}" "$gd_rest" ;;
          *) printf '%s/%s/%s\n' "$ROOT" "${MODELS_DIR%/}" "$gd_rest" ;;
        esac
        return
      fi
      ;;
  esac
  printf '%s/%s\n' "$(gguf_home)" "$gd_rel"
}

# File to use for a layout-relative GGUF path. The store (or MODELS_DIR) wins.
# A missing store file falls back to $ROOT/<layout> so a checkout copy is not
# stranded. MODELS_DIR does not fall back. Missing everywhere: the create path.
gguf_resolve() {
  gr_rel=$1
  gr_rel=${gr_rel#/}
  gr_dest=$(gguf_dest "$gr_rel")
  if [ -f "$gr_dest" ]; then
    printf '%s\n' "$gr_dest"
    return
  fi
  case "$gr_rel" in
    models/*)
      if [ -n "${MODELS_DIR:-}" ]; then
        printf '%s\n' "$gr_dest"
        return
      fi
      ;;
  esac
  case "$gr_rel" in
    models/*|models-optional/*|models-inactive/*)
      if [ -f "$ROOT/$gr_rel" ]; then
        printf '%s\n' "$ROOT/$gr_rel"
        return
      fi
      ;;
  esac
  printf '%s\n' "$gr_dest"
}

# True when $1 is inside the store or, for a models/ override, MODELS_DIR.
# Checkout copies are not managed: callers must not move them on their own.
gguf_is_managed() {
  gm_p=$1
  gm_h=$(gguf_home)
  case "$gm_p" in
    "$gm_h"/*) return 0 ;;
  esac
  if [ -n "${MODELS_DIR:-}" ]; then
    case "$MODELS_DIR" in
      /*) gm_m=${MODELS_DIR%/} ;;
      *) gm_m=$ROOT/${MODELS_DIR%/} ;;
    esac
    case "$gm_p" in
      "$gm_m"/*) return 0 ;;
    esac
  fi
  return 1
}

# How many big cores to use. $1 = sysfs cpu directory (tests pass a fake one).
# Prints nothing when the CPU is homogeneous or sysfs cannot be read.
big_cores() {
  bc_dir=${1:-/sys/devices/system/cpu}
  for bc_f in cpu_capacity cpufreq/cpuinfo_max_freq; do
    bc_vals=$(cat "$bc_dir"/cpu[0-9]*/"$bc_f" 2>/dev/null) || true
    [ -n "$bc_vals" ] || continue
    printf '%s\n' "$bc_vals" | awk '{v[NR]=$1; if ($1>max) max=$1; if (min=="" || $1<min) min=$1}
      END { if (NR < 2 || min == max) exit
            n=0; for (i in v) if (v[i] >= 0.75*max) n++
            if (n < 2) { n=0; for (i in v) if (v[i] > min) n++ }
            if (n >= 2) print n }'
    return
  done
}
