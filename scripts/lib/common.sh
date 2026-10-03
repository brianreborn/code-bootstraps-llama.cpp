# shellcheck shell=bash
# Shared shell helpers (sourced by scripts/*.sh and tests/; bash).

# "<size> <mtime in seconds>": the same format scripts/lib/common.ps1 writes, so
# .cache/verified/<sha256> stamps mean the same on every OS.
fingerprint() {
  stat -c '%s %Y' -L "$1" 2>/dev/null || stat -L -f '%z %m' "$1"   # GNU/busybox/Termux, else BSD/macOS
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Manifest of an unpacked directory: one line per file ("f <size> <sha256> <path>") or symlink
# ("l <target> <path>"), sorted, paths relative to the directory; .verified-* stamps excluded.
# Same format as Get-TreeManifest in scripts/lib/common.ps1.
tree_manifest() {
  ( cd "$1" && find . \( -type f -o -type l \) ! -name '.verified-*' | LC_ALL=C sort | while IFS= read -r p; do
      if [[ -L "$p" ]]; then printf 'l %s %s\n' "$(readlink "$p")" "${p#./}"
      else printf 'f %s %s %s\n' "$(stat -c %s "$p" 2>/dev/null || stat -f %z "$p")" "$(sha256_of "$p")" "${p#./}"; fi
    done )
}

# Lower-case option name of a command-line argument, for refusal checks: "--Models_Dir=x" ->
# "--models-dir" (llama-server accepts _ for - in long options).
arg_name() { local n="${1%%=*}"; n="${n//_/-}"; printf '%s' "$n" | tr '[:upper:]' '[:lower:]'; }

# big.LITTLE (Android, arm64 Linux): how many "big" cores to use. A core counts when its
# cpu_capacity (or, if the kernel does not export it, cpuinfo_max_freq) is at least 75% of
# the highest. Little cores slow every op down to their pace, so they are left out. If fewer
# than 2 cores pass (one prime core on a 3-cluster SoC, e.g. 1+3+4), every core outside the
# slowest cluster is used instead. Prints nothing (= use all physical cores) for a homogeneous
# CPU, unreadable sysfs, or when that still leaves one core (1 prime + 7 others).
# $1 = sysfs cpu directory (tests pass a synthetic one).
big_cores() {
  local dir="${1:-/sys/devices/system/cpu}" f vals
  for f in cpu_capacity cpufreq/cpuinfo_max_freq; do
    vals=$(cat "$dir"/cpu[0-9]*/"$f" 2>/dev/null) || vals=""
    [[ -n "$vals" ]] || continue
    echo "$vals" | awk '{v[NR]=$1; if ($1>max) max=$1; if (min=="" || $1<min) min=$1}
      END { if (NR < 2 || min == max) exit
            n=0; for (i in v) if (v[i] >= 0.75*max) n++
            if (n < 2) { n=0; for (i in v) if (v[i] > min) n++ }
            if (n >= 2) print n }'
    return
  done
}
