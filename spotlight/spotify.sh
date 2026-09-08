#!/usr/bin/env bash
# The break's Spotify remote. One short-lived agent process that talks to the
# Spotify desktop app while the pause screen is up.
#
# It is never run directly. pomodoro-watch.sh launches it through
# "TimeTracker Spotify.app" (Spotlight: "time spotify"), for the same reason
# pause-media.sh has a bundle of its own: macOS attributes an Automation
# permission to the app responsible for the process sending the event, and the
# watcher was detached from whichever category app started the session. Run
# from there it would ask "TimeTracker TDT4100 wants to control Spotify" once
# per course, mid-break, under a different name every time. Through this
# bundle it is asked once, as "TimeTracker Spotify", and can be answered at a
# calm moment by launching it by hand.
#
# The shape is a poll loop rather than a command per keypress, and that is a
# deliberate trade. A per-keypress design would mean one `open` per click
# (~200ms of LaunchServices before the event even leaves), and `open` cannot
# hand output back — while the panel needs the *current* track twice a second.
# So: one process, launched when the panel is first opened, that owns the
# conversation with Spotify for as long as the panel could want it.
#
#   reads   ~/.timetrack/.tomato-spotify-want   exists = the panel is open
#           ~/.timetrack/.tomato-spotify-cmd    one command, then deleted
#   writes  ~/.timetrack/.tomato-spotify        current state, one TSV line
#
# Four rules, three of them inherited from pause-media.sh because they were
# learned the same way:
#
# 1. Nothing from a file is ever interpolated into AppleScript source. The
#    playlist URI a command carries reaches osascript as `argv`, and is
#    additionally charset-checked before it gets that far — SECURITY.md §2 in
#    the one place where it would matter most.
# 2. Every event runs on a leash. An unanswered Automation prompt blocks the
#    event that raised it, and AppleScript's own default timeout is sixty
#    seconds; a break must not be able to notice either.
# 3. It only *reads* from an app that is already running. A state poll must
#    never be the thing that opens Spotify.
# 4. Playing is the one exception, and it is not a rule violation but the
#    point: the user just clicked play. That path may launch Spotify, and it
#    is also the only path that touches .media-stop first — see below.

set -uo pipefail

DATA_DIR="${TIMETRACK_DIR:-$HOME/.timetrack}"
WANT_FILE="$DATA_DIR/.tomato-spotify-want"
CMD_FILE="$DATA_DIR/.tomato-spotify-cmd"
STATE_FILE="$DATA_DIR/.tomato-spotify"
PID_FILE="$DATA_DIR/.tomato-spotify.pid"
# Left behind the first time this agent actually moves the player. The watcher
# reads it at the end of the break to decide whether the work playlist should
# come back: a break nobody touched the music in must end as silently as it
# began, and this file is the whole difference between the two.
PLAYED_FILE="$DATA_DIR/.tomato-spotify-played"
# pause-media.sh's stop signal. Touching it is what stops an in-flight break
# hush from pausing the music we are about to start — see play_uri().
MEDIA_STOP="$DATA_DIR/.media-stop"
POMO_FILE="$DATA_DIR/pomodoro"

IDLE_MAX=3      # ticks with no want file before giving up
GUARD=10800     # 3h backstop: no agent outlives a plausible break

# --- one agent at a time -----------------------------------------------------
# LaunchServices already refuses to relaunch a running app, so a second `open`
# normally never gets here. It does get here after a crash left a stale pid
# file, and it would get here if the bundle were ever launched by hand while a
# break was live — two agents both writing $STATE_FILE would flicker the panel
# between two truths.
if [[ -f "$PID_FILE" ]]; then
    other=$(head -1 "$PID_FILE" 2>/dev/null) || other=""
    if [[ "$other" =~ ^[0-9]+$ ]] && kill -0 "$other" 2>/dev/null; then
        # A live agent will pick up whatever command is waiting; nothing to do.
        exit 0
    fi
fi
printf '%s\n' "$$" > "$PID_FILE"
cleanup() { rm -f "$PID_FILE"; }
trap cleanup EXIT

# --- talking to Spotify ------------------------------------------------------
# -x is exact so Spotify's helper processes don't count as Spotify.
running() { pgrep -qx Spotify; }

# osascript on a leash. Everything Spotify is asked goes through here: the
# script arrives on stdin, any data as argv, and a run that has not finished
# in $1 seconds is killed rather than waited on. Output is printed; a failure
# of any kind (denied permission, wedged app, timeout) prints nothing and
# returns 1, which every caller reads as "no answer" rather than as an error.
osa() {
    local limit="$1" script="$2"; shift 2
    local out tmp rc
    tmp="$(mktemp "$DATA_DIR/.spotify-osa.XXXXXX")" || return 1
    /usr/bin/osascript - "$@" >"$tmp" 2>/dev/null <<<"$script" &
    local pid=$!
    local ticks=$(( limit * 10 ))
    while (( ticks-- > 0 )); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" >/dev/null 2>&1
        rm -f "$tmp"
        return 1
    fi
    wait "$pid"; rc=$?
    out=$(cat "$tmp" 2>/dev/null)
    rm -f "$tmp"
    (( rc == 0 )) || return 1
    printf '%s' "$out"
}

