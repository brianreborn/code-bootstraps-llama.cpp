# lib/path.mk: abs_path for POSIX sh scripts.
# Canonical copy: brianreborn/familia lib/path.mk. brianreborn/code-bootstraps-llama.cpp
# lib/path.mk is an identical copy (no runtime sourcing across repos); change both together.
# Self-contained. Load with:  . "$ROOT/lib/path.mk"
# abs_path PATH [BASE]: PATH unchanged if absolute, else BASE/PATH (BASE default $PWD).
# Purely lexical: no cd, no symlink resolution, PATH need not exist.
abs_path() {
  case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s\n' "${2:-$PWD}/$1" ;; esac
}
