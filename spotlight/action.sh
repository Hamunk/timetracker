#!/usr/bin/env bash
# TimeTracker action script — the only place that writes state/log data.
#
#   action.sh start:<key> [plan] [recap_of_previous] [at_epoch]
#   action.sh stop [recap] [at_epoch]
#   action.sh plan <text>                    (attach intent to a running timer)
#   action.sh addcat <key> <name> <keywords>
#   action.sh hidecat <key> on|off           (keep the history, drop the app)
#   action.sh delcat <key>                   (row moves to categories.deleted.tsv)
#   action.sh editsession <sel_start_iso> <sel_dur> <sel_key> \
#                         <start_epoch> <end_epoch> <key> [plan] [recap]
#   action.sh delsession  <sel_start_iso> <sel_dur> <sel_key>
#   action.sh setconf <key> <value>          (the only writer of settings.tsv)
#   action.sh addplaylist <name> <link>      (break-menu Spotify playlists)
#   action.sh delplaylist <uri>
#   action.sh workplaylist <uri>|-           (the one playlist kept for work)
#   action.sh setremlist <name>              (which Reminders list a break note goes to)
#   action.sh setpaintcal <name>|-           (which calendar the log is painted onto)
#   action.sh setupdone                      (the first-run setup has been completed)
#
# The optional [at_epoch] exists because the prompts are shown *before* the
# action lands: the caller stamps the moment you actually pressed the key, so
# time spent typing an answer (or ignoring the dialog for two minutes) never
# leaks into the segment.
#
# Categories are identified by a stable key (a course code like BØK2100).
# Names and keywords are display/search concerns and can change freely without
# touching a single logged row — that's the point of having a key at all.
#
# The same key indirection is why a category can be retired at all: hidecat
# takes it out of the launcher and the pickers while every logged row keeps
# pointing at the key, and delcat only removes the *label*, never the hours.
#
# Every run holds an exclusive lock for the whole read-modify-write cycle, so
# firing two actions at once (easy by double-tapping Enter in Spotlight)
# can't log the same segment twice.
#
# editsession / delsession are the only operations that touch an already-closed
# row, and they exist because forgetting to stop the timer is a real failure
# mode. A row is addressed by (start_iso, duration_sec, category) rather than by
# line number: line numbers go stale the moment anything else appends, whereas
# that triple is what the caller actually saw. If it doesn't match exactly one
# row, nothing is written.

set -euo pipefail

DATA_DIR="${TIMETRACK_DIR:-$HOME/.timetrack}"
STATE_FILE="$DATA_DIR/state"
CAT_FILE="$DATA_DIR/categories.tsv"
CAT_TRASH_FILE="$DATA_DIR/categories.deleted.tsv"
SESS_FILE="$DATA_DIR/sessions.tsv"
TRASH_FILE="$DATA_DIR/sessions.deleted.tsv"
SETTINGS_FILE="$DATA_DIR/settings.tsv"
POMO_FILE="$DATA_DIR/pomodoro"
# The break menu's two lists. Neither is settings.tsv material: settings.sh's
# table holds numbers and on/off switches, and these are rows and free text.
# They follow categories.tsv instead — a header line, tab separated, written
# only from here.
PLAYLIST_FILE="$DATA_DIR/spotify-playlists.tsv"
REMLIST_FILE="$DATA_DIR/reminders-list"
PAINTCAL_FILE="$DATA_DIR/paint-calendar"
LOCK_DIR="$DATA_DIR/.lock"
GUARD_SECS=$((8 * 3600))
MAX_EDIT_SECS=$((24 * 3600))   # ceiling for a hand-edited segment
LOCK_STALE_SECS=30
MIN_EPOCH=1577836800   # 2020-01-01; below this is corruption, not a timestamp
# The 5th column is "1" when the category is hidden, empty otherwise. Rows
# written before it existed simply have four fields, which every reader here
# already tolerates — a short row means "not hidden".
CAT_HEADER=$'key\tname\tkeywords\tlast_used_epoch\thidden'
# role is "work" on at most one row and empty on the rest. A short row (no
# third field) means "not the work playlist", the same tolerance categories.tsv
# extends to its hidden column.
PLAYLIST_HEADER=$'uri\tname\trole'
MAX_PLAYLISTS=60
# settings.sh (the settings defaults/ranges table) lives next to this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$DATA_DIR"
[[ -f "$STATE_FILE" ]] || : > "$STATE_FILE"
[[ -f "$CAT_FILE" ]] || printf '%s\n' "$CAT_HEADER" > "$CAT_FILE"
SESS_HEADER=$'start_iso\tend_iso\tduration_sec\tcategory\tnote\tplan\trecap\tpomodoros\tbreak_overrun_sec'
[[ -f "$SESS_FILE" ]] || printf '%s\n' "$SESS_HEADER" > "$SESS_FILE"

