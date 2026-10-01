#!/usr/bin/env bash
# Brings this install up to the newest release.
#
#   update.sh           check, ask, install, say how it went — "time update"
#   update.sh --check   print "<installed><TAB><latest>" and nothing else;
#                       latest is empty when the releases cannot be reached,
#                       and the installed version when there are none yet
#   update.sh --yes     install the newest release without asking (the app,
#                       which has already asked)
#
# A release is a git tag named vX.Y.Z on the repository below, and nothing
# else is: whatever is on main reaches nobody until it is tagged. The tag is
# fetched as it stands into a folder of its own and that version's install.sh
# is run, which backs the data up first, refuses data from a newer version,
# refuses while a pomodoro is live, and keeps this install's bundle identity.
# So everything that makes an update safe lives in the installer, where a
# hand-run install gets it too; this file only finds the release and fetches it.
#
# git rather than a tarball over curl, because the tags have to be listed
# anyway, and `git ls-remote` lists them without the GitHub API and its
# hourly limit. Every machine that can run TimeTracker has git: the pomodoro
# helpers need the same command line tools.
#
# TIMETRACK_UPDATE_REPO points it somewhere else — a local clone, for trying
# an update against a scratch install without publishing anything.

set -uo pipefail

BIN_DIR="${0%/*}"
case "$BIN_DIR" in
    /*) ;;
    *) BIN_DIR="$(cd "$BIN_DIR" && pwd)" ;;
esac
DATA_DIR="${TIMETRACK_DIR:-$HOME/.timetrack}"
REPO="${TIMETRACK_UPDATE_REPO:-https://github.com/Hamunk/timetracker.git}"
LOG="$DATA_DIR/update.log"

mode="${1:-}"

installed=$(head -1 "$BIN_DIR/VERSION" 2>/dev/null || true)
installed="${installed:-1}"

# The newest vX.Y.Z tag, without the v. Anything else that looks like a tag —
# a v2.1.0-rc1, a stray "latest" — is not a release and is skipped. Fails
# only when the repository cannot be reached: one reached with no release on
# it prints nothing and succeeds. Those were one answer, "Are you online?",
# which until the first tag was every install's answer however online it was.
latest_release() {
    local tags
    tags=$(GIT_TERMINAL_PROMPT=0 /usr/bin/git ls-remote --tags --refs "$REPO" 2>/dev/null) \
        || return 1
    printf '%s\n' "$tags" \
        | awk '{ sub("refs/tags/v", "", $2); print $2 }' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
    return 0
}

# True if $1 is a later version than $2. A missing part counts as 0, so the
# "1" every pre-2.0 install reports compares as 1.0.0.
newer() {
    local a b i
    IFS=. read -r -a a <<< "$1"
    IFS=. read -r -a b <<< "$2"
    for i in 0 1 2; do
        (( 10#${a[i]:-0} > 10#${b[i]:-0} )) && return 0
        (( 10#${a[i]:-0} < 10#${b[i]:-0} )) && return 1
    done
    return 1
}

dialog() {   # dialog <text> [button...]  — prints the button pressed
    local text="$1"; shift
    (( $# )) || set -- OK
    /usr/bin/osascript - "$text" "$@" 2>/dev/null <<'EOS'
on run argv
    set btns to items 2 thru -1 of argv
    tell application "System Events"
        activate
        try
            set r to display dialog (item 1 of argv) with title "Tomat" ¬
                buttons btns default button (count of btns)
            return button returned of r
        on error
            return ""
        end try
    end tell
end run
EOS
}

say() {
    if [[ "$mode" == "" ]]; then dialog "$1" >/dev/null; else printf '%s\n' "$1"; fi
}

# No release at all is nothing newer than this, which is what up to date
# means; so the installed version stands in for the latest.
if latest=$(latest_release); then
    latest="${latest:-$installed}"
else
    latest=""
fi

if [[ "$mode" == "--check" ]]; then
    printf '%s\t%s\n' "$installed" "$latest"
    exit 0
fi

if [[ -z "$latest" ]]; then
    say "Could not check for updates. Are you online?"
    exit 1
fi
if ! newer "$latest" "$installed"; then
    say "Tomat is up to date ($installed)."
    exit 0
fi

# install.sh refuses this too, but by then the download has happened; saying
# so here is quicker, and it is said in words rather than in a log.
if [[ -f "$DATA_DIR/pomodoro" ]]; then
    IFS=$'\t' read -r _ _ _ _ _ _ wpid < "$DATA_DIR/pomodoro" 2>/dev/null || true
    if [[ "${wpid:-}" =~ ^[0-9]+$ ]] && kill -0 "$wpid" 2>/dev/null; then
        say "A pomodoro is running. Update when it has ended."
        exit 1
    fi
fi

if [[ "$mode" == "" ]]; then
    [[ "$(dialog "Version $latest is available. You have $installed." "Later" "Update")" == "Update" ]] \
        || exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/timetracker-update.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

{
    printf 'update %s -> %s from %s, %s\n' "$installed" "$latest" "$REPO" "$(date)"
    GIT_TERMINAL_PROMPT=0 /usr/bin/git -c advice.detachedHead=false clone --quiet \
        --depth 1 --branch "v$latest" "$REPO" "$work/src" 2>&1
} > "$LOG" 2>&1

# The tag has to say what it is. A tag pointing at a commit whose VERSION
# disagrees is a release made by mistake, and installing it would leave an
# install that reports one version and is another.
got=$(head -1 "$work/src/VERSION" 2>/dev/null || true)
if [[ ! -x "$work/src/spotlight/install.sh" || "$got" != "$latest" ]]; then
    printf 'v%s does not contain version %s (found "%s")\n' "$latest" "$latest" "$got" >> "$LOG"
    say "The update could not be downloaded. Nothing was changed."
    exit 1
fi

# The installer reads the same variables the launcher bundles export, so a
# scratch install updates itself and never the real one.
if "$work/src/spotlight/install.sh" >> "$LOG" 2>&1; then
    say "Updated to $latest."
    exit 0
fi
say "The update stopped before it finished. Your data was backed up first, in $DATA_DIR/backups. Details are in update.log."
exit 1
