#!/bin/zsh
# run-tests.zsh — test suite for the claude-weekly-cleanup project.
# Every test runs against a throwaway fixture HOME under a temporary
# directory, with osascript, pgrep, and all package managers mocked.
# No real user data is read or deleted.
# Usage: zsh tests/run-tests.zsh

set -u

repo_dir="${0:A:h:h}"
cleanup_script="$repo_dir/bin/weekly-cleanup"
install_script="$repo_dir/install.sh"
uninstall_script="$repo_dir/uninstall.sh"

root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/claude-cleanup-tests.XXXXXX")" || exit 1
trap '/bin/chmod -R u+rwX "$root" 2>/dev/null; /bin/rm -rf "$root"' EXIT

typeset -i pass_count=0
typeset -i fail_count=0
script_status=0
fixture=""
state=""

# Assertion helpers

section() {
  print -r -- ""
  print -r -- "== $1"
}

ok() {
  (( pass_count += 1 ))
  print -r -- "   ok   - $1"
}

ko() {
  (( fail_count += 1 ))
  print -r -- "   FAIL - $1"
}

assert_true() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else ko "$desc"; fi
}

assert_false() {
  local desc="$1"
  shift
  if "$@" 2>/dev/null; then ko "$desc"; else ok "$desc"; fi
}

assert_status() {
  local desc="$1" expected="$2"
  if (( script_status == expected )); then
    ok "$desc"
  else
    ko "$desc (expected exit $expected, got $script_status)"
  fi
}

fixture_log() {
  print -r -- "$fixture/Library/Logs/com.local.weekly-cleanup.log"
}

assert_log_contains() {
  local desc="$1" needle="$2"
  if /usr/bin/grep -qF -- "$needle" "$(fixture_log)" 2>/dev/null; then
    ok "$desc"
  else
    ko "$desc"
  fi
}

file_contains() {
  /usr/bin/grep -qF -- "$2" "$1"
}

