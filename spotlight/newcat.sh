#!/usr/bin/env bash
# Adds a category. Spotlight can't pass arguments to an app, so the three
# fields are collected with sequential dialogs.
#
# Creating is all it does — the timer is not started. Start it the normal way
# ("time <key>", or the toggle), once you actually sit down to work.
#
#   key      stable id, normally the 7-character course code (BØK2100)
#   name     official course name, shown in the Spotlight title
#   keywords whatever you actually remember it by ("økstyr2")
#
# Only the key is required. Name and keywords are display/search sugar and can
# be edited any time with "time categories".

set -uo pipefail

BIN_DIR="${0%/*}"
case "$BIN_DIR" in
    /*) ;;
    *) BIN_DIR="$(cd "$BIN_DIR" && pwd)" ;;
esac

ask() {  # ask <prompt> <default>
    osascript - "$1" "$2" 2>/dev/null <<'APPLESCRIPT'
on run argv
    tell application "System Events"
        activate
        try
            set r to display dialog (item 1 of argv) default answer (item 2 of argv) ¬
                with title "TimeTracker" buttons {"Cancel", "Next"} default button "Next"
            return text returned of r
        on error
            return "««CANCEL»»"
        end try
    end tell
end run
APPLESCRIPT
}

key=$(ask "Key: a course code like TDT4100, or any short name. This is what the log stores." "")
[[ "$key" == "««CANCEL»»" || -z "$key" ]] && exit 0

name=$(ask "Name for $key (optional):" "")
[[ "$name" == "««CANCEL»»" ]] && exit 0

keywords=$(ask "Keywords to find it by, comma separated (optional):" "")
[[ "$keywords" == "««CANCEL»»" ]] && keywords=""

msg=$("$BIN_DIR/action.sh" addcat "$key" "$name" "$keywords")
"$BIN_DIR/sync-apps.sh" >/dev/null 2>&1
"$BIN_DIR/notify.sh" "$msg"
