#!/usr/bin/env bash
# Show one optional free-text prompt and echo the answer.
#
# Always succeeds and always exits: Skip, Cancel, Escape and the timeout all
# yield an empty string. The caller must treat "" as "no answer given" and
# carry on — answering is voluntary, and a dialog must never be able to block
# a timer from starting or stopping.
#
# The timeout matters for a second reason: while a dialog is open the app
# bundle is still running, and LaunchServices refuses to relaunch a running
# app. An abandoned dialog would make "time" appear broken until dismissed.
#
#   prompt.sh <question> [subtitle]
#
# This is the plain text prompt, used on every switch for the recap. It had a
# --pomodoro variant once, a three-button dialog standing in for the compiled
# helper's checkbox; it went when pomodoro mode stopped pretending to work
# without that helper. Nothing here is a fallback for anything any more.

QUESTION="${1:-}"
SUBTITLE="${2:-}"
[[ -z "$QUESTION" ]] && exit 0

TEXT="$QUESTION"
[[ -n "$SUBTITLE" ]] && TEXT="$QUESTION"$'\n\n'"$SUBTITLE"

osascript - "$TEXT" 2>/dev/null <<'APPLESCRIPT'
on run argv
    tell application "System Events"
        activate
        try
            set r to display dialog (item 1 of argv) default answer "" ¬
                with title "TimeTracker" buttons {"Skip", "Save"} ¬
                default button "Save" giving up after 120
            if gave up of r then return ""
            if button returned of r is not "Save" then return ""
            return text returned of r
        on error
            return ""
        end try
    end tell
end run
APPLESCRIPT
