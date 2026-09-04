# Security review — TimeTracker

Threat model first, because it determines what actually matters here.

Almost everything below is bounded by one fact: **anything running as your
macOS user can already read and write `~/.timetrack` and `~/Applications`
directly.** So "a malicious process as you could tamper with this" is not, by
itself, a vulnerability — that attacker doesn't need TimeTracker. What *does*
matter is where TimeTracker (a) makes such tampering unusually attractive or
durable, (b) widens exposure beyond your own user account, or (c) turns
*data* into *code*.

Ranked by real risk.

---

## 1. Generated app bundles are an attractive persistence foothold — HIGH

`~/Applications/TimeTracker/*.app/Contents/MacOS/run` are unsigned, editable
shell scripts that **you execute several times a day by reflex**, triggered
from Spotlight without ever looking at them.

That combination is what malware wants: user-writable code, auto-executed by
routine user action, in a location that looks legitimate. Appending a line to
`run` gives an attacker persistent execution under your account with no
launchd entry, no login item, and nothing in the usual autostart places
people check.

- **Not fixed, and not really fixable** at this design's level: unsigned
  bundles are what lets you build them locally without a developer account.
- **Mitigations worth considering:** ad-hoc sign the bundles
  (`codesign -s - <app>`) so modification is at least detectable; or check the
  scripts into git and periodically `diff` against the repo. `sync-apps.sh`
  rewrites all bundles from source, so re-running it clears any tampering.
- **Detection:** `ls -la ~/Applications/TimeTracker/*/Contents/MacOS/run` and
  compare mtimes against your last install.

## 2. `categories.tsv` is data that becomes executable code — HIGH (mitigated)

`sync-apps.sh` reads category names and writes them into generated bash
scripts and XML plists. Anything that can write `categories.tsv` therefore
influences the content of scripts you later execute.

Currently safe: names go through `printf %q` (shell) and XML escaping
(plist), and `action.sh` strips control characters, so a name can't break out
of its quoting.

- **The risk is future edits.** If anyone later interpolates a category name
  into a generated script without `%q`, or into an `osascript -e` string,
  that's immediate code execution on the next Spotlight launch.
- **Rule to keep:** category names are untrusted text. Never interpolate one
  into a shell string, AppleScript source, or SQL. Pass via argv (as
  `notify.sh` does) or quote with `%q`.

## 3. Dashboard HTTP server — MEDIUM (hardened)

Opening a listening socket is the only genuinely new attack surface this tool
adds. Current controls:

| Control | Blocks |
|---|---|
| Binds `127.0.0.1` only | Anyone on your LAN/coffee-shop wifi reaching it |
| Random 24-byte token required on every request | Blind local port scanning |
| `Host` header must be loopback | DNS rebinding — a website resolving its name to 127.0.0.1 and reading the page via your browser |
| Six fixed routes, no path handling | Path traversal, directory listing |
| Mutations are POST-only, and additionally need the token in an `X-TimeTracker-Token` header, `Content-Type: application/json`, and a matching `Origin` | CSRF: a cross-origin page can send none of those without a preflight, and `OPTIONS` is never answered |
| The server never writes — mutations shell out to `action.sh` via an argv list | Bypassing the lock; shell interpretation of logged text |
| CSP `default-src 'none'`, `nosniff`, `no-referrer` | Token leaking via Referer; page pulling remote resources |
| Token file `chmod 600` | Other local *user accounts* reading the token |
| Idle shutdown after 10 min | An unattended server lingering all day |

Residual risks:

- **The token is in the URL**, so it lands in browser history and could be
  shoulder-surfed. It's per-run and dies with the server, so the window is
  small.
- **Any process running as you** can read `~/.timetrack/.dashboard` and query
  the API. Same-user, so per the threat model this is not a real escalation.
- **`/usr/bin/open` is called with the URL.** Now passed as an argv list via
  `subprocess.run`, never a shell string — so even a URL containing shell
  metacharacters can't be interpreted. (It previously used `os.system`; the
  token charset made it safe in practice, but the pattern was fragile.)
