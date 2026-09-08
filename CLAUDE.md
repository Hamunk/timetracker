# Working on TimeTracker while TimeTracker is being used

The person who owns this repo is running the program while you change it. A
broken build is recoverable in a minute; a pomodoro interrupted at minute
twenty-three is not. Treat the running install as production, because it is.

## Two installs

|  | real | scratch |
|---|---|---|
| data | `~/.timetrack` | `~/.timetrack-dev` |
| bundles | `~/Applications/TimeTracker` | `~/Applications/TimeTracker-dev` |
| identity | `com.timetracker.*` | `com.timetracker.dev.*` |
| launcher word | `time` | `devtime` |

Separate data is the easy part, and on its own it is not enough. Identity is
what macOS hangs TCC grants on, so two installs sharing it means a test run
can revoke the Calendars grant the real one depends on. The launcher word is
what stops the real `time` from acquiring a twin in Spotlight at the moment
work is being started. `./dev.sh` sets all four; nothing else does.

## The repo is not live

`install.sh` copies into `~/.timetrack/bin/`, and the generated bundles bake
that path in. Editing `spotlight/*.sh` therefore changes nothing that is
running — it is inert until somebody installs it. Edit freely.

The exception, and it is a trap: running `sync-apps.sh` **from the repo**
makes `BIN_DIR` the repo and rewrites the bundles to point at the working
tree, turning a half-finished edit into the live program. Never invoke the
installers directly. `./dev.sh` exists so you do not have to.

## Where to work

    timetracker       main    — the owner's tree. Leave it alone.
    timetracker-wip   wip     — yours.

Two checkouts of one repository, via `git worktree`. The point is that
`./spotlight/install.sh` can be run from the first at any moment without
regard to what is half-finished in the second: the owner never has to stash
your work to update their own install.

So do not edit, switch branches in, or commit to the main checkout. Start each
note from the worktree, branching off main rather than off whatever `wip` was
last left at:

    cd ../timetracker-wip && git switch -c note/<slug> main

The one exception is this arrangement itself — this file, `dev.sh`, the guard.
When the owner asks for a change to how the work is done, rather than to the
program, it belongs on main and is committed there at once, so the tree is
never left dirty. Work from a note is never that exception.

`./dev.sh` installs from whichever tree it is run in, so run it from the
worktree and the scratch install is your branch, not the owner's.

## Commands

    ./dev.sh install        build or refresh the scratch install
    ./dev.sh remove         tear it down
    ./dev.sh status         both installs, and what is running in each
    ./dev.sh seed           copy the real categories — never the log — into it
    ./dev.sh install-real   the real side, only when asked, only when idle

The scratch settings are deliberately fast and quiet: a full work → break →
long-break cycle runs in well under a minute, with sound, media-pausing,
Spotify, Reminders and calendar painting all off.

Those last three are the one thing no environment variable can separate.
Spotify, Reminders and Calendar are single, shared, and outside this
filesystem — a scratch install painting onto the real calendar would be
precisely the disturbance this arrangement exists to prevent. If a task needs
one of them, turn it on for that one test, turn it off again, and say in your
report that you did.

## What is enforced rather than asked

`.claude/hooks/guard-prod.py` runs before every Bash, Write and Edit. It
blocks the installers unless they come through `./dev.sh`, blocks the runtime
scripts unless they are dev-scoped, blocks writes to and signals at the real
install, and blocks unscoped `pkill`/`killall` — the specific thing that ends
a live pomodoro. Reading the real data is allowed, and is often the point.

Its cases are in `guard-prod.test.py`; run it after changing either file.

If the guard blocks you, it is right and you are wrong. Do not work around it.

## Handling a note

Notes arrive in `notes/inbox.md`, in whatever form they occurred to their
author. One note is one task.

1. Read the note. If it is ambiguous in a way that changes the work, ask
   before starting; if it is ambiguous in a way that does not, decide, and say
   which way you decided.
2. Branch, in the worktree: `git switch -c note/<short-slug> main`.
3. Change the source. Match the surrounding style — the comments here explain
   *why*, at length, and a patch that skips that reads as foreign.
4. `./dev.sh install`, then actually exercise the change. A change nobody ran
   is not finished.
5. Commit on the note branch, without being asked. The usual caution about
   committing is about not putting work somewhere it is hard to take back, and
   a note branch is the opposite of that: it is scratch, it is never `main`,
   and left uncommitted it cannot be read with `git diff main...note/<slug>`,
   cannot be merged, and is one absent-minded `git switch` from gone. Write the
   message in the house style — what the change is for, and what went wrong
   without it.
6. Report: what changed, what you ran to see it work, what you did not cover.
   Do not merge, and do not install to the real side, unless the owner asks
   for exactly that. Then, from the owner's checkout, `./dev.sh install-real`:
   it refuses while a session or a cycle is live and keeps the identifiers
   the permission grants are keyed to. Those two steps are the only ones that
   reach the install being used for real work, and neither happens on your
   own initiative.

When a note has been done and reported, remove it from the inbox. The commit
is its record; an inbox that still lists finished work is a list nobody can
trust.

When the owner asks for the whole inbox at once, one branch for all of it,
`next`, with one commit per note in dependency order. Fifteen interlocking
changes on fifteen branches spend the day on merge conflicts instead of on
the work; one branch keeps every note reviewable on its own commit and lets
a settings row added for one note be read by the next.

## Style

Read three neighbouring functions before writing one. This codebase argues
with itself in comments, explains the failure a line prevents rather than the
thing the line does, and prefers one command that does the job to two that
split it. Terseness in the code, not in the reasoning about it.
