# TimeTracker

Logs time spent per university course, driven entirely from your **launcher**.
Works the same in Alfred or Spotlight — it installs ordinary macOS app bundles,
so anything that launches apps can drive it. No Alfred Powerpack, no workflow,
no dependencies beyond what ships with macOS.

### Two folders, similar names

Worth pinning down before anything else, because they're easy to mix up:

| | Path | What it is |
|---|---|---|
| Project | `.../prosjekter/timetracker/` | this repo — the source you edit |
| Data | `~/.timetrack/` | installed scripts and your actual logs |
| Apps | `~/Applications/TimeTracker/` | the generated launcher entries |

The data folder is `.timetrack`, **not** `.timetracker`. Every path in this
README refers to the data folder unless it starts with `./`.

## The category model

Every category has three parts:

| | Example | Role |
|---|---|---|
| **key** | `BØK2100` | Stable identity. This is what the log stores. |
| **name** | `Bærekraftig økonomistyring 2` | Official name, shown in the launcher title. |
| **keywords** | `økstyr2`, `økstyr` | Whatever you actually remember it by. |

The key is the only thing that's permanent. Names and keywords are display
and search concerns, so you can rename a course or add a nickname at any time
without touching a single logged row — the reason for having a key at all.

In your launcher you type **any** of the three:

```
time økstyr2       ┐
time BØK2100       ├─  all reach  →  time BØK2100 – Bærekraftig økonomistyring 2
time bærekraftig   ┘
```

The title shows `KEY – Name`; the keywords match without being displayed.

## How it works

Launchers fuzzy-match **applications** by name, so this generates a tiny
background app bundle per category. Each bundle is an `Info.plist` plus a bash
script as its `CFBundleExecutable`, marked `LSUIElement` so nothing appears in
the Dock or steals focus. They exit immediately, so repeated launches re-run
correctly rather than re-activating.

Because they're plain app bundles registered with LaunchServices, **Alfred and
Spotlight both drive them identically** — there's no workflow or plugin to
install for either.

Keywords ride along as **`kMDItemAlternateNames`**, an extended attribute that
is matched but not displayed. That's what lets a clean title and fuzzy
nicknames coexist: the launcher shows an app's *filename* and ignores
`CFBundleDisplayName`, so the title and the search terms can't be separated any
other way. (The separator is an en dash rather than the `:` you might expect: a
literal colon in a filename renders as `/` in Finder, a holdover from HFS.)

> **How Alfred matches these.** Alfred keeps its own cache
> (`~/Library/Application Support/Alfred/Databases/filecache.alfdb`) and *does*
> honour `kMDItemAlternateNames` — the aliases land in its `altnames` column.
> But it looks them up with a SQLite `LIKE`, whose case folding is ASCII-only,
> so an alias stored as `BØK2100` can never match a typed `bøk2100`. That's why
> `sync-apps.sh` writes a lowercased copy of every alias alongside the original.
> Two more Alfred quirks are worth knowing, since they shape what's typable:
> it splits every digit after the first into its own word (`BØK2100` caches as
> `bøk2 1 0 0`), so past the first digit a course number matches only via the
> aliases above; and it builds an acronym index from capitals and digits with
> non-ASCII dropped (`BK2100B2`), which is why a bare `bk2100` — no `time`
> prefix, no `Ø` — also finds the course.

All writes go through `action.sh` and nothing else. The dashboard can correct
or delete a logged session, but it does that by calling `action.sh` too — so
every write takes the same lock and the same validation, and a browser page has
no privileged path to your log.

## Install

```bash
./spotlight/install.sh
```

Copies the runtime scripts to `~/.timetrack/bin/`, migrates old data if
needed, generates the app bundles into `~/Applications/TimeTracker/`, and
registers them with LaunchServices and the Spotlight index (which is also what
makes them findable in Alfred). Idempotent — re-run any time.

The source folder is named `spotlight/` for historical reasons — it predates
the switch to Alfred and has nothing to do with which launcher you use.

