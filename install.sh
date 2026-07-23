#!/bin/zsh
#
# install.sh — install or update the com.local.weekly-cleanup LaunchAgent
# and its cleanup script.
#
# Usage: zsh install.sh [--weekday 0-6] [--hour 0-23] [--minute 0-59] [--no-launchctl]
# Weekday values: 0 = Sunday ... 6 = Saturday (Mac local timezone).
# When updating an existing installation, the currently installed schedule is
# preserved unless schedule flags are passed explicitly. Installations made
# under the previous name (com.local.claude-weekly-cleanup) are migrated:
# their schedule is preserved and the old agent and script are removed.

set -u

script_dir="${0:A:h}"

label="com.local.weekly-cleanup"
bin_dir="$HOME/.local/bin"
agents_dir="$HOME/Library/LaunchAgents"
logs_dir="$HOME/Library/Logs"
script_source="$script_dir/bin/weekly-cleanup"
script_target="$bin_dir/weekly-cleanup"
plist_template="$script_dir/launchagent/$label.plist.template"
plist_target="$agents_dir/$label.plist"
log_file="$logs_dir/com.local.weekly-cleanup.log"

# Previous project name; found installs are migrated automatically.
legacy_label="com.local.claude-weekly-cleanup"
legacy_plist="$agents_dir/$legacy_label.plist"
legacy_script="$bin_dir/claude-weekly-cleanup"

default_weekday=0   # Sunday
default_hour=18
default_minute=0

weekday_names=(Sunday Monday Tuesday Wednesday Thursday Friday Saturday)

usage() {
  /bin/cat <<'USAGE'
Install or update the weekly cleanup LaunchAgent.

Usage:
  zsh install.sh [options]

Options:
  --weekday N     Day of week to run (0 = Sunday ... 6 = Saturday)
  --hour N        Hour to run (0-23, Mac local timezone)
  --minute N      Minute to run (0-59)
  --no-launchctl  Install files only; skip launchctl bootout/bootstrap
  -h, --help      Show this help

When updating an existing installation the installed schedule is preserved
unless --weekday/--hour/--minute are passed explicitly. Installs under the
old name com.local.claude-weekly-cleanup are migrated automatically.
USAGE
}

validate_int() {
  local name="$1" value="$2" min="$3" max="$4"

  if [[ "$value" != <-> ]] || (( value < min || value > max )); then
    print -u2 -r -- "Invalid $name: $value (expected $min-$max)"
    exit 2
  fi
}

opt_weekday=""
opt_hour=""
opt_minute=""
use_launchctl=1

while (( $# > 0 )); do
  case "$1" in
    --weekday) opt_weekday="${2:?--weekday requires a value}"; shift 2 ;;
    --hour)    opt_hour="${2:?--hour requires a value}";       shift 2 ;;
    --minute)  opt_minute="${2:?--minute requires a value}";   shift 2 ;;
    --no-launchctl) use_launchctl=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 -r -- "Unknown option: $1"; usage; exit 2 ;;
  esac
done

[[ -f "$script_source" ]] || {
  print -u2 -r -- "Cleanup script not found: $script_source"
  exit 1
}
[[ -f "$plist_template" ]] || {
  print -u2 -r -- "Plist template not found: $plist_template"
  exit 1
}

# Resolve the schedule: installed plist first (current name, then the legacy
# name), defaults otherwise, explicit flags always winning.

read_schedule_from() {
  local plist="$1"
  local pb=/usr/libexec/PlistBuddy
  [[ -f "$plist" && -x "$pb" ]] || return 1

  existing_weekday=$("$pb" -c "Print :StartCalendarInterval:Weekday" \
    "$plist" 2>/dev/null) || return 1
  existing_hour=$("$pb" -c "Print :StartCalendarInterval:Hour" \
    "$plist" 2>/dev/null) || return 1
  existing_minute=$("$pb" -c "Print :StartCalendarInterval:Minute" \
    "$plist" 2>/dev/null) || return 1

  return 0
}

