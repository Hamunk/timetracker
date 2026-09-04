#!/usr/bin/env bash
# Babysits one pomodoro cycle. Detached with nohup from start.sh when the
# "Pomodoro mode" box is ticked:
#
#   pomodoro-watch.sh <key> <seg_start>
#
# Owns ~/.timetrack/pomodoro (phase, key, seg_start, target_epoch,
# completed_count, overrun_sec, watcher_pid — written atomically) and the
# overlay lifecycle. It never touches state or the log: action.sh consumes
# the pomodoro file at segment close, and this script's only job is to keep
# the file truthful, put a tomato on screen at the right moments, and hush
# whatever is playing when it does.
#
# It is also the courier for the break menu's two tools. The overlay is a
# WKWebView that may write a handful of fixed-name files and nothing else, so
# it cannot launch anything itself; this loop notices those files and launches
# the app bundle that does the work — "TimeTracker Spotify" for the remote,
# "TimeTracker Reminders" for a captured note. Both are bundles rather than
# bare scripts for the reason pause-media.sh already documents at length:
# permissions are granted to a name, and the name has to be stable.
#
# Short sleeps + wall-clock comparison, never one long sleep: macOS suspends
# sleeping processes across system sleep, and wall-clock math means a closed
# lid simply fast-forwards the cycle on wake. There is no overdue
# cancellation and no timeout on an overrunning break — sleep and long breaks
# are normal life, and the 8h guard is the only backstop. Only stopping or
# switching the course timer cancels the cycle.
#
# Killing this process at any moment leaves the log valid: the pomodoro file
# just goes stale, action.sh still flushes its counts if the same segment
# closes, and arming a new cycle replaces it.

set -uo pipefail

