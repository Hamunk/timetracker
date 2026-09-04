#!/usr/bin/env bash
# Installs the Spotlight edition of TimeTracker:
#   1. copies the runtime scripts into ~/.timetrack/bin/
#   2. generates + registers the app bundles in ~/Applications/TimeTracker/
#
# Re-run any time to update. Safe to run repeatedly.

set -euo pipefail

SRC_DIR="${0%/*}"
case "$SRC_DIR" in
    /*) ;;
    *) SRC_DIR="$(cd "$SRC_DIR" && pwd)" ;;
esac

DATA_DIR="${TIMETRACK_DIR:-$HOME/.timetrack}"
BIN_DIR="$DATA_DIR/bin"

# Reverse-DNS prefix for the helper bundles and the launchd labels. macOS ties
# TCC permission grants to this identity, so a change here costs one round of
# re-granting Automation/Calendars/Reminders and nothing else.
BID_PREFIX="com.timetracker"

mkdir -p "$BIN_DIR"
# Your log is a record of when you work and what on. On a shared Mac the
# default 755 would let other local accounts read it.
chmod 700 "$DATA_DIR"

for f in action.sh notify.sh toggle.sh newcat.sh sync-apps.sh prompt.sh start.sh \
         settings.sh pomodoro-watch.sh pause-media.sh spotify.sh \
         paint-calendar.sh; do
    cp "$SRC_DIR/$f" "$BIN_DIR/$f"
done
for f in dashboard.py migrate_v2.py; do
    cp "$SRC_DIR/$f" "$BIN_DIR/$f"
done

chmod +x "$BIN_DIR"/*.sh

# Reads a bundle's CFBundleIdentifier, printing nothing if there is no bundle
# or no key. Used by the rebuild checks: an identifier that no longer matches
# is a reason to rebuild that no file mtime can express.
bundle_id_of() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$1/Contents/Info.plist" 2>/dev/null || true
}

SESS_HEADER=$'start_iso\tend_iso\tduration_sec\tcategory\tnote\tplan\trecap\tpomodoros\tbreak_overrun_sec'

# Seed the data files so the first launch has something to read.
[[ -f "$DATA_DIR/state" ]] || : > "$DATA_DIR/state"
CAT_HEADER=$'key\tname\tkeywords\tlast_used_epoch\thidden'
[[ -f "$DATA_DIR/categories.tsv" ]] || \
    printf '%s\n' "$CAT_HEADER" > "$DATA_DIR/categories.tsv"
[[ -f "$DATA_DIR/sessions.tsv" ]] || \
    printf '%s\n' "$SESS_HEADER" > "$DATA_DIR/sessions.tsv"

# One-line header upgrade for the pomodoro columns: only if the first line is
# exactly a known older header — rows are untouched (readers tolerate short
# rows, per the established plan/recap convention).
OLD7=$'start_iso\tend_iso\tduration_sec\tcategory\tnote\tplan\trecap'
OLD5=$'start_iso\tend_iso\tduration_sec\tcategory\tnote'
first=$(head -1 "$DATA_DIR/sessions.tsv")
if [[ "$first" == "$OLD7" || "$first" == "$OLD5" ]]; then
    tmp=$(mktemp "$DATA_DIR/.sessions.XXXXXX")
    { printf '%s\n' "$SESS_HEADER"; tail -n +2 "$DATA_DIR/sessions.tsv"; } > "$tmp"
    mv -f "$tmp" "$DATA_DIR/sessions.tsv"
fi

# --- retire the calendar auto-start ------------------------------------------
# It read the calendar and started timers off a lecture already under way. It
# is gone: guessing what you are doing from what you scheduled is a guess, and
# a wrong guess is worse than no guess now that a session can be corrected
# afterwards. What replaced it points the other way — see the painter below.
#
# This runs on every install, not once, because the failure it prevents is
# silent: launchd would go on firing a script that no longer exists, every few
# minutes, for as long as the machine lives.
# Matched by shape, not by exact label: an install predating the current bundle
# prefix registered this agent under that prefix, and it is exactly the install
# most likely to still have it loaded.
for CAL_PLIST in "$HOME/Library/LaunchAgents"/*.timetracker.calendar.plist; do
    [[ -f "$CAL_PLIST" ]] || continue
    CAL_LABEL="${CAL_PLIST##*/}"; CAL_LABEL="${CAL_LABEL%.plist}"
    printf 'Removing the old calendar auto-start agent...\n'
    launchctl bootout "gui/$(id -u)/$CAL_LABEL" 2>/dev/null || \
        launchctl unload "$CAL_PLIST" 2>/dev/null || true
    rm -f "$CAL_PLIST"