# --- locking ----------------------------------------------------------------
# mkdir is atomic everywhere we care about, so it's the portable mutex here
# (macOS has no flock(1)).

acquire_lock() {
    local tries=0 lock_mtime age
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        lock_mtime=$(stat -f %m "$LOCK_DIR" 2>/dev/null || printf '0')
        age=$(( $(date +%s) - lock_mtime ))
        if (( age > LOCK_STALE_SECS )); then
            rm -rf "$LOCK_DIR" 2>/dev/null || true
            continue
        fi
        tries=$(( tries + 1 ))
        if (( tries > 100 )); then
            printf 'TimeTracker is busy. Try again\n'
            exit 1
        fi
        sleep 0.05
    done
    trap 'rm -rf "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM
}

acquire_lock

# --- helpers ----------------------------------------------------------------

fmtdur() {
    local s=$1 m h
    if (( s < 60 )); then printf '%ds' "$s"; return; fi
    m=$(( s / 60 )); h=$(( m / 60 )); m=$(( m % 60 ))
    if (( h > 0 )); then printf '%dh %dm' "$h" "$m"; else printf '%dm' "$m"; fi
}

# Single-line, tab-free text. Tabs and newlines would break the TSV rows.
sanitize_field() {
    printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177' | \
        sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | cut -c1-500
}

is_valid_epoch() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= MIN_EPOCH ))
}

# Same environment-not-(-v) rule as the writers below: a key looked up through
# -v would have its backslash escapes expanded and stop matching its own row.
cat_exists() {
    TT_K="$1" awk -F'\t' 'BEGIN { k=ENVIRON["TT_K"] }
        NR>1 && $1==k {found=1; exit} END{exit !found}' "$CAT_FILE"
}

cat_name() {
    TT_K="$1" awk -F'\t' 'BEGIN { k=ENVIRON["TT_K"] }
        NR>1 && $1==k {print $2; exit}' "$CAT_FILE"
}

# What the user sees in notifications: "BØK2100 (Bærekraftig økonomistyring 2)"
label() {
    local n; n=$(cat_name "$1")
    if [[ -n "$n" ]]; then printf '%s (%s)' "$1" "$n"; else printf '%s' "$1"; fi
}

LAST_DUR=0
# Set by anything that changes a logged row. Read once at the very end, where
# it detaches a calendar repaint — see the note above the exit.
LOG_CHANGED=0

close_segment() {
    local key="$1" start_ep="$2" end_ep="$3" note="$4"
    local plan="${5:-}" recap="${6:-}" start_iso end_iso dur
    local pomos="" overrun=""
    # Clock moved backwards (NTP, timezone edit). Never write a negative
    # duration — it would silently poison every total.
    if (( end_ep < start_ep )); then
        end_ep="$start_ep"
        note="${note:+$note }CLOCKSKEW"
    fi
    # A live pomodoro cycle for exactly this segment flushes its counts into
    # the row and is consumed. Anything else (stale cycle, other segment)
    # is left for the watcher to cancel; the columns stay empty.
    if [[ -f "$POMO_FILE" ]]; then
        local p_phase p_key p_seg p_target p_count p_over p_pid
        IFS=$'\t' read -r p_phase p_key p_seg p_target p_count p_over p_pid \
            < "$POMO_FILE" 2>/dev/null || true
        if [[ "${p_key:-}" == "$key" && "${p_seg:-}" == "$start_ep" && \
              "${p_count:-}" =~ ^[0-9]+$ && "${p_over:-}" =~ ^[0-9]+$ ]]; then
            pomos="$p_count" ; overrun="$p_over"
            rm -f "$POMO_FILE"
        fi
    fi
    start_iso=$(date -r "$start_ep" +"%Y-%m-%dT%H:%M:%S%z")
    end_iso=$(date -r "$end_ep" +"%Y-%m-%dT%H:%M:%S%z")
    dur=$(( end_ep - start_ep ))
    LAST_DUR=$dur
    printf '%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$start_iso" "$end_iso" "$dur" "$key" "$note" "$plan" "$recap" \
        "$pomos" "$overrun" >> "$SESS_FILE"
    LOG_CHANGED=1
}

