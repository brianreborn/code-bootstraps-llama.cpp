#!/bin/sh
# Ask for launcher settings. Enter, or the default itself, omits that key.
# panel.py writes .cache/panel.env so the quoting stays : "${KEY:=value}".
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
command -v python3 >/dev/null 2>&1 || { echo "configure.sh: python3 was not found" >&2; exit 1; }
panel=$ROOT/scripts/panel.py
spec=$(python3 "$panel" --fields)
answers=$(mktemp)
trap 'rm -f "$answers"' EXIT
: > "$answers"

if command -v whiptail >/dev/null 2>&1 && [ -t 0 ]; then
  # Visual Console UI
  while true; do
    menu_args=""
    # Create the menu arguments
    while IFS="$(printf '\t')" read -r key shown hint; do
      [ -n "$key" ] || continue
      curr=""
      if [ -f "$ROOT/.cache/panel.env" ]; then
         curr=$(grep "^$key=" "$ROOT/.cache/panel.env" | cut -d= -f2- || true)
      fi
      if [ -z "$curr" ]; then curr="(default)"; fi
      menu_args="$menu_args $key \"$shown [$curr]\""
    done <<EOM
$spec
EOM
    menu_args="$menu_args SAVE \"Save and Exit\""
    
    choice=$(echo "$menu_args" | xargs whiptail --title "FEELDZNUTTS Settings" --menu "Choose a setting to edit:" 22 76 14 3>&1 1>&2 2>&3 || echo "CANCEL")
    
    if [ "$choice" = "CANCEL" ] || [ "$choice" = "SAVE" ]; then
      break
    fi
    
    hint=$(echo "$spec" | awk -F'\t' -v k="$choice" '$1==k {print $3}' || true)
    
    new_val=$(whiptail --title "Edit $choice" --inputbox "$hint" 10 60 3>&1 1>&2 2>&3 || echo "CANCEL")
    if [ "$new_val" != "CANCEL" ]; then
      if python3 "$panel" --check "$choice" "$new_val"; then
        printf '%s\t%s\n' "$choice" "$new_val" > "$answers"
        python3 "$panel" --write "$answers"
      else
        whiptail --title "Error" --msgbox "Invalid value for $choice: $new_val" 8 40
      fi
    fi
  done
  exit 0
fi

# Fallback: line-oriented terminal reading from stdin
while IFS="$(printf '\t')" read -r key shown hint <&3; do
  [ -n "$key" ] || continue
  refused=0
  while true; do
    printf '%s [%s] (%s): ' "$key" "$shown" "$hint" >&2
    ans=
    eof=0
    if ! IFS= read -r ans; then eof=1; fi
    if [ "$eof" = 1 ] && [ -z "$ans" ]; then
      if [ "$refused" = 1 ]; then
        echo "configure.sh: refused $key" >&2
        exit 1
      fi
      break 2
    fi
    ans=$(printf '%s' "$ans" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -z "$ans" ]; then
      if [ "$eof" = 1 ]; then break 2; fi
      break
    fi
    if python3 "$panel" --check "$key" "$ans"; then
      printf '%s\t%s\n' "$key" "$ans" >> "$answers"
      if [ "$eof" = 1 ]; then break 2; fi
      break
    fi
    echo "configure.sh: refused $key=$ans" >&2
    if [ "$eof" = 1 ]; then exit 1; fi
    refused=1
  done
done 3<<EOM
$spec
EOM

python3 "$panel" --write "$answers"
