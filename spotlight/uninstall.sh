#!/usr/bin/env bash
# Removes the app bundles and unregisters them from LaunchServices.
# Your data in ~/.timetrack (sessions.tsv, categories.tsv, state) is NOT
# touched — pass --purge-data if you really want that gone too.

set -uo pipefail

DATA_DIR="${TIMETRACK_DIR:-$HOME/.timetrack}"
BIN_DIR="$DATA_DIR/bin"
APPS_DIR="${TIMETRACK_APPS_DIR:-$HOME/Applications/TimeTracker}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# A live pomodoro cycle dies with its tool: watcher, overlay, state file.
if [[ -f "$DATA_DIR/pomodoro" ]]; then
    IFS=$'\t' read -r _ _ _ _ _ _ wpid < "$DATA_DIR/pomodoro" 2>/dev/null || true
    [[ "${wpid:-}" =~ ^[0-9]+$ ]] && kill "$wpid" 2>/dev/null
fi
# The overlay and the Spotify agent each leave a pid behind; use it.
for PIDFILE in "$DATA_DIR/.tomato-overlay.pid" "$DATA_DIR/.tomato-spotify.pid"; do
    read -r p < "$PIDFILE" 2>/dev/null || continue
    [[ "$p" =~ ^[0-9]+$ ]] && kill "$p" 2>/dev/null
done
# Then a sweep for whatever those pids did not account for — matched by the
# path of *this* install's copy of each script, never by its bare name. A
# scratch install runs byte-identical copies of all three, and `pkill -f
# pomodoro-watch.sh` would reach across and end a real cycle that has nothing
# to do with the install being removed. pgrep patterns are extended regexes,
# so the path has to be quoted before it can be used as one.
re_quote() { printf '%s' "$1" | sed 's#[][^$.*+?(){}|\\]#\\&#g'; }
pkill -f "^$(re_quote "$BIN_DIR")/(pomodoro-watch|spotify)\.sh" 2>/dev/null
pkill -f "^$(re_quote "$APPS_DIR")/TimeTracker Prompt\.app/Contents/MacOS/ttprompt overlay" \
    2>/dev/null
rm -f "$DATA_DIR/pomodoro" "$DATA_DIR/.tomato-choice" "$DATA_DIR/.tomato-alive" \
      "$DATA_DIR/.prompt-answer" "$DATA_DIR/.tomato-audio" \
      "$DATA_DIR/.tomato-overlay.pid" \
      "$DATA_DIR/.media-stop" \
      "$DATA_DIR/.tomato-spotify" "$DATA_DIR/.tomato-spotify-want" \
      "$DATA_DIR/.tomato-spotify-cmd" "$DATA_DIR/.tomato-spotify.pid" \
      "$DATA_DIR/.tomato-spotify-played" \
      "$DATA_DIR/.tomato-reminder" "$DATA_DIR/.tomato-reminder-result" \
      "$DATA_DIR/.tomato-reminder-busy" \
      "$DATA_DIR/.paint-request.tsv" "$DATA_DIR/.paint-result.tsv" \
      "$DATA_DIR/.paint-calendars.tsv"
rm -rf "$DATA_DIR/.paint.lock"

# The calendar auto-start agent, which no longer exists but may still be loaded
# from an older install. Removing the scripts without removing this would leave
# launchd running a file that is gone, every five minutes, for ever.
# Matched by shape rather than by one exact label, so an agent registered by an
# install predating the current bundle prefix is removed too — that is the
# install most likely to still have one loaded.
for CAL_PLIST in "$HOME/Library/LaunchAgents"/*.timetracker.calendar.plist; do
    [[ -f "$CAL_PLIST" ]] || continue
    CAL_LABEL="${CAL_PLIST##*/}"; CAL_LABEL="${CAL_LABEL%.plist}"
    launchctl bootout "gui/$(id -u)/$CAL_LABEL" 2>/dev/null || \
        launchctl unload "$CAL_PLIST" 2>/dev/null || true
    rm -f "$CAL_PLIST"
done
rm -f "$DATA_DIR/.calendar-events.tsv" "$DATA_DIR/.calendar-handled" \
      "$DATA_DIR/calendar-agent.log"

if [[ -d "$APPS_DIR" ]]; then
    for app_path in "$APPS_DIR"/*.app; do
        [[ -e "$app_path" ]] || continue
        "$LSREGISTER" -u "$app_path" >/dev/null 2>&1
    done
    rm -rf "$APPS_DIR"
    printf 'Removed %s\n' "$APPS_DIR"
else
    printf 'No app bundles at %s\n' "$APPS_DIR"
fi

rm -rf "$DATA_DIR/bin"
printf 'Removed %s/bin\n' "$DATA_DIR"

if [[ "${1:-}" == "--purge-data" ]]; then
    rm -rf "$DATA_DIR"
    printf 'Purged data dir %s\n' "$DATA_DIR"
else
    printf 'Kept your logs in %s (pass --purge-data to delete them)\n' "$DATA_DIR"
fi

# Two permissions outlive the apps that used them, and macOS keeps them listed
# against names that no longer exist.
printf 'Revoke what is left in System Settings > Privacy & Security:\n'
printf '  Automation > TimeTracker Spotify     (control of Spotify)\n'
printf '  Calendars  > TimeTracker Calendar    (painting your sessions)\n'
printf '  Reminders  > TimeTracker Reminders   (break notes)\n'