write_state() {
    local tmp; tmp="$(mktemp "$DATA_DIR/.state.XXXXXX")"
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" > "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

clear_state() {
    local tmp; tmp="$(mktemp "$DATA_DIR/.state.XXXXXX")"
    : > "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

# Keys, names and keywords reach awk through the environment, never through -v:
# awk expands backslash escapes in a -v assignment, so a name containing a
# literal "\t" would turn into a tab and split the row in two.
bump_category() {
    local key="$1" now="$2" tmp
    tmp="$(mktemp "$DATA_DIR/.categories.XXXXXX")"
    TT_K="$key" awk -F'\t' -v OFS='\t' -v now="$now" -v hdr="$CAT_HEADER" '
        BEGIN { k=ENVIRON["TT_K"] }
        NR==1 { print hdr; next }
        NF>=4 && $1!="" && $4 ~ /^[0-9]+$/ {
            if ($1==k) { $4=now; $5=""; seen=1 }
            print
        }
        END { if (!seen) print k, "", "", now }
    ' "$CAT_FILE" > "$tmp"
    mv -f "$tmp" "$CAT_FILE"
}

add_category() {
    local key="$1" name="$2" keywords="$3" now="$4" tmp
    tmp="$(mktemp "$DATA_DIR/.categories.XXXXXX")"
    TT_K="$key" TT_N="$name" TT_KW="$keywords" \
    awk -F'\t' -v OFS='\t' -v now="$now" -v hdr="$CAT_HEADER" '
        BEGIN { k=ENVIRON["TT_K"]; n=ENVIRON["TT_N"]; kw=ENVIRON["TT_KW"] }
        NR==1 { print hdr; next }
        NF>=4 && $1!="" && $4 ~ /^[0-9]+$/ {
            if ($1==k) { $2=n; $3=kw; $4=now; $5=""; seen=1 }
            print
        }
        END { if (!seen) print k, n, kw, now }
    ' "$CAT_FILE" > "$tmp"
    mv -f "$tmp" "$CAT_FILE"
}

# Hiding is a flag, not a removal: the row stays, so the name still resolves
# for every session already logged against the key.
set_cat_hidden() {
    local key="$1" flag="$2" tmp
    tmp="$(mktemp "$DATA_DIR/.categories.XXXXXX")"
    TT_K="$key" awk -F'\t' -v OFS='\t' -v h="$flag" -v hdr="$CAT_HEADER" '
        BEGIN { k=ENVIRON["TT_K"] }
        NR==1 { print hdr; next }
        NF>=4 && $1!="" && $4 ~ /^[0-9]+$/ {
            if ($1==k) $5=h
            print
        }
    ' "$CAT_FILE" > "$tmp"
    mv -f "$tmp" "$CAT_FILE"
}

# Same bargain as delete_session: the row is moved, not shredded. Nothing in
# sessions.tsv is touched — the hours survive, only their label is retired.
delete_category() {
    local key="$1" tmp
    [[ -f "$CAT_TRASH_FILE" ]] || printf '%s\n' "$CAT_HEADER" > "$CAT_TRASH_FILE"
    tmp="$(mktemp "$DATA_DIR/.categories.XXXXXX")"
    TT_K="$key" TT_TRASH="$CAT_TRASH_FILE" awk -F'\t' -v OFS='\t' -v hdr="$CAT_HEADER" '
        BEGIN { k=ENVIRON["TT_K"]; trash=ENVIRON["TT_TRASH"] }
        NR==1 { print hdr; next }
        NF>=4 && $1!="" && $4 ~ /^[0-9]+$/ {
            if ($1==k) { print >> trash; next }
            print
        }
    ' "$CAT_FILE" > "$tmp"
    mv -f "$tmp" "$CAT_FILE"
}

# The only writer of settings.tsv (key<TAB>value, no header). Same atomic
# rewrite pattern as add_category. Other keys — including ones this version
# doesn't know about — and unparseable lines are preserved as they are.
write_setting() {
    local key="$1" value="$2" tmp
    tmp="$(mktemp "$DATA_DIR/.settings.XXXXXX")"
    if [[ -f "$SETTINGS_FILE" ]]; then
        TT_K="$key" TT_V="$value" awk -F'\t' -v OFS='\t' '
            BEGIN { k=ENVIRON["TT_K"]; v=ENVIRON["TT_V"] }
            $1==k { if (!seen) print k, v; seen=1; next }
            { print }
            END { if (!seen) print k, v }
        ' "$SETTINGS_FILE" > "$tmp"
    else
        printf '%s\t%s\n' "$key" "$value" > "$tmp"
    fi
    mv -f "$tmp" "$SETTINGS_FILE"
}

# --- the break menu's lists -------------------------------------------------

# A Spotify link as a URI, or nothing at all.
#
# The charset is the security control, not a tidiness one: this string ends up
# in an Apple Event, and although spotify.sh passes it as argv rather than
# splicing it into the script, a URI that cannot contain a quote, a backslash
# or a space is what makes that belt-and-braces rather than belt-alone. Every
# form Spotify's own "Copy link" produces is accepted, including the /intl-xx/
# prefix it adds when the app is not in English.
normalize_spotify_uri() {
    local in="$1" type id
    in="${in%%$'\n'*}"
    in="${in## }" ; in="${in%% }"
    case "$in" in
        spotify:*)
            type="${in#spotify:}" ; type="${type%%:*}"
            id="${in##*:}"
            ;;
        https://open.spotify.com/*)
            local path="${in#https://open.spotify.com/}"
            path="${path%%\?*}"          # drop ?si=... share tracking
            # An /intl-no/ style locale segment sits before the type.
            case "$path" in intl-*/*) path="${path#*/}" ;; esac
            type="${path%%/*}"
            id="${path#*/}" ; id="${id%%/*}"
            ;;
        *) return 1 ;;
    esac
    case "$type" in
        playlist|album|artist|track|show|episode) ;;
        *) return 1 ;;
    esac
    [[ "$id" =~ ^[A-Za-z0-9]{16,40}$ ]] || return 1
    printf 'spotify:%s:%s\n' "$type" "$id"
}

