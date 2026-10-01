#!/usr/bin/env bash
# What plain `time` does:
#   running -> stop, after asking what got done ("Keep working" stops nothing)
#   idle    -> start the most recently used category, through start.sh
#
# As in start.sh, the moment the key was pressed is stamped before the dialog,
# so time spent answering never lands in the segment.

set -uo pipefail

BIN_DIR="${0%/*}"
case "$BIN_DIR" in
    /*) ;;
    *) BIN_DIR="$(cd "$BIN_DIR" && pwd)" ;;
esac

DATA_DIR="${TIMETRACK_DIR:-$HOME/.timetrack}"
STATE_FILE="$DATA_DIR/state"
CAT_FILE="$DATA_DIR/categories.tsv"

pressed_at=$(date +%s)

status=""; cur_key=""; seg_start=""; cur_plan=""
if [[ -f "$STATE_FILE" ]]; then
    IFS=$'\t' read -r status cur_key seg_start cur_plan < "$STATE_FILE" 2>/dev/null || true
fi

case "${status:-}" in
    RUNNING)
        sub=""
        [[ -n "${cur_plan:-}" ]] && sub="Planned: $cur_plan"
        if [[ "${seg_start:-}" =~ ^[0-9]+$ ]]; then
            mins=$(( (pressed_at - seg_start) / 60 ))
            if (( mins >= 60 )); then t="$(( mins / 60 ))h $(( mins % 60 ))m"; else t="${mins}m"; fi
            sub="$t${sub:+ · $sub}"
        fi
        # By its name: the key is whatever the subject was called the day it
        # was added, and may be nothing like what it is called now.
        title=$(TT_K="$cur_key" awk -F'\t' 'BEGIN { k=ENVIRON["TT_K"] }
            NR>1 && $1==k { print $2; exit }' "$CAT_FILE" 2>/dev/null)
        answer=$("$BIN_DIR/prompt.sh" stop "Stop ${title:-$cur_key}" "$sub")
        [[ "$answer" == STOP$'\t'* || "$answer" == STOP ]] || exit 0
        recap="${answer#STOP}"; recap="${recap#$'\t'}"
        msg=$("$BIN_DIR/action.sh" stop "$recap" "$pressed_at")
        "$BIN_DIR/notify.sh" "$msg"
        ;;
    *)
        # Most recently used = highest last_used_epoch, skipping the header
        # and anything hidden.
        recent=""
        if [[ -s "$CAT_FILE" ]]; then
            recent=$(awk -F'\t' 'NR>1 && NF>=4 && $4 ~ /^[0-9]+$/ && $5!="1" {print $4"\t"$1}' \
                "$CAT_FILE" | sort -k1,1nr | head -1 | cut -f2)
        fi
        if [[ -z "$recent" ]]; then
            "$BIN_DIR/notify.sh" "No subjects yet. Open Tomat to add one"
        else
            exec "$BIN_DIR/start.sh" "$recent"
        fi
        ;;
esac

exit 0
