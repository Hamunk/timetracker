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
# The bundles that exist only to carry a name and a permission — the overlay,
# the Spotify remote, the media pause, the calendar and Reminders writers,
# Messages. Spotlight never indexes a folder whose name ends in .noindex, so
# typing "time" lists the things you can open and not the machinery behind
# them. LaunchServices still opens them by path, and macOS still keys their
# permissions to their bundle ids, which moving them does not change.
HELPERS_DIR="$APPS_DIR/Helpers.noindex"
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
#
# Every bundle carries it in its run script (make_app, below), so anything a
# bundle starts that comes back here — the dashboard adding a category, "time
# new" — rebuilds under the same identity. It used to carry only the folder,
# the data and the verb, and a category added from a scratch install's
# dashboard rebuilt every scratch bundle under the real install's identifiers.
# Unset all the same, the toggle's identity is the next best answer, and the
# default only the last.
BID_PREFIX="${TIMETRACK_BID_PREFIX:-}"
if [[ -z "$BID_PREFIX" ]]; then
    BID_PREFIX=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$APPS_DIR/${TIMETRACK_VERB:-time}.app/Contents/Info.plist" 2>/dev/null) || BID_PREFIX=""
    case "$BID_PREFIX" in *.toggle) BID_PREFIX="${BID_PREFIX%.toggle}" ;; *) BID_PREFIX="" ;; esac
fi
BID_PREFIX="${BID_PREFIX:-com.timetracker}"

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

mkdir -p "$APPS_DIR" "$HELPERS_DIR"

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

