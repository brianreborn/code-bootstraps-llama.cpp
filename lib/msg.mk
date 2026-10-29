# lib/msg.mk: say / warn / die for POSIX sh scripts.
# Canonical copy: brianreborn/familia lib/msg.mk. brianreborn/code-bootstraps-llama.cpp
# lib/msg.mk is an identical copy (no runtime sourcing across repos); change both together.
# Self-contained. Load with:  MK_TAG=name; . "$ROOT/lib/msg.mk"
#   MK_TAG     prefix: messages print as "MK_TAG: text" (unset or empty: no prefix)
#   MK_SAY_FD  1 sends say to stdout; default 2 (stderr). warn and die always use stderr
#   MK_ERR     text between the prefix and a die message; default "error: ", "" for none
# say TEXT...   warn TEXT...   die MESSAGE [EXIT_STATUS]   (status default 1)
say() {
  if [ "${MK_SAY_FD:-2}" = 1 ]; then printf '%s\n' "${MK_TAG:+$MK_TAG: }$*"
  else printf '%s\n' "${MK_TAG:+$MK_TAG: }$*" >&2; fi
}
warn() { printf '%s\n' "${MK_TAG:+$MK_TAG: }WARNING: $*" >&2; }
die() { printf '%s\n' "${MK_TAG:+$MK_TAG: }${MK_ERR-error: }$1" >&2; exit "${2:-1}"; }