dir_is_empty() {
  local -a entries
  entries=("$1"/*(DN))
  (( ${#entries[@]} == 0 ))
}

is_number() {
  [[ "$1" == <-> ]]
}

str_eq() {
  [[ "$1" == "$2" ]]
}

# Mocks

mockbin="$root/mockbin"
pkgbin="$root/pkgbin"
emptybin="$root/emptybin"
/bin/mkdir -p "$mockbin" "$pkgbin" "$emptybin"

/bin/cat > "$mockbin/osascript" <<'MOCK'
#!/bin/zsh
set -u
state="${MOCK_STATE_DIR:?}"

if [[ "${1:-}" == "-e" ]]; then
  script="${2:-}"

  if [[ "$script" == *"display notification"* ]]; then
    print -r -- "$script" >> "$state/notifications.log"
    exit 0
  fi

  if [[ "$script" == *"tell application"*"quit"* ]]; then
    app="${script#*\"}"
    app="${app%%\"*}"
    print -r -- "$app" >> "$state/quits.log"

    proc="$app"
    [[ "$app" == "Visual Studio Code" ]] && proc="Code"

    sticky=" ${MOCK_STICKY_PROCS:-} "
    if [[ "$sticky" != *" $proc "* && -f "$state/running" ]]; then
      /usr/bin/grep -vx "$proc" "$state/running" > "$state/running.tmp" || true
      /bin/mv "$state/running.tmp" "$state/running"
    fi
    exit 0
  fi

  exit 0
fi

# Dialogs are invoked as: osascript - <kind> <arguments...>
if [[ "${1:-}" == "-" ]]; then
  /bin/cat > /dev/null
  kind="${2:-confirm}"

  case "$kind" in
    menu)
      print -r -- "dialog kind=menu timeout=${3:-} mode=${MOCK_MENU_MODE:-choice}" \
        >> "$state/dialogs.log"
      case "${MOCK_MENU_MODE:-choice}" in
        timeout) print -r -- "Cancel" ;;
        error)   exit 1 ;;
        *)       print -r -- "${MOCK_MENU_CHOICE:-Cancel}" ;;
      esac
      ;;

    scan)
      print -r -- "dialog kind=scan items=$(( $# - 3 ))" >> "$state/dialogs.log"
      shift 3
      for line in "$@"; do
        print -r -- "$line" >> "$state/scan-items.log"
      done
      print -r -- "${MOCK_SCAN_SELECTION:-}"
      ;;

    *)
      print -r -- "dialog kind=confirm size=${3:-} timeout=${4:-} retention=${5:-} mode=${MOCK_DIALOG_MODE:-choice}" \
        >> "$state/dialogs.log"
      case "${MOCK_DIALOG_MODE:-choice}" in
        timeout) print -r -- "Cancel" ;;
        error)   exit 1 ;;
        *)       print -r -- "${MOCK_DIALOG_CHOICE:-Cancel}" ;;
      esac
      ;;
  esac
  exit 0
fi

exit 0
MOCK
/bin/chmod 755 "$mockbin/osascript"

/bin/cat > "$mockbin/open" <<'MOCK'
#!/bin/zsh
set -u
print -r -- "$*" >> "${MOCK_STATE_DIR:?}/opened.log"
MOCK
/bin/chmod 755 "$mockbin/open"

/bin/cat > "$mockbin/pgrep" <<'MOCK'
#!/bin/zsh
set -u
state="${MOCK_STATE_DIR:?}"
name="${@[-1]}"
[[ -f "$state/running" ]] || exit 1
/usr/bin/grep -qx -- "$name" "$state/running"
MOCK
/bin/chmod 755 "$mockbin/pgrep"

for tool in npm pip3 pip brew pnpm yarn; do
  upper="${(U)tool}"
  /bin/cat > "$pkgbin/$tool" <<MOCK
#!/bin/zsh
print -r -- "$tool \$*" >> "\${MOCK_STATE_DIR:?}/commands.log"
exit "\${MOCK_${upper}_EXIT:-0}"
MOCK
  /bin/chmod 755 "$pkgbin/$tool"
done

# Fixtures and runners

new_fixture() {
  fixture="$(/usr/bin/mktemp -d "$root/fixture.XXXXXX")"
  state="$fixture/.mockstate"
  /bin/mkdir -p "$state"
  : > "$state/running"

  /bin/mkdir -p "$fixture/Library/Logs"
  /bin/mkdir -p "$fixture/.Trash"

  local sub
  for sub in \
    "Code/Cache" "Code/Code Cache" "Code/GPUCache" \
    "Claude/vm_bundles" "Claude/Cache" "Claude/Code Cache" "Claude/GPUCache" \
    "obsidian/Cache" "obsidian/Code Cache" "obsidian/GPUCache"
  do
    /bin/mkdir -p "$fixture/Library/Application Support/$sub/nested dir"
    print -r -- "junk" > \
      "$fixture/Library/Application Support/$sub/cache file with spaces.tmp"
    print -r -- "junk" > \
      "$fixture/Library/Application Support/$sub/nested dir/data.bin"
  done

  /bin/mkdir -p "$fixture/Library/Application Support/Code/CachedData/v1"
  print -r -- "keep" > \
    "$fixture/Library/Application Support/Code/CachedData/v1/important.js"

  /bin/mkdir -p "$fixture/Library/Developer/Xcode/DerivedData/MyApp-abcdef"
  print -r -- "keep" > \
    "$fixture/Library/Developer/Xcode/DerivedData/MyApp-abcdef/build.o"
  /bin/mkdir -p "$fixture/Library/Developer/Xcode/Archives/2026-07-01"
  /bin/mkdir -p "$fixture/Library/Caches/org.swift.swiftpm/repositories"
}

# run_script [EXTRA_ENV=value ...] [-- SCRIPT_ARG ...] — runs the cleanup
# script against the current fixture; extra env assignments override the
# defaults, and anything after -- is passed to the script itself.
# The menu defaults to "Cleanup" so the cleanup flow stays the default path.
run_script() {
  local arg
  local -a env_args script_args
  local -i after_marker=0

  for arg in "$@"; do
    if [[ "$arg" == "--" && after_marker -eq 0 ]]; then
      after_marker=1
      continue
    fi
    if (( after_marker )); then
      script_args+=("$arg")
    else
      env_args+=("$arg")
    fi
  done

  /usr/bin/env \
    HOME="$fixture" \
    CLEANUP_PATH_OVERRIDE="$pkgbin" \
    CLEANUP_OSASCRIPT="$mockbin/osascript" \
    CLEANUP_PGREP="$mockbin/pgrep" \
    CLEANUP_OPEN="$mockbin/open" \
    CLEANUP_QUIT_WAIT_SECONDS=1 \
    MOCK_STATE_DIR="$state" \
    MOCK_MENU_CHOICE="Cleanup" \
    MOCK_DIALOG_CHOICE="Clean now" \
    "${env_args[@]}" \
    /bin/zsh "$cleanup_script" "${script_args[@]}"
  script_status=$?
}

fixture_scan_report() {
  print -r -- "$fixture/Library/Logs/com.local.weekly-cleanup-scan.txt"
}

# The first path line under a section heading of the scan report.
first_report_entry_after() {
  /usr/bin/awk -v heading="$1" \
    'index($0, heading) { found = 1; next }
     found && index($0, "/") { print; exit }' \
    "$(fixture_scan_report)" 2>/dev/null
}

report_line_number() {
  /usr/bin/grep -nF -- "$1" "$(fixture_scan_report)" 2>/dev/null |
    /usr/bin/head -n 1 | /usr/bin/cut -d: -f1
}

# True when the first path is listed above the second one in the report.
listed_before() {
  local a b
  a="$(report_line_number "$1")"
  b="$(report_line_number "$2")"
  [[ -n "$a" && -n "$b" ]] && (( a < b ))
}

# Unit-test helpers: source the script (main does not run) and call one
# function inside a fixture HOME.
protected_check() {
  HOME="$fixture" /bin/zsh -c \
    'set -u; source "$1"; is_protected_build_path "$2"' \
    zsh "$cleanup_script" "$1"
}

cache_list_check() {
  HOME="$fixture" /bin/zsh -c '
    set -u
    source "$1"
    for p in "${cache_paths[@]}"; do
      case "$p" in
        *CachedData* | */.build* | *DerivedData* | \
        *SourcePackages* | *ModuleCache.noindex* | */Archives*)
          exit 1 ;;
      esac
    done
    exit 0
  ' zsh "$cleanup_script"
}