# Tabs and control characters would break the one-line TSV the panel reads,
# and a track title is somebody else's data. Track names contain everything.
clean() {
    printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177' | cut -c1-120
}

# One question, four answers, returned on one line. Asking for all of it in a
# single event rather than four keeps the poll to one round trip — and keeps
# the four fields consistent with each other, which four separate events would
# not guarantee.
#
# `player state` is asked first and the track only if something is loaded:
# reading `current track` with nothing loaded is an error, not an empty string.
read_state() {
    local raw
    raw=$(osa 4 'tell application "Spotify"
    with timeout of 3 seconds
        set s to player state as text
        set v to sound volume as text
        set n to ""
        set a to ""
        try
            set n to name of current track
            set a to artist of current track
        end try
        return s & tab & v & tab & n & tab & a
    end timeout
end tell') || return 1
    printf '%s' "$raw"
}

write_state() {
    local line="$1" tmp
    tmp="$(mktemp "$DATA_DIR/.tspotify.XXXXXX")" || return 0
    printf '%s\n' "$line" > "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

poll() {
    local raw s v n a
    if ! running; then
        write_state $'off\t0\t\t'
        return 0
    fi
    raw=$(read_state) || { write_state $'unreachable\t0\t\t'; return 0; }
    IFS=$'\t' read -r s v n a <<< "$raw"
    case "${s:-}" in playing|paused|stopped) ;; *) s=unreachable ;; esac
    [[ "${v:-}" =~ ^[0-9]+$ ]] || v=0
    write_state "$s"$'\t'"$v"$'\t'"$(clean "${n:-}")"$'\t'"$(clean "${a:-}")"
}

# --- the commands ------------------------------------------------------------
# Each one is a fixed AppleScript constant. The only variable that ever
# reaches osascript is a playlist URI or a volume number, both as argv.

simple() {   # $1 = a command word that takes no argument
    running || return 0
    osa 5 "tell application \"Spotify\"
    try
        with timeout of 4 seconds
            $1
        end timeout
    end try
end tell" >/dev/null
}

# Start something. The only command allowed to launch Spotify, because it is
# the only one the user asked for by clicking.
#
# .media-stop is touched *first*, and that ordering is the whole fix for the
# race this feature was born with: the break hush (pause-media.sh) is fired
# the instant the tomato lands and its browser sweep can still be walking tabs
# seconds later. Press play inside that window and the sweep arrives after us
# and pauses the music we just started — the user sees a play button that
# does nothing. The stop file is the sweep's own "drop everything" signal, so
# claiming it here means the last word is ours.
play_uri() {
    : > "$MEDIA_STOP"
    # Cold, it is launched here first, hidden and in the background, so that
    # the Apple Event below finds it running and never launches it itself.
    # An app launched by an Apple Event comes up activated, with a window,
    # and that is what a video in a browser tab under the overlay reacts to:
    # the tab sees its occlusion change and a player that paused itself when
    # the tomato covered it un-pauses because it believes it is visible
    # again. A paused lecture starting up under a break is the report that
    # led here. Launched hidden, no window appears and nothing underneath
    # the overlay changes.
    if ! running; then
        /usr/bin/open -g -j -a Spotify >/dev/null 2>&1 || return 0
        local t=0
        while ! running && (( t < 80 )); do sleep 0.1; t=$(( t + 1 )); done
        running || return 0
        sleep 1     # scriptable a beat after the process exists
    fi
    osa 8 'on run argv
    tell application "Spotify"
        try
            with timeout of 6 seconds
                play track (item 1 of argv)
            end timeout
        end try
    end tell
end run' "$1" >/dev/null
}

# Accepted commands, and the only place a command's shape is trusted. Swift
# validates before writing the file and this validates before acting: the file
# sits in a directory the user can write, so "Swift already checked" is not a
# property this script may assume.
run_command() {
    local line="$1"
    case "$line" in
        # A person pressed something. That is what the watcher's end-of-break
        # rule turns on, so every button the panel actually has leaves the
        # marker — including next and previous, which on a paused player are
        # how you start it. The bare `pause` below is the watcher's own and
        # deliberately does not, or every break would inherit the last one's.
        playpause) : > "$PLAYED_FILE" ; simple "playpause" ;;
        play)      : > "$PLAYED_FILE" ; simple "play" ;;
        pause)     simple "pause" ;;
        next)      : > "$PLAYED_FILE" ; simple "next track" ;;
        prev)
            # Once, deliberately. `previous track` behaves like the app's own
            # button — past the first few seconds it restarts the current
            # track rather than leaving it — and sending a second one to force
            # a real skip would silently jump two tracks whenever it didn't.
            # Matching the button people already know beats being clever.
            : > "$PLAYED_FILE"
            simple "previous track"
            ;;
        "vol "*)
            local v="${line#vol }"
            [[ "$v" =~ ^[0-9]{1,3}$ ]] && (( v <= 100 )) || return 0
            running || return 0
            osa 5 'on run argv
    tell application "Spotify"
        try
            with timeout of 4 seconds
                set sound volume to ((item 1 of argv) as integer)
            end timeout
        end try
    end tell
