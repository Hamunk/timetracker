#!/usr/bin/env bash
# The scratch install: everything the real one has, and one named way to
# reach the real one.
#
#   ./dev.sh install        build or refresh the scratch install
#   ./dev.sh remove         tear it down  (--purge-data to drop its log too)
#   ./dev.sh status         what is installed and what is running, both sides
#   ./dev.sh seed           copy your categories — never your log — into it
#   ./dev.sh env            the four exports, for `eval "$(./dev.sh env)"`
#   ./dev.sh install-real   install this tree to the real side, if nothing is live
#
# Four things have to be separate before two installs can coexist, and three
# of them are not the data:
#
#   TIMETRACK_DIR         the log, the settings, the state file
#   TIMETRACK_APPS_DIR    the bundles
#   TIMETRACK_BID_PREFIX  their identity — what macOS hangs TCC grants on
#   TIMETRACK_VERB        the word you type — what the launcher matches
#
# Miss the third and a test run can revoke the Automation or Calendars grant
# the real install depends on. Miss the fourth and the launcher offers two
# identical rows at the moment you are trying to start work. Separate data is
# the easy part, and on its own it is not enough.

set -uo pipefail

ROOT="${0%/*}"
case "$ROOT" in
    /*) ;;
    *) ROOT="$(cd "$ROOT" && pwd)" ;;
esac

export TIMETRACK_DIR="$HOME/.timetrack-dev"
export TIMETRACK_APPS_DIR="$HOME/Applications/TimeTracker-dev"
export TIMETRACK_BID_PREFIX="com.timetracker.dev"
export TIMETRACK_VERB="devtime"

PROD_DIR="$HOME/.timetrack"
PROD_APPS="$HOME/Applications/TimeTracker"

# Three things no environment variable can separate, because they do not live
# on this machine's filesystem: your Spotify player, your Reminders lists, and
# your calendar. A scratch install that painted sessions onto the calendar you
# actually read would be a disturbance of exactly the kind this whole
# arrangement exists to prevent — so the scratch install is born with all
# three off, and with sound and media-pausing off besides. Turn one on
# deliberately, for one test, if you must; nothing here will do it for you.
#
# The durations are the minimum the settings table allows, so a full cycle —
# work, break, long break — runs in well under a minute instead of an hour.
write_dev_settings() {
    cat > "$TIMETRACK_DIR/settings.tsv" <<'TSV'
pomodoro_minutes	0.2
break_minutes	0.1
long_break_minutes	1
long_break_every	2
snooze_minutes	1
auto_accept_seconds	5
sound	off
pause_media	off
spotify	off
reminders	off
paint_calendar	off
TSV
}

cmd_seed() {
    mkdir -p "$TIMETRACK_DIR"
    chmod 700 "$TIMETRACK_DIR"
    if [[ -f "$PROD_DIR/categories.tsv" ]]; then
        cp "$PROD_DIR/categories.tsv" "$TIMETRACK_DIR/categories.tsv"
        printf 'Copied your categories (%s rows).\n' \
            "$(( $(wc -l < "$TIMETRACK_DIR/categories.tsv") - 1 ))"
    else
        printf 'No categories to copy from %s.\n' "$PROD_DIR"
    fi
    # The log is never copied. Testing wants realistic *categories*, so that
    # the bundles and the launcher behave as they really do; it has no use for
    # your hours, and a scratch copy of them is one more place they can leak.
    [[ -f "$TIMETRACK_DIR/sessions.tsv" ]] || \
        printf 'start_iso\tend_iso\tduration_sec\tcategory\tnote\tplan\trecap\tpomodoros\tbreak_overrun_sec\n' \
            > "$TIMETRACK_DIR/sessions.tsv"
    write_dev_settings
    printf 'Wrote fast, quiet scratch settings.\n'
}

cmd_install() {
    [[ -d "$TIMETRACK_DIR" ]] || cmd_seed
    [[ -f "$TIMETRACK_DIR/settings.tsv" ]] || write_dev_settings
    "$ROOT/spotlight/install.sh"
}

cmd_remove() {
    "$ROOT/spotlight/uninstall.sh" "${1:-}"
}

# The one path from this script to the real install, named for what it does.
# Two guards. It refuses while a session or a cycle is live: the installer
# overwrites the scripts a running watcher is executing and replaces the
# bundle a running overlay is drawn from, and a break interrupted by its own
# tool is the one failure this whole arrangement exists to prevent. And it
# keeps the identity the installed bundles already have, read off one of
# them, so the Automation, Reminders and Calendars grants macOS keyed to that
# identity survive the reinstall. A first install on a fresh machine has no
# bundles to read and gets the default.
cmd_install_real() {
    local live bid prefix="" app
    if [[ -s "$PROD_DIR/state" ]]; then
        printf 'Refused: a session is running (%s). Stop it first.\n' \
            "$(cut -f2 "$PROD_DIR/state" 2>/dev/null)"
        return 1
    fi
    if [[ -f "$PROD_DIR/pomodoro" ]]; then
        printf 'Refused: a pomodoro cycle is live.\n'
        return 1
    fi
    live=$(running "$PROD_DIR" "$PROD_APPS")
    case "$live" in
        *watcher*|*overlay*)
            printf 'Refused: still running on the real side:%s\n' "$live"
            return 1 ;;
    esac
    for app in "$PROD_APPS"/*.app; do
        bid=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "$app/Contents/Info.plist" 2>/dev/null) || continue
        case "$bid" in *.toggle) prefix="${bid%.toggle}"; break ;; esac
    done
    printf 'Installing %s to the real side\n  data      %s\n  apps      %s\n  identity  %s%s\n\n' \
        "$ROOT" "$PROD_DIR" "$PROD_APPS" "${prefix:-com.timetracker}" \
        "${prefix:+   (kept, so the permission grants survive)}"
    # Every scratch variable this script exported is dropped here, so the
    # installer sees the real defaults and nothing else.
    env -u TIMETRACK_DIR -u TIMETRACK_APPS_DIR -u TIMETRACK_VERB \
        TIMETRACK_BID_PREFIX="${prefix:-com.timetracker}" \
        "$ROOT/spotlight/install.sh"
}

running() {
    # Scoped to one install's own copies, the same way uninstall.sh is: a bare
    # name would count the other install's processes as this one's.
    local bin="$1/bin" apps="$2" out q
    q() { printf '%s' "$1" | sed 's#[][^$.*+?(){}|\\]#\\&#g'; }
    pgrep -f "^$(q "$bin")/pomodoro-watch\.sh" >/dev/null 2>&1 && printf ' watcher'
    pgrep -f "^$(q "$apps")/TimeTracker Prompt\.app/Contents/MacOS/ttprompt overlay" \
        >/dev/null 2>&1 && printf ' overlay'
    pgrep -f "^/usr/bin/python3 $(q "$bin")/dashboard\.py" >/dev/null 2>&1 && printf ' dashboard'
    return 0
}

cmd_status() {
    local d a
    for side in "real:$PROD_DIR:$PROD_APPS:time" \
                "scratch:$TIMETRACK_DIR:$TIMETRACK_APPS_DIR:$TIMETRACK_VERB"; do
        IFS=: read -r label d a verb <<< "$side"
        printf '%-8s  verb "%s"\n' "$label" "$verb"
        printf '          data     %s%s\n' "$d" \
            "$([[ -d $d ]] && printf '' || printf '   (absent)')"
        printf '          apps     %s   (%s bundles)\n' "$a" \
            "$(ls -d "$a"/*.app 2>/dev/null | wc -l | tr -d ' ')"
        if [[ -s "$d/state" ]]; then
            printf '          session  RUNNING — %s\n' "$(cut -f1,2 "$d/state" 2>/dev/null | tr '\t' ' ')"
        else
            printf '          session  idle\n'
        fi
        r=$(running "$d" "$a"); printf '          running %s\n' "${r:- none}"
    done
}

cmd_env() {
    printf 'export TIMETRACK_DIR=%q\n'        "$TIMETRACK_DIR"
    printf 'export TIMETRACK_APPS_DIR=%q\n'   "$TIMETRACK_APPS_DIR"
    printf 'export TIMETRACK_BID_PREFIX=%q\n' "$TIMETRACK_BID_PREFIX"
    printf 'export TIMETRACK_VERB=%q\n'       "$TIMETRACK_VERB"
}

case "${1:-status}" in
    install)      cmd_install ;;
    install-real) cmd_install_real ;;
    remove)       cmd_remove "${2:-}" ;;
    seed)         cmd_seed ;;
    status)       cmd_status ;;
    env)          cmd_env ;;
    *) sed -n '2,11p' "$0"; exit 2 ;;
esac