done
rm -f "$BIN_DIR/calendar-agent.sh" "$BIN_DIR/calendar_agent.py" \
      "$DATA_DIR/.calendar-events.tsv" "$DATA_DIR/.calendar-handled" \
      "$DATA_DIR/calendar-agent.log"

# Converts a pre-key categories.tsv and rewrites the log to keys. Backs up
# both first, and is a no-op once already migrated.
/usr/bin/python3 "$BIN_DIR/migrate_v2.py"

# Same one-line header upgrade as sessions.tsv above, for the hidden column.
# Rows keep four fields until something hides them; every reader treats a
# missing 5th field as "not hidden".
OLD_CAT=$'key\tname\tkeywords\tlast_used_epoch'
first=$(head -1 "$DATA_DIR/categories.tsv")
if [[ "$first" == "$OLD_CAT" ]]; then
    tmp=$(mktemp "$DATA_DIR/.categories.XXXXXX")
    { printf '%s\n' "$CAT_HEADER"; tail -n +2 "$DATA_DIR/categories.tsv"; } > "$tmp"
    mv -f "$tmp" "$DATA_DIR/categories.tsv"
fi

# --- pomodoro prompt/overlay helper ------------------------------------------
# A native window with a real checkbox, and the full-screen tomato. Compiled
# like the calendar helper. It is what pomodoro mode *is*: without swiftc the
# plan prompt still appears, the tracker is untouched, and the cycle is not
# offered at all — there is no notifications-only imitation of it.

