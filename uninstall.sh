#!/bin/zsh
# uninstall.sh — remove the com.local.weekly-cleanup LaunchAgent and cleanup
# script (including any leftovers from the previous claude-weekly-cleanup
# name). Never runs the cleanup, and keeps the log file unless --remove-log
# is passed explicitly.
# Usage: zsh uninstall.sh [--remove-log] [--no-launchctl]

set -u

label="com.local.weekly-cleanup"
plist_target="$HOME/Library/LaunchAgents/$label.plist"
script_target="$HOME/.local/bin/weekly-cleanup"
log_file="$HOME/Library/Logs/com.local.weekly-cleanup.log"

legacy_label="com.local.claude-weekly-cleanup"
legacy_plist="$HOME/Library/LaunchAgents/$legacy_label.plist"
legacy_script="$HOME/.local/bin/claude-weekly-cleanup"

remove_log=0
use_launchctl=1

while (( $# > 0 )); do
  case "$1" in
    --remove-log) remove_log=1; shift ;;
    --no-launchctl) use_launchctl=0; shift ;;
    -h|--help)
      print -r -- "Usage: zsh uninstall.sh [--remove-log] [--no-launchctl]"
      exit 0
      ;;
    *) print -u2 -r -- "Unknown option: $1"; exit 2 ;;
  esac
done

if (( use_launchctl )); then
  uid=$(/usr/bin/id -u)
  /bin/launchctl bootout "gui/$uid/$label" 2>/dev/null || true
  /bin/launchctl bootout "gui/$uid/$legacy_label" 2>/dev/null || true
  print -r -- "LaunchAgent unloaded (if it was loaded)."
fi

for f in "$plist_target" "$script_target" "$legacy_plist" "$legacy_script"; do
  if [[ -f "$f" ]]; then
    /bin/rm -f -- "$f"
    print -r -- "Removed: $f"
  fi
done

if (( remove_log )); then
  if [[ -f "$log_file" ]]; then
    /bin/rm -f -- "$log_file"
    print -r -- "Removed: $log_file"
  else
    print -r -- "Not present: $log_file"
  fi
else
  print -r -- "Log kept: $log_file (pass --remove-log to delete it)"
fi

print -r -- "Uninstall complete. No cleanup was run."