playlist_exists() {
    [[ -f "$PLAYLIST_FILE" ]] || return 1
    TT_U="$1" awk -F'\t' 'BEGIN { u=ENVIRON["TT_U"] }
        NR>1 && $1==u {found=1; exit} END{exit !found}' "$PLAYLIST_FILE"
}

count_playlists() {
    [[ -f "$PLAYLIST_FILE" ]] || { printf '0\n'; return; }
    awk 'NR>1 && NF' "$PLAYLIST_FILE" | wc -l | tr -d ' '
}

add_playlist() {
    local uri="$1" name="$2"
    [[ -f "$PLAYLIST_FILE" ]] || printf '%s\n' "$PLAYLIST_HEADER" > "$PLAYLIST_FILE"
    printf '%s\t%s\t\n' "$uri" "$name" >> "$PLAYLIST_FILE"
}

delete_playlist() {
    local uri="$1" tmp
    [[ -f "$PLAYLIST_FILE" ]] || return 0
    tmp="$(mktemp "$DATA_DIR/.playlists.XXXXXX")"
    TT_U="$uri" awk -F'\t' 'BEGIN { u=ENVIRON["TT_U"] }
        NR==1 { print; next }
        $1==u { next }
        { print }' "$PLAYLIST_FILE" > "$tmp"
    mv -f "$tmp" "$PLAYLIST_FILE"
}

# Exactly one row may carry "work", so this clears the column before setting
# it. "-" clears it everywhere and leaves nothing marked, which is the honest
# state for someone who does not keep a work playlist.
set_work_playlist() {
    local uri="$1" tmp
    [[ -f "$PLAYLIST_FILE" ]] || return 0
    tmp="$(mktemp "$DATA_DIR/.playlists.XXXXXX")"
    TT_U="$uri" awk -F'\t' -v OFS='\t' 'BEGIN { u=ENVIRON["TT_U"] }
        NR==1 { print; next }
        NF==0 { next }
        { print $1, $2, ($1==u ? "work" : "") }' "$PLAYLIST_FILE" > "$tmp"
    mv -f "$tmp" "$PLAYLIST_FILE"
}

# --- editing closed rows ----------------------------------------------------

# Free text reaches awk through the environment here too, for the same reason
# the category writers above do it: -v expands backslash escapes.
#
# How many logged rows the (start_iso, duration, key) triple picks out. Anything
# other than exactly 1 means the caller's view of the log is stale — refuse.
count_sessions() {
    TT_S="$1" TT_D="$2" TT_C="$3" awk -F'\t' '
        BEGIN { s=ENVIRON["TT_S"]; d=ENVIRON["TT_D"]; c=ENVIRON["TT_C"] }
        NR>1 && $1==s && $3==d && $4==c { n++ }
        END { print n+0 }
    ' "$SESS_FILE"
}

# How many logged rows carry a key — what retiring a category would orphan.
count_key_sessions() {
    TT_C="$1" awk -F'\t' 'BEGIN { c=ENVIRON["TT_C"] }
        NR>1 && $4==c { n++ } END { print n+0 }' "$SESS_FILE"
}