call_function() {
  HOME="$fixture" /bin/zsh -c \
    'set -u; source "$1"; shift; "$@"' \
    zsh "$cleanup_script" "$@"
}

days_ago() {
  /bin/date -v-"$1"d +%Y%m%d%H%M
}

make_old_file() {
  local path="$1" age_days="$2"
  print -r -- "old" > "$path"
  /usr/bin/touch -t "$(days_ago "$age_days")" "$path"
}

# Tests

section "syntax checks"
for f in "$cleanup_script" "$install_script" "$uninstall_script"; do
  assert_true "zsh -n ${f:t}" /bin/zsh -n "$f"
done

section "protected Swift/Xcode paths (unit)"
new_fixture
for p in \
  "$fixture/Library/Developer" \
  "$fixture/Library/Developer/Xcode/DerivedData" \
  "$fixture/Library/Developer/Xcode/Archives" \
  "$fixture/Library/Developer/Xcode/ModuleCache.noindex" \
  "$fixture/Library/Caches/org.swift.swiftpm" \
  "$fixture/Library/org.swift.swiftpm" \
  "$fixture/.swiftpm" \
  "$fixture/some/project/.build" \
  "$fixture/some/project/.build/debug" \
  "$fixture/some/DerivedData" \
  "$fixture/some/SourcePackages" \
  "$fixture/some/ModuleCache.noindex" \
  "$fixture/some/Archives"
do
  assert_true "protected: ${p#$fixture/}" protected_check "$p"
done
assert_false "not protected: Code/Cache" \
  protected_check "$fixture/Library/Application Support/Code/Cache"

section "target list never selects excluded or protected directories (unit)"
assert_true "cache_paths has no CachedData/.build/DerivedData/etc." \
  cache_list_check

section "size formatting (unit)"
assert_true "0 -> 0 KB"        str_eq "$(call_function format_kb 0)" "0 KB"
assert_true "500 -> 500 KB"    str_eq "$(call_function format_kb 500)" "500 KB"
assert_true "1536 -> 1.5 MB"   str_eq "$(call_function format_kb 1536)" "1.5 MB"
assert_true "844288 -> 824.5 MB" \
  str_eq "$(call_function format_kb 844288)" "824.5 MB"
assert_true "2233466 -> 2.13 GB" \
  str_eq "$(call_function format_kb 2233466)" "2.13 GB"

section "size estimate tolerates missing and unreadable paths (unit)"
new_fixture
/bin/rm -rf "$fixture/Library/Application Support/obsidian"
/bin/chmod 000 "$fixture/Library/Application Support/Code/Cache"
estimate_out="$(call_function estimate_reclaimable_kb)"
/bin/chmod 755 "$fixture/Library/Application Support/Code/Cache"
assert_true "estimate is numeric" is_number "$estimate_out"

section "full run: caches, package managers, logs, and Trash"
new_fixture
print -r -- "delete me" > "$fixture/.Trash/normal file.txt"
/bin/mkdir -p "$fixture/.Trash/SwiftApp"
print -r -- "// swift-tools-version:6.0" > "$fixture/.Trash/SwiftApp/Package.swift"
make_old_file "$fixture/Library/Logs/old-app.log" 40
/bin/mkdir -p "$fixture/Library/Logs/OldApp"
make_old_file "$fixture/Library/Logs/OldApp/nested.log" 40
print -r -- "new" > "$fixture/Library/Logs/recent.log"
print -r -- "Code" >> "$state/running"
print -r -- "Claude" >> "$state/running"
print -r -- "Obsidian" >> "$state/running"

run_script
assert_status "exits 0" 0
assert_true "VS Code Cache emptied" \
  dir_is_empty "$fixture/Library/Application Support/Code/Cache"