- **The page can now edit and delete logged sessions**, which the read-only
  version could not. That's a deliberate trade for a real problem (forgetting
  to stop the timer), fenced as tightly as it can be:
  - Exactly five mutations exist: `/api/session/update`,
    `/api/session/delete`, `/api/setconf` (settings values, validated against
    the whitelist table in `settings.sh`), `/api/category/hide` and
    `/api/category/delete`. There is no start, stop or pause from the page, so
    the *running* timer can't be touched over HTTP — and the two category
    routes refuse outright to touch the category it is running.
  - None of them is implemented in `dashboard.py`. Each builds an argv list and
    runs `action.sh`, which re-validates every bound (epoch sanity, 24h
    ceiling, known category, no overlap with a running segment), holds the same
    lock as every other write, and sanitizes the text fields. The dashboard has
    no privileged path to the log that `action.sh` doesn't gate.
  - A category write additionally runs `sync-apps.sh` to rebuild the launcher
    bundles — with an empty argv, so nothing from the request reaches it. It
    runs only after `action.sh` has already accepted the change, and a failure
    there degrades to a message on the page rather than failing the write:
    a stale app bundle is cosmetic, and re-running the script fixes it.
  - Rows are addressed by `(start_iso, duration_sec, category)`, and a write
    that doesn't match exactly one row is refused. A stale or guessed selector
    is a no-op, not a wrong-row edit.
  - Deletes move the row to `sessions.deleted.tsv` rather than dropping it,
    and a deleted *category* moves to `categories.deleted.tsv` the same way.
    No HTTP route removes a logged hour: deleting a category deletes a label.
  - **Rule to keep:** if a future route needs to do more than call
    `action.sh` with fixed arguments, stop and re-read this section. The value
    here is that the HTTP surface can only ask for things `action.sh` already
    knows how to refuse.
- **Worst case is still bounded by the threat model.** An attacker who can
  defeat all of the above is already running as you and can edit
  `sessions.tsv` with a text editor. What the mutations must never become is a
  path to *code* execution — hence argv lists, no shell strings, and no user
  input reaching a filesystem path.

## 3b. Calendar painting — MEDIUM (it deletes events)

The agent that *read* your calendar and started timers from it is gone, and
with it the two worries it carried: a rolling plaintext copy of your calendar
beside the log, and event titles — a string anyone who can send you an invite
controls — being fed into a matcher. Nothing here reads an event title any
more.

What replaced it writes, and writing means deleting.

- **Reconciling deletes.** Making the window match the log means removing
  events in it that no longer match a session. That is safe only because
  everything in the calendar was put there by a previous paint, and that claim
  is exactly false the first time — so **the first paint into any calendar
  refuses to delete anything**, reports what it found, and commits nothing at
  all. Only a paint that actually succeeded records the calendar as adopted
  (`.paint-adopted`); until then every request carries `STRICT 1`. This is the
  whole protection against picking your real calendar out of a dropdown, and
  it is worth keeping in exactly that shape: *check before mutating, and treat
  "I have written here before" as something you have to have earned.*
- **The blast radius is bounded twice more.** It touches only the one calendar
  it was named — no nearest match, and it will not create one — and only the
  window it was given, which never extends past `now`. Future events are never
  a candidate for deletion under any code path.
- **The helper only ever writes its own files.** Same containment rule as the
  reader it replaced: a handed path whose basename isn't
  `.paint-request.tsv` is ignored, so `open -a "TimeTracker Calendar"
  notes.txt` cannot make it read — or, through the result file beside it,
  overwrite — notes.txt.
- **Full calendar access, and it has to be.** Reconciling reads back what is
  in the window, so EventKit's write-only tier cannot do this job. The grant
  is listed and revocable under System Settings > Privacy & Security >
  Calendars.
- **Nothing untrusted reaches a shell or a script.** Session titles and notes
  are your own log, and they travel to the helper as file *content* in a TSV,
  never as arguments and never as AppleScript. The one thing that comes back
  from outside — an event's title, when deciding whether it matches — is only
  ever compared, never executed or logged.
- **No launchd agent any more.** The old one ran every five minutes for ever;
  painting is triggered by a logged row changing, runs once, and exits. One
  painter at a time, via a `mkdir` lock with a two-minute staleness break, so
  a crashed painter cannot wedge every future one.

Attack surface it does *not* add: no network access and no ports. Same
persistence caveat as §1 — `paint-calendar.sh` is another user-writable script
run automatically, and anything that can rewrite it inherits the calendar
grant.

## 3c. Pomodoro prompt/overlay helper — LOW

`TimeTracker Prompt.app` (the start prompt with the checkbox, and the
full-screen tomato) follows the calendar helper's containment rules:

