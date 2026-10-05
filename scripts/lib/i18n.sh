# shellcheck shell=sh
# Plain sentences for the person running the launcher.
# Do not pass paths, model names, flags, hashes, JSON, or lines another script matches.
# Those stay as written. A missing translation stays English.
# Catalog: config/messages/<lang> with one "english<TAB>translation" per line.

norm_lang() {
  nl=${1%%.*}
  nl=${nl%%@*}
  nl=${nl%%[-_]*}
  nl=$(printf '%s' "$nl" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
  case "$nl" in ""|c|posix) printf '%s\n' en ;; *) printf '%s\n' "$nl" ;; esac
}

# $1 = raw locale (ja_JP.UTF-8, auto, empty)
lang_code_of() {
  case "$1" in
    ""|auto)
      norm_lang "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
      ;;
    *) norm_lang "$1" ;;
  esac
}

# t "English sentence"  -> translation or the same sentence
t() {
  if [ "${LANG_CODE:-en}" = en ] || [ -z "${ROOT:-}" ]; then
    printf '%s\n' "$1"
    return
  fi
  lc_file=$ROOT/config/messages/$LANG_CODE
  if [ -f "$lc_file" ]; then
    lc_hit=$(awk -v k="$1" 'BEGIN{FS="\t"} $1==k { print substr($0, length(k)+2); found=1; exit } END{ if (!found) exit 1 }' "$lc_file") && {
      printf '%s\n' "$lc_hit"
      return
    }
  fi
  printf '%s\n' "$1"
}
