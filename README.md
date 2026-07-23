# Weekly Mac Cleanup

A confirmation-based weekly macOS cleanup tool that reclaims cache and package-manager storage while preserving Swift and Xcode project data. It covers VS Code, Claude, and Obsidian caches, npm/pip/Homebrew/pnpm/Yarn, old user logs, and the Trash — hence the general name.

- LaunchAgent label: `com.local.weekly-cleanup`
- LaunchAgent plist: `~/Library/LaunchAgents/com.local.weekly-cleanup.plist`
- Cleanup script: `~/.local/bin/weekly-cleanup`
- Log file: `~/Library/Logs/com.local.weekly-cleanup.log`

> Renamed from "Claude Cleanup for Mac users" (`com.local.claude-weekly-cleanup`).
> Running `zsh install.sh` migrates an old-name installation automatically:
> the existing schedule is preserved and the old agent and script are removed.

## How the warning dialog works

Once a week the LaunchAgent starts the script. The script first calculates
an approximate size for the selected caches, old user log files, and the
Trash, then shows a confirmation dialog that:

- Summarizes exactly what will and will not be cleaned.
- Shows the size estimate, and states that it is an estimate — package-manager
  cleanup may reclaim additional storage on top of it.
- States that the Trash will be emptied.
- Has **Cancel** as the default button. Pressing Return or Escape cancels.
- Automatically cancels after 5 minutes (300 seconds) with no response.
- Cancels if the dialog cannot be shown (AppleScript error).

**No cleanup occurs unless you explicitly click "Clean now."**

If you confirm, Visual Studio Code, Claude, and Obsidian are asked to quit
gracefully (never force-killed). If any of them is still running after 15
seconds, the entire cleanup is canceled and a notification lists the
applications that stayed open.

## What is cleaned

Only the *contents* of these directories (the directories themselves are
kept so the apps can rebuild their caches in place):

- `~/Library/Application Support/Code/{Cache, Code Cache, GPUCache}`
- `~/Library/Application Support/Claude/{vm_bundles, Cache, Code Cache, GPUCache}`
- `~/Library/Application Support/obsidian/{Cache, Code Cache, GPUCache}`

Plus:

- **npm** — `npm cache verify` (verifies and garbage-collects the cache)
- **pip** — `pip3 cache purge` (falls back to `pip cache purge`)
- **Homebrew** — `brew cleanup --prune=all` (old versions and downloads only)
- **pnpm** — `pnpm store prune` (when installed)
- **Yarn** — `yarn cache clean` (when installed)
- **User logs** — regular files in `~/Library/Logs` older than 30 days
  (configurable), with emptied subdirectories removed afterwards
- **Trash** — except items detected as Swift/Xcode projects (see below)

Missing directories and missing package managers are skipped and logged;
individual package-manager failures are logged and never abort the rest of
the cleanup.

## What is deliberately preserved

This tool **does not clean Xcode or Swift project build data.** The script
refuses to touch anything matching or contained in:

- `~/Library/Developer` (including `Xcode/DerivedData`, `Xcode/Archives`,
  `Xcode/ModuleCache.noindex`, SDKs, and simulators)
- `~/Library/Caches/org.swift.swiftpm`, `~/Library/org.swift.swiftpm`,
  `~/.swiftpm`
- Any `.build`, `DerivedData`, `SourcePackages`, `ModuleCache.noindex`, or
  `Archives` directory
- `Package.swift`, `*.xcodeproj`, `*.xcworkspace`

These protections are a hard safety guard validated *before* anything is
deleted: if a protected or overly broad path ever ends up in the target
list, the run aborts with a nonzero exit and a notification, deleting
nothing. The script never searches your home directory recursively for
these directories, and it never uses `sudo`.

Trash items are preserved when they are named `.build`, `DerivedData`,
`SourcePackages`, `ModuleCache.noindex`, or `Archives`, or when they contain
a `Package.swift`, `*.xcodeproj`, `*.xcworkspace`, or `.build` within three
directory levels (a shallow scan, to avoid slow recursion — markers buried
deeper than that are not detected). Symbolic links are never followed.
Every preserved Trash item is logged.

### Why VS Code `CachedData` is excluded

`~/Library/Application Support/Code/CachedData` holds pre-compiled workbench
and extension-host JavaScript. Deleting it does not free meaningful space
long-term — VS Code regenerates it — but it does make the next launch
noticeably slower. It stays.

### Why `brew autoremove` is not used

`brew autoremove` uninstalls formulas it believes are no longer needed as
dependencies. That can silently remove runtimes, SDKs, and development tools
that projects outside Homebrew's dependency graph still rely on. This tool
only runs `brew cleanup --prune=all`, which removes old versions and
downloaded bottles — never installed packages.

### Why npm uses `npm cache verify`