assert_true "'Code Cache' (path with spaces) emptied" \
  dir_is_empty "$fixture/Library/Application Support/Code/Code Cache"
assert_true "Claude vm_bundles emptied" \
  dir_is_empty "$fixture/Library/Application Support/Claude/vm_bundles"
assert_true "obsidian GPUCache emptied" \
  dir_is_empty "$fixture/Library/Application Support/obsidian/GPUCache"
assert_true "cache parent directory preserved" \
  test -d "$fixture/Library/Application Support/obsidian/GPUCache"
assert_true "VS Code CachedData preserved" \
  test -f "$fixture/Library/Application Support/Code/CachedData/v1/important.js"
assert_true "DerivedData preserved" \
  test -f "$fixture/Library/Developer/Xcode/DerivedData/MyApp-abcdef/build.o"
assert_true "Xcode Archives preserved" \
  test -d "$fixture/Library/Developer/Xcode/Archives/2026-07-01"
assert_true "SwiftPM cache preserved" \
  test -d "$fixture/Library/Caches/org.swift.swiftpm/repositories"
assert_false "normal Trash file deleted" \
  test -e "$fixture/.Trash/normal file.txt"
assert_true "Package.swift project preserved in Trash" \
  test -f "$fixture/.Trash/SwiftApp/Package.swift"
assert_log_contains "protected Trash item logged" "PROTECTED in Trash"
assert_false "old log deleted" test -e "$fixture/Library/Logs/old-app.log"
assert_false "emptied log subdirectory removed" \
  test -e "$fixture/Library/Logs/OldApp"
assert_true "recent log kept" test -f "$fixture/Library/Logs/recent.log"
assert_true "own log file kept" test -f "$(fixture_log)"
assert_log_contains "log deletion count logged" "Deleted 2 old user log file(s)."
assert_log_contains "estimate logged" "Estimated reclaimable size"
assert_true "VS Code asked to quit" \
  file_contains "$state/quits.log" "Visual Studio Code"
assert_true "Claude asked to quit" file_contains "$state/quits.log" "Claude"
assert_true "Obsidian asked to quit" file_contains "$state/quits.log" "Obsidian"
assert_true "menu dialog was shown first" \
  file_contains "$state/dialogs.log" "kind=menu"
assert_true "confirmation dialog showed the size estimate" \
  file_contains "$state/dialogs.log" "kind=confirm size="
assert_log_contains "selected action logged" "Selected action: cleanup"
assert_true "success notification sent" \
  file_contains "$state/notifications.log" "completed"
assert_true "npm used cache verify" \
  file_contains "$state/commands.log" "npm cache verify"
assert_false "npm cache clean --force never used" \
  file_contains "$state/commands.log" "cache clean --force"
assert_true "pip3 cache purged" \
  file_contains "$state/commands.log" "pip3 cache purge"
assert_true "brew cleanup --prune=all used" \
  file_contains "$state/commands.log" "brew cleanup --prune=all"
assert_true "pnpm store prune used" \
  file_contains "$state/commands.log" "pnpm store prune"
assert_true "yarn cache clean used" \
  file_contains "$state/commands.log" "yarn cache clean"
assert_log_contains "final status completed" "Final status: completed"

section "missing target directories are skipped"
new_fixture
/bin/rm -rf "$fixture/Library/Application Support"
print -r -- "junk" > "$fixture/.Trash/file.txt"
run_script
assert_status "exits 0" 0
assert_log_contains "missing directories logged" "Not found; skipping:"
assert_log_contains "still completes" "Final status: completed"

section "fatal safety check: protected extra target"
new_fixture
run_script CLEANUP_EXTRA_CACHE_PATHS="$fixture/Library/Developer/Xcode/DerivedData"
assert_status "exits nonzero" 1
assert_log_contains "refusal logged" "FATAL: cleanup target is protected Swift/Xcode data"
assert_true "no dialog was shown" test ! -e "$state/dialogs.log"
assert_true "caches untouched" \
  test -f "$fixture/Library/Application Support/Code/Cache/cache file with spaces.tmp"
assert_true "DerivedData untouched" \
  test -f "$fixture/Library/Developer/Xcode/DerivedData/MyApp-abcdef/build.o"
assert_true "safety notification sent" \
  file_contains "$state/notifications.log" "safety check"

section "fatal safety check: target outside ~/Library"
new_fixture
run_script CLEANUP_EXTRA_CACHE_PATHS="$root/outside-home"
assert_status "exits nonzero" 1
assert_log_contains "refusal logged" "FATAL: cleanup target is outside ~/Library"

section "user cancels the dialog"
new_fixture
print -r -- "junk" > "$fixture/.Trash/file.txt"
run_script MOCK_DIALOG_CHOICE="Cancel"
assert_status "exits 0" 0
assert_true "caches untouched" \
  test -f "$fixture/Library/Application Support/Code/Cache/cache file with spaces.tmp"