APPS_DIR="${TIMETRACK_APPS_DIR:-$HOME/Applications/TimeTracker}"
HELPER_APP="$APPS_DIR/TimeTracker Prompt.app"
HELPER_BIN="$HELPER_APP/Contents/MacOS/ttprompt"
if command -v swiftc >/dev/null 2>&1; then
    mkdir -p "$APPS_DIR"
    # Rebuild only when something actually changed. This matters more than it
    # looks: an up-to-date bundle is left completely untouched, and touching
    # it is exactly what macOS forbids (see below).
    if [[ ! -x "$HELPER_BIN" || "$SRC_DIR/ttprompt.swift" -nt "$HELPER_BIN" \
          || "$SRC_DIR/tomato.html" -nt "$HELPER_BIN" \
          || $(bundle_id_of "$HELPER_APP") != "$BID_PREFIX.prompt.helper" ]]; then
        printf 'Compiling prompt/overlay helper (takes ~1 min)...\n'
        # Build a complete bundle beside the real one and swap it in.
        # Once this bundle is code-signed, macOS App Management (Sonoma and
        # later) refuses writes *into* it from anything without App Management
        # permission: an in-place rebuild dies with
        #   ld: open() failed, errno=1 (Operation not permitted)
        # after the linker has already removed the old executable, leaving an
        # empty Contents/MacOS. Replacing the whole bundle is allowed, so
        # compile off to the side, sign last, then delete and move.
        STAGE="$APPS_DIR/.prompt-build.$$"
        rm -rf "$STAGE"
        mkdir -p "$STAGE/TimeTracker Prompt.app/Contents/MacOS" \
                 "$STAGE/TimeTracker Prompt.app/Contents/Resources"
        STAGE_APP="$STAGE/TimeTracker Prompt.app"
        swiftc -O "$SRC_DIR/ttprompt.swift" -o "$STAGE_APP/Contents/MacOS/ttprompt"
        cp "$SRC_DIR/tomato.html" "$STAGE_APP/Contents/Resources/tomato.html"
        cat > "$STAGE_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>TimeTracker Prompt</string>
	<key>CFBundleDisplayName</key>
	<string>TimeTracker Prompt</string>
	<key>CFBundleExecutable</key>
	<string>ttprompt</string>
	<key>CFBundleIdentifier</key>
	<string>$BID_PREFIX.prompt.helper</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSUIElement</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>11.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF
        # Ad-hoc signing gives the bundle a stable identity across rebuilds,
        # following the calendar helper's precedent. Signed last, so every
        # write above happens while the bundle is still unprotected.
        codesign --force -s - "$STAGE_APP" >/dev/null 2>&1 || \
            printf 'warning: could not ad-hoc sign the prompt helper\n'
        rm -rf "$HELPER_APP"
        mv "$STAGE_APP" "$APPS_DIR/"
        rm -rf "$STAGE"
    fi
    # --- reminder capture helper ---------------------------------------------
    # The break menu's "Add Reminder" writes through EventKit, which macOS only
    # grants to a bundle launched through LaunchServices — the same rule, and
    # the same shape, as the calendar helper. Built here rather than in a
    # separate installer because it needs no permission until the first note is
    # actually saved, and the tracker is unaffected either way: without this
    # binary the watcher simply never offers the entry.
    REM_APP="$APPS_DIR/TimeTracker Reminders.app"
    REM_BIN="$REM_APP/Contents/MacOS/ttremind"
    if [[ ! -x "$REM_BIN" || "$SRC_DIR/ttremind.swift" -nt "$REM_BIN" \
          || $(bundle_id_of "$REM_APP") != "$BID_PREFIX.reminders.helper" ]]; then
        printf 'Compiling reminder helper...\n'
        # Same build-beside-and-swap dance as above: once a bundle is signed,
        # macOS App Management refuses writes into it, and an in-place rebuild
        # dies after the linker has already removed the old executable.
        RSTAGE="$APPS_DIR/.reminders-build.$$"
        rm -rf "$RSTAGE"
        mkdir -p "$RSTAGE/TimeTracker Reminders.app/Contents/MacOS"
        RSTAGE_APP="$RSTAGE/TimeTracker Reminders.app"
        swiftc -O "$SRC_DIR/ttremind.swift" -o "$RSTAGE_APP/Contents/MacOS/ttremind"
        cat > "$RSTAGE_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>TimeTracker Reminders</string>
	<key>CFBundleDisplayName</key>
	<string>TimeTracker Reminders</string>
	<key>CFBundleExecutable</key>
	<string>ttremind</string>
	<key>CFBundleIdentifier</key>
	<string>$BID_PREFIX.reminders.helper</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSUIElement</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>11.0</string>
	<key>NSRemindersUsageDescription</key>
	<string>TimeTracker files the notes you write during a pomodoro break in your Reminders.</string>
	<key>NSRemindersFullAccessUsageDescription</key>
	<string>TimeTracker files the notes you write during a pomodoro break in your Reminders.</string>
