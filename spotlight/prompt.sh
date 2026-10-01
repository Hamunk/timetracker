#!/usr/bin/env bash
# The dialog in front of a start, a stop or a switch. Prints one line:
#
#   prompt.sh start  <title> <subtitle> <ticked>   START<TAB><pomodoro><TAB><plan>
#   prompt.sh stop   <title> <subtitle>            STOP<TAB><recap>
#   prompt.sh switch <title> <subtitle> <from> <ticked>
#                                 SWITCH<TAB><pomodoro><TAB><recap><TAB><plan>
#
# or CANCEL, which means nothing is to happen. Cancel is the way out of a start
# and a switch; "Keep working" is the way out of a stop, because that is what
# not stopping is.
#
# The compiled helper draws the dialog when it is installed (ttprompt.swift
# documents the answers, which are these). Without it, AppleScript does, in
# the same words and with the same answers, minus the pomodoro box: no helper
# means no overlay, and no overlay means no pomodoro to offer.
#
# Every path out ends in an answer. Two minutes without one is the default
# button, never Cancel: you asked for the start or the stop, and an unanswered
# dialog must not undo that behind your back. The limit matters for a second
# reason: while a dialog is up its bundle is still running, and LaunchServices
# will not launch a running app again, so an abandoned dialog would make "time"
# look broken until it went.

kind="${1:-}"; title="${2:-}"; sub="${3:-}"
case "$kind" in
    start)  from="";       ticked="${4:-0}" ;;
    switch) from="${4:-}"; ticked="${5:-0}" ;;
    stop)   from="";       ticked=0 ;;
    *) printf 'CANCEL\n'; exit 0 ;;
esac

DATA_DIR="${TIMETRACK_DIR:-$HOME/.timetrack}"
APPS_DIR="${TIMETRACK_APPS_DIR:-$HOME/Applications/TimeTracker}"
PROMPT_APP="$APPS_DIR/Helpers.noindex/Tomat Prompt.app"
ANSWER_FILE="$DATA_DIR/.prompt-answer"

if [[ -x "$PROMPT_APP/Contents/MacOS/ttprompt" ]]; then
    rm -f "$ANSWER_FILE"
    if [[ "$kind" == "switch" ]]; then
        /usr/bin/open -W "$PROMPT_APP" --args switch "$ANSWER_FILE" "$title" "$sub" \
            "$from" "$ticked" 2>/dev/null
    else
        /usr/bin/open -W "$PROMPT_APP" --args "$kind" "$ANSWER_FILE" "$title" "$sub" \
            "$ticked" 2>/dev/null
    fi
    line=""
    IFS= read -r line < "$ANSWER_FILE" 2>/dev/null
    rm -f "$ANSWER_FILE"
    # A helper that died without answering said nothing either way. Cancel is
    # the answer that changes nothing, which is the only safe reading of
    # silence from a dialog that crashed.
    printf '%s\n' "${line:-CANCEL}"
    exit 0
fi

# ask <text> <way out> <go> — prints OK<TAB><what was typed>, or CANCEL.
ask() {
    osascript - "$1" "$2" "$3" 2>/dev/null <<'APPLESCRIPT'
on run argv
    tell application "System Events"
        activate
        try
            set r to display dialog (item 1 of argv) default answer "" ¬
                with title "Tomat" buttons {item 2 of argv, item 3 of argv} ¬
                default button 2 cancel button 1 giving up after 120
            return "OK" & tab & (text returned of r)
        on error
            return "CANCEL"
        end try
    end tell
end run
APPLESCRIPT
}

text="$title"
[[ -n "$sub" ]] && text="$title"$'\n'"$sub"
case "$kind" in
    start)
        a=$(ask "$text"$'\n\n'"Plan" Cancel Start)
        if [[ "$a" == OK$'\t'* ]]; then printf 'START\t0\t%s\n' "${a#OK$'\t'}"
        else printf 'CANCEL\n'; fi
        ;;
    stop)
        a=$(ask "$text"$'\n\n'"What did you get done?" "Keep working" Stop)
        if [[ "$a" == OK$'\t'* ]]; then printf 'STOP\t%s\n' "${a#OK$'\t'}"
        else printf 'CANCEL\n'; fi
        ;;
    switch)
        a=$(ask "$text"$'\n\n'"Done on $from" Cancel Next)
        [[ "$a" == OK$'\t'* ]] || { printf 'CANCEL\n'; exit 0; }
        b=$(ask "$text"$'\n\n'"Plan" Cancel Switch)
        [[ "$b" == OK$'\t'* ]] || { printf 'CANCEL\n'; exit 0; }
        printf 'SWITCH\t0\t%s\t%s\n' "${a#OK$'\t'}" "${b#OK$'\t'}"
        ;;
esac