- **It only ever writes its own result files.** A handed path whose filename
  isn't `.prompt-answer` / `.tomato-choice` is ignored and the standard
  location used instead — the overwrite-your-argument bug class is fenced the
  same way as in the calendar helper. The overlay also touches
  `.tomato-alive` (its visibility heartbeat) in that same validated
  directory, and writes nothing anywhere else.
- The overlay UI is a bundled local `tomato.html` in a WKWebView; no network
  and no remote content. Two message channels are accepted from the page and
  nothing else: `choice`, which takes four fixed words, and `menu`, whose
  vocabulary is listed in `handleMenu()` — every branch either touches one of
  three fixed-name files or does nothing. The page cannot name a file, and it
  cannot name a playlist: it is sent names, it answers with an index, and
  Swift resolves that index against the list it just read.
- **The overlay's write list grew by three, and stayed a list.** Alongside
  `.tomato-choice` and `.tomato-alive` it may now create
  `.tomato-spotify-want`, `.tomato-spotify-cmd` and `.tomato-reminder`, all in
  the same validated directory and all with fixed names. It still launches
  nothing: `pomodoro-watch.sh` is the only thing that turns one of those files
  into a running process.
- The watcher (`pomodoro-watch.sh`) never writes `state` or the log; it owns
  only `~/.timetrack/pomodoro`, and `action.sh` re-validates its contents
  (numeric checks, segment match) before flushing them into a row.
- Same persistence caveat as §1: it's another user-writable script run
  automatically while a cycle is live. It exits when the cycle ends.

## 3d. Break-time media pausing — LOW (but it is new reach)

`pause-media.sh` (run through `TimeTracker Media.app` when the tomato lands)
is the first part of this tool that reaches *outside* its own files: it sends
Apple Events to other applications, and in browsers it injects a line of
JavaScript into every open tab.

