#!/usr/bin/env bash
# Unit test for big_cores() (scripts/lib/common.sh) with synthetic sysfs trees.
#   bash tests/test_cpu.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/common.sh
. "$ROOT/scripts/lib/common.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
# $1 name, $2 file (cpu_capacity | cpufreq/cpuinfo_max_freq), $3 expected, rest = one value per
# core ("-" = that core has no such file: offline, or unreadable)
check() {
  local name="$1" file="$2" want="$3"; shift 3
  local d="$tmp/$name" i=0 v got
  for v in "$@"; do
    mkdir -p "$d/cpu$i"; [[ "$v" == - ]] || { mkdir -p "$d/cpu$i/$(dirname "$file")"; echo "$v" > "$d/cpu$i/$file"; }
    i=$((i + 1))
  done
  got="$(big_cores "$d")"
  if [[ "$got" == "$want" ]]; then echo "ok   $name: ${got:-<none>}"; else echo "FAIL $name: got '${got}', want '${want}'"; fails=$((fails + 1)); fi
}
# Galaxy A57 (Exynos 1680): 1x A720 2.9 GHz + 4x A720 2.6 GHz + 3x A520 1.95 GHz
check a57-freq   cpufreq/cpuinfo_max_freq 5 2900000 2600000 2600000 2600000 2600000 1950000 1950000 1950000
check a57-cap    cpu_capacity 5 1024 918 918 918 918 410 410 410
# 3 clusters 1+3+4 where only the prime core passes 75%: everything but the slowest cluster
check 1-3-4      cpu_capacity 4 1024 700 700 700 300 300 300 300
check 1-3-4-freq cpufreq/cpuinfo_max_freq 4 3200000 2400000 2400000 2400000 1800000 1800000 1800000 1800000
# classic 4+4
check 4-4        cpu_capacity 4 1024 1024 1024 1024 450 450 450 450
# Galaxy Note 9: Exynos 9810 (4x M3 2.704 GHz + 4x A55 1.794 GHz) and Snapdragon 845
# (4x 2.8032 + 4x 1.7664 GHz); the capacities are illustrative, not read from a device
check note9-9810-freq cpufreq/cpuinfo_max_freq 4 1794000 1794000 1794000 1794000 2704000 2704000 2704000 2704000
check note9-9810-cap  cpu_capacity 4 389 389 389 389 1024 1024 1024 1024
check note9-845-freq  cpufreq/cpuinfo_max_freq 4 1766400 1766400 1766400 1766400 2803200 2803200 2803200 2803200
# a big core hotplugged off (its cpufreq/ is gone): the 3 online big cores
check offline-big     cpufreq/cpuinfo_max_freq 3 1794000 1794000 1794000 1794000 2704000 - 2704000 2704000
# one unreadable file: the other cores still count
check one-unreadable  cpu_capacity 4 1024 1024 1024 1024 450 450 450 -
# 1 prime + 7 others: one big core is not worth it -> nothing (all physical cores)
check 1-7        cpu_capacity "" 1024 600 600 600 600 600 600 600
# homogeneous: nothing (serve.sh then uses the physical core count)
check same       cpu_capacity "" 1024 1024 1024 1024
check none       cpu_capacity "" 
[[ "$fails" == 0 ]] && echo "all big_cores tests passed" || { echo "$fails failed"; exit 1; }
