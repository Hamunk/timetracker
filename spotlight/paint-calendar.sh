#!/usr/bin/env bash
# Paint the log onto a calendar.
#
# Turns the last few days of sessions.tsv into a request the EventKit helper
# can act on, hands it over, and reports what came back. It reads the log and
# writes nothing but its own request file — action.sh stays the only writer of
# anything that matters.
#
#   paint-calendar.sh            paint, print one line
#   paint-calendar.sh --quiet    paint, say nothing (action.sh's detached call)
#   paint-calendar.sh --list     refresh the list of paintable calendars
#
# It is called after every session close, and that only works because the
# helper *reconciles*: the request describes the whole window, and the tenth
# run over the same week changes nothing. Nothing here has to remember what it
# painted last time, which is what lets a session edited in the dashboard —
# or deleted there — reach the calendar with no extra machinery at all.
#
# Why the app bundle rather than a binary: macOS grants calendar access to the
# bundle launched through LaunchServices, and denies it outright, without a
# prompt, to the same binary exec'd directly.

set -uo pipefail

BIN_DIR="${0%/*}"
case "$BIN_DIR" in
    /*) ;;
    *) BIN_DIR="$(cd "$BIN_DIR" && pwd)" ;;
esac

DATA_DIR="${TIMETRACK_DIR:-$HOME/.timetrack}"
SESS_FILE="$DATA_DIR/sessions.tsv"
CAT_FILE="$DATA_DIR/categories.tsv"
CAL_FILE="$DATA_DIR/paint-calendar"
# Six letters, made once per install, that end the mark on every event it
# paints. paintplan.swift touches nothing without its own mark, so this is
# what lets a scratch install and the real one paint the same calendar
# without either ever removing the other's events.
ID_FILE="$DATA_DIR/.paint-id"
# A calendar an older version painted, before events carried a mark. Written
# by that version after its first successful paint, and only read now: its
# unmarked events for a session are that version's work and are taken over,
# where anywhere else they would be left alone. See rule 4 in paintplan.swift.
ADOPTED_FILE="$DATA_DIR/.paint-adopted"
REQ_FILE="$DATA_DIR/.paint-request.tsv"
RESULT_FILE="$DATA_DIR/.paint-result.tsv"
LIST_FILE="$DATA_DIR/.paint-calendars.tsv"
APPS_DIR="${TIMETRACK_APPS_DIR:-$HOME/Applications/TimeTracker}"
HELPER="$APPS_DIR/Helpers.noindex/Tomat Calendar.app"

. "$BIN_DIR/settings.sh"

mode="${1:-}"
say() { [[ "$mode" == "--quiet" ]] || printf '%s\n' "$1"; }

[[ -d "$HELPER" ]] || { say "Calendar helper not installed. Re-run install.sh"; exit 1; }

# The detached call after every session close has nothing to do with painting
# off, and must not take the lock below to find that out.
if [[ "$mode" == "--quiet" && "$(tt_setting paint_calendar)" != "on" ]]; then exit 0; fi

# One painter at a time. Stopping one timer and starting another is two closes
# a second apart, and two painters would both launch the same bundle — where
# the second `open` finds the app already running, passes it nothing, and then
# reads the *first* one's result. Waiting is the right answer rather than
# skipping: the painter that waits goes on to read a log that now includes
# whatever the first one was called about, so the last one out is always the
# one holding the whole truth. mkdir is the mutex, exactly as in action.sh.
# A listing takes it too: it clears the request file, which a paint under way
# is about to hand the helper.
PAINT_LOCK="$DATA_DIR/.paint.lock"
waited=0
until mkdir "$PAINT_LOCK" 2>/dev/null; do
    # A lock older than a helper could plausibly take is a crashed painter.
    if [[ -n "$(find "$PAINT_LOCK" -maxdepth 0 -mmin +2 2>/dev/null)" ]]; then
        rm -rf "$PAINT_LOCK" 2>/dev/null
        continue
    fi
    (( waited++ >= 60 )) && { say "Another paint is still running."; exit 1; }
    sleep 0.5
done
trap 'rm -rf "$PAINT_LOCK" 2>/dev/null' EXIT INT TERM

cal=""
[[ -r "$CAL_FILE" ]] && cal=$(head -1 "$CAL_FILE" 2>/dev/null | tr -d '\t\r')

# --- listing -----------------------------------------------------------------
# The helper is handed the request file's path with no file at it, and dumps
# what it can see beside it, touching nothing. The path is the point: launched
# bare it wrote into ~/.timetrack whatever install had launched it, so a scratch
# install's listing landed in the real one's folder and was never seen. This is
# also the launch that raises the permission prompt, which is why "time
# calendar" with no calendar chosen yet lists rather than refusing.

if [[ "$mode" == "--list" || ( -z "$cal" && "$mode" != "--quiet" ) ]]; then
    rm -f "$LIST_FILE" "$RESULT_FILE" "$REQ_FILE"
    /usr/bin/open -W -g "$HELPER" --args "$REQ_FILE" >/dev/null 2>&1
    if [[ ! -f "$LIST_FILE" ]]; then
        status=""
        [[ -f "$RESULT_FILE" ]] && status=$(cut -f1 "$RESULT_FILE" 2>/dev/null)
        if [[ "$status" == "denied" ]]; then
            say "Calendar access refused. Turn it on in System Settings > Privacy & Security > Calendars."
        else
            say "The calendar helper did not answer."
        fi
        exit 1
    fi
    n=$(grep -c '^CAL' "$LIST_FILE" 2>/dev/null) || n=0
    say "Found $n calendar(s) you can paint into."
    exit 0
fi

# --- painting ----------------------------------------------------------------

[[ "$(tt_setting paint_calendar)" == "on" ]] || { say "Calendar painting is off."; exit 0; }

if [[ -z "$cal" ]]; then
    say "No calendar chosen yet. Pick one in Tomat's Settings."
    exit 1
fi

days=$(tt_setting paint_days)
min_secs=$(( $(tt_setting paint_min_minutes) * 60 ))
now=$(date +%s)
# Midnight $days days ago, not "now minus N×86400": the window is a set of
# days, and a window that slides by the hour would keep re-deciding whether
# the oldest morning is in or out.
from=$(date -j -v-"${days}"d -v0H -v0M -v0S +%s 2>/dev/null) || from=$(( now - days * 86400 ))
# Rule 2 of the helper, enforced from this side too: never the future. A
# calendar's job tomorrow is to hold what you intend, and this program has no
# opinion about that.
to=$now

# Category labels, so an event says "MAT2300 Optimeringsmetoder..." rather
# than a bare key — code and name, since the key is neither any more. Read
# once into an awk lookup rather than once per row.
tmp="$(mktemp "$DATA_DIR/.paint.XXXXXX")" || exit 1
trap 'rm -f "$tmp"; rm -rf "$PAINT_LOCK" 2>/dev/null' EXIT INT TERM

adopted=""
[[ -r "$ADOPTED_FILE" ]] && adopted=$(head -1 "$ADOPTED_FILE" 2>/dev/null)

id=""
[[ -r "$ID_FILE" ]] && id=$(head -1 "$ID_FILE" 2>/dev/null)
if [[ ! "$id" =~ ^[a-z0-9]{6}$ ]]; then
    id=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 6)
    printf '%s\n' "$id" > "$ID_FILE"
fi

{
    printf 'CAL\t%s\n' "$cal"
    printf 'WINDOW\t%s\t%s\n' "$from" "$to"
    printf 'ID\t%s\n' "$id"
    [[ -n "$adopted" && "$adopted" == "$cal" ]] && printf 'LEGACY\t1\n'

    # One awk pass over the log. Dates arrive as ISO with an offset, which
    # mktime cannot read, so the epoch is rebuilt from the fields directly and
    # the offset applied by hand — no forking `date` once per session, which
    # on a busy fortnight is hundreds of processes for nothing.
    TT_FROM="$from" TT_TO="$to" TT_MIN="$min_secs" \
    awk -F'\t' -v OFS='\t' '
        BEGIN {
            from = ENVIRON["TT_FROM"] + 0
            to   = ENVIRON["TT_TO"] + 0
            minsec = ENVIRON["TT_MIN"] + 0
            US = sprintf("%c", 31)      # \x1f: a line break inside a field
        }
        # Pass one: the label for every key.
        NR == FNR {
            if (FNR > 1 && $1 != "") { name[$1] = $2; code[$1] = $6 }
            next
        }
        FNR == 1 { next }               # the log header
        {
            s = epoch($1); e = epoch($2)
            if (s == 0 || e == 0 || e <= s) next
            if (e < from || s > to) next
            if (e - s < minsec) next

            key = $4
            title = name[key] != "" ? name[key] : key
            if (code[key] != "") title = code[key] " " title

            # plan, recap, note, then the pomodoro line — in the order you
            # would want to read them back: what you meant to do, what you
            # did, and how the cycle went.
            notes = ""
            notes = add(notes, $6)      # plan
            notes = add(notes, $7)      # recap
            notes = add(notes, $5)      # note
            stats = ""
            if ($8 + 0 > 0) stats = $8 " pomodoro" ($8 + 0 == 1 ? "" : "s")
            if ($9 + 0 > 0) {
                over = int(($9 + 59) / 60)
                stats = stats (stats == "" ? "" : " \xc2\xb7 ") over "m break overrun"
            }
            notes = add(notes, stats)

            print "S", s, e, title, notes
        }
        function add(acc, part) {
            gsub(/^[ \t]+|[ \t]+$/, "", part)
            if (part == "") return acc
            return acc == "" ? part : acc US part
        }
        # "2026-09-04T14:05:00+0200" -> epoch, without calling date(1).
        function epoch(iso,   y, mo, d, h, mi, se, sign, oh, om, t) {
            if (iso !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}/) return 0
            y = substr(iso, 1, 4);  mo = substr(iso, 6, 2);  d = substr(iso, 9, 2)
            h = substr(iso, 12, 2); mi = substr(iso, 15, 2); se = substr(iso, 18, 2)
            t = days(y + 0, mo + 0, d + 0) * 86400 + h * 3600 + mi * 60 + se
            sign = substr(iso, 20, 1)
            if (sign == "+" || sign == "-") {
                oh = substr(iso, 21, 2) + 0
                om = substr(iso, 23, 2) + 0
                t -= (sign == "+" ? 1 : -1) * (oh * 3600 + om * 60)
            }
            return t
        }
        # Days since the epoch for a civil date. The standard shift so that
        # March starts the year, which makes the leap day the last day of it
        # and the whole thing branchless.
        function days(y, m, d,   era, yoe, doy, doe) {
            y -= (m <= 2)
            era = int((y >= 0 ? y : y - 399) / 400)
            yoe = y - era * 400
            doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
            doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
            return era * 146097 + doe - 719468
        }
    ' "$CAT_FILE" "$SESS_FILE" 2>/dev/null
} > "$tmp"

mv -f "$tmp" "$REQ_FILE"
trap 'rm -rf "$PAINT_LOCK" 2>/dev/null' EXIT INT TERM

rm -f "$RESULT_FILE"
# -W so the result is there when we read it; -g so a paint triggered by
# closing a timer can never steal focus from whatever you moved on to.
/usr/bin/open -W -g "$HELPER" --args "$REQ_FILE" >/dev/null 2>&1

status=""; f2=""; f3=""; f4=""; f5=""
# Tested rather than redirected blindly: a helper that never launched leaves no
# result at all, and the shell reports a failed redirect on stderr — which for
# the --quiet call from action.sh would be noise nobody ever sees the reason for.
if [[ -f "$RESULT_FILE" ]]; then
    IFS=$'\t' read -r status f2 f3 f4 f5 < "$RESULT_FILE" || true
fi
case "${status:-}" in
    ok)
        say "Wrote to “${f2}”: ${f3:-0} added, ${f4:-0} updated, ${f5:-0} removed."
        ;;
    denied)
        say "Calendar access refused. Turn it on in System Settings > Privacy & Security > Calendars."
        exit 1
        ;;
    nocal)
        say "No writable calendar called “${f2}”. Create it, then pick it in Tomat's Settings."
        exit 1
        ;;
    error)
        say "Could not write to the calendar: ${f2:-unknown error}"
        exit 1
        ;;
    *)
        say "The calendar helper did not answer."
        exit 1
        ;;
esac
exit 0
