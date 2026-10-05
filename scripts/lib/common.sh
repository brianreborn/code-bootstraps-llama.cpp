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

# "--Models_Dir=x" -> "--models-dir"
arg_name() {
  an=${1%%=*}
  printf '%s' "$an" | tr '_' '-' | tr '[:upper:]' '[:lower:]'
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
