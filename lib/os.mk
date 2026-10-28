# lib/os.mk: platform helpers for POSIX sh scripts.
# Canonical copy: brianreborn/familia lib/os.mk. brianreborn/code-bootstraps-llama.cpp
# lib/os.mk is an identical copy (no runtime sourcing across repos); change both together.
# Self-contained. Load with:  . "$ROOT/lib/os.mk"
# mk_is_termux: true when PREFIX points into com.termux (Termux shells export it).
mk_is_termux() { case "${PREFIX:-}" in *com.termux*) return 0 ;; esac; return 1; }
# mk_nproc [FALLBACK]: online CPU count; getconf, then sysctl hw.ncpu (BSD/macOS),
# then nproc, then FALLBACK (default 2).
mk_nproc() {
  getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null \
    || nproc 2>/dev/null || printf '%s\n' "${1:-2}"
}
