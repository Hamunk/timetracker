# TimeTracker

> *Simplicity is prerequisite for reliability.*
> — Edsger W. Dijkstra, EWD498

A record of when you worked and on what. It is kept in a tab-separated file,
it is driven from the launcher you already use, and it depends on nothing that
does not ship with macOS.

There is no daemon, no database, and no account. A category is an ordinary
application bundle; in consequence Alfred and Spotlight both drive this program
without either of them being told that it exists. That neither requires a
plugin is not an achievement. It is the absence of a mistake.

## The category model

Three parts, of which only the first is permanent.

| | Example | Role |
|---|---|---|
| key | `BØK2100` | identity — this, and only this, is what the log stores |
| name | `Bærekraftig økonomistyring 2` | what it is called officially |
| keywords | `økstyr2`, `økstyr` | what you actually type |

Renaming is therefore free, and a nickname costs nothing. A program that
stores what a thing is *called*, rather than what it *is*, acquires sooner or
later a rename it cannot perform.

In the launcher, any of the three will do:

```
time økstyr2       ┐
time BØK2100       ├─  all reach  →  time BØK2100 – Bærekraftig økonomistyring 2
time bærekraftig   ┘
```

## Install

```bash
./spotlight/install.sh
```

Requires the Xcode command line tools (`xcode-select --install`); without
`swiftc` the pomodoro cycle is not offered at all, rather than offered in some
degraded imitation. Re-run the installer whenever you please — it is
idempotent, which is a property one should insist upon in an installer and is
too often not given.

`./spotlight/uninstall.sh` removes the program. It does not remove your log;
`--purge-data` does, and says so first.

## Usage

Hotkey, type, Enter.

| Type | Does |
|---|---|
| `time` | toggle — running stops it, idle resumes your most recent category |
| `time <key\|name\|keyword>` | start, or switch to, that category |
| `time dashboard` | the log, in your browser |
| `time settings` | durations, sounds, retiring a category |
| `time new` | create a category; no timer starts |
| `time categories` | edit names and keywords in a text editor |
| `time data` | open the data folder |
| `time calendar` | report what one calendar pass would match |

There is no `time stop` and no `time pause`. The toggle stops, and a break is
part of a work block rather than an interruption of the accounting. Two
commands that do what one command does are not twice as convenient.

Starting asks what you plan to do; stopping asks what you did. Both may be
skipped, and both are stored on the row. A log of durations alone is a log
nobody reads a second time.

## Pomodoro

> *The competent programmer is fully aware of the strictly limited size of his
> own skull.*
> — Edsger W. Dijkstra, EWD340

Twenty-five minutes of work, five of break, a longer break every fourth. At
the end of a pomodoro the screen is taken by something impossible to ignore,
because a reminder one can dismiss without noticing is not a reminder.

The break offers a Spotify remote and a note to Reminders. Neither can start a
cycle, end a break, or write a row. They hang off the break; they are not part
of it, and the distinction is the reason the break remains trustworthy.

## Settings

`time settings`, or `~/.timetrack/settings.tsv` — `key<TAB>value`, one per
line. A missing file means every default. A value out of range reads back as
its default rather than as an error, on the principle that a configuration
file should not be able to break the program that reads it.

`pomodoro_minutes` 25 · `break_minutes` 5 · `long_break_minutes` 15 ·
`long_break_every` 4 · `snooze_minutes` 5 · `auto_accept_seconds` 60 ·
`pomodoro_default` off · `sound` on · `pause_media` on · `easter_egg` on ·
`spotify` on · `spotify_resume_work` on · `reminders` on ·
`paint_calendar` on · `paint_days` 14 · `paint_min_minutes` 2

The two pomodoro durations accept fractions, so a whole cycle can be exercised
in seconds instead of in an afternoon.

## Where things are

> *The art of programming is the art of organizing complexity.*
> — Edsger W. Dijkstra, EWD249

Everything is in `~/.timetrack/`, mode 700, and every file in it is text.

| File | Contents |
|---|---|
| `sessions.tsv` | the log: start, end, duration, category, note, plan, recap, pomodoros |
| `categories.tsv` | key, name, keywords, last used, hidden |
| `settings.tsv` | what you changed from the defaults |
| `state` | the running session, if there is one |
| `paint-calendar` | the calendar to paint into; absent means none |
| `reminders-list` | the list break notes go to |
| `spotify-playlists.tsv` | break playlists, and the one kept for work |

Set `TIMETRACK_DIR` and `TIMETRACK_APPS_DIR` to install against a scratch
directory. The installer bakes both into the generated bundles, so a test
install cannot reach your real log — an arrangement worth more than the
carefulness it replaces.

Every write goes through `action.sh`, which takes a lock and validates.
The dashboard is not an exception to this; it calls `action.sh` like everything
else, and has no privileged path to the log.

## Calendar

Name a calendar in settings and each closed session is painted onto it. A
paint reconciles a window of the last fourteen days against the log, so an
outage costs nothing and corrections propagate. Give it an empty calendar of
its own: it rewrites what it finds there.

Until a paint has succeeded once against the calendar you named, it refuses to
delete anything it did not itself create.

## Two remarks on trust

> *Program testing can be used to show the presence of bugs, but never to show
> their absence!*
> — Edsger W. Dijkstra, EWD249

`categories.tsv` is data you may edit, and data you may edit becomes, in a
careless program, code that runs. It does not run here. See `SECURITY.md`,
which is longer than this file and deliberately so.

The log is a record of your hours. It is kept locally, it is sent nowhere, and
it is readable — by you, in any text editor, for as long as text files exist.

## License

MIT.