weekday="$default_weekday"
hour="$default_hour"
minute="$default_minute"
schedule_source="default"

if read_schedule_from "$plist_target"; then
  weekday="$existing_weekday"
  hour="$existing_hour"
  minute="$existing_minute"
  schedule_source="preserved from the installed LaunchAgent"
elif read_schedule_from "$legacy_plist"; then
  weekday="$existing_weekday"
  hour="$existing_hour"
  minute="$existing_minute"
  schedule_source="preserved from the previous $legacy_label install"
fi

if [[ -n "$opt_weekday$opt_hour$opt_minute" ]]; then
  [[ -n "$opt_weekday" ]] && weekday="$opt_weekday"
  [[ -n "$opt_hour" ]]    && hour="$opt_hour"
  [[ -n "$opt_minute" ]]  && minute="$opt_minute"
  schedule_source="selected on the command line"
fi

validate_int "weekday" "$weekday" 0 6
validate_int "hour" "$hour" 0 23
validate_int "minute" "$minute" 0 59

# Install files

/bin/mkdir -p "$bin_dir" "$agents_dir" "$logs_dir"

/bin/cp "$script_source" "$script_target"
/bin/chmod 700 "$script_target"

content="$(<"$plist_template")"
content="${content//__CLEANUP_SCRIPT__/$script_target}"
content="${content//__LOG_FILE__/$log_file}"
content="${content//__WEEKDAY__/$weekday}"
content="${content//__HOUR__/$hour}"
content="${content//__MINUTE__/$minute}"

tmp_plist="$plist_target.tmp.$$"
print -r -- "$content" > "$tmp_plist"

if ! /usr/bin/plutil -lint "$tmp_plist" >/dev/null; then
  print -u2 -r -- "Generated plist failed plutil -lint; not installing."
  /bin/rm -f -- "$tmp_plist"
  exit 1
fi

/bin/mv -f -- "$tmp_plist" "$plist_target"

# Migrate away any legacy-name install

if [[ -f "$legacy_plist" || -f "$legacy_script" ]]; then
  if (( use_launchctl )); then
    /bin/launchctl bootout "gui/$(/usr/bin/id -u)/$legacy_label" \
      2>/dev/null || true
  fi
  [[ -f "$legacy_plist" ]] && /bin/rm -f -- "$legacy_plist"
  [[ -f "$legacy_script" ]] && /bin/rm -f -- "$legacy_script"
  print -r -- "Migrated: removed the previous $legacy_label agent and script."
fi

# Reload the LaunchAgent

if (( use_launchctl )); then
  uid=$(/usr/bin/id -u)

  # Safe when the agent was never loaded; bootout failures are expected then.
  /bin/launchctl bootout "gui/$uid" "$plist_target" 2>/dev/null || true

  if ! /bin/launchctl bootstrap "gui/$uid" "$plist_target"; then
    print -u2 -r -- "launchctl bootstrap failed for gui/$uid."
    print -u2 -r -- "Try logging out and back in, then rerun: zsh install.sh"
    exit 1
  fi
fi

# Summary

printf 'Installed cleanup script: %s (mode 700)\n' "$script_target"
printf 'Installed LaunchAgent:    %s\n' "$plist_target"
printf 'Schedule: %s at %02d:%02d (%s)\n' \
  "${weekday_names[weekday + 1]}" "$hour" "$minute" "$schedule_source"

/bin/cat <<'COMMANDS'

Run the cleanup immediately (for testing):

  launchctl kickstart -k \
    "gui/$(id -u)/com.local.weekly-cleanup"

View the log:

  tail -n 100 \
    "$HOME/Library/Logs/com.local.weekly-cleanup.log"

Inspect the loaded LaunchAgent:

  launchctl print \
    "gui/$(id -u)/com.local.weekly-cleanup"
COMMANDS