BIN_DIR="${0%/*}"
case "$BIN_DIR" in
    /*) ;;
    *) BIN_DIR="$(cd "$BIN_DIR" && pwd)" ;;
esac

DATA_DIR="${TIMETRACK_DIR:-$HOME/.timetrack}"
STATE_FILE="$DATA_DIR/state"
POMO_FILE="$DATA_DIR/pomodoro"
CHOICE_FILE="$DATA_DIR/.tomato-choice"
ALIVE_FILE="$DATA_DIR/.tomato-alive"
AUDIO_FILE="$DATA_DIR/.tomato-audio"
STOP_FILE="$DATA_DIR/.media-stop"
# --- break menu: Spotify ---
# want    the panel is open and would like a live agent
# cmd     one command, written by the overlay, consumed by the agent
# state   one TSV line the agent writes and the overlay reads
# played  the agent has actually moved the music this break (see resume_music)
SPOT_WANT="$DATA_DIR/.tomato-spotify-want"
SPOT_CMD="$DATA_DIR/.tomato-spotify-cmd"
SPOT_STATE="$DATA_DIR/.tomato-spotify"
SPOT_PID="$DATA_DIR/.tomato-spotify.pid"
SPOT_PLAYED="$DATA_DIR/.tomato-spotify-played"
PLAYLIST_FILE="$DATA_DIR/spotify-playlists.tsv"
# --- break menu: reminders ---
REM_FILE="$DATA_DIR/.tomato-reminder"
REM_RESULT="$DATA_DIR/.tomato-reminder-result"
REM_BUSY="$DATA_DIR/.tomato-reminder-busy"
OVERLAY_STALE=25   # two helper heartbeats plus slack
APPS_DIR="${TIMETRACK_APPS_DIR:-$HOME/Applications/TimeTracker}"
HELPER_BIN="$APPS_DIR/TimeTracker Prompt.app/Contents/MacOS/ttprompt"
MEDIA_APP="$APPS_DIR/TimeTracker Media.app"
# A Spotlight verb ("time spotify"), not a hidden name like the media bundle:
# there is exactly one bundle allowed to talk to Spotify — a second would be a
# second Automation prompt — so the one that does it is also the one you run by
# hand to answer that prompt before a break ever raises it.
SPOTIFY_APP="$APPS_DIR/time spotify.app"
REMINDERS_APP="$APPS_DIR/TimeTracker Reminders.app"
TICK=10

# The durations all come from the settings table — the one in settings.sh.
. "$BIN_DIR/settings.sh"

key="${1:-}"
seg="${2:-}"
[[ -n "$key" && "$seg" =~ ^[0-9]+$ ]] || exit 0

phase=WORK
target=$(( seg + $(tt_setting_secs pomodoro_minutes) ))
count=0
over=0
nudged=0
hushed=0
silent=0
last_audio=0
last_menu=0

write_pomo() {
    local tmp; tmp="$(mktemp "$DATA_DIR/.pomodoro.XXXXXX")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$phase" "$key" "$seg" "$target" "$count" "$over" "$$" > "$tmp"
    mv -f "$tmp" "$POMO_FILE"
}

# Overlay instances are told apart from the start prompt by their mode arg.
overlay_running() { pgrep -qf "ttprompt overlay"; }
kill_overlay()    { pkill -f "ttprompt overlay" 2>/dev/null || true
                    rm -f "$ALIVE_FILE" "$AUDIO_FILE"; }

# Which break-menu entries the overlay may draw, as one argv word so the
# helper's argument list stays short: "spotify,reminders", or "-" for neither.
#
# A setting alone is not enough to offer a tool. Spotify needs Spotify to be
# installed and its bundle built; capture needs the compiled EventKit helper.
# Offering a button that cannot work is worse than not offering it, because
# the failure would land in the middle of a break with no way to explain
# itself — the same reasoning that killed the notifications-only fallback.
menu_features() {
    local f=""
    if [[ "$(tt_setting spotify)" == "on" && -d "$SPOTIFY_APP" ]] \
       && [[ -d /Applications/Spotify.app || -d "$HOME/Applications/Spotify.app" ]]
    then
        f="spotify"
    fi
    if [[ "$(tt_setting reminders)" == "on" && -d "$REMINDERS_APP" ]]; then
        f="${f:+$f,}reminders"
    fi
    printf '%s' "${f:--}"
}

# A live process is not the same as a visible window. Mission Control (or a
# Space switch) can order the panel off screen while the process runs on
# happily — and with no Dock icon or Cmd-Tab entry there is then no way for
# the user to reach it, so the break can never be ended. The helper only
# heartbeats while it is genuinely on screen, so a stale beat means "alive
# but invisible": kill it and put a fresh one up.
overlay_healthy() {
    overlay_running || return 1
    local beat age
    beat=$(stat -f %m "$ALIVE_FILE" 2>/dev/null) || return 1
    age=$(( $(date +%s) - beat ))
    (( age <= OVERLAY_STALE ))
}

# One process for the whole visible stretch: it reads the phase out of the
# pomodoro file itself and morphs, so this is only called to put it up or to
# replace one that was lost.
launch_overlay() {
    kill_overlay
    rm -f "$CHOICE_FILE"
    # Seed the heartbeat so the grace period starts now, not at the helper's
    # first tick — otherwise the next pass would judge a fresh overlay stale.
    : > "$ALIVE_FILE"
    "$HELPER_BIN" overlay "$CHOICE_FILE" "$(tt_setting long_break_every)" \
        "$(tt_setting auto_accept_seconds)" "$(tt_setting easter_egg)" \
        "$(menu_features)" \
        >/dev/null 2>&1 &
}

# Is sound actually reaching the speakers? coreaudiod holds a named power
# assertion for as long as an output stream is live and drops it about a
# second after the last sample — the OS's own answer, free of permissions
# and indifferent to which app is making the noise.
#
# Counted, never `grep -q`: this script runs under `set -o pipefail`, where
# a quiet grep exits at the first match, hands pmset a SIGPIPE, and turns a
# successful match into a failed pipeline. That reads as silence, and the
# bug is invisible.
audio_playing() {
    local n
    n=$(pmset -g assertions 2>/dev/null \
        | grep -ci 'com\.apple\.audio\..*preventuseridlesleep') || n=0
    (( n > 0 ))
}

# The overlay shows "Still playing something? Press F8" while this file
# exists. The media key reaches a cross-origin lecture player that nothing
# else here can touch, and it works with the tomato on screen because media
# keys ignore window focus — which is the whole point of saying so there.
# Sampled only while the overlay is up, with hysteresis in one direction:
# appear at once, but survive a few seconds of silence so a gap between
# tracks doesn't make it blink.
#
# It knows about sound, not about video. A muted video gets no hint.
update_audio_hint() {
    if audio_playing; then
        silent=0
        : > "$AUDIO_FILE"
    else
        silent=$(( silent + 1 ))
        (( silent >= 3 )) && rm -f "$AUDIO_FILE"
    fi
}

play_sound() {
    [[ "$(tt_setting sound)" == "on" ]] || return 0
    ( afplay /System/Library/Sounds/Glass.aiff >/dev/null 2>&1 & )
}

# Silence whatever is playing, so a tomato that covers the screen also stops
# the video behind it. The pausing itself is pause-media.sh's job; what is
# decided here is only *how* it is launched, which matters more than it
# looks. macOS attributes an Automation permission to the app responsible
# for the process sending the event, and this watcher was detached from
# whichever category app started the session — so running the script
# directly would ask "TimeTracker TDT4100 wants to control Google Chrome",
# once per category, at the worst possible moment: the start of a break.
# Going through a bundle of its own gives every one of those requests a
# single stable name to be granted once. -g so the launch can't take key
# focus off the overlay. There is deliberately no "just run the script
# directly" fallback if the bundle is missing: install.sh always runs
# sync-apps.sh, so it cannot be — and a fallback would quietly reintroduce
# the per-category permission prompts this bundle exists to prevent.
pause_media() {
    [[ "$(tt_setting pause_media)" == "on" ]] || return 0
    [[ -x "$MEDIA_APP/Contents/MacOS/run" ]] || return 0
    ( /usr/bin/open -g "$MEDIA_APP" >/dev/null 2>&1 & )
}

# --- the break menu's couriers ----------------------------------------------
# The overlay can write files and nothing else. Everything below is this
# script noticing one of those files and launching the bundle that acts on it.
# Same -g as pause_media so no launch can take key focus off the overlay, and
# same "no fallback to running the script directly" rule: a direct run would
# be attributed to whichever category app started the session, which is the
# whole problem the bundles exist to solve.

spotify_agent_live() {
    local pid
    [[ -f "$SPOT_PID" ]] || return 1
    pid=$(head -1 "$SPOT_PID" 2>/dev/null) || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

# Start the remote if something wants it and it isn't already up. The agent
# guards against duplicates itself; this only keeps us from paying for an
# `open` twice a second.
spotify_agent() {
    [[ -d "$SPOTIFY_APP" ]] || return 0
    spotify_agent_live && return 0
    ( /usr/bin/open -g "$SPOTIFY_APP" >/dev/null 2>&1 & )
}

# A command for the agent, written the way every other file here is written:
# through a temp file, so the agent can never read half a line.
spotify_command() {
    local tmp
    [[ -d "$SPOTIFY_APP" ]] || return 0
    tmp="$(mktemp "$DATA_DIR/.spotcmd.XXXXXX")" || return 0
    printf '%s\n' "$1" > "$tmp"
    mv -f "$tmp" "$SPOT_CMD"
    spotify_agent
}

# What happens to the music when work starts again — the accepted break's end,
# a skipped break, a snoozed tomato. All three are "back to a silent work
# session", and all three follow the same rule.
#
# The rule is: only if you touched the music yourself this break. The agent
# leaves $SPOT_PLAYED behind the first time it actually moves the player, and
# without that file nothing happens here at all — a break spent in silence
# ends in silence, exactly as it did before this feature existed. Starting a
# playlist nobody asked for, because a timer elapsed, would be the single
# worst thing this tool could do to a quiet room.
#
# With it, the break's music does not follow you back to your desk: the work
# playlist takes over if one is marked, and otherwise Spotify is paused. There
# is no third option where break music simply keeps playing, because the next
# tomato's hush would stop it anyway — see "the tomato silences your
# headphones" in the README.
resume_music() {
    local uri=""
    [[ -f "$SPOT_PLAYED" ]] || return 0
    rm -f "$SPOT_PLAYED"
    [[ "$(tt_setting spotify)" == "on" ]] || return 0
    if [[ "$(tt_setting spotify_resume_work)" == "on" && -f "$PLAYLIST_FILE" ]]; then
        uri=$(awk -F'\t' 'NR>1 && $3=="work" { print $1; exit }' \
            "$PLAYLIST_FILE" 2>/dev/null) || uri=""
    fi
    # The panel is gone, so the agent is told to stop wanting to live before
    # it is given its last errand: it runs this and exits.
    rm -f "$SPOT_WANT"
    if [[ "$uri" =~ ^spotify:[a-z]{4,12}:[A-Za-z0-9]{16,40}$ ]]; then
        # `resume`, not `uri`: the agent must not mark this as the user having
        # touched the music, or the next break would resume without being asked.
        spotify_command "resume $uri"
    else
        spotify_command "pause"
    fi
}

# One captured note, handed to the EventKit helper. The helper consumes the
# request file itself and leaves its verdict in $REM_RESULT, which the overlay
# reads back — so a denied permission shows up in the panel as a refusal
# rather than as a note that silently never existed.
#
# $REM_BUSY is not belt and braces: `open` cannot pass arguments to an app
# that is already running, so a second note sent while the first is still
# being saved would launch nothing and sit in the file forever.
reminder_send() {
    [[ -f "$REM_FILE" ]] || return 0
    [[ -f "$REM_BUSY" ]] && return 0
    if [[ ! -d "$REMINDERS_APP" ]]; then
        printf 'error\treminders helper not installed\n' > "$REM_RESULT"
        rm -f "$REM_FILE"
        return 0
    fi
    : > "$REM_BUSY"
    ( /usr/bin/open -W -g "$REMINDERS_APP" --args "$REM_FILE" >/dev/null 2>&1
      rm -f "$REM_BUSY" ) &
}

# Everything the menu left lying about. Called when the tomato leaves the
# screen and again when the cycle ends: a stale state line would have the next
# panel open onto whatever was playing an hour ago, and a stale result would
# show last break's "saved" over this break's empty box.
menu_idle() {
    rm -f "$SPOT_WANT" "$SPOT_STATE" "$REM_RESULT"
}

menu_end() {
    menu_idle
    rm -f "$SPOT_CMD" "$SPOT_PLAYED" "$REM_FILE"
}

# --- transitions -------------------------------------------------------------
# $1 is the moment the user actually chose (the choice file's mtime), so up
# to a tick of watcher lag never leaks into overrun or the next phase.

do_accept() {
    local at="$1" next every len   # len is seconds
    next=$(( count + 1 ))
    every=$(tt_setting long_break_every)
    if (( next % every == 0 )); then
        len=$(tt_setting_secs long_break_minutes)
    else
        len=$(tt_setting_secs break_minutes)
    fi
    phase=BREAK
    target=$(( at + len ))
    nudged=0
    write_pomo
}

do_snooze() {
    local at="$1" base=$target
    # += the scheduled target in the normal case; from now if the tomato
    # itself was overdue (lid closed mid-work), so it really does come back
    # in snooze_minutes rather than instantly.
    (( at > base )) && base=$at
    target=$(( base + $(tt_setting_secs snooze_minutes) ))
    resume_music
    write_pomo
}

do_skip() {
    local at="$1"
    count=$(( count + 1 ))
    phase=WORK
    target=$(( at + $(tt_setting_secs pomodoro_minutes) ))
    resume_music
    write_pomo
}

do_back_to_work() {
    local at="$1"
    count=$(( count + 1 ))
    # Ending a break early is allowed and simply has 0 overrun.
    (( at > target )) && over=$(( over + at - target ))
    phase=WORK
    target=$(( at + $(tt_setting_secs pomodoro_minutes) ))
    nudged=0
    resume_music
    write_pomo
}

# --- arm ---------------------------------------------------------------------

write_pomo
rm -f "$CHOICE_FILE"

# --- the loop ----------------------------------------------------------------

last_health=0

while :; do
    now=$(date +%s)

    # The file is the cycle. Gone = consumed by action.sh at close, or a new
    # cycle replaced it; either way this watcher is done.
    [[ -f "$POMO_FILE" ]] || exit 0
    p_phase=""; p_key=""; p_seg=""; p_target=""; p_count=""; p_over=""; p_pid=""
    IFS=$'\t' read -r p_phase p_key p_seg p_target p_count p_over p_pid \
        < "$POMO_FILE" 2>/dev/null || true
    if [[ ! "$p_phase" =~ ^(WORK|BREAK)$ || ! "$p_target" =~ ^[0-9]+$ || \
          ! "$p_count" =~ ^[0-9]+$ || ! "$p_over" =~ ^[0-9]+$ ]]; then
        # A line that doesn't parse is deleted, like corrupt state handling.
        rm -f "$POMO_FILE"
        exit 0
    fi
    [[ "$p_pid" == "$$" ]] || exit 0   # replaced by a newer cycle

    # Cancel the moment the timer this cycle belongs to is no longer the one
    # running — stopped, switched, or a new segment of the same course.
    st=""; s_key=""; s_seg=""
    IFS=$'\t' read -r st s_key s_seg _ < "$STATE_FILE" 2>/dev/null || true
    if [[ "${st:-}" != "RUNNING" || "${s_key:-}" != "$key" || "${s_seg:-}" != "$seg" ]]; then
        : > "$STOP_FILE"
        rm -f "$POMO_FILE" "$CHOICE_FILE"
        menu_end          # the agent notices the missing pomodoro file and exits
        kill_overlay      # also clears the heartbeat and the hint flag
        exit 0
    fi

    # An overlay choice landed? Answering fast is what makes a click feel
    # immediate — the overlay stays up and crossfades to whatever we write.
    if [[ -f "$CHOICE_FILE" ]]; then
        at=$(stat -f %m "$CHOICE_FILE" 2>/dev/null) || at=$now
        [[ "$at" =~ ^[0-9]+$ ]] || at=$now
        choice=$(head -1 "$CHOICE_FILE" 2>/dev/null) || choice=""
        rm -f "$CHOICE_FILE"
        case "$phase:$choice" in
            WORK:accept)         do_accept "$at" ;;
            WORK:snooze)         do_snooze "$at" ;;
            WORK:skip)           do_skip "$at" ;;
            BREAK:back-to-work)  do_back_to_work "$at" ;;
            *) : ;;   # stale or mismatched choice — ignore
        esac
        continue      # re-read immediately; no nap between phases
    fi

    # Is the overlay meant to be on screen? One process covers the whole
    # visible stretch and switches phase in place, so this only ever has to
    # put it up in the first place or replace a lost one.
    overlay_wanted=0
    if [[ "$phase" == "BREAK" ]] || (( now >= target )); then overlay_wanted=1; fi

    # Hush the room the moment the tomato lands — once per visible stretch,
    # never per tick, and not a second time when the break follows the
    # tomato. Snooze puts the tomato away, which resets this, so the next
    # one silences whatever got restarted in between.
    if (( overlay_wanted )); then
        if (( hushed == 0 )); then hushed=1; pause_media; fi
        # Every couple of seconds is plenty for a hint, and keeps this off
        # the 0.5s click-polling path.
        if (( now - last_audio >= 2 )); then
            last_audio=$now
            update_audio_hint
        fi
        # The menu's errands. A note is forwarded the moment it appears — the
        # panel is showing a spinner and a second of lag is a second of it —
        # while the Spotify agent only needs starting occasionally, and asking
        # twice a second whether a process exists is a fork twice a second for
        # nothing.
        reminder_send
        if (( now - last_menu >= 2 )); then
            last_menu=$now
            if [[ -f "$SPOT_WANT" || -f "$SPOT_CMD" ]]; then spotify_agent; fi
        fi
    else
        # The tomato has left the screen — skipped, snoozed, or worked
        # through. Anything the pause is still walking through has to stop
        # now: a browser sweep can outlive the tomato by a good many
        # seconds, and arriving late means pausing a video the user has
        # deliberately gone back to. Only on the transition, not every tick.
        (( hushed )) && : > "$STOP_FILE"
        hushed=0
        silent=0
        last_menu=0
        rm -f "$AUDIO_FILE"
        # The panel went with the tomato. Its live state goes too, so the next
        # one opens onto now rather than onto the last break.
        menu_idle
    fi

    # No helper, no cycle. There used to be a notifications-only mode here
    # that advanced the phases by itself — and that was the wrong trade: it
    # kept the name "pomodoro mode" while quietly becoming a different
    # feature (breaks you never accept, overrun never measured), on a code
    # path no machine with the tools installed ever runs. Ending loudly is
    # the honest failure. It also covers the case that actually happens: the
    # binary vanishing mid-cycle, which XProtect once did (see the header of
    # ttprompt.swift). The timer itself is untouched and keeps running; only
    # the cycle ends, and it ends the way every other cancellation here does
    # — the file goes, so the counts accrued so far go with it. Keeping the
    # file to save them would leave the dashboard showing a countdown that
    # will never move again, which is a worse lie than an empty column.
    if [[ ! -x "$HELPER_BIN" ]]; then
        play_sound
        "$BIN_DIR/notify.sh" \
            "🍅 Pomodoro needs the Xcode tools — xcode-select --install" || true
        : > "$STOP_FILE"
        menu_end
        rm -f "$POMO_FILE" "$CHOICE_FILE" "$AUDIO_FILE"
        exit 0
    fi

    if (( overlay_wanted )); then
        # pgrep is the expensive part of a tick, so only probe every few
        # seconds; the fast polling below is just for picking up clicks.
        if (( now - last_health >= 5 )); then
            last_health=$now
            overlay_healthy || launch_overlay
        fi
    fi

    # The break-over sound, once, at the scheduled end.
    if [[ "$phase" == "BREAK" ]] && (( now >= target && nudged == 0 )); then
        play_sound
        nudged=1
    fi

    # Sleep exactly as long as there is nothing to do — capped, never one long
    # sleep, so the wall-clock math still survives the lid being closed. This
    # is what makes the tomato land on time instead of up to a tick late.
    if (( overlay_wanted )); then
        nap=0.5                       # a click has to register promptly
    else
        remain=$(( target - now ))
        if (( remain < TICK )); then nap=$remain; else nap=$TICK; fi
        (( nap < 1 )) && nap=1
    fi
    sleep "$nap"
done
