#!/usr/bin/env bash
# Smart toggle — what plain `time` in Spotlight does.
#   RUNNING -> stop  (asks what you worked on)
#   idle    -> start the most recently used category (asks what you're planning)
#
# As in start.sh, the moment the key was pressed is stamped before any dialog,
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
        [[ -n "${cur_plan:-}" ]] && sub="You planned: $cur_plan"
        recap=$("$BIN_DIR/prompt.sh" "What did you work on?" "$sub")
        msg=$("$BIN_DIR/action.sh" stop "$recap" "$pressed_at")
        "$BIN_DIR/notify.sh" "$msg"
        ;;
    *)
        # Most recently used category = highest last_used_epoch. 5 columns now:
        # key, name, keywords, last_used, hidden — skip the header and anything
        # hidden, take the key.
        recent=""
        if [[ -s "$CAT_FILE" ]]; then
            recent=$(awk -F'\t' 'NR>1 && NF>=4 && $4 ~ /^[0-9]+$/ && $5!="1" {print $4"\t"$1}' \
                "$CAT_FILE" | sort -k1,1nr | head -1 | cut -f2)
        fi
        if [[ -z "$recent" ]]; then
            "$BIN_DIR/notify.sh" "No categories yet. Use \"${TIMETRACK_VERB:-time} new\" to create one"
        else
            # Same flow as a category app, prompts included.
            exec "$BIN_DIR/start.sh" "$recent"
        fi
        ;;
esac

exit 0