assert_true "Trash untouched" test -f "$fixture/.Trash/file.txt"
assert_true "no quit requests sent" test ! -e "$state/quits.log"
assert_log_contains "cancel logged" "Final status: canceled"

section "dialog times out"
new_fixture
print -r -- "junk" > "$fixture/.Trash/file.txt"
run_script MOCK_DIALOG_MODE="timeout"
assert_status "exits 0" 0
assert_true "timeout path exercised" \
  file_contains "$state/dialogs.log" "mode=timeout"
assert_true "Trash untouched" test -f "$fixture/.Trash/file.txt"
assert_log_contains "cancel logged" "Final status: canceled"

section "dialog AppleScript error cancels"
new_fixture
print -r -- "junk" > "$fixture/.Trash/file.txt"
run_script MOCK_DIALOG_MODE="error"
assert_status "exits 0" 0
assert_true "Trash untouched" test -f "$fixture/.Trash/file.txt"
assert_log_contains "cancel logged" "Final status: canceled"

section "one managed application remains open"
new_fixture
print -r -- "Code" >> "$state/running"
print -r -- "Claude" >> "$state/running"
run_script MOCK_STICKY_PROCS="Code"
assert_status "exits 1" 1
assert_true "caches untouched" \
  test -f "$fixture/Library/Application Support/Code/Cache/cache file with spaces.tmp"
assert_log_contains "blocking app logged" "still running"
assert_true "notification lists the app" \
  file_contains "$state/notifications.log" "Visual Studio Code"
assert_log_contains "cancel logged" "Final status: canceled"

section "package managers not installed"
new_fixture
run_script CLEANUP_PATH_OVERRIDE="$emptybin"
assert_status "exits 0" 0
assert_log_contains "npm skipped" "npm not found; skipped."
assert_log_contains "pip skipped" "pip not found; skipped."
assert_log_contains "brew skipped" "Homebrew not found; skipped."
assert_log_contains "pnpm skipped" "pnpm not found; skipped."
assert_log_contains "yarn skipped" "yarn not found; skipped."
assert_log_contains "still completes" "Final status: completed"

section "package-manager command failures do not abort"
new_fixture
print -r -- "junk" > "$fixture/.Trash/file.txt"
run_script MOCK_NPM_EXIT=1 MOCK_PIP3_EXIT=1 MOCK_BREW_EXIT=1 \
  MOCK_PNPM_EXIT=1 MOCK_YARN_EXIT=1
assert_status "exits 0" 0
assert_log_contains "npm failure logged" "'npm cache verify' returned an error"
assert_log_contains "pip3 failure logged" "'pip3 cache purge' returned an error"
assert_log_contains "brew failure logged" "'brew cleanup --prune=all' returned an error"
assert_log_contains "pnpm failure logged" "'pnpm store prune' returned an error"
assert_log_contains "yarn failure logged" "'yarn cache clean' returned an error"
assert_false "Trash still cleaned afterwards" test -e "$fixture/.Trash/file.txt"
assert_log_contains "still completes" "Final status: completed"

section "Trash protection variants"
new_fixture
print -r -- "junk" > "$fixture/.Trash/disposable.txt"
/bin/mkdir -p "$fixture/.Trash/plain dir"
print -r -- "junk" > "$fixture/.Trash/plain dir/file.txt"
/bin/mkdir -p "$fixture/.Trash/.build"
print -r -- "obj" > "$fixture/.Trash/.build/artifact.o"
/bin/mkdir -p "$fixture/.Trash/ProjWithBuild/.build"
/bin/mkdir -p "$fixture/.Trash/XcApp/XcApp.xcodeproj"
/bin/mkdir -p "$fixture/.Trash/WsApp/App.xcworkspace"
/bin/mkdir -p "$fixture/.Trash/DeepProj/a/b"
print -r -- "// pkg" > "$fixture/.Trash/DeepProj/a/b/Package.swift"
/bin/mkdir -p "$fixture/.Trash/TooDeep/a/b/c"
print -r -- "// pkg" > "$fixture/.Trash/TooDeep/a/b/c/Package.swift"
run_script
assert_status "exits 0" 0
assert_false "disposable file deleted" test -e "$fixture/.Trash/disposable.txt"
assert_false "plain directory deleted" test -e "$fixture/.Trash/plain dir"
assert_true ".build folder preserved" test -d "$fixture/.Trash/.build"
assert_true "dir containing .build preserved" \
  test -d "$fixture/.Trash/ProjWithBuild"
assert_true ".xcodeproj container preserved" \
  test -d "$fixture/.Trash/XcApp/XcApp.xcodeproj"