end run' "$v" >/dev/null
            ;;
        "uri "*|"resume "*)
            # Two words for one action, and the difference is only who asked.
            # `uri` is a click in the panel and counts as touching the music;
            # `resume` is the watcher putting the work playlist back on at the
            # end of the break, and must not — or every break would inherit a
            # "played" marker from the one before it and resume for ever.
            local u="${line#* }"
            # No quote, no backslash, no space can survive this — which is the
            # belt to argv's braces.
            [[ "$u" =~ ^spotify:[a-z]{4,12}:[A-Za-z0-9]{16,40}$ ]] || return 0
            [[ "$line" == uri\ * ]] && : > "$PLAYED_FILE"
            play_uri "$u"
            ;;
        *) : ;;   # unknown or truncated: ignore, never guess
    esac
}

take_command() {
    [[ -f "$CMD_FILE" ]] || return 1
    local line
    line=$(head -1 "$CMD_FILE" 2>/dev/null) || line=""
    rm -f "$CMD_FILE"
    [[ -n "$line" ]] || return 1
    run_command "$line"
    return 0
}

# --- launched by hand --------------------------------------------------------
# No pomodoro file means nothing sent us here: this is the Spotlight verb
# ("time spotify"), and its whole job is to raise the Automation prompt at a
# moment when answering it costs nothing, then say what came back. It is the
# same bundle as the agent because it has to be — a separate one would be a
# separate grant — so the two modes are told apart by the cycle, not by an
# argument nobody would pass.
if [[ ! -f "$POMO_FILE" ]]; then
    poll
    hand_state=""; hand_vol=""; hand_track=""; hand_artist=""
    IFS=$'\t' read -r hand_state hand_vol hand_track hand_artist \
        < "$STATE_FILE" 2>/dev/null || true
    case "${hand_state:-}" in
        playing|paused)
            msg="Spotify is reachable, ${hand_state}."
            [[ -n "${hand_track:-}" ]] && msg="$msg"$'\n\n'"${hand_track}"
            [[ -n "${hand_artist:-}" ]] && msg="$msg, ${hand_artist}"
            ;;
        stopped)
            msg="Spotify is reachable. Nothing is loaded." ;;
        off)
            msg="Spotify is not running. Open it, then run this again." ;;
        *)
            msg="Could not reach Spotify."$'\n\n'"Allow it in System Settings > Privacy & Security > Automation, under this app." ;;
    esac
    rm -f "$STATE_FILE"
    /usr/bin/osascript - "$msg" >/dev/null 2>&1 <<'EOS'
on run argv
    tell application "System Events"
        activate
        display dialog (item 1 of argv) with title "TimeTracker Spotify" ¬
            buttons {"OK"} default button "OK"
    end tell
end run
EOS
    exit 0
fi

# --- the loop ----------------------------------------------------------------
# A pending command is served before anything else and before the want file is
# consulted, because the last command of a break — "I'm back", which resumes
# the work playlist — is deliberately issued *after* the panel is gone.

started=$(date +%s)
idle=0

take_command || true

while :; do
    now=$(date +%s)
    (( now - started > GUARD )) && break

    # The cycle is over, or was cancelled: nothing left to serve.
    [[ -f "$POMO_FILE" ]] || break

    if [[ -f "$WANT_FILE" ]]; then
        # Answer before sleeping, not after: the panel is on screen from the
        # moment it was asked for, and a first reading that arrives a second
        # later is a second of "connecting" nobody needs to see.
        idle=0
        poll
    else
        # Not wanted. Linger a couple of ticks rather than exiting instantly:
        # closing and reopening the panel is one click, and paying a fresh
        # LaunchServices launch for it would show an empty panel each time.
        idle=$(( idle + 1 ))
        (( idle > IDLE_MAX )) && break
    fi

    # One state poll per second, but the command file is checked ten times
    # in that second: a click has to feel immediate, and asking Spotify for
    # its state is the expensive half of a tick. It was four; a quarter
    # second between a click and anything happening was the lag the panel
    # was reported for.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if take_command; then
            # Something changed; report it without waiting for the next tick.
            poll
        fi
        sleep 0.1
    done

done

# Leaving a stale line behind would have the next panel open onto whatever was
# playing at the end of the last break.
rm -f "$STATE_FILE"
exit 0
