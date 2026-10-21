#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
command -v python3 >/dev/null 2>&1 || { echo "configure-tui.sh: python3 was not found" >&2; exit 1; }
command -v whiptail >/dev/null 2>&1 || { echo "configure-tui.sh: whiptail was not found" >&2; exit 1; }
panel=$ROOT/scripts/panel.py
spec=$(python3 "$panel" --fields)

answers=$(mktemp)
trap 'rm -f "$answers"' EXIT
: > "$answers"

while true; do
  menu_args=""
  while IFS="$(printf '\t')" read -r key shown hint; do
    [ -n "$key" ] || continue
    # get current value
    curr=""
    if [ -f "$ROOT/.cache/panel.env" ]; then
       curr=$(grep "^$key=" "$ROOT/.cache/panel.env" | cut -d= -f2- || true)
    fi
    menu_args="$menu_args $key \"$shown [$curr]\""
  done <<EOM
$spec
EOM
  menu_args="$menu_args SAVE \"Save and Exit\""
  
  choice=$(echo "$menu_args" | xargs whiptail --title "FAMILIA Configuration" --menu "Choose a setting to edit:" 20 70 12 3>&1 1>&2 2>&3 || echo "CANCEL")
  
  if [ "$choice" = "CANCEL" ] || [ "$choice" = "SAVE" ]; then
    break
  fi
  
  # Find the hint
  hint=$(echo "$spec" | grep "^$choice" | cut -f3 || true)
  
  new_val=$(whiptail --title "Edit $choice" --inputbox "$hint" 10 60 3>&1 1>&2 2>&3 || echo "CANCEL")
  if [ "$new_val" != "CANCEL" ]; then
    if python3 "$panel" --check "$choice" "$new_val"; then
      printf '%s\t%s\n' "$choice" "$new_val" >> "$answers"
      # Immediately write to see updates in menu
      python3 "$panel" --write "$answers"
      > "$answers"
    else
      whiptail --title "Error" --msgbox "Invalid value for $choice: $new_val" 8 40
    fi
  fi
done