</dict>
</plist>
EOF
        # Ad-hoc signed for a stable identity, so the Reminders permission
        # survives a rebuild instead of being asked for again.
        codesign --force -s - "$RSTAGE_APP" >/dev/null 2>&1 || \
            printf 'warning: could not ad-hoc sign the reminder helper\n'
        rm -rf "$REM_APP"
        mv "$RSTAGE_APP" "$APPS_DIR/"
        rm -rf "$RSTAGE"
    fi
    # --- calendar painter ------------------------------------------------------
    # Writes the sessions you logged into a calendar of their own. Keeps the
    # bundle name and identifier the old calendar *reader* had, so the Calendar
    # permission you already granted carries over rather than being asked for
    # again under a new name — the app is doing the opposite job now, but it is
    # the same app asking for the same access to the same store.
    CAL_APP="$APPS_DIR/TimeTracker Calendar.app"
    CAL_BIN="$CAL_APP/Contents/MacOS/ttpaint"
    if [[ ! -x "$CAL_BIN" || "$SRC_DIR/ttpaint.swift" -nt "$CAL_BIN" \
          || $(bundle_id_of "$CAL_APP") != "$BID_PREFIX.calendar.helper" ]]; then
        printf 'Compiling calendar painter...\n'
        CSTAGE="$APPS_DIR/.calendar-build.$$"
        rm -rf "$CSTAGE"
        mkdir -p "$CSTAGE/TimeTracker Calendar.app/Contents/MacOS"
        CSTAGE_APP="$CSTAGE/TimeTracker Calendar.app"
        swiftc -O "$SRC_DIR/ttpaint.swift" -o "$CSTAGE_APP/Contents/MacOS/ttpaint"
        cat > "$CSTAGE_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>TimeTracker Calendar</string>
	<key>CFBundleDisplayName</key>
	<string>TimeTracker Calendar</string>
	<key>CFBundleExecutable</key>
	<string>ttpaint</string>
	<key>CFBundleIdentifier</key>
	<string>$BID_PREFIX.calendar.helper</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSUIElement</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>11.0</string>
	<key>NSCalendarsUsageDescription</key>
	<string>TimeTracker paints the sessions you have tracked onto a calendar of their own, so you can see what you actually did next to what you planned.</string>
	<key>NSCalendarsFullAccessUsageDescription</key>
	<string>TimeTracker paints the sessions you have tracked onto a calendar of their own, so you can see what you actually did next to what you planned.</string>
</dict>
</plist>
EOF
        codesign --force -s - "$CSTAGE_APP" >/dev/null 2>&1 || \
            printf 'warning: could not ad-hoc sign the calendar painter\n'
        rm -rf "$CAL_APP"
        mv "$CSTAGE_APP" "$APPS_DIR/"
        rm -rf "$CSTAGE"
    fi
else
    printf 'swiftc not found — the tracker is fully installed, but pomodoro\n'
    printf 'mode needs the compiled helper and will not be offered.\n'
    printf 'To enable it: xcode-select --install, then re-run this script.\n'
fi

# A running dashboard loaded dashboard.py once, at startup, and "time
# settings" deliberately reuses an existing server rather than starting a
# second one — so after an upgrade the old code goes on being served until it
# times out. It holds nothing but a port and a token, so stopping it is free
# and the next launch starts fresh on the code just installed.
if pkill -f "$BIN_DIR/dashboard.py" 2>/dev/null; then
    rm -f "$DATA_DIR/.dashboard"
    printf 'Stopped the running dashboard so it picks up this version.\n'
fi

"$BIN_DIR/sync-apps.sh"

cat <<EOF

Installed.

  scripts:  $BIN_DIR
  apps:     ${TIMETRACK_APPS_DIR:-$HOME/Applications/TimeTracker}

Try it:  Cmd+Space  ->  "time new"  ->  Enter

The pomodoro break menu has two tools, and each needs one permission that is
much better answered now than in the middle of a break — an unanswered prompt
blocks the thing that raised it:

  Cmd+Space  ->  "time spotify"    ->  Enter     (Automation: Spotify)
  Cmd+Space  ->  "time reminders"  ->  Enter     (Privacy: Reminders)
  Cmd+Space  ->  "time calendar"   ->  Enter     (Privacy: Calendars)

All three report what they found and change nothing. Then open Settings to add
your break playlists, pick the one you keep for work, and choose the calendar
your tracked sessions get painted onto:

  Cmd+Space  ->  "time settings"   ->  Enter

Give painting an empty calendar of its own: everything in it inside the last
two weeks is rewritten to match the log, every time a session closes. To have
it sync to your phone and toggle on and off like any other, create it in
Google Calendar (Other calendars > +), tick it at

  https://calendar.google.com/calendar/syncselect

and it will appear here for you to choose. Google's CalDAV cannot create
calendars, which is why that one step has to be yours.
EOF