Remove with `./spotlight/uninstall.sh` (add `--purge-data` to also delete your
logs; by default they're kept).

## Usage

All via your launcher hotkey, type, Enter:

| Type | Does |
|---|---|
| `time` | **Smart toggle** — running → stop, idle → start your most recent category |
| `time <key\|name\|keyword>` | Start/switch to that course |
| `time dashboard` | Live dashboard in your browser |
| `time settings` | The dashboard's settings page (pomodoro durations, sound, retiring categories) |
| `time new` | Prompts for key, name and keywords; creates the category — no timer starts |
| `time categories` | Opens `categories.tsv` in a text editor to edit names and keywords |
| `time data` | Opens the data folder in Finder (it's hidden — a dotfolder) |
| `time calendar` | Runs one calendar check and reports what it matched (calendar extra only) |

Start and stop are the whole loop: `time` toggles, and typing a course name
switches straight to it. There are deliberately no `time stop` / `time stats`
apps — the toggle covers stopping, and the dashboard supersedes stats. (There
is no pause either, by design: a break is part of the work block — see
[Pomodoro mode](#pomodoro-mode-) — and stopping is always one keystroke away.)
The verbs still exist in `action.sh` if you ever want them from a terminal:

```bash
~/.timetrack/bin/action.sh stop
```

The smart toggle is the main ergonomic win: the common start/stop rhythm is
hotkey, `time`, Enter — no list to pick from.

### Session notes

Starting a timer asks **"What are you planning to work on?"**; stopping asks
**"What did you work on?"**. Both answers are stored on the session row, so
the log records intent and outcome, not just duration — which is what makes it
worth reading back.

Both are entirely voluntary. Skip, Cancel, Escape and the 120-second timeout
all store an empty answer and change nothing else. **A dialog can never block
or delay a timer**:

- Starting stamps the moment you pressed the key, starts the timer
  immediately, and attaches your answer a few seconds later. Time spent typing
  is inside the session, because the session had already begun.
- Stopping also stamps the moment you pressed the key and passes it to
  `action.sh`, so time spent answering is **excluded** from the segment. A
  six-second pause at the dialog still logs a three-second session.
- Switching courses asks both: what the outgoing session turned out to be,
  then what the incoming one is for.

The 120-second timeout matters for a second reason: an app bundle is still
"running" while its dialog is open, and LaunchServices refuses to relaunch a
running app — regardless of which launcher asked. Without a timeout, an
abandoned dialog would make `time` appear broken until dismissed.

Calendar auto-start never prompts — it runs headless, and a background dialog
would hang forever. Those rows simply have an empty plan.

Notifications name both parts, e.g. `Started BØK2100 (Bærekraftig
økonomistyring 2) — stopped LED2200 (Prosjektledelse) 23m`.

### Adding and editing categories

`time new` asks three questions in sequence — key, name, keywords — then
creates the category and regenerates its app bundle. Only the key is required.
It does not start the timer: creating a category and sitting down to work on it
are separate decisions, and `time <key>` is one keystroke away when you mean
the second one.

To change a name or add a keyword later, `time categories` opens the TSV
directly. After editing, run `~/.timetrack/bin/sync-apps.sh` to rebuild the
bundles. Because the log stores keys, renaming affects only what's displayed.

### Retiring a category

A finished course shouldn't keep cluttering the launcher. The **Categories**
panel on the settings page (`time settings`) lists every key with what it
holds — sessions, hours, whether it's running — and gives each one two ways
out:

- **Hide** drops its app bundle, keeps it out of the smart toggle's
  most-recent pick, and stops the calendar agent matching events to it. The row
  stays in `categories.tsv` with `hidden=1`, so the name still resolves
  everywhere in your history. **Show** puts it back exactly as it was, and so
  does starting it explicitly (`time <key>`) — hidden means "not in use", so
  using it un-hides it.
- **Delete** moves the row to `categories.deleted.tsv`. The sessions are
  untouched — deleting a category deletes the *name*, never the hours — but
  those rows now display the bare key, and the confirmation says how many.
  Seeding won't resurrect a deleted course on the next `install.sh` either.

Neither is offered for the category that's running right now; stop the timer
first. Keys that exist only in the log — a deleted category's history, or a
hand-edited row — are listed too, greyed out, so the hours are still accounted
for somewhere.

## Pomodoro mode 🍅

The start prompt has a **"Pomodoro mode"** checkbox. Tick it and the session
runs in a work/break cycle; leave it off and nothing about the tool changes.
All durations come from [Settings](#settings) (`time settings`).

If most of your sessions are pomodoros, set `pomodoro_default` to `on` and the
box starts ticked — you untick it for the sessions that aren't. It moves the
checkbox and nothing else: skipping the prompt still starts no cycle, and the
timer runs the same either way.

The cycle:

1. **Silent work session** (default 25 min), measured from the moment you
   pressed the key — not from when you answered the prompt.
2. When it elapses, a **huge tomato fills the screen** with three choices:
   - **Accept break** (Enter; also what happens on its own after
     `auto_accept_seconds`): the overlay switches to a break countdown.
   - **Snooze** (Esc): the tomato goes away and returns after
     `snooze_minutes`. Repeatable. The pomodoro doesn't count as completed
     until its break is accepted or skipped.
   - **Skip break**: the tomato explodes, and the next silent work session
     starts immediately. Counts as completed.
3. At the break's scheduled end a sound plays (if `sound` is `on`) and the
   overlay flips to a prominent **"Back to work"** state. Clicking it (or
   Enter) starts the next work session.
4. Every `long_break_every`-th completed pomodoro (default 4) gets
   `long_break_minutes` instead of `break_minutes`. Skips count as completed.

Three rules make it fit the rest of the tool:

- **The timer never pauses.** Breaks count as category time, and a 4-pomodoro
  block is still **one row** in the log. What the row does record is
  `pomodoros` (how many completed) and `break_overrun_sec`.
- **A break ends when you end it**, not when the clock says so. The scheduled
  end is when the sound plays and the overlay flips — going to fetch water,
  getting caught in a conversation, or closing the lid just accumulates
  measurable **break overrun**, logged on the row. There is no timeout and
  nothing auto-cancels on sleep; the 8h guard is the only backstop.
- **Only stopping or switching the course timer cancels the cycle.** The
  closing row still gets the counts accrued so far. Calendar auto-starts
  never prompt, so they are never pomodoro.

The overlay and the checkbox come from a small compiled helper
(`TimeTracker Prompt.app`, built at install — needs the Xcode command line
tools like the calendar extra). That helper *is* pomodoro mode: without it the
checkbox isn't offered, and a cycle that somehow finds itself running without
it says so and cancels rather than carrying on. Everything else — the timer,
the log, the prompts, the dashboard — works exactly the same with or without
`swiftc`.

There was briefly a notifications-only fallback that advanced the phases by
itself. It went, and the reason is worth keeping: it wasn't a smaller version
of the feature, it was a different one wearing the same name — breaks you
never accept, overrun never measured — on a path that only runs where nobody
could have tested it. Failing loudly beats degrading silently.

Under the hood: a detached watcher process babysits the cycle via
`~/.timetrack/pomodoro` (deleted when the cycle ends), compares wall-clock
time rather than sleeping long — so a closed lid simply fast-forwards on
wake — and never writes to the log: `action.sh` reads the cycle's counts
into the row at segment close, staying the single writer. Kill the watcher
or the overlay at any moment and the log stays valid.

**The overlay can't be lost.** Mission Control, a Space switch or another app
can push a full-screen panel off screen, and since the helper is `LSUIElement`
there'd be no Dock icon or Cmd-Tab entry to bring it back — a break you could
never end. So the overlay re-asserts itself every two seconds, and emits a
heartbeat *only while it is genuinely on screen*. The watcher checks that
heartbeat rather than mere process liveness: an overlay that is running but
invisible is killed and relaunched within ~30s.

### The tomato silences your headphones

A break that covers the screen but leaves the lecture playing isn't a break:
the video rolls on behind the tomato, the sound stays in your ears, and the
only way to stop it is to end the break you just started. So the moment the
tomato lands, TimeTracker pauses every player it can reach — browser tabs
(Chrome, Brave, Edge, Vivaldi, Chromium, Arc, Safari), Music, TV, Spotify,
VLC and QuickTime Player. Set `pause_media` to `off` if you'd rather your
music played through the break.

Three things it deliberately does not do:

- **It never resumes.** Ending a break puts you back at your desk, not back
  in the video — press play yourself when you actually mean to.
- **It never touches an app that isn't already running,** so it can't open
  Music on you, and it never asks for permission to control an app you don't
  use.
- **It never touches the output volume.** A global you'd have to remember to
  put back is worse than a video that got missed.

It fires once per tomato, not once per tick: snooze, restart the video, and
the next tomato silences it again.

**Two permissions, both one-time.** The first tomato after installing puts up
the system's *"TimeTracker Media wants to control Google Chrome"* — allow it
(one prompt per app you actually play things in, granted once and revocable
in System Settings > Privacy & Security > Automation). And a browser will not
run the pause script until you tick **View > Developer > Allow JavaScript
from Apple Events** in Chrome, or **Develop > Allow JavaScript from Apple
Events** in Safari. Without it the browser silently keeps playing.

To get both out of the way at a calm moment rather than at the start of a
break, launch **TimeTracker Media** from Spotlight: it's the same "pause
everything" run by hand, and a perfectly good panic button on its own.

### The break menu

A small hamburger appears in the **top-left corner of the pause screen** —
during a break, never on the tomato, where the screen is a decision with an
auto-accept running behind it. It holds two things.

**Spotify.** A remote for the Spotify app on this Mac: what's playing now,
previous / play-pause / next, volume, and your playlists. It talks to Spotify
the way `pause-media.sh` already does, over Apple Events — no account, no
Premium, no network, and nothing embedded. What that costs is what AppleScript
does not expose: there is **no search and no library**, because Spotify's
scripting dictionary hands out playback and the current track and nothing
else. So you list the playlists you want offered in `time settings` — paste
the link (right-click a playlist → Share → Copy link) and give it a name;
nothing local can ask Spotify what it's called. There's no artwork either, for
the same reason and because fetching one would mean the overlay touching the
network; the tile beside each name is derived from the name instead.

**The work playlist is separate.** Mark one playlist as **work** and it is
kept *out* of the break list — the break is for other music — and started
again the moment you press "I'm back". If none is marked, Spotify is paused
instead. Either way the break's music does not follow you into the next work
session.

Both of those only happen **if you touched the music during the break.** A
break you spent in silence ends in silence, exactly as it did before this
existed: a timer elapsing is not a reason to start playing something in a
quiet room. Set `spotify_resume_work` to `off` and the work playlist stays
where it is; the break's music is still stopped.

One more consequence worth knowing: the tomato's hush pauses Spotify like
everything else, so **every break starts silent**, including the work
playlist. That is the intended shape — you choose break music, or you don't.

**Add Reminder.** A box to write down the idea that arrived while you were
away from the desk, filed into Apple Reminders through EventKit. It goes to a
list of its own (`Pause Notes` by default, changeable in `time settings`,
created on first use) precisely so it *is* an inbox: catch it now, drag it
where it belongs later. `⌘↵` saves; `esc` steps back and keeps the draft, and
the draft also survives the break ending mid-sentence.

It is write-only in behaviour — the panel never shows you your reminders —
but not in permission: **EventKit has no write-only tier for reminders** the
way it does for calendar events, so saving one note requires a grant that
could read them all. There is no way to ask for less; `SECURITY.md` says so
too.

**Two more one-time permissions, and both are worth answering early.** An
unanswered permission prompt *blocks* the thing that raised it, and the middle
of a break is the worst place to discover that. So:

```
Cmd+Space  ->  "time spotify"    ->  Enter     (Automation: Spotify)
Cmd+Space  ->  "time reminders"  ->  Enter     (Privacy: Reminders)
```

Both report what they found and change nothing — `time spotify` also tells you
what is playing, which is the quickest way to check the grant is still there.
Set `spotify` or `reminders` to `off` and that entry is simply not offered;
with both off there is no hamburger and the pause screen is exactly what it
was.

Under the hood the overlay still launches nothing. It writes fixed-name files
(`.tomato-spotify-cmd`, `.tomato-reminder`), and `pomodoro-watch.sh` is the
only thing that turns one into a running process — always through an app
bundle, because a permission is granted to a *name* and the watcher inherits
the name of whichever category app started the session. The Spotify remote is
one short-lived agent process for the whole panel rather than one launch per
click, and it touches `.media-stop` before it starts anything, so a break hush
still walking browser tabs can't arrive late and pause the music you just
chose.

The bundle exists for a duller reason than a Spotlight verb. macOS grants
Automation permission to the app *responsible* for whatever sends the event,
and the pomodoro watcher belongs to whichever category app started the
session — so without a bundle of its own the request would arrive as
"TimeTracker TDT4100 wants to control Google Chrome", mid-break, under a
different name for every course. One bundle, one name, granted once.

**What it cannot reach, and why there is no clever workaround.** Canvas
embeds lectures as *LTI tool launches* — an `<iframe src="about:blank">` that
Canvas POSTs an external tool into — so the player's document belongs to
another origin and nothing running in the Canvas page can touch it. Same for
a YouTube or Vimeo embed inside any page.

The system play/pause key *does* reach those, which is why pressing F8 by
hand works, so a small signed helper was built to post one. **It doesn't
work.** On macOS 26 every variant — HID tap, session tap, annotated session
tap, real timestamp, direct post to the target's pid, plain F8 keycode — is
accepted by the system and consumed by nothing, with the Accessibility grant
confirmed live and a playing-audio oracle to measure against. Media keys now
travel through the Now Playing service, which ignores synthesised events;
the physical key works because it originates a layer below anything a
process can post. The helper was removed rather than left in place, because
a feature that asks for Accessibility and does nothing is worse than no
feature. Don't rebuild it without evidence the platform changed.

**The tomato tells you when something is still playing.** Since F8 reaches
what nothing else can, the overlay says so — *"Still playing something? Press
F8"*, bottom left — but only while sound is actually coming out of the
speakers. The watcher samples `coreaudiod`'s power assertion every two
seconds while the tomato is up, and writes `~/.timetrack/.tomato-audio` for
the overlay to read. The hint appears at once and survives about six seconds
of silence, so a gap between tracks doesn't make it blink. It knows about
sound, not about video: a muted video gets no hint.

(The flag is a file of its own rather than an eighth column in
`~/.timetrack/pomodoro`, because three readers parse that file with a plain
`read` into seven variables, where a trailing field would land silently
inside the watcher pid.)

**Only the tab you're looking at.** The pause asks the *active tab of every
window* and nothing else — two Apple Events per browser, landing in well
under a second. A video playing in a tab you aren't looking at keeps playing.
That's deliberate.

It wasn't always. A full sweep of every tab came first, and it was the source
of every hard problem this feature had. Chrome discards background tabs to
save memory, and a discarded tab doesn't refuse an Apple Event — it never
answers, at a timeout each. Measured on an ordinary browser with fifteen
tabs, eight of them discarded: **seventeen seconds per pause**. That is long
enough to outlive the tomato, and a pause landing after the tomato is gone
stops a video you have deliberately gone back to — tomato appears, video
stops (right), break skipped, video restarted, and then the sweep finally
arrives and stops it again (very wrong).

It got a deadline, a stop signal and halved timeouts, and then the simpler
question got asked: does a tab nobody is looking at need pausing at all? It
doesn't. Seventeen seconds became **0.9**.

Two things from that episode are kept, because they're cheap and they guard a
whole class of bug. Every event carries its own `with timeout` — 3s for a
tab, 5s for a music player — so a wedged app can't stall anything. And the
watcher signals the pause to stop the instant the tomato leaves the screen,
whether you skipped, snoozed or ended the break, so nothing can arrive late.
Each app also runs in its own `osascript`, in parallel: in sequence, a
browser sitting on a permission prompt delayed Spotify by ten seconds.

**What still plays.** A video in a tab you aren't looking at, by design.
Players with no AppleScript dictionary — IINA among them — which aren't
reachable at all. And a muted video, which nothing can detect and nothing
needs to: there's no sound to interrupt, and the tomato is over the picture
anyway.

## Dashboard

`time dashboard` starts a small local web server and opens your browser. The
table updates while a timer runs: the in-flight segment isn't in
`sessions.tsv` yet, so it's folded into the totals on the fly, and the clock
ticks client-side. Start, stop or switch from your launcher and the page
follows within ~2s without a reload.

Shows current status with a live clock (and the current session's intent
beneath the course name), today/week/all-time totals, a per-category breakdown
labelled `KEY: Name`, recent sessions with **Planned** and **Actually did**
side by side, and a **Needs attention** section listing any `AUTOCLOSED` or
`CLOCKSKEW` rows. While a pomodoro cycle is live, the status card also shows
the phase, a ticking countdown, completed-count dots (🍅🍅○○) and accrued
break overrun; logged pomodoro rows carry a `🍅×N` tag.

### Fixing a session

Every row in **Recent sessions** and **Needs attention** has **Edit** and
**Delete**. This is the answer to "I forgot to stop the timer": stop it (or let
the 8h guard close it), then trim the end time back to when you actually
stopped.

**Edit** opens the row in place — start, end, category, planned, actually did —
and shows the resulting duration as you type, so you can see the segment shrink
from `8h 00m` to the real `3h 10m` before saving. `Esc` cancels, `Enter` saves.
Polling pauses while a row is open, so a refresh can't wipe what you're typing.
The row is re-tagged `EDITED`, which also clears it out of **Needs attention**.

**Delete** asks first, then moves the row to `sessions.deleted.tsv` — it isn't
shredded, so a mis-click is recoverable by hand.

Refused edits say why: an end time in the future, an end before the start, a
segment over 24h, an unknown course, or an edit that would overlap the timer
that's running right now (stop it first — otherwise the overlap gets counted
twice).

### How it's kept safe

The page binds to `127.0.0.1` only, requires a random per-run token, validates
the `Host` header, and shuts down after 10 minutes with no polls. Running
`time dashboard` again reuses the existing server.

Editing and deleting are the only session writes it can do — there's no start
or stop from the page — and it doesn't perform them itself: both shell out to
`action.sh`, which stays the single writer and holds the lock. They're POST-only
and additionally require the token in a custom header, a JSON content type and a
matching `Origin`, none of which a hostile web page can send without a preflight
the server never answers. See [SECURITY.md](SECURITY.md) for the full picture.

## Settings

`time settings` opens the dashboard's settings page (starting the server the
same way `time dashboard` does, or reusing a running one). Saving posts each
changed value through `action.sh setconf`, so settings take the same lock and
validation as every other write.

Values live in `~/.timetrack/settings.tsv` — `key<TAB>value`, one per line,
no header. A missing file simply means "all defaults", and a hand-corrupted or
out-of-range value reads back as the default rather than an error. Unknown
keys are preserved on rewrite.

| key | default | range | meaning |
|---|---|---|---|
| `pomodoro_minutes` | `25` | 0.1–180 | length of one pomodoro work session |
| `break_minutes` | `5` | 0.1–60 | short break length |
| `long_break_minutes` | `15` | 1–120 | long break length |
| `long_break_every` | `4` | 1–12 | every Nth completed pomodoro gets the long break |
| `snooze_minutes` | `5` | 1–60 | how long "snooze" postpones the tomato |
| `auto_accept_seconds` | `60` | 1–600 | seconds before an unanswered tomato takes the break itself |
| `pomodoro_default` | `off` | on/off | start the prompt with the "Pomodoro mode" box already ticked |
| `sound` | `on` | on/off | play a sound with pomodoro notifications |
| `pause_media` | `on` | on/off | pause video and music everywhere when the tomato appears |
| `easter_egg` | `on` | on/off | let the tomato open its hidden game on a break |
| `spotify` | `on` | on/off | offer the Spotify remote in the break menu |
| `spotify_resume_work` | `on` | on/off | start the work playlist again when a break you played music in ends |
| `reminders` | `on` | on/off | offer "Add Reminder" in the break menu |
| `paint_calendar` | `on` | on/off | paint logged sessions onto a calendar |
| `paint_days` | `14` | 1–90 | how many days back each paint reconciles |
| `paint_min_minutes` | `2` | 0–60 | sessions shorter than this are not painted |

**`pomodoro_minutes` and `break_minutes` also take fractional minutes**, down
to `0.1`, so a whole cycle can be exercised in seconds while you're trying
settings out: `0.5` is 30 seconds, and the length used is
`floor(minutes × 60)`. The other durations stay whole minutes.

Scripts read settings by sourcing `~/.timetrack/bin/settings.sh` and calling
`tt_setting <key>` — or `tt_setting_secs <key>` for a duration in seconds,
which is what the fractional ones require, since the shell can't multiply a
decimal. Neither ever fails, and neither executes the file (it's parsed with
awk — user-editable data stays data). The defaults table lives in that one
file only. From a terminal:

```bash
~/.timetrack/bin/action.sh setconf pomodoro_minutes 30
```

The same page carries two list panels that are not settings-table material,
because the table holds numbers and switches and these hold rows and free
text: **Break playlists** (see [The break menu](#the-break-menu)) and **Break
notes**, the Reminders list a captured note goes to. Both write through
`action.sh` like everything else:

```bash
~/.timetrack/bin/action.sh addplaylist "Break café" "https://open.spotify.com/playlist/…"
~/.timetrack/bin/action.sh workplaylist spotify:playlist:…     # or "-" for none
~/.timetrack/bin/action.sh setremlist "Pause Notes"
~/.timetrack/bin/action.sh setpaintcal "TimeTracker"          # or "-" for none
```

The same page carries the **Categories** panel — hiding and deleting a
category, described under [Retiring a category](#retiring-a-category). Those
two go through `action.sh hidecat` / `action.sh delcat` and are equally
available from a terminal:

```bash
~/.timetrack/bin/action.sh hidecat BØK2100 on
```

The dashboard runs `sync-apps.sh` itself afterwards, so the launcher matches
the change without a second step; from a terminal you run it yourself.

## Calendar painting

Every session you track is written onto a calendar of its own, so the week you
planned and the week you had can be looked at side by side — and toggled off
when you'd rather not see it.

This replaced the opposite feature. There was an agent that *read* the
calendar and started a timer when a lecture was already under way, and it went
because it guessed: a lecture on the calendar is a plan, not a fact, and a
wrong guess costs more than it saves now that a session can simply be
corrected in the dashboard afterwards. Painting makes the same data flow the
other way, where it is a record rather than a guess.

### Setting it up

Give it **an empty calendar of its own**, and make it in Google Calendar if you
want it on your phone:

1. Google Calendar → *Other calendars* → **+** → *Create new calendar*.
2. Tick it at [calendar.google.com/calendar/syncselect](https://calendar.google.com/calendar/syncselect),
   or macOS will never see it. (Google's CalDAV cannot create calendars, which
   is why this step is yours and not the installer's.)
3. `time calendar` once, to grant Calendar access and let it read the list.
4. `time settings` → **Calendar painting** → pick it → Save.

It paints immediately, and then after every session close.

### What it does

- **One event per logged session**, titled with the category (`MAT2300
  Optimering og modellering…`). The plan, the recap, the session note and the
  pomodoro counts go in the description.
- **It reconciles, it doesn't append.** Every paint makes the last
  `paint_days` (default 14) match the log exactly: new sessions appear,
  corrected ones move, deleted ones vanish. That is what makes it safe to run
  after every close — the tenth paint over the same week does nothing — and
  it's why an edit in the dashboard reaches the calendar with no extra
  machinery.
- **It never touches the future,** and never anything outside that window.
  Tomorrow's plans are yours.
- **Events are free-time and have no alerts.** A record of what already
  happened should not make you look busy or buzz at you.
- Sessions shorter than `paint_min_minutes` (default 2) are left off, so a
  mis-tap doesn't turn into a calendar entry.

### The one thing to be careful about

Reconciling means **deleting events in the window that don't match a session**.
That is only safe because everything in the calendar was put there by a
previous paint — which is exactly false the first time.

So the first paint into any calendar refuses to delete anything: if the window
already holds events TimeTracker didn't put there, it reports the count and
changes nothing at all. Only once a paint has actually succeeded is that
calendar recorded as adopted (`.paint-adopted`) and reconciled freely
afterwards. Picking your real calendar out of the dropdown by mistake costs you
an error message, not a fortnight.

After that, treat the calendar as generated: anything you add to it by hand
inside the window will be removed on the next paint.

### How it's put together

- `paint-calendar.sh` turns the last `paint_days` of `sessions.tsv` into a
  request file — one `awk` pass, with the ISO timestamps converted to epochs
  in `awk` itself rather than forking `date` once per row.
- `ttpaint.swift`, inside `TimeTracker Calendar.app`, does the reconcile. It
  lives in a bundle because macOS only grants calendar access to a bundle
  launched through LaunchServices; the same binary exec'd directly is denied
  without a prompt.
- `action.sh` fires the paint, detached and silent, whenever a logged row
  changes — a close, an edit, or a delete. Nothing waits for it, and a failure
  (no permission, no calendar chosen) never turns stopping a timer into an
  error. The next close retries the same window anyway.
- One painter at a time, via a `mkdir` lock: stopping one timer and starting
  another is two closes a second apart, and the one that waits goes on to read
  a log that already includes what the first was called about.
- `time calendar` runs a paint by hand and says what it did. With no request
  to act on it just lists your writable calendars, which is what the settings
  dropdown offers and how the permission prompt gets raised at a calm moment.

Requires the Xcode command line tools (`xcode-select --install`) for `swiftc`.
The compile happens at install and takes a few seconds.

## Data model

Everything lives in `~/.timetrack/` (created on first run, `chmod 700`).
Override with `TIMETRACK_DIR` — and `TIMETRACK_APPS_DIR` for the bundles — to
test against a scratch directory. When those are set, `sync-apps.sh` bakes
them into the generated bundles so a test install can't touch your real logs.

### `spotify-playlists.tsv`

```
uri	name	role
spotify:playlist:37i9dQZF1DWZeKCadgRdKQ	Deep Focus	work
spotify:playlist:1BwMyLKUUvMCEQZfLzWnAB	Break café	
```

The break menu's Spotify list, in file order. `role` is `work` on at most one
row — the playlist kept for work sessions, which is why it is the one the
break menu does *not* offer. A row with no third field is an ordinary break
playlist, the same tolerance `categories.tsv` extends to its `hidden` column.
Links are normalised to `spotify:<type>:<id>` on the way in, which is also
what makes them safe to hand to an Apple Event: no quote, backslash or space
can survive that shape.

### `reminders-list`

One line: the Reminders list that "Add Reminder" files into. Absent means
`Pause Notes`. Free text, which is exactly why it isn't in `settings.tsv`.

### `paint-calendar`

One line: the calendar [painting](#calendar-painting) writes to. Absent means
nothing is painted. Beside it, `.paint-adopted` records the calendar a paint
has actually succeeded against — until those two agree, every paint refuses to
delete anything it did not put there.

### `categories.tsv`

```
key	name	keywords	last_used_epoch	hidden
BØK2100	Bærekraftig økonomistyring 2	økstyr2,økstyr	1787225346	
INF1050	Digitale systemer	øksys	1787225000	1
```

Keywords are comma-separated. Rewritten in full on each update.

`hidden` is `1` for a retired category and empty otherwise. Rows written before
the column existed simply have four fields, and every reader treats a missing
fifth field as "not hidden" — so an old file needs no migration to stay
correct.

### `sessions.tsv` — the log

```
start_iso	end_iso	duration_sec	category	note	plan	recap	pomodoros	break_overrun_sec
2026-08-20T09:14:03+0200	2026-08-20T10:41:55+0200	5272	BØK2100		les kap 4	kom gjennom kap 4	3	140
```

- One row per closed segment. Rows are appended as segments close; the only
  things that ever rewrite one are the dashboard's Edit and Delete.
- `start_iso` / `end_iso`: local time, `%Y-%m-%dT%H:%M:%S%z`.
- `duration_sec`: integer, precomputed, never negative.
- **`category` holds the category *key*.** Join against `categories.tsv` for
  the display name.
- `note`: empty, `AUTOCLOSED` (8h guard), `CLOCKSKEW` (clock went backwards),
  or `EDITED` (corrected by hand from the dashboard).
- `plan` / `recap`: your answers at start and stop. Either may be empty, and
  rows logged before this feature existed have neither — readers tolerate the
  shorter width.
- `pomodoros` / `break_overrun_sec`: empty = pomodoro mode was off for this
  session. Otherwise: how many pomodoros completed in this row, and the total
  seconds its breaks ran past their scheduled length (0 = none). Same
  short-row tolerance as `plan`/`recap`.
- Total time on a course = sum of its `duration_sec` — a flat list of closed
  intervals, nothing to interpret. Pomodoro breaks are inside the interval,
  not between rows.

A row is addressed for editing by the triple `(start_iso, duration_sec,
category)`, not by line number — line numbers go stale the moment another
segment closes. If that triple doesn't match exactly one row, nothing is
written and the dashboard says to reload.

### `sessions.deleted.tsv` — tombstones

Same columns. A row deleted from the dashboard is appended here rather than
dropped, so an accidental delete is a copy-paste away from being restored.
Created on first delete; nothing reads it.

### `categories.deleted.tsv` — retired categories

Same bargain, same columns as `categories.tsv`. A category deleted from the
settings page lands here instead of vanishing, so its name can be pasted back.
Unlike the session tombstones it *is* read, by exactly one caller:
`migrate_v2.py` skips seeding a course you deleted, so re-running `install.sh`
can't bring it back.

### `state` — current timer (single line, or empty = idle)

```
RUNNING	BØK2100	1755678843	les kapittel 4
```

`status`, `key`, `segment_start_epoch`, `plan`. `RUNNING` is the only status
that exists. The plan lives here because it's captured at start but only
written to the log at stop. A line that doesn't parse — including a `PAUSED`
line from an older version — is discarded with a notification rather than
trusted.

## Forgot-to-stop guard

Every action first checks whether a `RUNNING` segment has been going for more
than 8 hours. If so it's closed at `start + 8h`, tagged `AUTOCLOSED`, and the
notification says so — before the action you asked for runs. Nothing is ever
silently discarded or logged as a 14-hour session; the dashboard's **Needs
attention** section lists these rows, and each one has an **Edit** button for
trimming the end back to when you actually stopped — see
[Fixing a session](#fixing-a-session). The guard keeps a forgotten timer from
poisoning your totals; the edit is how you make the row true.

## Loading the log later (pandas)

`pandas` isn't installed on this machine — `pip3 install pandas` first, or use
`csv` from the standard library. The join itself is verified: every key in the
log resolves against `categories.tsv`.

```python
import pandas as pd

df = pd.read_csv("~/.timetrack/sessions.tsv", sep="\t", parse_dates=["start_iso", "end_iso"])
cats = pd.read_csv("~/.timetrack/categories.tsv", sep="\t")
df = df.merge(cats, left_on="category", right_on="key", how="left")
by_course = df.groupby(["key", "name"])["duration_sec"].sum() / 3600  # hours per course
```

## Migration

`install.sh` runs `migrate_v2.py`, which converts a pre-key `categories.tsv`
(`name<TAB>last_used`) to the keyed format and rewrites the log's category
column from names to keys. It derives each key from the course code in the old
name, keeps the old name as a searchable keyword, and seeds the current course
list. Both files are backed up as `*.bak-<timestamp>` first, and it's a no-op
once already migrated.

## Fixed bugs

| Bug | Symptom | Fix |
|---|---|---|
| **Concurrent writes** | Double-tapping Enter logged the same segment twice, silently doubling your time | `mkdir`-based lock around the whole read-modify-write |
| **Newline in category name** | Corrupted both TSVs into malformed rows | Control characters stripped from all fields |
| **Category with an empty field got no app** | A course with no keywords, or a bare key with no name, never appeared in the launcher | `read` treats tab as IFS *whitespace* and collapses runs of it, so the empty fields vanished and `last_used` landed in the wrong variable, failing the digit check. `sync-apps.sh` now splits on `\037` instead |
| **Slug collisions** | `TDT4136 AI` / `TDT4136-AI` produced the same bundle id | Slug carries an md5 suffix of the original |
| **Non-ASCII names** | `Økonomi` collided with `Konomi`; a non-Latin name got **no app at all** | Same hash suffix — never empty, never colliding |
| **Corrupt state** | A malformed `state` line produced a bogus 8h row dated 1970 | State validated and discarded if implausible |
| **Clock skew** | A backwards clock jump logged a **negative** duration | Clamped to 0 and tagged `CLOCKSKEW` |
| **Silent switching** | Starting a course while another ran gave no hint the first was closed | Notification now names both |
| **Dashboard couldn't relaunch** | "time dashboard is not responding" — the server *was* the app process, so LaunchServices refused to relaunch it | Server detached with `nohup`; the bundle exits immediately like every other app |
| **Keyword false positives** | Norwegian compounds meant `ml` matched `Samling` and `prosjekt` matched `Prosjektmøte`, auto-starting a course timer on a dinner | Calendar matching is now key-only; keywords never match there |
| **Calendar helper overwrote its argument** | `open -a "TimeTracker Calendar" notes.txt` destroyed notes.txt | Refuses any path not named `.calendar-events.tsv` |
| **Empty notification on first start** | `start_key` ended in a test that returns 1 when nothing was closed, so `set -e` killed the script before it printed | Explicit `return 0` |

## Verification

Point at a scratch directory, install, exercise, tear down:

```bash
export TIMETRACK_DIR=$HOME/tt_sandbox/data TIMETRACK_APPS_DIR=$HOME/tt_sandbox/apps
./spotlight/install.sh
mdfind -onlyin "$TIMETRACK_APPS_DIR" "økstyr2"
./spotlight/uninstall.sh --purge-data && rm -rf ~/tt_sandbox
```

Verified: bundles index as `kMDItemKind = Application`; keyword aliases
resolve (`økstyr2` → BØK2100, `øksys` → INF1050, `optmod` → MAT2300) while the
title stays `KEY – Name`; repeated `open` re-runs rather than re-activating;
the smart toggle covers all three states; unknown keys are rejected;
`sync-apps.sh` prunes removed and hidden categories while preserving control apps;
migration rewrites the log to keys with backups; calendar titles resolve to
keys by course code; and the dashboard tracks a running timer without a
reload.

## Known limitations

- **No live subtitles in the launcher.** It shows an app name and
  "Application" — today's totals can't appear there. That's what the dashboard
  is for.
- **New categories need `time new`,** because a launcher can't pass an argument
  to an app.
- **Indexing lag.** A new category's app registers immediately, but the index
  can take a few seconds to surface it — and a newly-added *keyword* needs
  `sync-apps.sh` plus a moment for `mdimport` before it matches.
- **Course numbers are only partly typable in Alfred.** Alfred splits every
  digit after the first into its own word, so `time bøk21` matches nothing on
  the name alone; it resolves through the lowercased aliases instead. See
  [How it works](#how-it-works) for the full matching rules.
- **`time` alone may not be top hit initially** — Time Machine competes for the
  prefix until your launcher learns your pick.
- **Case-only duplicate keys** collide as filenames on a case-insensitive
  volume, so only one app is generated.
- **Some players keep playing through a break.** The tomato pauses the active
  tab of each browser window plus the scriptable players; a background tab, a
  cross-origin embed or an unscriptable player keeps going. See
  [The tomato silences your headphones](#the-tomato-silences-your-headphones).
- **The Spotify remote reaches this Mac only.** Apple Events go to the desktop
  app, so it cannot see or drive playback on your phone, and it cannot search
  or browse your library — the scripting dictionary doesn't expose one. Hence
  the hand-listed playlists, hand-typed names and no artwork.
- **Playlist names are yours, not Spotify's.** Nothing local can look one up,
  so renaming a playlist in Spotify does not rename it in the break menu.
- **Capturing a reminder needs full Reminders access.** EventKit has no
  write-only tier for reminders, only for calendar events, so a feature that
  only ever writes still holds a grant that could read.
- **A break note is one line.** Newlines are collapsed to spaces on save,
  which is what makes the request file a TSV like everything else here.
- **The painted calendar is generated, not shared.** Anything you add to it by
  hand inside the repaint window is removed on the next paint. Give it a
  calendar nothing else writes to.
- **Painting can't create the calendar for you.** Google's CalDAV has no way to
  make one, so the calendar has to exist before it can be chosen.
- **A renamed calendar stops the painting.** The choice is stored by title, so
  renaming it in Google leaves the setting pointing at nothing; the settings
  page says so, and re-picking it is one click.