# Deleted rows are moved, not shredded: a mis-click shouldn't be the one
# operation in this tool that loses data for good.
delete_session() {
    local tmp
    [[ -f "$TRASH_FILE" ]] || printf '%s\n' "$SESS_HEADER" > "$TRASH_FILE"
    tmp="$(mktemp "$DATA_DIR/.sessions.XXXXXX")"
    TT_S="$1" TT_D="$2" TT_C="$3" TT_TRASH="$TRASH_FILE" awk -F'\t' '
        BEGIN { s=ENVIRON["TT_S"]; d=ENVIRON["TT_D"]; c=ENVIRON["TT_C"]
                trash=ENVIRON["TT_TRASH"] }
        NR>1 && !done && $1==s && $3==d && $4==c { print >> trash; done=1; next }
        { print }
    ' "$SESS_FILE" > "$tmp"
    mv -f "$tmp" "$SESS_FILE"
    LOG_CHANGED=1
}

edit_session() {
    local ns="$4" ne="$5" start_iso end_iso dur tmp
    start_iso=$(date -r "$ns" +"%Y-%m-%dT%H:%M:%S%z")
    end_iso=$(date -r "$ne" +"%Y-%m-%dT%H:%M:%S%z")
    dur=$(( ne - ns ))
    tmp="$(mktemp "$DATA_DIR/.sessions.XXXXXX")"
    # The note becomes EDITED, which is also how an AUTOCLOSED row leaves the
    # dashboard's "needs attention" list once you've actually fixed it.
    # The pomodoro columns ($8, $9) ride through unchanged — the edit form
    # doesn't expose them, so an edit must never wipe them.
    TT_S="$1" TT_D="$2" TT_C="$3" TT_SI="$start_iso" TT_EI="$end_iso" \
    TT_DU="$dur" TT_K="$6" TT_PL="$7" TT_RC="$8" awk -F'\t' -v OFS='\t' '
        BEGIN { s=ENVIRON["TT_S"]; d=ENVIRON["TT_D"]; c=ENVIRON["TT_C"] }
        NR>1 && !done && $1==s && $3==d && $4==c {
            print ENVIRON["TT_SI"], ENVIRON["TT_EI"], ENVIRON["TT_DU"],
                  ENVIRON["TT_K"], "EDITED", ENVIRON["TT_PL"], ENVIRON["TT_RC"],
                  $8, $9
            done=1; next
        }
        { print }
    ' "$SESS_FILE" > "$tmp"
    mv -f "$tmp" "$SESS_FILE"
    LOG_CHANGED=1
}

# --- read current state -----------------------------------------------------

query="${1:-}"
now=$(date +%s)

status="" ; cur_key="" ; seg_start="" ; cur_plan=""
# Read the plan into its own variable — without it the trailing field would be
# swallowed into seg_start and every timestamp check would fail.
IFS=$'\t' read -r status cur_key seg_start cur_plan < "$STATE_FILE" 2>/dev/null || true
status="${status:-}" ; cur_key="${cur_key:-}" ; seg_start="${seg_start:-}"
cur_plan="${cur_plan:-}"

recovered_msg=""
if [[ "$status" == "RUNNING" ]]; then
    if [[ -z "$cur_key" ]] || ! is_valid_epoch "$seg_start"; then
        recovered_msg="Discarded corrupt timer state"
        status="" ; cur_key="" ; seg_start=0
        clear_state
    fi
elif [[ -n "$status" ]]; then
    # RUNNING is the only live status. Anything else — including a PAUSED
    # line from before that state was removed — is corrupt, not a timer.
    recovered_msg="Discarded corrupt timer state"
    status="" ; cur_key="" ; seg_start=0
    clear_state
else
    status="" ; cur_key="" ; seg_start=0
fi

# --- forgot-to-stop guard ---------------------------------------------------

autoclose_msg=""
if [[ "$status" == "RUNNING" ]] && (( now - seg_start > GUARD_SECS )); then
    close_segment "$cur_key" "$seg_start" "$(( seg_start + GUARD_SECS ))" "AUTOCLOSED" \
        "$cur_plan" ""
    autoclose_msg="Auto-stopped $(label "$cur_key") after 8h (AUTOCLOSED)"
    clear_state
    status="" ; cur_key="" ; seg_start=0
fi

# --- dispatch ---------------------------------------------------------------

action_msg=""
action_rc=0

# start_key <key> <start_epoch> <plan> <recap_of_previous> <close_at>
start_key() {
    local key="$1" at="$2" plan="${3:-}" recap="${4:-}"
    local close_at="${5:-$now}" closed_msg=""
    if [[ "$status" == "RUNNING" ]]; then
        close_segment "$cur_key" "$seg_start" "$close_at" "" "$cur_plan" "$recap"
        [[ "$cur_key" != "$key" ]] && \
            closed_msg="stopped $(label "$cur_key") $(fmtdur "$LAST_DUR")"
    fi
    write_state "RUNNING" "$key" "$at" "$plan"
    bump_category "$key" "$now"
    action_msg="Started $(label "$key")"
    [[ -n "$closed_msg" ]] && action_msg="$action_msg; $closed_msg"
    # Explicit: without this the function inherits the exit status of the test
    # above, which is 1 when nothing was closed — and under `set -e` that kills
    # the script before it ever prints the notification.
    return 0
}