# Folded for comparing names the way the disk does: APFS is case-insensitive,
# so two names that differ only in case are one folder, and the second bundle
# written there replaces the first.
fold() {
    printf '%s' "$1" | perl -CSD -pe '$_ = lc' 2>/dev/null
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

# make_app <app-name> <bundle-id-suffix> <body-script> [<folder>]
make_app() {
    local app_name="$1" bid="$2" body="$3" dir="${4:-$APPS_DIR}"
    # A slash would make a folder of the name. Finder shows a colon in a file
    # name as a slash, so "Matte 1/2" is still what Spotlight lists.
    local app_path="$dir/${app_name//\//:}.app"
    local macos_dir="$app_path/Contents/MacOS"

    mkdir -p "$macos_dir"

    # LSArchitecturePriority, because the executable is a script. There is no
    # Mach-O header for LaunchServices to read an architecture from, so on
    # Apple Silicon it assumes Intel and starts the whole bundle under Rosetta.
    # For bash and every other system binary that is invisible. For
    # /usr/bin/python3 it is not: that is an xcrun shim, the shim loads
    # libxcrun from the Command Line Tools, and once a CLT update shipped that
    # library arm64-only, "time dashboard" failed in dlopen before Python
    # started, with its output sent to /dev/null and nothing on screen to say
    # so. x86_64 stays in the list for an Intel Mac, where arm64 is skipped.
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
	<key>LSArchitecturePriority</key>
	<array>
		<string>arm64</string>
		<string>x86_64</string>
	</array>
	<key>LSMinimumSystemVersion</key>
	<string>10.13</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF

    {
        printf '#!/usr/bin/env bash\n'
        printf '# Generated by sync-apps.sh. Do not edit; changes are overwritten.\n'
        printf 'BIN=%q\n' "$BIN_DIR"
        if [[ -n "${TIMETRACK_DIR:-}" ]]; then
            printf 'export TIMETRACK_DIR=%q\n' "$TIMETRACK_DIR"
        fi
        if [[ -n "${TIMETRACK_APPS_DIR:-}" ]]; then
            printf 'export TIMETRACK_APPS_DIR=%q\n' "$TIMETRACK_APPS_DIR"
        fi
        # The app and the notifications name the verb, so a bundle that did
        # not carry it would have a scratch install talk about "time".
        if [[ -n "${TIMETRACK_VERB:-}" ]]; then
            printf 'export TIMETRACK_VERB=%q\n' "$TIMETRACK_VERB"
        fi
        printf 'export TIMETRACK_BID_PREFIX=%q\n' "$BID_PREFIX"
        printf '%s\n' "$body"
    } > "$macos_dir/run"
    chmod +x "$macos_dir/run"

    printf '%s\n' "$app_path"
}

# --- What Spotlight shows ----------------------------------------------------
# The app, the toggle, the updater, and one launcher per subject: nothing
# else answers to "time". There used to be a verb for each page of the app,
# one per permission, and one for the data folder, and typing the one word
# this program is reached by listed a dozen rows of it before the one you
# wanted. The app has all of those, as buttons.

make_app "$VERB" "toggle" 'exec "$BIN/toggle.sh"' > /dev/null

# Asks before it changes anything, and says what it did. Kept as a verb for
# the day the app itself will not open, which is the day it is needed most.
if [[ -f "$BIN_DIR/update.sh" ]]; then
    make_app "$VERB update" "update" 'exec "$BIN/update.sh"' > /dev/null
fi

# The app is called Tomat, and is found by that or by the word you already
# type: "time" lists it under the toggle, so nobody has to know its name to
# open it. A scratch install's carries its verb in its name and answers only
# to its verb. Built by install.sh; only its aliases are set here.
APP_NAME="Tomat"
[[ "$VERB" == "time" ]] || APP_NAME="Tomat ($VERB)"
# Without a compiler there is no app to build, and the same pages open in
# the browser instead, under the same name: the one way in is still the one
# way in. install.sh replaces this with the real app once it can build one.
if [[ ! -d "$APPS_DIR/$APP_NAME.app" ]]; then
    make_app "$APP_NAME" "app" 'nohup /usr/bin/python3 "$BIN/dashboard.py" >/dev/null 2>&1 &
exit 0' > /dev/null
fi
if [[ -d "$APPS_DIR/$APP_NAME.app" ]]; then
    declare -a app_aliases=("$VERB")
    (( BARE_ALIASES )) && app_aliases+=("TimeTracker" "pomodoro")
    set_aliases "$APPS_DIR/$APP_NAME.app" "${app_aliases[@]}"
    unset app_aliases
fi

# --- The helpers --------------------------------------------------------------

# A bundle whose only purpose is to be a *name*. Everything it runs would work
# fine from the watcher, but macOS grants Automation permission to the app
# responsible for the process that sends the event, and the watcher belongs to
# whichever category app started the session. Without this bundle, "wants to
# control Google Chrome" would be asked once per category, mid-break, under a
# different name each time; with it, once, as "Tomat Media".
make_app "Tomat Media" "media" 'exec "$BIN/pause-media.sh"' "$HELPERS_DIR" > /dev/null

# The break menu's Spotify remote. Exactly one bundle, and that is a rule
# rather than a convenience: an Automation grant belongs to the app
# responsible for the process that sent the event, so a second bundle running
# the same script would be a second "wants to control Spotify" prompt. The
# app's "--check" is a launch through this bundle too, with its arguments
# passed through, so that the grant it asks about is this bundle's grant.
if [[ -f "$BIN_DIR/spotify.sh" ]]; then
    make_app "Tomat Spotify" "spotify" 'exec "$BIN/spotify.sh" "$@"' "$HELPERS_DIR" > /dev/null
fi

# --- One app per category ---------------------------------------------------

# The bundles just written, folded, so the prune pass below can keep exactly
# these. It used to keep anything whose bundle id was still wanted, which kept
# a renamed subject's old bundle too, under its old name, beside the new one.
declare -a wanted_apps=()

# Names the program's own apps already hold. A subject called "Update" with
# no code would be "time Update", one folder with "time update" on a disk
# that ignores case, and whichever was written second would be the only one
# left.
taken=""
for app_path in "$APPS_DIR"/*.app; do
    [[ -e "$app_path" ]] || continue
    bid=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$app_path/Contents/Info.plist" 2>/dev/null) || continue
    [[ "$bid" == "$BID_PREFIX."* && "$bid" != "$BID_PREFIX.cat."* ]] || continue
    taken+="$(fold "${app_path%.app}")"$'\n'
done

if [[ -s "$CAT_FILE" ]]; then
    first=1
    # Split on US (\037), not on the tab itself: tab is IFS *whitespace*, so
    # read collapses runs of it and drops empties — a category with no
    # keywords would shift last_used into $keywords, fail the digit check
    # below and silently lose its app. action.sh strips every control
    # character from the fields, so \037 can never occur in the data.
    while IFS=$'\037' read -r key name keywords last hidden code || [[ -n "${key:-}" ]]; do
        if (( first )); then first=0; [[ "$key" == "key" ]] && continue; fi
        [[ -z "${key:-}" ]] && continue
        [[ "${last:-}" =~ ^[0-9]+$ ]] || continue
        # Hidden: no bundle. Leaving it out of wanted_apps is also what makes
        # the prune pass below tear down the app it used to have.
        [[ "${hidden:-}" == "1" ]] && continue

        # Named for what the subject is called, never for its key: the key is
        # whatever it was called the day it was added, and is not a word
        # anybody types. The bundle id is the key's, so it survives renames.
        name="${name:-$key}"
        if [[ -n "${code:-}" ]]; then
            app_name="$VERB $code – $name"
        else
            app_name="$VERB $name"
        fi
        base="$app_name"; n=1
        while grep -Fxq -- "$(fold "$APPS_DIR/${app_name//\//:}")" <<< "$taken"; do
            n=$(( n + 1 )); app_name="$base ($n)"
        done
        taken+="$(fold "$APPS_DIR/${app_name//\//:}")"$'\n'

        slug=$(slugify "$key")
        app_path=$(make_app "$app_name" "cat.$slug" \
            "$(printf 'exec "$BIN/start.sh" %q' "$key")")
        wanted_apps+=("$(fold "$app_path")")

        # Aliases: the code, the name, and every keyword. Several subjects
        # may share a code, and then "time med5" lists all of them, which is
        # the right answer to it.
        declare -a aliases=()
        if [[ -n "${code:-}" ]]; then
            aliases+=("$VERB $code")
            (( BARE_ALIASES )) && aliases+=("$code")
        fi
        aliases+=("$VERB $name")
        (( BARE_ALIASES )) && aliases+=("$name")
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

#
# The 2.0 verbs went the same way: one per page of the app, one per
# permission, and the data folder. So did the helpers' old places beside the
# launchers — Spotify, Media, and the four install.sh compiles — which are
# found by id at the top of the folder, where they no longer belong; their
# replacements are in Helpers.noindex, under the same ids.

for app_path in "$APPS_DIR"/*.app; do
    [[ -e "$app_path" ]] || continue
    bid=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$app_path/Contents/Info.plist" 2>/dev/null) || continue
    for retired in stop pause resume stats dashboard settings guide new categories \
                   data reminders calendar spotify media \
                   prompt.helper reminders.helper chat.helper calendar.helper; do
        if [[ "$bid" == "$BID_PREFIX.$retired" || "$bid" == *".timetracker.$retired" ]]; then
            "$LSREGISTER" -u "$app_path" >/dev/null 2>&1
            rm -rf "$app_path"
            break
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
        here=$(fold "$app_path")
        keep=0
        for w in ${wanted_apps+"${wanted_apps[@]}"}; do
            [[ "$w" == "$here" ]] && { keep=1; break; }
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
# Registered, so they open by path at once, but never imported: being out of
# Spotlight is the reason they are in there.
for app_path in "$HELPERS_DIR"/*.app; do
    [[ -e "$app_path" ]] || continue
    "$LSREGISTER" -f "$app_path" >/dev/null 2>&1
done

printf 'Synced app bundles in %s\n' "$APPS_DIR"
