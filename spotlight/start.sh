#!/usr/bin/env bash
# Prompted start/switch — what a category app runs.
#
#   start.sh <key>
#
# Ordering is deliberate:
#   1. stamp the moment the key was pressed, before any dialog
#   2. if a timer is running, ask what that session ended up being
#   3. start (closing the old segment at the stamped moment)
#   4. notify, so there's feedback before the second dialog
#   5. ask what this session is for — and whether to run it in pomodoro mode
#      (the box starts ticked iff the pomodoro_default setting says so)
#   6. attach the plan; arm the pomodoro watcher if the box was ticked
#
# The timer therefore starts at step 3 regardless of how long the prompts take,
# and the intent lands a few seconds later. Both answers are voluntary; an
# empty answer is stored as empty and nothing is blocked. The pomodoro work
# session is measured from the timer's start (pressed_at), not from when the
# prompt is answered.

set -uo pipefail

BIN_DIR="${0%/*}"
case "$BIN_DIR" in
    /*) ;;
    *) BIN_DIR="$(cd "$BIN_DIR" && pwd)" ;;
esac

DATA_DIR="${TIMETRACK_DIR:-$HOME/.timetrack}"
STATE_FILE="$DATA_DIR/state"
POMO_FILE="$DATA_DIR/pomodoro"
ANSWER_FILE="$DATA_DIR/.prompt-answer"
APPS_DIR="${TIMETRACK_APPS_DIR:-$HOME/Applications/TimeTracker}"
PROMPT_APP="$APPS_DIR/TimeTracker Prompt.app"

# Only for the checkbox's starting position — see below.
. "$BIN_DIR/settings.sh"

key="${1:-}"
[[ -z "$key" ]] && exit 0

pressed_at=$(date +%s)

status=""; cur_key=""; seg_start=""; cur_plan=""
if [[ -f "$STATE_FILE" ]]; then
    IFS=$'\t' read -r status cur_key seg_start cur_plan < "$STATE_FILE" 2>/dev/null || true
fi

recap=""
if [[ "${status:-}" == "RUNNING" && -n "${cur_key:-}" && "$cur_key" != "$key" ]]; then
    sub=""
    [[ -n "${cur_plan:-}" ]] && sub="You planned: $cur_plan"
    recap=$("$BIN_DIR/prompt.sh" "Wrapping up $cur_key. What did you work on?" "$sub")
fi

msg=$("$BIN_DIR/action.sh" "start:$key" "" "$recap" "$pressed_at")
"$BIN_DIR/notify.sh" "$msg"

# --- plan prompt, with the pomodoro checkbox ---------------------------------
# The Swift helper shows a real checkbox and writes its answer to a file
# ("POMODORO<TAB><text>" or "<TAB><text>") because stdout of an open'ed app
# isn't capturable. Skip/Esc/timeout write an empty answer with the flag off.
#
# Without the helper there is no checkbox and no pomodoro: the plan prompt
# still appears as plain text (its answer carries no tab, which the parser
# below reads as "no flag"), and the cycle is simply not offered. There used
# to be a three-button dialog standing in for the checkbox, but a tomato
# needs the overlay the same helper provides — offering the tick without it
# only promised a cycle that would cancel itself seconds later.
#
# pomodoro_default only decides where the checkbox starts. Skipping the
# prompt still means no cycle, whatever the setting says: an unanswered
# dialog is not consent, and the timer itself is unaffected either way.

ticked=0
[[ "$(tt_setting pomodoro_default)" == "on" ]] && ticked=1

flagged=""
if [[ -x "$PROMPT_APP/Contents/MacOS/ttprompt" ]]; then
    rm -f "$ANSWER_FILE"
    /usr/bin/open -W "$PROMPT_APP" --args prompt \
        "What are you planning to work on?" "$key (optional)" "$ANSWER_FILE" \
        "$ticked" 2>/dev/null || true
    if [[ -f "$ANSWER_FILE" ]]; then
        IFS= read -r flagged < "$ANSWER_FILE" || true
        rm -f "$ANSWER_FILE"
    fi
else
    flagged=$("$BIN_DIR/prompt.sh" \
        "What are you planning to work on?" "$key (optional)")
fi

pomodoro=0
plan="$flagged"
if [[ "$flagged" == POMODORO$'\t'* ]]; then
    pomodoro=1
    plan="${flagged#POMODORO$'\t'}"
elif [[ "$flagged" == $'\t'* ]]; then
    plan="${flagged#$'\t'}"
fi

[[ -n "$plan" ]] && "$BIN_DIR/action.sh" plan "$plan" >/dev/null 2>&1

# --- arm the pomodoro cycle --------------------------------------------------
# The watcher owns the cycle from here. It writes the pomodoro file itself
# (with its own pid), so all this does is retire any previous watcher and
# hand over the segment identity. Only armed if the timer we started is
# still the one running — a stop or switch during the prompt wins.

if (( pomodoro )); then
    st=""; k2=""; seg2=""
    IFS=$'\t' read -r st k2 seg2 _ < "$STATE_FILE" 2>/dev/null || true
    if [[ "${st:-}" == "RUNNING" && "${k2:-}" == "$key" && "${seg2:-}" =~ ^[0-9]+$ ]]; then
        if [[ -f "$POMO_FILE" ]]; then
            IFS=$'\t' read -r _ _ _ _ _ _ old_pid < "$POMO_FILE" 2>/dev/null || true
            [[ "${old_pid:-}" =~ ^[0-9]+$ ]] && kill "$old_pid" 2>/dev/null
        fi
        nohup "$BIN_DIR/pomodoro-watch.sh" "$key" "$seg2" >/dev/null 2>&1 &
    fi
fi

exit 0
