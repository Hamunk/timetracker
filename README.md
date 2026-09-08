# TimeTracker

> *Simplicity is prerequisite for reliability.*
> — Edsger W. Dijkstra, EWD498

A record of when you worked and on what, kept in a tab-separated file, driven
from the launcher you already use. It depends on nothing that does not ship
with macOS.

There is no daemon, no database, and no account. Each category is a small
application bundle, so Spotlight and Alfred can both start it without a
plugin.

## Install

```bash
git clone https://github.com/Hamunk/timetracker.git
cd timetracker
./spotlight/install.sh
```

The pomodoro screen needs the Xcode command line tools
(`xcode-select --install`). Without them the tracker installs and works, and
pomodoro mode is not offered.

The first install opens a setup page in your browser: name your first
categories, choose whether pomodoro mode is on by default, and grant the three
optional permissions while nothing is waiting on them. Re-run the installer
whenever you like; it only changes what changed.

`./spotlight/uninstall.sh` removes the program and keeps your log.
`--purge-data` removes the log too, and says so first.

## Use

Open the launcher, type, press Enter.

| Type | Does |
|---|---|
| `time` | stop the running timer, or start the most recent category |
| `time <key, name or keyword>` | start that category, or switch to it |
| `time new` | create a category |
| `time dashboard` | totals and recent sessions, in your browser |
| `time settings` | durations, keys, Spotify, Reminders, calendar, categories |
| `time guide` | how everything works |
| `time categories` | edit names and keywords in a text editor |
| `time data` | open the data folder |

Starting asks what you plan to do; stopping asks what you did. Both answers
are optional and both are stored with the session. There is no pause: a break
is part of the session.

## Categories

| | Example | Role |
|---|---|---|
| key | `TDT4100` | the permanent identity; the only thing the log stores |
| name | `Objektorientert programmering` | what it is called |
| keywords | `oop`, `java` | what you actually type |

Renaming is free and a nickname costs nothing, because the log never stores
either. In the launcher, any of the three will do:

```
time oop        ┐
time TDT4100    ├─  all reach  →  time TDT4100 – Objektorientert programmering
time objekt     ┘
```

## Pomodoro

> *The competent programmer is fully aware of the strictly limited size of his
> own skull.*
> — Edsger W. Dijkstra, EWD340

Twenty-five minutes of work, five of break, a longer break every fourth. When
a work session ends, a tomato takes the whole screen. Music and video that
can be reached are paused. The break ends when you say so, and time past the
scheduled end is logged as overrun on the session.

The break screen has a menu with two tools: a Spotify remote for your break
playlists, and a note box that saves into Apple Reminders. Neither can start a
cycle, end a break, or write to the log.

## Settings

`time settings`, or `~/.timetrack/settings.tsv`: `key<TAB>value`, one per
line. A missing file means every default; a value out of range reads as its
default. The settings page groups them: timer, break screen, Spotify,
Reminders, calendar, categories.

The two short durations accept decimals, so a whole cycle can be tried in
seconds.

## Where things are

> *The art of programming is the art of organizing complexity.*
> — Edsger W. Dijkstra, EWD249

Everything is in `~/.timetrack/`, readable only by your user, and every file
is text.

| File | Contents |
|---|---|
| `sessions.tsv` | the log: start, end, duration, category, note, plan, recap, pomodoros, overrun |
| `categories.tsv` | key, name, keywords, last used, hidden |
| `settings.tsv` | what you changed from the defaults |
| `state` | the running session, if there is one |
| `paint-calendar` | the calendar to write sessions to; absent means none |
| `reminders-list` | the list break notes go to |
| `spotify-playlists.tsv` | break playlists, and the one kept for work |

Every write goes through `action.sh`, which takes a lock and validates. The
dashboard has no other path to the log.

## Calendar

Name a calendar in settings and each closed session is written to it. Each
update reconciles the last fourteen days against the log, so corrections
propagate and an outage costs nothing. Give it an empty calendar of its own:
it rewrites what it finds there. Until one update has succeeded against the
calendar you named, it refuses to delete anything it did not create.

## Working on it

`dev.sh` builds a second, fully separate install (its own data, bundles,
identifiers and launcher word) so the program can be changed while the real
one is in use. `CLAUDE.md` describes the arrangement. To install against a
scratch directory by hand, set `TIMETRACK_DIR`, `TIMETRACK_APPS_DIR`,
`TIMETRACK_BID_PREFIX` and `TIMETRACK_VERB`; the installer bakes all four into
the bundles it generates.

## Security

> *Program testing can be used to show the presence of bugs, but never to show
> their absence!*
> — Edsger W. Dijkstra, EWD249

`categories.tsv` is data you may edit, and it never runs as code. The
dashboard listens only on this computer, only while open, with a per-run
token. `SECURITY.md` has the full review.

The log is a record of your hours. It is kept locally and sent nowhere.

## License

MIT.