`npm cache clean --force` deletes the entire cache, forcing every package to
be re-downloaded. `npm cache verify` validates the cache and garbage-collects
unneeded data, reclaiming space without destroying the useful part of the
cache.

## Install or update

```bash
zsh install.sh
```

The installer creates `~/.local/bin` and `~/Library/LaunchAgents`, installs
the cleanup script with `700` permissions, generates the plist from
[launchagent/com.local.weekly-cleanup.plist.template](launchagent/com.local.weekly-cleanup.plist.template),
validates it with `plutil -lint`, unloads any existing copy, and bootstraps
the LaunchAgent. An installation under the previous
`com.local.claude-weekly-cleanup` name is migrated automatically.

**When updating an existing installation, your current schedule is
preserved** unless you pass schedule flags explicitly.

## Changing the weekday and time

The schedule uses `StartCalendarInterval` and the Mac's **local timezone**.
Weekday values:

```text
0 = Sunday
1 = Monday
2 = Tuesday
3 = Wednesday
4 = Thursday
5 = Friday
6 = Saturday
```

The default is Sunday at 18:00. Easiest way to change it — rerun the
installer with flags (it reloads the agent for you):

```bash
zsh install.sh --weekday 5 --hour 20 --minute 30
```

Or edit the plist by hand (`nano
"$HOME/Library/LaunchAgents/com.local.weekly-cleanup.plist"`).
Example: Friday at 20:30:

```xml
<key>StartCalendarInterval</key>
<dict>
    <key>Weekday</key>
    <integer>5</integer>
    <key>Hour</key>
    <integer>20</integer>
    <key>Minute</key>
    <integer>30</integer>
</dict>
```

After editing by hand, validate and reload:

```bash
PLIST="$HOME/Library/LaunchAgents/com.local.weekly-cleanup.plist" && plutil -lint "$PLIST" && { launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null; launchctl bootstrap "gui/$(id -u)" "$PLIST"; }
```

## Testing the LaunchAgent

Trigger a run immediately (the confirmation dialog still appears — nothing
is deleted unless you click "Clean now"):

```bash
launchctl kickstart -k "gui/$(id -u)/com.local.weekly-cleanup"
```

Inspect the loaded agent and verify its schedule:

```bash
launchctl print "gui/$(id -u)/com.local.weekly-cleanup"
```

## Inspecting logs

```bash
tail -n 100 "$HOME/Library/Logs/com.local.weekly-cleanup.log"
```

Each run logs: start and completion date/time, the size estimate, every path
cleaned or skipped, protected paths refused, applications asked to quit (and
any that blocked the run), package managers found or skipped, command
failures, preserved Trash items, and a final status of `completed`,
`canceled`, or `failed`. File contents are never logged.

## Uninstall

```bash
zsh uninstall.sh
```

This unloads the LaunchAgent and removes the plist and the installed script.
The log file is kept unless you pass `--remove-log`. Uninstalling never runs
the cleanup.

## Configuration

The configuration block sits at the top of
[bin/weekly-cleanup](bin/weekly-cleanup): cache paths, managed
application names, and `log_retention_days` (default 30) are all there.

Opt-in extras (off by default): additional cache directories can be supplied
via the `CLEANUP_EXTRA_CACHE_PATHS` environment variable (one absolute path
per line, e.g. through an `EnvironmentVariables` dict in the plist). Every
extra path must live under `~/Library` and pass the Swift/Xcode protection
checks, otherwise the whole run aborts before deleting anything. The cleanup
is never broadened beyond the documented targets without this explicit
opt-in.

## Tests

```bash
zsh tests/run-tests.zsh
```

The suite runs the script against throwaway fixture home directories with
`osascript`, `pgrep`, and all package managers mocked — it never touches
real user data. It covers missing directories, paths with spaces, every
protection rule, dialog cancel/timeout/error, apps refusing to quit, absent
and failing package managers, Trash protection variants, log retention,
size-estimate robustness, installer schedule preservation, and uninstaller
safety.

## Warnings and limitations

- **Deleted caches get rebuilt.** After a cleanup, applications and package
  managers may re-download or regenerate data, so first launches and first
  installs can be slower and use the network.
- **macOS permissions (TCC):**
  - Asking apps to quit uses Apple Events; macOS may show a one-time
    "wants to control" prompt, and denying it means the quit request
    silently fails (the cleanup then cancels because the app stays open).
  - Emptying `~/.Trash` from a script may require granting Full Disk Access
    to the executing context on recent macOS versions; without it, some
    Trash items may fail to delete (failures are logged, the run continues).
  - Notifications from `osascript` require notification permission for the
    executing context; if denied, the cleanup still works but completion
    notices are not shown.
- The confirmation dialog requires a logged-in GUI session; if the Mac is
  asleep at the scheduled time, launchd runs the job at the next
  opportunity.
- The size estimate is computed before confirmation, so the freed amount can
  differ from it; package-manager caches are excluded from the estimate
  entirely.