assert_true ".xcworkspace container preserved" \
  test -d "$fixture/.Trash/WsApp/App.xcworkspace"
assert_true "marker within 3 levels preserved" \
  test -d "$fixture/.Trash/DeepProj"
assert_false "marker deeper than 3 levels not detected (documented limit)" \
  test -e "$fixture/.Trash/TooDeep"
assert_log_contains "protected items logged" "PROTECTED in Trash"

section "log retention respects the configured period"
new_fixture
make_old_file "$fixture/Library/Logs/aged-40d.log" 40
make_old_file "$fixture/Library/Logs/aged-10d.log" 10
run_script
assert_false "40-day-old log deleted (retention 30)" \
  test -e "$fixture/Library/Logs/aged-40d.log"
assert_true "10-day-old log kept (retention 30)" \
  test -f "$fixture/Library/Logs/aged-10d.log"

new_fixture
make_old_file "$fixture/Library/Logs/aged-10d.log" 10
run_script CLEANUP_LOG_RETENTION_DAYS=5
assert_false "10-day-old log deleted (retention 5)" \
  test -e "$fixture/Library/Logs/aged-10d.log"
assert_true "own log survives its own run" test -f "$(fixture_log)"

section "no eligible cleanup targets"
new_fixture
/bin/rm -rf "$fixture/Library/Application Support" \
  "$fixture/Library/Developer" "$fixture/Library/Caches" "$fixture/.Trash"
run_script CLEANUP_PATH_OVERRIDE="$emptybin"
assert_status "exits 0" 0
assert_true "nothing-to-clean notification sent" \
  file_contains "$state/notifications.log" "No eligible cleanup targets"
assert_false "no confirmation dialog was shown" \
  file_contains "$state/dialogs.log" "kind=confirm"

section "action menu"
new_fixture
print -r -- "junk" > "$fixture/.Trash/file.txt"
run_script MOCK_MENU_CHOICE="Cancel"
assert_status "cancel exits 0" 0
assert_true "menu dialog was shown" file_contains "$state/dialogs.log" "kind=menu"
assert_false "no confirmation dialog after cancel" \
  file_contains "$state/dialogs.log" "kind=confirm"
assert_true "Trash untouched" test -f "$fixture/.Trash/file.txt"
assert_true "no quit requests sent" test ! -e "$state/quits.log"
assert_log_contains "cancel logged" "Final status: canceled"

new_fixture
print -r -- "junk" > "$fixture/.Trash/file.txt"
run_script MOCK_MENU_MODE="timeout"
assert_status "timeout exits 0" 0
assert_true "Trash untouched after menu timeout" test -f "$fixture/.Trash/file.txt"
assert_log_contains "menu timeout cancels" "Final status: canceled"

new_fixture
print -r -- "junk" > "$fixture/.Trash/file.txt"
run_script MOCK_MENU_MODE="error"
assert_status "AppleScript error exits 0" 0
assert_true "Trash untouched after menu error" test -f "$fixture/.Trash/file.txt"
assert_log_contains "menu error cancels" "Final status: canceled"

new_fixture
print -r -- "junk" > "$fixture/.Trash/file.txt"
run_script -- --cleanup
assert_status "--cleanup exits 0" 0
assert_false "menu skipped with --cleanup" \
  file_contains "$state/dialogs.log" "kind=menu"
assert_true "confirmation dialog shown" \
  file_contains "$state/dialogs.log" "kind=confirm"
assert_false "Trash emptied" test -e "$fixture/.Trash/file.txt"
assert_log_contains "cleanup completed" "Final status: completed"

new_fixture
run_script -- --help >/dev/null 2>&1
assert_status "--help exits 0" 0
assert_false "--help does nothing else" test -e "$(fixture_log)"
new_fixture
run_script -- --bogus >/dev/null 2>&1
assert_status "unknown option exits 2" 2
assert_false "unknown option does nothing else" test -e "$(fixture_log)"

section "storage scan (read-only)"
new_fixture
scan_root="$fixture/scandata"
/bin/mkdir -p "$scan_root/big/nested" "$scan_root/small" "$scan_root/dir with spaces"
/bin/dd if=/dev/zero of="$scan_root/big/nested/biggest.bin" \
  bs=1048576 count=4 >/dev/null 2>&1
/bin/dd if=/dev/zero of="$scan_root/dir with spaces/medium file.bin" \
  bs=1048576 count=2 >/dev/null 2>&1
print -r -- "tiny" > "$scan_root/small/tiny.txt"
print -r -- "junk" > "$fixture/.Trash/file.txt"
print -r -- "Code" >> "$state/running"

run_script MOCK_MENU_CHOICE="Scan" CLEANUP_SCAN_ROOTS="$scan_root" \
  CLEANUP_SCAN_MIN_FILE_MB=1
