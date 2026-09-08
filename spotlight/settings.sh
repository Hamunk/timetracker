#!/usr/bin/env bash
# TimeTracker settings reader — the one place the settings table lives.
#
# Source this file; never execute settings.tsv (it's user-editable data, and
# user-editable content must never run as code — it is parsed with awk only).
#
#   tt_setting <key>        prints the value, or the default if the file, the
#                           key, or a sane value is missing. Never fails and
#                           never prints an error: callers trust it blindly.
#   tt_setting_secs <key>   a minutes setting as whole seconds, floor(v*60).
#                           Use this rather than multiplying in the shell:
#                           some durations accept fractional minutes.
#   tt_setting_spec <key>   sets TT_DEF, TT_MIN, TT_MAX (MIN/MAX empty means
#                           the value is the on/off enum, or a key name when
#                           TT_KEY is set). rc 1 = unknown key.
#   tt_setting_keys         prints every known key, one per line.
#   tt_setting_valid <key> <value>   rc 0 iff the value is in range.
#
# settings.tsv is key<TAB>value, one per line, no header, honouring
# TIMETRACK_DIR like every other data file. All writes go through
# "action.sh setconf", which sources this file for validation.

# The whole defaults-and-ranges table. Add new settings here and only here.
tt_setting_spec() {
    TT_DEF="" TT_MIN="" TT_MAX="" TT_FRAC="" TT_KEY=""
    case "$1" in
        # TT_FRAC marks a setting that also takes fractional minutes, so a
        # whole cycle can be exercised in seconds while testing: 0.5 is 30
        # seconds. Read them with tt_setting_secs, never with plain shell
        # arithmetic, which can't multiply a decimal.
        pomodoro_minutes)   TT_DEF=25 TT_MIN=0.1 TT_MAX=180 TT_FRAC=1 ;;
        break_minutes)      TT_DEF=5  TT_MIN=0.1 TT_MAX=60  TT_FRAC=1 ;;
        long_break_minutes) TT_DEF=15 TT_MIN=1 TT_MAX=120 ;;
        long_break_every)   TT_DEF=4  TT_MIN=1 TT_MAX=12  ;;
        snooze_minutes)     TT_DEF=5  TT_MIN=1 TT_MAX=60  ;;
        # In seconds, not minutes: this one is meant to be short. It only
        # applies to the tomato — a break waits for you indefinitely.
        auto_accept_seconds) TT_DEF=60 TT_MIN=1 TT_MAX=600 ;;
        # Only the starting position of the start prompt's checkbox. The box
        # is still there either way — this never arms a cycle by itself.
        pomodoro_default)   TT_DEF=off ;;
        sound)              TT_DEF=on ;;
        # Pause every player we can reach when the tomato takes the screen.
        # Off is the honest setting for anyone who listens to music through
        # breaks — it silences the break's start, not just the video.
        pause_media)        TT_DEF=on ;;
        # The tomato clicker hidden behind a click on the break screen. Off
        # just makes the tomato inert on break — nothing else changes.
        easter_egg)         TT_DEF=on ;;
        # The two break-menu tools. Each only *offers* itself: with both off
        # the hamburger never renders and the pause screen is exactly what it
        # was before. Neither one can start a cycle, end a break, or write a
        # row — they hang off the break, they are not part of it.
        spotify)            TT_DEF=on ;;
        reminders)          TT_DEF=on ;;
        # What happens to the music when you press "I'm back". On: the work
        # playlist (the one marked `work` in spotify-playlists.tsv) starts and
        # the break's music is gone. Off: Spotify is paused instead, which is
        # still not "leave it playing" — break music bleeding into a work
        # session is the thing this exists to prevent, and the next tomato
        # would only hush it again anyway.
        spotify_resume_work) TT_DEF=on ;;
        # A break that runs over while music you started is still playing:
        # pause it. The silence is the notification, and it is the one kind
        # that reaches someone who has wandered off with headphones on.
        # Only ever fires for music the break menu itself started.
        spotify_pause_on_overrun) TT_DEF=on ;;
        # Keys on the break screen. TT_KEY marks a setting whose value is a
        # key name: a single letter or digit, or Tab or Space. Letters are
        # matched without regard to case.
        key_menu)           TT_DEF=Tab TT_KEY=1 ;;
        key_spotify)        TT_DEF=s   TT_KEY=1 ;;
        key_reminder)       TT_DEF=n   TT_KEY=1 ;;
        # Painting the log onto a calendar. On by itself does nothing: the
        # calendar to paint into is named in its own file (free text, so not
        # table material), and without one every paint says so and stops.
        paint_calendar)     TT_DEF=on ;;
        # How far back a paint reconciles. It is a *window*, not a start
        # date: everything in it is made to match the log, so a longer one
        # costs a little more work and forgives a longer outage.
        paint_days)         TT_DEF=14 TT_MIN=1 TT_MAX=90 ;;
        # Sessions shorter than this are not painted. A mis-tap that ran for
        # forty seconds is not something you want to see in a week view.
        paint_min_minutes)  TT_DEF=2 TT_MIN=0 TT_MAX=60 ;;
        *) return 1 ;;
    esac
}

