#!/usr/bin/env bash
# Installs TimeTracker, or updates it in place:
#   1. checks it is safe to: no pomodoro cycle live, no data from a newer version
#   2. backs up the data and brings it to this version's format (migrate.py)
#   3. copies the runtime scripts into ~/.timetrack/bin/
#   4. builds the helpers and registers the launcher bundles
#
# Re-run any time. It only changes what changed.

set -euo pipefail

SRC_DIR="${0%/*}"
case "$SRC_DIR" in
    /*) ;;
    *) SRC_DIR="$(cd "$SRC_DIR" && pwd)" ;;
esac

DATA_DIR="${TIMETRACK_DIR:-$HOME/.timetrack}"
BIN_DIR="$DATA_DIR/bin"
APPS_DIR="${TIMETRACK_APPS_DIR:-$HOME/Applications/TimeTracker}"
VERB="${TIMETRACK_VERB:-time}"

NEW_VERSION=$(head -1 "$SRC_DIR/../VERSION" 2>/dev/null || true)
NEW_VERSION="${NEW_VERSION:-unknown}"
OLD_VERSION=$(head -1 "$BIN_DIR/VERSION" 2>/dev/null || true)
if [[ -z "$OLD_VERSION" ]]; then
    # Everything before 2.0 installed without a VERSION file.
    if [[ -d "$BIN_DIR" ]]; then OLD_VERSION="1"; else OLD_VERSION="none"; fi
fi

# Reads a bundle's CFBundleIdentifier, printing nothing if there is no bundle
# or no key. Used by the rebuild checks: an identifier that no longer matches
# is a reason to rebuild that no file mtime can express.
bundle_id_of() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$1/Contents/Info.plist" 2>/dev/null || true
}

# Reverse-DNS prefix for every bundle. macOS ties TCC permission grants to this
# identity, so a change here costs one round of re-granting Automation,
# Calendars and Reminders.
#
# Unset, it is the identity the installed bundles already have, read off the
# toggle — not the default. An update that quietly moved an install from one
# prefix to another would be a release whose first visible effect is three
# permission prompts in the middle of a break. A fresh machine has nothing to
# read and gets the default.
#
# A scratch install sets it, and TIMETRACK_DIR alone is not enough to make one
# safe. Two bundles sharing an identifier are, to LaunchServices and to TCC,
# the same app: the grants you answered for the real one would be handed to
# whichever copy asked last, and taken from it again just as quietly.
BID_PREFIX="${TIMETRACK_BID_PREFIX:-}"
if [[ -z "$BID_PREFIX" ]]; then
    for app in "$APPS_DIR"/*.app; do
        bid=$(bundle_id_of "$app")
        case "$bid" in *.toggle) BID_PREFIX="${bid%.toggle}"; break ;; esac
    done
fi
BID_PREFIX="${BID_PREFIX:-com.timetracker}"
# sync-apps.sh bakes it into every bundle it generates, so that a category
# added later — from the dashboard, or with "time new" — is built under the
# same identity and not under the default.
export TIMETRACK_BID_PREFIX="$BID_PREFIX"

# --- is it safe? ---------------------------------------------------------------
# A live pomodoro cycle is running the watcher script this would replace, and
# the overlay bundle this would rebuild; the watcher relaunches that overlay
# by path, so a cycle that outlived its install would come back as a new
# program speaking to an old one. A plain running timer is fine: it is one
# line in `state`, and every version reads it.
if [[ -f "$DATA_DIR/pomodoro" ]]; then
    IFS=$'\t' read -r _ _ _ _ _ _ wpid < "$DATA_DIR/pomodoro" 2>/dev/null || true
    if [[ "${wpid:-}" =~ ^[0-9]+$ ]] && kill -0 "$wpid" 2>/dev/null; then
        printf 'A pomodoro is running. Install again when it has ended.\n'
        exit 1
    fi
fi

mkdir -p "$BIN_DIR"
# Your log is a record of when you work and what on. On a shared Mac the
# default 755 would let other local accounts read it.
chmod 700 "$DATA_DIR"

SESS_HEADER=$'start_iso\tend_iso\tduration_sec\tcategory\tnote\tplan\trecap\tpomodoros\tbreak_overrun_sec'
CAT_HEADER=$'key\tname\tkeywords\tlast_used_epoch\thidden\tcode'

# Seed the data files so the first launch has something to read.
[[ -f "$DATA_DIR/state" ]] || : > "$DATA_DIR/state"
[[ -f "$DATA_DIR/categories.tsv" ]] || \
    printf '%s\n' "$CAT_HEADER" > "$DATA_DIR/categories.tsv"
[[ -f "$DATA_DIR/sessions.tsv" ]] || \
    printf '%s\n' "$SESS_HEADER" > "$DATA_DIR/sessions.tsv"

# Run from the source, not from bin: it is the new version's migrations that
# have to run, and the new version's ceiling that decides whether this data is
# too new for it. That refusal comes before a single script is replaced.
if ! /usr/bin/python3 "$SRC_DIR/migrate.py" --install "$OLD_VERSION" "$NEW_VERSION"; then
    printf 'Nothing was installed.\n'
    exit 1
fi

# Each file goes in beside its old copy and is renamed over it. cp alone
# rewrites the old file where it stands, and bash reads a script as it runs:
# a toggle started a moment before would carry on reading the new bytes at
# the old offsets.
install_file() {
    local tmp
    tmp=$(mktemp "$BIN_DIR/.install.XXXXXX")
    cp "$1" "$tmp"
    chmod "$3" "$tmp"
    mv -f "$tmp" "$BIN_DIR/$2"
}
for f in action.sh notify.sh toggle.sh sync-apps.sh prompt.sh start.sh \
         settings.sh pomodoro-watch.sh pause-media.sh spotify.sh \
         paint-calendar.sh update.sh; do
    install_file "$SRC_DIR/$f" "$f" 755
done
for f in dashboard.py migrate.py app.html; do
    install_file "$SRC_DIR/$f" "$f" 644
done
install_file "$SRC_DIR/../VERSION" VERSION 644
# Gone in 2.0. The first's example seed went with it, and the rest of it is
# migrate.py; the second's three dialogs are the app's Subjects page.
rm -f "$BIN_DIR/migrate_v2.py" "$BIN_DIR/newcat.sh"

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

# --- pomodoro prompt/overlay helper ------------------------------------------
# A native window with a real checkbox, and the full-screen tomato. Compiled
# like the calendar helper. It is what pomodoro mode *is*: without swiftc the
# plan prompt still appears, the tracker is untouched, and the cycle is not
# offered at all — there is no notifications-only imitation of it.

HELPER_APP="$APPS_DIR/TimeTracker Prompt.app"
HELPER_BIN="$HELPER_APP/Contents/MacOS/ttprompt"
if command -v swiftc >/dev/null 2>&1; then
    mkdir -p "$APPS_DIR"
    # The Now Playing pause, for pause-media.sh. A bare binary in bin rather
    # than a bundle: it asks macOS for no permission, so there is no grant for
    # a bundle's name to carry. Built beside and renamed in, like the scripts.
    if [[ ! -x "$BIN_DIR/ttpause" || "$SRC_DIR/ttpause.swift" -nt "$BIN_DIR/ttpause" ]]; then
        swiftc -O "$SRC_DIR/ttpause.swift" -o "$BIN_DIR/.ttpause.$$" \
            && mv -f "$BIN_DIR/.ttpause.$$" "$BIN_DIR/ttpause"
    fi
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
        # The page shows text written on other people's machines, so the copy
        # installed here allows exactly one script: its own, by hash. With
        # 'unsafe-inline', as the source has so it can be opened in a browser
        # for the #demo views, an injected onerror="" would run; with the hash
        # it cannot. If the hash cannot be taken the page keeps 'unsafe-inline'
        # and says so, rather than being installed with its script blocked — a
        # break screen whose script does not run is one that cannot be ended.
        /usr/bin/python3 - "$STAGE_APP/Contents/Resources/tomato.html" <<'PY' || \
            printf 'warning: the break screen keeps script-src unsafe-inline\n'
import base64, hashlib, re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
blocks = re.findall(r"<script>(.*?)</script>", s, re.S)
if len(blocks) != 1 or s.count("script-src 'unsafe-inline'") != 1:
    sys.exit(1)
h = base64.b64encode(hashlib.sha256(blocks[0].encode("utf-8")).digest()).decode()
open(p, "w", encoding="utf-8").write(
    s.replace("script-src 'unsafe-inline'", "script-src 'sha256-%s'" % h))
PY
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
    # --- break chat helper ---------------------------------------------------
    # The break menu's Messages, and the one program here that talks to the
    # internet. It needs no permission from macOS — it only ever connects out —
    # so it could be a bare binary; it is a bundle so that it has a name and
    # an identity of its own, which is what an outbound firewall shows you
    # when it asks whether "TimeTracker Chat" may reach ntfy.sh. The watcher
    # runs its binary directly, during a break and never otherwise.
    CHAT_APP="$APPS_DIR/TimeTracker Chat.app"
    CHAT_BIN="$CHAT_APP/Contents/MacOS/ttchat"
    if [[ ! -x "$CHAT_BIN" || "$SRC_DIR/ttchat.swift" -nt "$CHAT_BIN" \
          || $(bundle_id_of "$CHAT_APP") != "$BID_PREFIX.chat.helper" ]]; then
        printf 'Compiling break chat helper...\n'
        # The same build-beside-and-swap as the two helpers above.
        HSTAGE="$APPS_DIR/.chat-build.$$"
        rm -rf "$HSTAGE"
        mkdir -p "$HSTAGE/TimeTracker Chat.app/Contents/MacOS"
        HSTAGE_APP="$HSTAGE/TimeTracker Chat.app"
        swiftc -O "$SRC_DIR/ttchat.swift" -o "$HSTAGE_APP/Contents/MacOS/ttchat"
        cat > "$HSTAGE_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>TimeTracker Chat</string>
	<key>CFBundleDisplayName</key>
	<string>TimeTracker Chat</string>
	<key>CFBundleExecutable</key>
	<string>ttchat</string>
	<key>CFBundleIdentifier</key>
	<string>$BID_PREFIX.chat.helper</string>
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
</dict>
</plist>
EOF
        codesign --force -s - "$HSTAGE_APP" >/dev/null 2>&1 || \
            printf 'warning: could not ad-hoc sign the break chat helper\n'
        rm -rf "$CHAT_APP"
        mv "$HSTAGE_APP" "$APPS_DIR/"
        rm -rf "$HSTAGE"
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
    # --- the app -------------------------------------------------------------
    # The window: everything the launcher does, as buttons. A regular app,
    # with a Dock icon, because it is the one bundle here meant to be found
    # and opened by somebody who has never heard of the launcher. A scratch
    # install's carries its verb in its name, so the two are told apart in
    # the Dock as well as in Spotlight.
    #
    # Its environment is a file in Resources, written before signing, since
    # nothing may write into the bundle after. A changed environment is a
    # reason to rebuild, the same as a changed source.
    APP_NAME="TimeTracker"
    [[ "$VERB" == "time" ]] || APP_NAME="TimeTracker $VERB"
    MAIN_APP="$APPS_DIR/$APP_NAME.app"
    MAIN_BIN="$MAIN_APP/Contents/MacOS/ttapp"
    APP_ENV=$(printf 'TT_BIN=%s\nTIMETRACK_DIR=%s\nTIMETRACK_APPS_DIR=%s\nTIMETRACK_VERB=%s\nTIMETRACK_BID_PREFIX=%s\n' \
        "$BIN_DIR" "$DATA_DIR" "$APPS_DIR" "$VERB" "$BID_PREFIX")
    if [[ ! -x "$MAIN_BIN" || "$SRC_DIR/ttapp.swift" -nt "$MAIN_BIN" \
          || $(bundle_id_of "$MAIN_APP") != "$BID_PREFIX.app" \
          || "$(cat "$MAIN_APP/Contents/Resources/env" 2>/dev/null)" != "$APP_ENV" \
          || $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
               "$MAIN_APP/Contents/Info.plist" 2>/dev/null) != "$NEW_VERSION" ]]; then
        printf 'Building %s...\n' "$APP_NAME"
        ASTAGE="$APPS_DIR/.app-build.$$"
        rm -rf "$ASTAGE"
        ASTAGE_APP="$ASTAGE/$APP_NAME.app"
        mkdir -p "$ASTAGE_APP/Contents/MacOS" "$ASTAGE_APP/Contents/Resources"
        swiftc -O "$SRC_DIR/ttapp.swift" -o "$ASTAGE_APP/Contents/MacOS/ttapp"
        printf '%s\n' "$APP_ENV" > "$ASTAGE_APP/Contents/Resources/env"
        if "$ASTAGE_APP/Contents/MacOS/ttapp" --icon "$ASTAGE/AppIcon.iconset" 2>/dev/null; then
            iconutil -c icns "$ASTAGE/AppIcon.iconset" \
                -o "$ASTAGE_APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true
        fi
        cat > "$ASTAGE_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleExecutable</key>
	<string>ttapp</string>
	<key>CFBundleIdentifier</key>
	<string>$BID_PREFIX.app</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$NEW_VERSION</string>
	<key>CFBundleVersion</key>
	<string>$NEW_VERSION</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.productivity</string>
	<key>LSMinimumSystemVersion</key>
	<string>11.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsLocalNetworking</key>
		<true/>
	</dict>
</dict>
</plist>
EOF
        codesign --force -s - "$ASTAGE_APP" >/dev/null 2>&1 || \
            printf 'warning: could not ad-hoc sign %s\n' "$APP_NAME"
        rm -rf "$MAIN_APP"
        mv "$ASTAGE_APP" "$APPS_DIR/"
        rm -rf "$ASTAGE"
    fi
else
    printf 'swiftc not found. The tracker is installed, but the app and\n'
    printf 'pomodoro mode need it: xcode-select --install, then install again.\n'
fi

# A running server loaded dashboard.py once, at startup, so after an upgrade
# it would go on serving the old code. It holds nothing but a port and a
# token, so stopping it is free. The app notices its server go and starts
# the new one, or, when this install changed the version, reopens as the new
# app.
if pkill -f "$BIN_DIR/dashboard.py" 2>/dev/null; then
    rm -f "$DATA_DIR/.dashboard"
fi

"$BIN_DIR/sync-apps.sh"

printf '\nInstalled TimeTracker %s.\n' "$NEW_VERSION"

# First run: no setup marker and no categories. The app opens on its setup,
# which asks what you work on and whether you want pomodoros.
first_run=0
[[ -f "$DATA_DIR/.setup-done" ]] || first_run=1
if (( first_run )) && [[ "$(awk 'NR>1 && NF' "$DATA_DIR/categories.tsv" | wc -l)" -gt 0 ]]; then
    first_run=0
fi
if (( first_run )) && [[ -n "${MAIN_APP:-}" && -d "$MAIN_APP" ]]; then
    /usr/bin/open "$MAIN_APP" >/dev/null 2>&1 || true
elif (( first_run )) && [[ -d "$APPS_DIR/$VERB dashboard.app" ]]; then
    /usr/bin/open -g "$APPS_DIR/$VERB dashboard.app" >/dev/null 2>&1 || true
fi