assert_status "exits 0" 0
assert_true "scan report written" test -f "$(fixture_scan_report)"
assert_true "report lists folders section" \
  file_contains "$(fixture_scan_report)" "Largest folders"
assert_true "report lists files section" \
  file_contains "$(fixture_scan_report)" "Largest files"
assert_true "the scanned root, holding everything, is listed first" \
  str_eq "$(first_report_entry_after 'Largest folders')" \
  "$(printf '%10s   %s' '6.0 MB' "$scan_root")"
assert_true "folders are ranked largest to smallest" \
  listed_before "$scan_root/big/nested" "$scan_root/dir with spaces"
assert_true "smallest folder ranked last" \
  listed_before "$scan_root/dir with spaces" "$scan_root/small"
assert_true "biggest file listed first" \
  str_eq "$(first_report_entry_after 'Largest files')" \
  "$(printf '%10s   %s' '4.0 MB' "$scan_root/big/nested/biggest.bin")"
assert_true "file in a path with spaces listed" \
  file_contains "$(fixture_scan_report)" "$scan_root/dir with spaces/medium file.bin"
assert_false "files under the size floor are not listed" \
  file_contains "$(fixture_scan_report)" "tiny.txt"
assert_true "results dialog was shown" \
  file_contains "$state/dialogs.log" "kind=scan"
assert_true "results dialog received the report lines" \
  file_contains "$state/scan-items.log" "$scan_root/big/nested/biggest.bin"
assert_log_contains "scan report path logged" "Scan report:"
assert_log_contains "scan final status" "Final status: completed (scan)"

# The scan must not touch anything.
assert_false "no confirmation dialog shown" \
  file_contains "$state/dialogs.log" "kind=confirm"
assert_true "caches untouched" \
  test -f "$fixture/Library/Application Support/Code/Cache/cache file with spaces.tmp"
assert_true "Trash untouched" test -f "$fixture/.Trash/file.txt"
assert_true "scanned files untouched" \
  test -f "$scan_root/big/nested/biggest.bin"
assert_true "no quit requests sent" test ! -e "$state/quits.log"
assert_true "no package-manager commands run" test ! -e "$state/commands.log"

section "scan: --scan flag, reveal, and missing roots"
new_fixture
scan_root="$fixture/scandata"
/bin/mkdir -p "$scan_root/big"
/bin/dd if=/dev/zero of="$scan_root/big/biggest.bin" \
  bs=1048576 count=2 >/dev/null 2>&1
run_script CLEANUP_SCAN_ROOTS="$scan_root
$fixture/does-not-exist" CLEANUP_SCAN_MIN_FILE_MB=1 \
  MOCK_MENU_CHOICE="Cancel" \
  MOCK_SCAN_SELECTION="    2.0 MB   $scan_root/big/biggest.bin" \
  -- --scan
assert_status "exits 0" 0
assert_false "menu skipped with --scan" \
  file_contains "$state/dialogs.log" "kind=menu"
assert_true "missing scan root tolerated" \
  file_contains "$(fixture_scan_report)" "$scan_root/big"
assert_true "selected path revealed in Finder" \
  file_contains "$state/opened.log" "$scan_root/big/biggest.bin"
assert_log_contains "reveal logged" "Revealing in Finder:"
assert_true "revealed file untouched" test -f "$scan_root/big/biggest.bin"

new_fixture
/bin/mkdir -p "$fixture/scandata"
run_script CLEANUP_SCAN_ROOTS="$fixture/scandata" \
  MOCK_SCAN_SELECTION="── Largest folders (top 30) ──" -- --scan
assert_status "exits 0" 0
assert_true "section headings are not revealed" test ! -e "$state/opened.log"
assert_true "empty section reported" \
  file_contains "$(fixture_scan_report)" "(nothing found)"

section "installer: fresh install and schedule preservation"
new_fixture
HOME="$fixture" /bin/zsh "$install_script" --no-launchctl \
  --weekday 3 --hour 9 --minute 15 >/dev/null 2>&1
script_status=$?
plist="$fixture/Library/LaunchAgents/com.local.weekly-cleanup.plist"
installed="$fixture/.local/bin/weekly-cleanup"
pb() { /usr/libexec/PlistBuddy -c "Print :StartCalendarInterval:$1" "$plist" 2>/dev/null; }
assert_status "installer exits 0" 0
assert_true "plist installed" test -f "$plist"
assert_true "plist passes plutil -lint" /usr/bin/plutil -lint "$plist"
assert_true "cleanup script installed" test -f "$installed"
assert_true "script permissions are 700" \
  str_eq "$(/usr/bin/stat -f %Lp "$installed")" "700"
