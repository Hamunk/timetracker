#!/usr/bin/env bash
# Pause everything that is playing.
#
# The tomato takes over the screen; this takes over your headphones. It is
# called by pomodoro-watch.sh the moment the overlay goes up — once per
# visible stretch, not once per tick — and it also runs on its own, which is
# how the Automation prompts get answered at a calm moment instead of in the
# middle of a break (Spotlight: "TimeTracker Media").
#
# Four rules shape the whole file:
#
# 1. It never starts playback. Everything below is a real "pause", never a
#    toggle. The obvious implementation — posting the play/pause media key,
#    which every player understands — was rejected for exactly that reason:
#    it is a toggle, so a break beginning while nothing played would *start*
#    something. It also needs Accessibility, a far larger permission than
#    this earns. The price is the list below being a list: a player that is
#    neither scriptable nor a browser (IINA, for one) plays on.
#
# 2. It only speaks to apps that are already running. pgrep first, always —
#    naming an app in AppleScript is enough to launch it, and a break that
#    opens Music is worse than a break that misses it. It also keeps the
#    Automation prompt for an app you never use from ever appearing.
#
# 3. It never fails and never hangs. Every tell is wrapped in try and run on
#    a leash, so a refused permission, a busy app, or a browser with
#    JavaScript-from-Apple-Events switched off all read as "nothing
#    happened" rather than as an error in the middle of a break. Exit status
#    is always 0.
#
# 4. It never resumes anything, and it never touches a global you'd have to
#    put back (output volume included). Ending a break returns you to your
#    desk, not to the video: restarting what you were watching is a
#    decision, and an app that woke up playing after a break would be a bug.
#
# There is no media key here, and that absence was expensive enough to be
# worth recording. Canvas embeds lectures as LTI tool launches — an
# <iframe src="about:blank"> that Canvas POSTs an external tool into — so
# the player belongs to another origin and no JavaScript from the page can
# reach it. The system play/pause key does reach it, which is why F8 works
# by hand, so a small signed helper was built to post one. It does not
# work: on macOS 26 every variant (HID tap, session tap, annotated session
# tap, real timestamp, direct post to the target pid, plain F8 keycode) is
# accepted by the system and consumed by nothing. Media keys now travel
# through the Now Playing service, which ignores synthesised events; the
# physical key works because it originates a layer below anything a process
# can post to. Measured against a live audio oracle, seven variants, with
# the Accessibility grant confirmed live. Do not spend another evening on
# it without new evidence that the platform changed.

set -uo pipefail

DATA_DIR="${TIMETRACK_DIR:-$HOME/.timetrack}"

# The watcher creates this the moment the tomato leaves the screen, and it
# means: stop, whatever you are in the middle of. Without it a sweep that is
# still walking tabs will pause a video the user has already gone back to —
# the tomato appears, the video stops (right), the break is skipped, the
# video is restarted, and thirty tabs later the sweep arrives and stops it
# again (very wrong). A pause is a moment, not a background job.
STOP_FILE="$DATA_DIR/.media-stop"

