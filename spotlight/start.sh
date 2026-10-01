#!/usr/bin/env bash
# Start a category, or switch to it.
#
#   start.sh <key>                         what a category app runs: asks first
#   start.sh <key> --answer <pomodoro 0|1> <plan> [<recap>]
#                                          what the app runs: it has asked already
#
# Ordering is deliberate:
#   1. stamp the moment the key was pressed, before any dialog
#   2. ask — Start, or Switch if another category is running — in one dialog
#      whose Cancel means nothing happens at all
#   3. start, closing the running segment (if any) at the stamped moment
#   4. arm the pomodoro watcher if the box was ticked
#
# The stamp is what lets the question come first. It used to come second: the
# timer started, a notification said so, and then a dialog asked for a plan —
# so its Skip could only mean "no plan", and there was no way to say "I didn't
# mean to start". Now nothing is written until the dialog is answered, and the
# segment still begins when the key was pressed, however long the answer took.
# The pomodoro's first work block is measured from there too.

set -uo pipefail

BIN_DIR="${0%/*}"
case "$BIN_DIR" in
    /*) ;;
    *) BIN_DIR="$(cd "$BIN_DIR" && pwd)" ;;
esac

DATA_DIR="${TIMETRACK_DIR:-$HOME/.timetrack}"
STATE_FILE="$DATA_DIR/state"
POMO_FILE="$DATA_DIR/pomodoro"
CAT_FILE="$DATA_DIR/categories.tsv"

# Only for the checkbox's starting position — see below.
. "$BIN_DIR/settings.sh"

key="${1:-}"
[[ -z "$key" ]] && exit 0

pressed_at=$(date +%s)

status=""; cur_key=""; seg_start=""; cur_plan=""
if [[ -f "$STATE_FILE" ]]; then
    IFS=$'\t' read -r status cur_key seg_start cur_plan < "$STATE_FILE" 2>/dev/null || true
fi
switching=0
[[ "${status:-}" == "RUNNING" && -n "${cur_key:-}" && "$cur_key" != "$key" ]] && switching=1

# What a key is called, then a tab and its code. The key is never shown: it
# is whatever the subject was called the day it was added. The dialog said
# "Start med5" over the name, which with three subjects in med5 was three
# dialogs nobody could tell apart; it says "Start patologi" over "med5" now.
cat_title() {
    TT_K="$1" awk -F'\t' 'BEGIN { k=ENVIRON["TT_K"] }
        NR>1 && $1==k { print ($2 != "" ? $2 : $1) "\t" $6; exit }' "$CAT_FILE" 2>/dev/null
}
IFS=$'\t' read -r title code <<< "$(cat_title "$key")"
title="${title:-$key}"
cur_title=""
if (( switching )); then
    IFS=$'\t' read -r cur_title _ <<< "$(cat_title "$cur_key")"
    cur_title="${cur_title:-$cur_key}"
fi

pomodoro=0; plan=""; recap=""
if [[ "${2:-}" == "--answer" ]]; then
    [[ "${3:-}" == "1" ]] && pomodoro=1
    plan="${4:-}"
    recap="${5:-}"
else
    # pomodoro_default only decides where the checkbox starts. The box is
    # always there, and nothing arms a cycle except a ticked box on a dialog
    # somebody answered.
    ticked=0
    [[ "$(tt_setting pomodoro_default)" == "on" ]] && ticked=1
    sub="${code:-}"
    if (( switching )); then
        [[ -n "${cur_plan:-}" ]] && sub="${sub:+$sub · }Planned for $cur_title: $cur_plan"
        answer=$("$BIN_DIR/prompt.sh" switch "Switch to $title" "$sub" "$cur_title" "$ticked")
    else
        answer=$("$BIN_DIR/prompt.sh" start "Start $title" "$sub" "$ticked")
    fi
    # Split on US, not on the tab: tab is IFS whitespace, and read collapses
    # a run of it, so an empty recap would hand the plan to the recap.
    IFS=$'\037' read -r verb f1 f2 f3 <<< "${answer//$'\t'/$'\037'}"
    case "${verb:-}" in
        START)  pomodoro="${f1:-0}"; plan="${f2:-}" ;;
        SWITCH) pomodoro="${f1:-0}"; recap="${f2:-}"; plan="${f3:-}" ;;
        *)      exit 0 ;;
    esac
fi

msg=$("$BIN_DIR/action.sh" "start:$key" "$plan" "$recap" "$pressed_at")
[[ "${2:-}" == "--answer" ]] || "$BIN_DIR/notify.sh" "$msg"

# --- arm the pomodoro cycle --------------------------------------------------
# The watcher owns the cycle from here. It writes the pomodoro file itself
# (with its own pid), so all this does is retire any previous watcher and
# hand over the segment identity. Only armed if the timer just started is
# the one running: a stop or a switch in the meantime wins.

if [[ "$pomodoro" == "1" ]]; then
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