assert_true "weekday written" str_eq "$(pb Weekday)" "3"
assert_true "hour written" str_eq "$(pb Hour)" "9"
assert_true "minute written" str_eq "$(pb Minute)" "15"
assert_true "ProgramArguments points at installed script" \
  str_eq "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$plist")" \
  "$installed"

HOME="$fixture" /bin/zsh "$install_script" --no-launchctl >/dev/null 2>&1
script_status=$?
assert_status "update exits 0" 0
assert_true "weekday preserved on update" str_eq "$(pb Weekday)" "3"
assert_true "hour preserved on update" str_eq "$(pb Hour)" "9"
assert_true "minute preserved on update" str_eq "$(pb Minute)" "15"

HOME="$fixture" /bin/zsh "$install_script" --no-launchctl \
  --weekday 5 >/dev/null 2>&1
assert_true "explicit weekday overrides" str_eq "$(pb Weekday)" "5"
assert_true "unspecified hour still preserved" str_eq "$(pb Hour)" "9"
assert_true "unspecified minute still preserved" str_eq "$(pb Minute)" "15"

section "installer migrates a legacy claude-weekly-cleanup install"
new_fixture
/bin/mkdir -p "$fixture/Library/LaunchAgents" "$fixture/.local/bin"
legacy_plist="$fixture/Library/LaunchAgents/com.local.claude-weekly-cleanup.plist"
/bin/cat > "$legacy_plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.local.claude-weekly-cleanup</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key>
        <integer>2</integer>
        <key>Hour</key>
        <integer>7</integer>
        <key>Minute</key>
        <integer>45</integer>
    </dict>
</dict>
</plist>
PLIST
print -r -- "old script" > "$fixture/.local/bin/claude-weekly-cleanup"
HOME="$fixture" /bin/zsh "$install_script" --no-launchctl >/dev/null 2>&1
script_status=$?
plist="$fixture/Library/LaunchAgents/com.local.weekly-cleanup.plist"
assert_status "migration install exits 0" 0
assert_true "new plist installed" test -f "$plist"
assert_true "legacy schedule preserved: weekday" str_eq "$(pb Weekday)" "2"
assert_true "legacy schedule preserved: hour" str_eq "$(pb Hour)" "7"
assert_true "legacy schedule preserved: minute" str_eq "$(pb Minute)" "45"
assert_false "legacy plist removed" test -e "$legacy_plist"
assert_false "legacy script removed" \
  test -e "$fixture/.local/bin/claude-weekly-cleanup"
assert_true "new script installed" test -f "$fixture/.local/bin/weekly-cleanup"

section "uninstaller removes only its own files and never runs cleanup"
new_fixture
HOME="$fixture" /bin/zsh "$install_script" --no-launchctl >/dev/null 2>&1
print -r -- "log data" > "$(fixture_log)"
print -r -- "unrelated" > "$fixture/.local/bin/unrelated-tool"
print -r -- "unrelated" > "$fixture/Library/LaunchAgents/com.other.agent.plist"
print -r -- "junk" > "$fixture/.Trash/file.txt"
print -r -- "leftover" > \
  "$fixture/Library/LaunchAgents/com.local.claude-weekly-cleanup.plist"
print -r -- "leftover" > "$fixture/.local/bin/claude-weekly-cleanup"
HOME="$fixture" /bin/zsh "$uninstall_script" --no-launchctl >/dev/null 2>&1
script_status=$?
assert_status "uninstaller exits 0" 0
assert_false "plist removed" \
  test -e "$fixture/Library/LaunchAgents/com.local.weekly-cleanup.plist"
assert_false "cleanup script removed" \
  test -e "$fixture/.local/bin/weekly-cleanup"
assert_false "legacy plist leftover removed" \
  test -e "$fixture/Library/LaunchAgents/com.local.claude-weekly-cleanup.plist"
assert_false "legacy script leftover removed" \
  test -e "$fixture/.local/bin/claude-weekly-cleanup"
assert_true "log kept by default" test -f "$(fixture_log)"
assert_true "unrelated ~/.local/bin file kept" \
  test -f "$fixture/.local/bin/unrelated-tool"
assert_true "unrelated LaunchAgent kept" \
  test -f "$fixture/Library/LaunchAgents/com.other.agent.plist"
assert_true "Trash untouched (cleanup did not run)" \
  test -f "$fixture/.Trash/file.txt"

HOME="$fixture" /bin/zsh "$uninstall_script" --no-launchctl --remove-log \
  >/dev/null 2>&1
assert_false "log removed with --remove-log" test -e "$(fixture_log)"

# Summary

print -r -- ""
print -r -- "=================================================="
print -r -- "Passed: $pass_count   Failed: $fail_count"
print -r -- "=================================================="

(( fail_count == 0 )) || exit 1
exit 0