BIN_DIR="${0%/*}"
case "$BIN_DIR" in
    /*) ;;
    *) BIN_DIR="$(cd "$BIN_DIR" && pwd)" ;;
esac

# One leash for the whole run, not one per app — see osa() below.
#
# This was 120 seconds once, on the reasoning that nothing waits for it so
# it may take as long as it likes. That was wrong in a way worth keeping:
# work still running after the tomato is dismissed will pause whatever the
# user has just gone back to. Being late here is not useless, it is harmful.
# With the tab sweep gone a normal run finishes in well under a second, so
# this now only ever fires for an app that is genuinely stuck — wedged, or
# sitting on an unanswered permission prompt — and STOP_FILE cuts even that
# short the instant the tomato leaves the screen.
DEADLINE=8

# One page's worth of pausing, and the reason the browsers need JavaScript at
# all: no browser exposes "the tab that is making noise" to AppleScript, so
# every tab is asked to pause its own media. Same-origin iframes are walked;
# a cross-origin one (an embedded YouTube or Vimeo player) is unreachable
# from here and keeps playing — the one gap that bites in practice.
#
# It contains no double quote and no backslash, which is what makes it safe
# to drop into AppleScript's own "..." below. Keep it that way.
#
# Every event below is wrapped in `with timeout`, and that is not belt and
# braces — it is the whole difference between working and not. A tab that
# cannot run JavaScript right now (a wedged renderer, a page sitting on an
# alert(), a tab the browser has discarded) does not refuse: it says nothing
# at all, and AppleScript's default Apple Event timeout is *sixty seconds*.
# One such tab is enough to stall a sweep past any deadline worth having,
# which is exactly how this file failed its first real break — the browser
# pass hit the leash and died having paused nothing.
#
# A cross-origin iframe cannot be walked, but it can be written to:
# postMessage crosses origins by design, and the two embedded players that
# account for most lecture video answer to a published message each. YouTube
# takes {event:'command',func:'pauseVideo'} on an embed created with
# enablejsapi=1; Vimeo takes {method:'pause'}. A frame that understands
# neither ignores both, which is the whole risk. It does not reach a player
# nested inside a tool's own frame (Canvas puts LTI tools one level down),
# and it was never going to: that frame is the tool's, not the player's.
PAUSE_JS="(function p(d){try{d.querySelectorAll('video,audio').forEach(function(m){m.pause()});Array.prototype.forEach.call(d.querySelectorAll('iframe'),function(f){try{p(f.contentDocument)}catch(e){}try{var w=f.contentWindow;w.postMessage(JSON.stringify({event:'command',func:'pauseVideo',args:[]}),'*');w.postMessage(JSON.stringify({method:'pause'}),'*')}catch(e){}})}catch(e){}})(document)"

# -x is exact: Chrome's dozen "Google Chrome Helper" processes must not count
# as Chrome, or we'd script an app that quit.
running() { pgrep -qx "$1"; }

# Start an AppleScript; never wait for it. Everything below is launched at
# once and reaped at the end together.
#
# Sequential was the first shape of this file and it was wrong in a way that
# took exactly ten seconds to show: a browser sweep can run for seconds — or
# block outright on an unanswered "wants to control" prompt — and every
# player queued behind it went on playing for precisely that long. Nothing
# here depends on anything else here. Nothing here should wait for it.
#
# osascript inherits the caller's Automation verdict, so the first run
# against each app puts up the system's "wants to control" prompt; a denial
# (or a later revoke) surfaces as a non-zero exit that we deliberately
# ignore. An *unanswered* prompt is worse than a denied one — the event
# blocks until it is answered — which is the other reason for the leash.
PIDS=()
osa() {
    /usr/bin/osascript - >/dev/null 2>&1 <<<"$1" &
    PIDS+=($!)
}

# Wait for the batch, then shoot whatever is still standing — but check for
# the stop signal four times a second, because the whole point is to be able
# to give up early. Polling rather than `wait` for exactly that reason.
reap() {
    (( ${#PIDS[@]} )) || return 0
    local ticks=$(( DEADLINE * 4 )) p alive
    while (( ticks-- > 0 )); do
        alive=0
        for p in "${PIDS[@]}"; do
            if kill -0 "$p" 2>/dev/null; then alive=1; break; fi
        done
        (( alive )) || return 0          # everything finished on its own
        [[ -f "$STOP_FILE" ]] && break   # the tomato is gone; drop it
        sleep 0.25
    done
    kill -9 "${PIDS[@]}" >/dev/null 2>&1
    return 0
}

# --- the players -------------------------------------------------------------
# App names here are this file's own constants and never user data, so
# interpolating them into AppleScript source is safe. Nothing from
# categories.tsv, a note, or a setting may ever be added to these strings.

# Music, TV and Spotify share one shape: ask the player state, and only then
# pause. The state check is not strictly needed (pause on a paused player is
# a no-op) but it keeps the event a question first, which is what makes a
# denied permission harmless.
pause_player_state() {
    osa "tell application \"$1\"
    try
        with timeout of 5 seconds
            if player state is playing then pause
        end timeout
    end try
end tell"
}

# VLC has no pause: play is a toggle, and its "playing" property is what
# tells us which way that toggle would swing.
pause_vlc() {
    osa 'tell application "VLC"
    try
        with timeout of 5 seconds
            if playing then play
        end timeout
    end try
end tell'
}

pause_quicktime() {
    osa 'tell application "QuickTime Player"
    repeat with d in documents
        try
            with timeout of 5 seconds
                if playing of d then pause d
            end timeout
        end try
    end repeat
end tell'
}

# The active tab of every window, and deliberately nothing else.
#
# There was a full sweep here once — every tab of every window — and it was
# the source of every hard problem this file ever had. Tabs Chrome has
# discarded answer nothing at all, at a timeout each, so a sweep took
# seventeen measured seconds on an ordinary browser. That is long enough to
# outlive the tomato, and a pause arriving after the tomato is gone stops a
# video the user has deliberately gone back to. It got a deadline, a stop
# signal and halved timeouts — and then the simpler question got asked,
# whether a tab nobody is looking at needed pausing at all. It did not.
#
# So: two Apple Events per browser, both bounded, landing in well under a
# second. The cost is a podcast in a tab you are not looking at, which keeps
# playing. That is the trade, chosen deliberately.
pause_chromium() {
    osa "tell application \"$1\"
    repeat with w in windows
        try
            with timeout of 3 seconds
                execute (active tab of w) javascript \"$PAUSE_JS\"
            end timeout
        end try
    end repeat
end tell"
}

pause_safari() {
    osa "tell application \"Safari\"
    repeat with w in windows
        try
            with timeout of 3 seconds
                do JavaScript \"$PAUSE_JS\" in (current tab of w)
            end timeout
        end try
    end repeat
end tell"
}

# --- do it -------------------------------------------------------------------
# Order is nearly meaningless now that these all run at once — a few
# microseconds separate the launches. What matters is that nobody waits for
# anybody else: a browser sitting on a permission prompt must not delay
# Spotify, which it once did by ten seconds.

rm -f "$STOP_FILE"

for b in "Google Chrome" "Brave Browser" "Microsoft Edge" Vivaldi Chromium Arc; do
    running "$b" && pause_chromium "$b"
done
running Safari && pause_safari

for p in Music TV Spotify; do
    running "$p" && pause_player_state "$p"
done
running VLC && pause_vlc
running "QuickTime Player" && pause_quicktime

reap
exit 0
