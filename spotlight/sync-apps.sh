#!/usr/bin/env bash
# Generates the Spotlight-launchable app bundles: fixed control apps plus one
# per category from categories.tsv. Idempotent — safe to re-run any time.
#
# Each bundle is minimal: Info.plist + a bash script as CFBundleExecutable.
# LSUIElement keeps them out of the Dock and stops them stealing focus.
#
# Naming: the bundle is named "time <KEY> – <Name>", because Spotlight
# displays an app's *filename* (CFBundleDisplayName is ignored for this), and
# a literal ":" in a filename renders as "/". Keywords are attached instead as
# kMDItemAlternateNames, which Spotlight matches on without showing them — so
# "time økstyr2" finds a bundle titled "time BØK2100 – Organisasjon og
# teknologi 2".

set -uo pipefail

BIN_DIR="${0%/*}"
case "$BIN_DIR" in
    /*) ;;
    *) BIN_DIR="$(cd "$BIN_DIR" && pwd)" ;;
esac

DATA_DIR="${TIMETRACK_DIR:-$HOME/.timetrack}"
CAT_FILE="$DATA_DIR/categories.tsv"
APPS_DIR="${TIMETRACK_APPS_DIR:-$HOME/Applications/TimeTracker}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Reverse-DNS prefix for every generated bundle. It is the identity macOS ties
# TCC permission grants to, so changing it makes the system forget every grant
# and ask again.
#
# The prune passes below deliberately match on the *shape* `*.timetracker.…`
# rather than on this exact value. A bundle generated under some earlier prefix
# is still one of ours, and it has to go: it is not regenerated, nothing
# updates it, and it would sit in the launcher for ever as a second copy of a
# course that already has one.
BID_PREFIX="${TIMETRACK_BID_PREFIX:-com.timetracker}"

# The word you type. It is the bundle *filename*, because that is what the
# launcher displays and matches, so it is also the only thing keeping a
# scratch install out of the way of the real one: with both installed and
# both called "time", the launcher offers two identical rows and the wrong
# one writes to the wrong log.
#
# A scratch install therefore also gives up the bare aliases. "BØK2100" and
# "økstyr2" are what you actually type, they belong to the real install, and
# a second bundle answering to them would put that same ambiguous pair in
# front of you at the exact moment you are trying to start work.
VERB="${TIMETRACK_VERB:-time}"
if [[ "$VERB" == "time" ]]; then BARE_ALIASES=1; else BARE_ALIASES=0; fi

mkdir -p "$APPS_DIR"

xmlesc() {
    local s=$1
    s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; s=${s//\"/&quot;}
    printf '%s' "$s"
}

# Stable, collision-free bundle id fragment. The readable part is ASCII-only
# so it collides and can go empty for non-Latin names; the md5 of the original
# makes it unique and never blank.
slugify() {
    local readable hash
    readable=$(printf '%s' "$1" | LC_ALL=C tr -c '[:alnum:]' '-' | LC_ALL=C tr -s '-' | \
        sed -e 's/^-//' -e 's/-$//' | LC_ALL=C tr '[:upper:]' '[:lower:]')
    hash=$(printf '%s' "$1" | /sbin/md5 -q 2>/dev/null | cut -c1-8)
    [[ -z "$hash" ]] && hash=$(printf '%s' "$1" | cksum | cut -d' ' -f1)
    printf '%s%s' "${readable:+$readable-}" "$hash"
}

# Alfred caches these aliases raw-cased and matches them with a SQLite LIKE,
# whose case folding is ASCII-only: a typed "ø" never matches the "Ø" in
# BØK2100, so the alias is unreachable for anyone typing lowercase. Emitting a
# lowercased copy of every alias gives that LIKE something to hit. Folding has
# to be Unicode-aware, so perl -CSD rather than tr, which is byte-oriented.
# Originals are kept: Spotlight's own matcher is case-insensitive either way.
lowercase_variants() {
    [[ $# -eq 0 ]] && return 0
    printf '%s\n' "$@" | perl -CSD -e '
        my @a = <STDIN>; chomp @a;
        my %seen = map { $_ => 1 } @a;
        for my $x (@a) { my $l = lc $x; next if $seen{$l}++; print "$l\n"; }
    ' 2>/dev/null
}

# Attach search aliases. Spotlight matches these but keeps displaying the
# filename, which is how a clean title and fuzzy keywords coexist.
set_aliases() {
    local app_path="$1"; shift
    local tmp_plist tmp_bin hex
    [[ $# -eq 0 ]] && return 0
    tmp_plist="$(mktemp /tmp/tt-alias.XXXXXX)"
    tmp_bin="$(mktemp /tmp/tt-aliasb.XXXXXX)"
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        printf '<plist version="1.0"><array>\n'
        for a in "$@"; do
            [[ -z "$a" ]] && continue
            printf '<string>%s</string>\n' "$(xmlesc "$a")"
        done
        printf '</array></plist>\n'
    } > "$tmp_plist"
    if plutil -convert binary1 "$tmp_plist" -o "$tmp_bin" 2>/dev/null; then
        hex=$(xxd -p "$tmp_bin" | tr -d '\n')
        xattr -w com.apple.metadata:_kMDItemUserTags "" "$app_path" 2>/dev/null || true
        xattr -wx com.apple.metadata:kMDItemAlternateNames "$hex" "$app_path" 2>/dev/null || true
    fi
    rm -f "$tmp_plist" "$tmp_bin"
}

# make_app <app-name> <bundle-id-suffix> <body-script>
make_app() {
    local app_name="$1" bid="$2" body="$3"
    local app_path="$APPS_DIR/$app_name.app"
    local macos_dir="$app_path/Contents/MacOS"

    mkdir -p "$macos_dir"

    cat > "$app_path/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>$(xmlesc "$app_name")</string>
	<key>CFBundleDisplayName</key>
	<string>$(xmlesc "$app_name")</string>
	<key>CFBundleExecutable</key>
	<string>run</string>
	<key>CFBundleIdentifier</key>
	<string>$BID_PREFIX.$bid</string>
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
	<string>10.13</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF

    {
        printf '#!/usr/bin/env bash\n'
        printf '# Generated by sync-apps.sh — do not edit; changes are overwritten.\n'
        printf 'BIN=%q\n' "$BIN_DIR"
        if [[ -n "${TIMETRACK_DIR:-}" ]]; then
            printf 'export TIMETRACK_DIR=%q\n' "$TIMETRACK_DIR"
        fi
        if [[ -n "${TIMETRACK_APPS_DIR:-}" ]]; then
            printf 'export TIMETRACK_APPS_DIR=%q\n' "$TIMETRACK_APPS_DIR"
        fi
        # The break menu opens "<verb> spotify.app" by name, so a bundle that
        # did not carry the verb would send the watcher looking for the real
        # install's name inside the scratch install's folder, and the Spotify
        # entry would go quietly missing with nothing to explain why.
        if [[ -n "${TIMETRACK_VERB:-}" ]]; then
            printf 'export TIMETRACK_VERB=%q\n' "$TIMETRACK_VERB"
        fi
        printf '%s\n' "$body"
    } > "$macos_dir/run"
    chmod +x "$macos_dir/run"

    printf '%s\n' "$app_path"
}

# --- Fixed control apps -----------------------------------------------------

make_app "$VERB" "toggle" 'exec "$BIN/toggle.sh"' > /dev/null
make_app "$VERB new" "new" 'exec "$BIN/newcat.sh"' > /dev/null
make_app "$VERB categories" "categories" \
    'exec /usr/bin/open -t "${TIMETRACK_DIR:-$HOME/.timetrack}/categories.tsv"' > /dev/null

# The data folder is a dotfolder, so Finder hides it. This is the shortcut.
make_app "$VERB data" "data" \
    'exec /usr/bin/open "${TIMETRACK_DIR:-$HOME/.timetrack}"' > /dev/null

# Detached, not exec'd: if the app process *is* the server it stays alive while
# the browser polls, and LaunchServices then refuses to relaunch the app.
make_app "$VERB dashboard" "dashboard" \
    'nohup /usr/bin/python3 "$BIN/dashboard.py" >/dev/null 2>&1 &
exit 0' > /dev/null

# Same detached body — the server reuses a running instance — but lands the
# browser on the settings page.
make_app "$VERB settings" "settings" \
    'nohup /usr/bin/python3 "$BIN/dashboard.py" --settings >/dev/null 2>&1 &
exit 0' > /dev/null


# Not a Spotlight verb like the rest — a bundle whose only purpose is to be
# a *name*. Everything it runs would work fine from the watcher, but macOS
# grants Automation permission to the app responsible for the process that
# sends the event, and the watcher belongs to whichever category app started
# the session. Without this bundle, "wants to control Google Chrome" would be
# asked once per category, mid-break, under a different name each time; with
# it, once, as "TimeTracker Media". Launching it by hand is also the calm way
# to answer those prompts before a break ever raises them.
make_app "TimeTracker Media" "media" 'exec "$BIN/pause-media.sh"' > /dev/null

# The break menu's Spotify remote. Exactly one bundle, and that is a rule
# rather than a convenience: an Automation grant belongs to the app
# responsible for the process that sent the event, so a second bundle running
# the same script would be a second "wants to control Spotify" prompt. This is
# also a Spotlight verb, unlike the media one, because it is worth running by
# hand — with no cycle in progress spotify.sh answers the permission prompt at
# a calm moment and reports what it can see, which is the quickest way to find
# out whether the grant survived.
if [[ -f "$BIN_DIR/spotify.sh" ]]; then
    make_app "$VERB spotify" "spotify" 'exec "$BIN/spotify.sh"' > /dev/null
fi

# The break menu's capture box, in the calendar's two-bundle shape: the
# compiled helper (TimeTracker Reminders.app, built by install.sh) holds the
# Reminders grant, and this verb exists to make that grant answerable before a
# break rather than during one. Running it writes nothing — the helper only
# asks for access and reports back when it is handed no note.
if [[ -d "$APPS_DIR/TimeTracker Reminders.app" ]]; then
    make_app "$VERB reminders" "reminders" \
        'D="${TIMETRACK_DIR:-$HOME/.timetrack}"
rm -f "$D/.tomato-reminder-result"
/usr/bin/open -W -g "${TIMETRACK_APPS_DIR:-$HOME/Applications/TimeTracker}/TimeTracker Reminders.app"
IFS=$'"'"'\t'"'"' read -r status detail < "$D/.tomato-reminder-result" 2>/dev/null
case "${status:-}" in
    ok)     out="Reminders access is granted. Break notes go to “${detail:-Pause Notes}”." ;;
    denied) out="Reminders access was refused. Turn it on in System Settings > Privacy & Security > Reminders." ;;
    *)      out="The reminders helper did not answer. Re-run install.sh." ;;
esac
rm -f "$D/.tomato-reminder-result"
osascript - "$out" >/dev/null 2>&1 <<'"'"'EOS'"'"'
on run argv
    tell application "System Events"
        activate
        display dialog (item 1 of argv) with title "TimeTracker Reminders" buttons {"OK"} default button "OK"
    end tell
end run
EOS' > /dev/null
fi

# Paint the log onto a calendar, and say what it did. Also the launch that
# raises the Calendar permission prompt and refreshes the list of calendars
# the settings page offers — which is why it is worth being a verb rather
# than a hidden bundle. (It used to be the other way round: this name once ran
# an agent that read the calendar and started timers off it. That went.)
if [[ -f "$BIN_DIR/paint-calendar.sh" ]]; then
    make_app "$VERB calendar" "calendar" \
        'out=$("$BIN/paint-calendar.sh" 2>&1)
[[ -z "$out" ]] && out="Nothing to report."
osascript - "$out" >/dev/null 2>&1 <<'"'"'EOS'"'"'
on run argv
    tell application "System Events"
        activate
        display dialog (item 1 of argv) with title "TimeTracker Calendar" buttons {"OK"} default button "OK"
    end tell
end run
EOS' > /dev/null
fi

# --- One app per category ---------------------------------------------------

declare -a wanted_slugs=()

if [[ -s "$CAT_FILE" ]]; then
    first=1
    # Split on US (\037), not on the tab itself: tab is IFS *whitespace*, so
    # read collapses runs of it and drops empties — a category with no
    # keywords would shift last_used into $keywords, fail the digit check
    # below and silently lose its app. action.sh strips every control
    # character from the fields, so \037 can never occur in the data.
    while IFS=$'\037' read -r key name keywords last hidden || [[ -n "${key:-}" ]]; do
        if (( first )); then first=0; [[ "$key" == "key" ]] && continue; fi
        [[ -z "${key:-}" ]] && continue
        [[ "${last:-}" =~ ^[0-9]+$ ]] || continue
        # Hidden: no bundle. Leaving it out of wanted_slugs is also what makes
        # the prune pass below tear down the app it used to have.
        [[ "${hidden:-}" == "1" ]] && continue

        slug=$(slugify "$key")
        wanted_slugs+=("$slug")

        if [[ -n "${name:-}" && "$name" != "$key" ]]; then
            app_name="$VERB $key – $name"
        else
            app_name="$VERB $key"
        fi

        app_path=$(make_app "$app_name" "cat.$slug" \
            "$(printf 'exec "$BIN/start.sh" %q' "$key")")

        # Aliases: the key, the name, and every keyword.
        declare -a aliases=("$VERB $key")
        (( BARE_ALIASES )) && aliases+=("$key")
        if [[ -n "${name:-}" ]]; then
            aliases+=("$VERB $name")
            (( BARE_ALIASES )) && aliases+=("$name")
        fi
        if [[ -n "${keywords:-}" ]]; then
            IFS=',' read -r -a kws <<< "$keywords"
            for kw in "${kws[@]}"; do
                kw="${kw#"${kw%%[![:space:]]*}"}"
                kw="${kw%"${kw##*[![:space:]]}"}"
                [[ -z "$kw" ]] && continue
                aliases+=("$VERB $kw")
                (( BARE_ALIASES )) && aliases+=("$kw")
            done
        fi
        while IFS= read -r lc_alias; do
            [[ -n "$lc_alias" ]] && aliases+=("$lc_alias")
        done < <(lowercase_variants "${aliases[@]}")
        set_aliases "$app_path" "${aliases[@]}"
        unset aliases
    done < <(tr '\t' '\037' < "$CAT_FILE")
fi

# --- Retired control apps ----------------------------------------------------
# "time" (the toggle) covers stopping, and the dashboard supersedes stats.
# Listed by bundle-id suffix so re-running this cleans up an older install
# rather than leaving orphans in Spotlight.

for retired in stop pause resume stats; do
    for app_path in "$APPS_DIR"/*.app; do
        [[ -e "$app_path" ]] || continue
        bid=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "$app_path/Contents/Info.plist" 2>/dev/null) || continue
        if [[ "$bid" == *".timetracker.$retired" ]]; then
            "$LSREGISTER" -u "$app_path" >/dev/null 2>&1
            rm -rf "$app_path"
        fi
    done
done

# --- Prune apps for categories that no longer exist --------------------------

for app_path in "$APPS_DIR"/*.app; do
    [[ -e "$app_path" ]] || continue
    bid=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$app_path/Contents/Info.plist" 2>/dev/null) || continue
    # A category bundle under any other prefix is pruned outright, category
    # still wanted or not: the current prefix has already regenerated it, so
    # keeping this one would show the same course twice.
    if [[ "$bid" == *".timetracker.cat."* && "$bid" != "$BID_PREFIX.cat."* ]]; then
        "$LSREGISTER" -u "$app_path" >/dev/null 2>&1
        rm -rf "$app_path"
    elif [[ "$bid" == "$BID_PREFIX.cat."* ]]; then
        slug="${bid#$BID_PREFIX.cat.}"
        keep=0
        for w in ${wanted_slugs+"${wanted_slugs[@]}"}; do
            [[ "$w" == "$slug" ]] && { keep=1; break; }
        done
        if [[ "$keep" -eq 0 ]]; then
            "$LSREGISTER" -u "$app_path" >/dev/null 2>&1
            rm -rf "$app_path"
        fi
    fi
done

# --- Register with LaunchServices + Spotlight --------------------------------

for app_path in "$APPS_DIR"/*.app; do
    [[ -e "$app_path" ]] || continue
    "$LSREGISTER" -f "$app_path" >/dev/null 2>&1
    /usr/bin/mdimport "$app_path" >/dev/null 2>&1
done

printf 'Synced app bundles in %s\n' "$APPS_DIR"