- **What that buys an attacker is the script, not the events.** Anything that
  can write `~/.timetrack/bin/pause-media.sh` (§1's threat, again) inherits
  whatever Automation grants you have handed out — so it could read or alter
  pages in your browser under your session. The Automation grants themselves
  are the mitigation you control: they are per app, prompted, listed in
  System Settings > Privacy & Security > Automation, and revocable there.
  Browsers additionally need "Allow JavaScript from Apple Events" ticked
  before any of it works, which is off by default.
- **Nothing untrusted goes into the AppleScript.** The app names and the
  injected JavaScript are fixed constants in the script; no category name,
  note, plan, or setting value is ever interpolated into AppleScript source
  (§2's rule, in the one place it would matter most). The JavaScript contains
  no double quote or backslash, which is what keeps it inside AppleScript's
  own string quoting.
- **It cannot start anything.** Every command is a pause, guarded by `pgrep`
  so an app that isn't running is never named — naming an app is enough to
  launch it. The play/pause media key would have been simpler and was
  rejected partly for this: it toggles, and posting synthetic key events
  needs Accessibility, which is a much broader grant than Automation.
- Failures are swallowed on purpose (a denied grant must not break a break),
  so a revoked permission shows up as media that keeps playing, not as an
  error. If pausing stops working, check Automation first.

## 3e. The break menu — LOW (two more grants, and one of them is broad)

`spotify.sh` (through `time spotify.app`) and `ttremind.swift` (through
`TimeTracker Reminders.app`) are the second and third parts of this tool that
reach outside its own files.

- **Exactly one bundle may talk to Spotify, and that is a security property
  as much as a usability one.** An Automation grant belongs to the app
  responsible for the process that sent the event; a second bundle running the
  same script would be a second grant to audit and a second prompt to click
  through. `time spotify` is that one bundle, listed and revocable under
  System Settings > Privacy & Security > Automation.
- **Nothing untrusted goes into the AppleScript** — §2's rule again, in the
  other place it matters. A playlist URI is checked against
  `^spotify:[a-z]{4,12}:[A-Za-z0-9]{16,40}$` in Swift *and* again in
  `spotify.sh`, and then passed to `osascript` as `argv` rather than spliced
  into the source. The charset check means no quote, backslash or space can
  reach the event even if the argv discipline were ever lost; the argv
  discipline means the charset check is not the only thing standing there.
  The command file is validated the same way on read, because it sits in a
  directory the user can write: "Swift already checked it" is not a property
  this script may assume.
- **The agent is short-lived and cannot start anything by itself.** It exits
  when the pomodoro file goes, when the panel closes, or after three hours,
  whichever is first. Every command except an explicit play is guarded by
  `pgrep` so an app that isn't running is never named — naming an app is
  enough to launch it. Playing is the exception, and it is the one command a
  person clicked.
- **Reminders access is broader than the feature.** EventKit has no
  write-only tier for reminders (calendar events have one; reminders do not),
  so a capture box that never reads anything still requires a grant that
  could read every reminder you have. There is no way to ask for less. What
  limits the blast radius is that the helper is a separate bundle doing one
  thing: it reads a fixed-name file, writes one `EKReminder`, and exits.
- **The note text never becomes an argument or a script.** It reaches the
  helper as file *content*, in a TSV the helper parses; the only thing on the
  helper's command line is a path whose basename must be `.tomato-reminder`,
  the same containment rule as the calendar helper's.
- Same persistence caveat as §1 for both: they are user-writable scripts and
  binaries run automatically during a cycle, and anything that can rewrite
  `~/.timetrack/bin/spotify.sh` inherits the Automation grant you handed out.
  The grants themselves are the mitigation you control.

## 4. Spotlight name-squatting — MEDIUM

Spotlight ranks by name match and your selection history. Any app on the
system can name itself `time stop` or `time TDT4136 AI`. If a malicious app
outranks yours, `Cmd+Space → time stop → Enter` runs attacker code with your
muscle memory doing the clicking, and the notification could even mimic the
real one.

- Bundle-id collisions (which could have caused *your own* apps to mislaunch)
  are fixed by the hash suffix.
- Cross-app squatting is inherent to Spotlight and can't be fixed from here.
- **Detection:** `mdfind "kMDItemDisplayName == 'time*'c"` and confirm every
  hit lives in `~/Applications/TimeTracker`.

## 5. `TIMETRACK_DIR` / `TIMETRACK_APPS_DIR` are trusted from the environment — LOW

Both are read straight from the environment and used for writes, including
`rm -rf "$DATA_DIR/.lock"`, `mv` onto `state`/`categories.tsv`, and `mktemp`.
A process that controls your environment could redirect those writes to
another user-writable location.

Controlling your environment already implies code execution as you, so this
is defence-in-depth rather than a real hole. Two practical notes:

- **Never point `TIMETRACK_DIR` at a world-writable directory** like `/tmp`
  on a shared machine — `mktemp` + `mv` there invites a symlink race.
- The variables exist so tests can't touch real data, which is worth keeping.

## 6. Data sensitivity — LOW, but worth knowing

`sessions.tsv` is a precise record of **when you are awake and working, and
on what**, in plaintext. That's a behavioural profile: sleep schedule, work
habits, which courses you're struggling with.

- Now `chmod 700` on the data dir, so other local accounts can't read it.
- It is **not** encrypted at rest beyond FileVault, and it will be swept into
  Time Machine and any cloud backup of your home directory.
- If you ever share the repo or a dashboard screenshot, that's what you're
  sharing.

## 7. Lock reaper has a narrow race — LOW

The stale-lock reaper deletes any lock older than 30s. Two processes could in
principle both judge the same lock stale and proceed together, reintroducing
the double-write. It requires a real 30s+ stall (a killed process mid-action)
plus near-simultaneous retries — vanishingly unlikely for hand-driven
Spotlight launches, and the failure mode is a duplicate row, not corruption.

A PID-in-lockfile check with liveness testing would close it if you ever
automate actions.

## 8. No fsync on append — LOW (reliability, not security)

`sessions.tsv` rows are appended with a single `>>` redirect, which is
atomic enough against interleaving but isn't flushed to disk. A hard power
loss could lose or tear the last row. Acceptable for time tracking; noting it
so it isn't a surprise.

---

## Things that are explicitly *not* problems

- **AppleScript injection via notifications.** `notify.sh` passes the message
  through `argv`, never interpolated into the script source, so a category
  named `" & do shell script "…` is inert. Verified with quote/apostrophe
  names.
- **TSV injection via category names.** Tabs and newlines are stripped before
  anything is written.
- **XSS in the dashboard.** All values are inserted with `textContent` via an
  escaping helper, never `innerHTML` with raw data, and CSP forbids remote
  loads.
- **Privilege escalation.** Nothing runs as root, nothing is setuid, install
  touches only your home directory, and no `sudo` is required at any point.
