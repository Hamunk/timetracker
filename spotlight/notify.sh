#!/usr/bin/env bash
# Show a TimeTracker notification. Message is passed via argv (never
# interpolated into the AppleScript source) so category names containing
# quotes or backslashes can't break or inject into the script.

[[ -z "${1:-}" ]] && exit 0

osascript - "$1" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
    display notification (item 1 of argv) with title "TimeTracker"
end run
APPLESCRIPT