case "$query" in
    addcat)
        key=$(sanitize_field "${2:-}")
        name=$(sanitize_field "${3:-}")
        keywords=$(sanitize_field "${4:-}")
        if [[ -z "$key" ]]; then
            action_msg="Key cannot be empty"
        else
            add_category "$key" "$name" "$keywords" "$now"
            action_msg="Saved $(label "$key")"
        fi
        ;;
    hidecat)
        # Retire a category without touching a row of history: it drops out of
        # the launcher, the toggle and the calendar matcher, and comes back
        # with "off" exactly as it was.
        key=$(sanitize_field "${2:-}")
        want=$(sanitize_field "${3:-}")
        if [[ -z "$key" ]]; then
            action_msg="Key cannot be empty" ; action_rc=1
        elif [[ "$want" != "on" && "$want" != "off" ]]; then
            action_msg="Hidden must be on or off" ; action_rc=1
        elif ! cat_exists "$key"; then
            action_msg="Unknown category $key" ; action_rc=1
        elif [[ "$want" == "on" && "$status" == "RUNNING" && "$cur_key" == "$key" ]]; then
            action_msg="$(label "$key") is running. Stop it first" ; action_rc=1
        elif [[ "$want" == "on" ]]; then
            set_cat_hidden "$key" 1
            action_msg="Hid $(label "$key"). History kept"
        else
            set_cat_hidden "$key" ""
            action_msg="Restored $(label "$key")"
        fi
        ;;
    delcat)
        key=$(sanitize_field "${2:-}")
        if [[ -z "$key" ]]; then
            action_msg="Key cannot be empty" ; action_rc=1
        elif ! cat_exists "$key"; then
            action_msg="Unknown category $key" ; action_rc=1
        elif [[ "$status" == "RUNNING" && "$cur_key" == "$key" ]]; then
            action_msg="$(label "$key") is running. Stop it first" ; action_rc=1
        else
            # The label has to be read before the row leaves, and the count
            # before anyone can wonder where the hours went: deleting the
            # category deletes the *name*, and those rows now show the bare key.
            orphans=$(count_key_sessions "$key")
            gone=$(label "$key")
            delete_category "$key"
            action_msg="Deleted $gone"
            if (( orphans > 0 )); then
                action_msg="$action_msg. $orphans logged session(s) now show as $key"
            fi
        fi
        ;;
    start:*|switch:*)
        key=$(sanitize_field "${query#*:}")
        in_plan=$(sanitize_field "${2:-}")
        in_recap=$(sanitize_field "${3:-}")
        at="${4:-$now}"
        # The caller stamps when the key was actually pressed; anything absurd
        # falls back to now rather than being trusted.
        if ! is_valid_epoch "$at" || (( at > now )); then at="$now"; fi
        if [[ "$status" == "RUNNING" ]] && (( at < seg_start )); then at="$now"; fi

        if [[ -z "$key" ]]; then
            action_msg="Key cannot be empty"
        elif ! cat_exists "$key"; then
            action_msg="Unknown category $key. Add it with \"${TIMETRACK_VERB:-time} new\""
        else
            start_key "$key" "$at" "$in_plan" "$in_recap" "$at"
        fi
        ;;
    plan)
        # Attach intent to an already-running timer. Kept separate from start
        # so the timer begins immediately and the prompt can take its time.
        in_plan=$(sanitize_field "${2:-}")
        if [[ "$status" != "RUNNING" ]]; then
            action_msg="Nothing running to annotate"
        else
            write_state "RUNNING" "$cur_key" "$seg_start" "$in_plan"
            action_msg="Noted"
        fi
        ;;
    stop)
        in_recap=$(sanitize_field "${2:-}")
        at="${3:-$now}"
        if ! is_valid_epoch "$at" || (( at > now )); then at="$now"; fi
        if [[ "$status" == "RUNNING" ]] && (( at < seg_start )); then at="$now"; fi
        if [[ "$status" == "RUNNING" ]]; then
            close_segment "$cur_key" "$seg_start" "$at" "" "$cur_plan" "$in_recap"
            action_msg="Stopped $(label "$cur_key"), $(fmtdur "$LAST_DUR")"
        else
            action_msg="Nothing running"
        fi
        clear_state
        ;;
    editsession)
        sel_start="${2:-}" ; sel_dur="${3:-}" ; sel_key="${4:-}"
        new_start="${5:-}" ; new_end="${6:-}"
        new_key=$(sanitize_field "${7:-}")
        new_plan=$(sanitize_field "${8:-}")
        new_recap=$(sanitize_field "${9:-}")

        if [[ ! "$sel_dur" =~ ^[0-9]+$ ]] || [[ -z "$sel_start" || -z "$sel_key" ]]; then
            action_msg="Bad session selector" ; action_rc=1
        elif ! is_valid_epoch "$new_start" || ! is_valid_epoch "$new_end"; then
            action_msg="Invalid start or end time" ; action_rc=1
        elif (( new_end < new_start )); then
            action_msg="End is before start" ; action_rc=1
        elif (( new_end > now )); then
            action_msg="End is in the future" ; action_rc=1
        elif (( new_end - new_start > MAX_EDIT_SECS )); then
            action_msg="Longer than 24h. Split it instead" ; action_rc=1
        elif [[ -z "$new_key" ]] || ! cat_exists "$new_key"; then
            action_msg="Unknown category ${new_key:-(empty)}" ; action_rc=1
        elif [[ "$status" == "RUNNING" ]] && (( new_end > seg_start )); then
            # Overlapping the live segment would count the overlap twice.
            action_msg="Overlaps the running timer. Stop it first" ; action_rc=1
        elif [[ "$(count_sessions "$sel_start" "$sel_dur" "$sel_key")" != "1" ]]; then
            action_msg="Session not found or changed. Reload" ; action_rc=1
        else
            edit_session "$sel_start" "$sel_dur" "$sel_key" \
                "$new_start" "$new_end" "$new_key" "$new_plan" "$new_recap"
            action_msg="Updated $(label "$new_key"), $(fmtdur $(( new_end - new_start )))"
        fi
        ;;
    delsession)
        sel_start="${2:-}" ; sel_dur="${3:-}" ; sel_key="${4:-}"
        if [[ ! "$sel_dur" =~ ^[0-9]+$ ]] || [[ -z "$sel_start" || -z "$sel_key" ]]; then
            action_msg="Bad session selector" ; action_rc=1
        elif [[ "$(count_sessions "$sel_start" "$sel_dur" "$sel_key")" != "1" ]]; then
            action_msg="Session not found or changed. Reload" ; action_rc=1
        else
            delete_session "$sel_start" "$sel_dur" "$sel_key"
            action_msg="Deleted $(label "$sel_key"), $(fmtdur "$sel_dur")"
        fi
        ;;
    setconf)
        key=$(sanitize_field "${2:-}")
        value=$(sanitize_field "${3:-}")
        if [[ ! -r "$SCRIPT_DIR/settings.sh" ]]; then
            action_msg="settings.sh not found next to action.sh" ; action_rc=1
        else
            # Sourced, not duplicated: the defaults/ranges table lives in
            # settings.sh and nowhere else.
            # shellcheck source=settings.sh
            . "$SCRIPT_DIR/settings.sh"
            if ! tt_setting_spec "$key"; then
                action_msg="Unknown setting ${key:-(empty)}" ; action_rc=1
            elif ! tt_setting_valid "$key" "$value"; then
                # Braces are load-bearing: under the C locale (how the app
                # bundles launch), bash pulls the en dash's first byte into
                # the variable name and dies on "TT_MIN\xe2: unbound".
                if [[ -n "$TT_KEY" ]]; then range="one letter or digit, Tab or Space"
                elif [[ -n "$TT_MIN" ]]; then range="${TT_MIN} to ${TT_MAX}"
                else range="on or off"; fi
                action_msg="Invalid value for $key. Allowed: $range"
                action_rc=1
            else
                write_setting "$key" "$value"
                action_msg="Set $key = $value"
            fi
        fi
        ;;
    addplaylist)
        # <name> <link>. The link is what Spotify's "Copy link to playlist"
        # puts on the clipboard; the name is yours, because nothing local can
        # ask Spotify what a playlist is called — its scripting dictionary
        # exposes playback and the current track, and no library at all.
        pl_name=$(sanitize_field "${2:-}")
        pl_raw=$(sanitize_field "${3:-}")
        if ! pl_uri=$(normalize_spotify_uri "$pl_raw"); then
            action_msg="Not a Spotify link. Copy one from Spotify: Share, Copy link"
            action_rc=1
        elif [[ -z "$pl_name" ]]; then
            action_msg="Give the playlist a name" ; action_rc=1
        elif playlist_exists "$pl_uri"; then
            action_msg="That playlist is already in the list" ; action_rc=1
        elif (( $(count_playlists) >= MAX_PLAYLISTS )); then
            action_msg="Playlist list is full ($MAX_PLAYLISTS)" ; action_rc=1
        else
            add_playlist "$pl_uri" "$pl_name"
            action_msg="Added $pl_name"
        fi
        ;;
    delplaylist)
        pl_raw=$(sanitize_field "${2:-}")
        if ! pl_uri=$(normalize_spotify_uri "$pl_raw"); then
            action_msg="Not a Spotify link" ; action_rc=1
        elif ! playlist_exists "$pl_uri"; then
            action_msg="Playlist not in the list. Reload" ; action_rc=1
        else
            delete_playlist "$pl_uri"
            action_msg="Removed from the break menu"
        fi
        ;;
    workplaylist)
        pl_raw=$(sanitize_field "${2:-}")
        if [[ "$pl_raw" == "-" ]]; then
            set_work_playlist "-"
            action_msg="No work playlist. Break music is paused when you are back"
        elif ! pl_uri=$(normalize_spotify_uri "$pl_raw"); then
            action_msg="Not a Spotify link" ; action_rc=1
        elif ! playlist_exists "$pl_uri"; then
            action_msg="Playlist not in the list. Reload" ; action_rc=1
        else
            set_work_playlist "$pl_uri"
            action_msg="Work playlist set"
        fi
        ;;
    setremlist)
        # The Reminders list a break note lands in. Free text, so it lives in
        # its own one-line file rather than in settings.tsv, whose table only
        # knows numbers and on/off.
        #
        # The braces around every expansion next to a curly quote below are
        # load-bearing, exactly as they are in setconf: these scripts run under
        # the C locale when launched from an app bundle, where bash pulls the
        # quote's first byte into the variable name and dies on
        # "rl_name\xe2: unbound variable".
        rl_name=$(sanitize_field "${2:-}")
        if [[ -z "$rl_name" ]]; then
            action_msg="Give the list a name" ; action_rc=1
        elif (( ${#rl_name} > 60 )); then
            action_msg="List name is too long" ; action_rc=1
        else
            tmp="$(mktemp "$DATA_DIR/.remlist.XXXXXX")"
            printf '%s\n' "$rl_name" > "$tmp"
            mv -f "$tmp" "$REMLIST_FILE"
            action_msg="Break notes go to “${rl_name}”"
        fi
        ;;
    setpaintcal)
        # Which calendar the log is painted onto. Free text like the reminders
        # list, and for the same reason it lives outside settings.tsv. "-"
        # clears it, which stops painting without touching the setting — the
        # honest way to say "not right now" rather than "never".
        pc_name=$(sanitize_field "${2:-}")
        if [[ "$pc_name" == "-" || -z "$pc_name" ]]; then
            rm -f "$PAINTCAL_FILE"
            action_msg="No calendar chosen. Nothing is written"
        elif (( ${#pc_name} > 200 )); then
            action_msg="Calendar name is too long" ; action_rc=1
        else
            tmp="$(mktemp "$DATA_DIR/.paintcal.XXXXXX")"
            printf '%s\n' "$pc_name" > "$tmp"
            mv -f "$tmp" "$PAINTCAL_FILE"
            # Not deferred to the next session close: choosing a calendar is
            # exactly the moment you want to see whether it worked.
            LOG_CHANGED=1
            action_msg="Painting onto “${pc_name}”"
        fi
        ;;
    setupdone)
        # A marker, not a setting: the dashboard opens on the setup page until
        # this exists, and it is written here because nothing else writes.
        : > "$DATA_DIR/.setup-done"
        action_msg="Setup complete"
        ;;
    *)
        action_msg="Unknown action: $query"
        ;;
esac

out=""
for part in "$recovered_msg" "$autoclose_msg" "$action_msg"; do
    [[ -z "$part" ]] && continue
    out="${out:+$out. }$part"
done
printf '%s\n' "$out"

# A logged row changed, so the calendar is now out of date. Detached and
# silent: painting launches an app bundle and waits on it, which is far too
# slow to sit in front of the notification that says your timer stopped — and
# nothing here depends on the outcome. It is safe to fire after *any* change
# because the painter reconciles a whole window rather than appending, so a
# close, an edit and a delete are all just "make the calendar match the log".
# A failure (no permission yet, no calendar chosen) is silent by design: it
# must never turn stopping a timer into an error, and the next close retries
# the same window anyway.
if (( LOG_CHANGED )) && [[ -x "$SCRIPT_DIR/paint-calendar.sh" ]]; then
    nohup "$SCRIPT_DIR/paint-calendar.sh" --quiet >/dev/null 2>&1 &
fi

# Callers that need to branch on success (the dashboard does) read the exit
# status; every pre-existing action still exits 0.
exit "$action_rc"