tt_setting_keys() {
    printf '%s\n' pomodoro_minutes break_minutes long_break_minutes \
        long_break_every snooze_minutes auto_accept_seconds pomodoro_default \
        sound pause_media key_menu key_spotify key_reminder \
        easter_egg spotify spotify_resume_work spotify_pause_on_overrun \
        reminders paint_calendar paint_days paint_min_minutes
}

tt_setting_valid() {
    tt_setting_spec "$1" || return 1
    if [[ -n "$TT_KEY" ]]; then
        [[ "$2" =~ ^([A-Za-z0-9]|Tab|Space)$ ]]
    elif [[ -z "$TT_MIN" ]]; then
        [[ "$2" == "on" || "$2" == "off" ]]
    elif [[ -n "$TT_FRAC" ]]; then
        # Decimals need awk: the shell can only compare integers.
        [[ "$2" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
        awk -v v="$2" -v lo="$TT_MIN" -v hi="$TT_MAX" \
            'BEGIN { exit !(v+0 >= lo+0 && v+0 <= hi+0) }'
    else
        # 10# so a value like "08" is compared as decimal, not rejected octal.
        [[ "$2" =~ ^[0-9]+$ ]] && (( 10#$2 >= TT_MIN && 10#$2 <= TT_MAX ))
    fi
}

# A minutes setting as whole seconds: floor(value * 60). This is the only
# way callers should turn a duration into seconds — plain $(( x * 60 )) dies
# on a decimal. The epsilon is deliberate: 0.7 * 60 is 41.999... in binary
# floating point, and flooring that to 41 would be a surprise.
tt_setting_secs() {
    local v; v=$(tt_setting "$1")
    awk -v v="$v" 'BEGIN { s = int(v * 60 + 1e-9); if (s < 1) s = 1; print s }'
}

tt_setting() {
    local file="${TIMETRACK_DIR:-$HOME/.timetrack}/settings.tsv" value=""
    # The key reaches awk through the environment, never through -v: awk
    # expands backslash escapes in -v assignments (same rule as action.sh).
    if [[ -r "$file" ]]; then
        value=$(TT_SK="$1" awk -F'\t' 'BEGIN{k=ENVIRON["TT_SK"]}
            $1==k { print $2; exit }' "$file" 2>/dev/null) || value=""
    fi
    if [[ -n "$value" ]] && tt_setting_valid "$1" "$value"; then
        printf '%s\n' "$value"
    elif tt_setting_spec "$1"; then
        printf '%s\n' "$TT_DEF"
    fi
    # An unknown key prints nothing — but still exits 0, per the contract.
    return 0
}
