# Security review

Threat model first, because it decides what matters.

Almost everything below is bounded by one fact: **anything running as your
macOS user can already read and write `~/.timetrack` and `~/Applications`
directly.** "A malicious process running as you could tamper with this" is
therefore not, by itself, a vulnerability; that attacker does not need
TimeTracker. What matters is where TimeTracker (a) makes such tampering
unusually attractive or durable, (b) widens exposure beyond your own account,
or (c) turns data into code.

Ranked by real risk.

## 1. Generated app bundles are a persistence foothold. HIGH

`~/Applications/TimeTracker/*.app/Contents/MacOS/run` are unsigned, editable
shell scripts that you execute several times a day from the launcher without
looking at them. That is what malware wants: user-writable code, run by
routine user action, in a location that looks legitimate. One appended line
gives an attacker persistent execution under your account with no launchd
entry and no login item.

- Not fixable at this design's level: unsigned bundles are what lets you
  build them locally without a developer account.
- Mitigations: `sync-apps.sh` rewrites every bundle from source, so re-running
  it clears any tampering. Checking the scripts into git and diffing against
  the repo works too.
- Detection: `ls -la ~/Applications/TimeTracker/*/Contents/MacOS/run` and
  compare mtimes against your last install.

## 2. `categories.tsv` is data that becomes code. HIGH, mitigated

`sync-apps.sh` reads category names and writes them into generated shell
scripts and XML plists. Anything that can write `categories.tsv` therefore
influences scripts you later execute.

Currently safe: names go through `printf %q` for the shell and XML escaping
for the plist, and `action.sh` strips control characters, so a name cannot
break out of its quoting.

- The risk is future edits. Interpolating a category name into a generated
  script without `%q`, or into AppleScript source, is code execution on the
  next launch.
- Rule to keep: category names are untrusted text. Never interpolate one into
  a shell string or AppleScript source. Pass it as argv, as `notify.sh` does,
  or quote it with `%q`.

## 3. The dashboard HTTP server. MEDIUM, hardened

Opening a listening socket is the only genuinely new attack surface this tool
adds on this machine: it is the one socket anything here listens on. (Messages,
3f, talks to the internet, but only ever by connecting out.) Controls:

| Control | Blocks |
|---|---|
| Binds `127.0.0.1` only | Anyone on the same network |
| Random 24-byte token on every request | Blind local port scanning |
| `Host` header must be loopback | DNS rebinding from a website |
| Fixed routes, no path handling | Path traversal, directory listing |
| Mutations are POST-only and need the token in an `X-TimeTracker-Token` header, `Content-Type: application/json`, and a matching `Origin` | CSRF: a cross-origin page can send none of those without a preflight, and `OPTIONS` is never answered |
| The server never writes; mutations shell out to `action.sh` with an argv list | Bypassing the lock; shell interpretation of logged text |
| CSP `default-src 'none'`, `nosniff`, `no-referrer` | Token leaking via Referer; the page loading remote resources |
| Token file mode 600 | Other local accounts reading the token |
| Idle shutdown after ten minutes | An unattended server lingering |

Residual risks:

- The token is in the URL, so it lands in browser history. It is per-run and
  dies with the server.
- Any process running as you can read `~/.timetrack/.dashboard` and use the
  API. Same user, so not an escalation under the threat model.
- `/usr/bin/open` is called with the URL as an argv list, never a shell
  string, so a URL with shell metacharacters is inert.

The page can edit and delete logged sessions, change settings, retire
categories, add categories and playlists, and open the three permission
helpers. Every one of those:

- calls `action.sh` with fixed arguments, or opens a bundle whose name is
  built from a fixed list. `action.sh` re-validates every bound (epoch sanity,
  24h ceiling, known category, no overlap with the running segment), holds
  the same lock as every other write, and sanitizes text fields. The
  dashboard has no path to the log that `action.sh` does not gate.
- cannot start, stop or pause a timer. The two category routes refuse to touch
  the category that is running.
- rebuilds the launcher bundles after a category change by running
  `sync-apps.sh` with an empty argv, and only after `action.sh` accepted the
  change. A failure there is a message on the page, not a failed write.
- addresses a session by `(start_iso, duration_sec, category)`, and refuses
  anything that does not match exactly one row.
- moves deleted rows to `sessions.deleted.tsv` and deleted categories to
  `categories.deleted.tsv`. No route removes a logged hour.

`/api/grant` opens one of `<verb> spotify.app`, `<verb> reminders.app` or
`<verb> calendar.app`, chosen from a three-entry list; the request supplies
only which of the three. Each helper asks macOS for its permission and reports
back in a dialog, which is what typing the verb into the launcher does.

Rule to keep: if a future route needs to do more than call `action.sh` with
fixed arguments, stop and re-read this section.

## 3b. Calendar writing. MEDIUM, it deletes events

Making the window match the log means removing events in it that no longer
match a session. That is safe only because everything in the calendar was put
there by a previous write, and that claim is false the first time. So the
first write into any calendar refuses to delete anything, reports what it
found, and commits nothing. Only a write that succeeded records the calendar
as adopted (`.paint-adopted`); until then every request carries `STRICT 1`.

- It touches only the one calendar it was named, and only the window it was
  given, which never extends past now. Future events are never a deletion
  candidate.
- The helper only writes its own files. A handed path whose basename is not
  `.paint-request.tsv` is ignored.
- It needs full calendar access, because reconciling reads back what is in
  the window. The grant is listed and revocable under System Settings,
  Privacy & Security, Calendars.
- Nothing untrusted reaches a shell or a script. Session titles and notes
  travel to the helper as file content in a TSV. An event's title, when
  deciding whether it matches, is only ever compared.
- No launchd agent. Writing is triggered by a logged row changing, runs once
  and exits, one at a time via a `mkdir` lock with a two-minute staleness
  break.

## 3c. The prompt and overlay helper. LOW

`TimeTracker Prompt.app` (the start prompt with the checkbox, and the
full-screen tomato) follows the calendar helper's containment rules.

- It only writes its own result files. A handed path whose filename is not
  `.prompt-answer` or `.tomato-choice` is ignored and the standard location
  used instead.
- The overlay UI is a bundled local `tomato.html` in a WKWebView, with no
  network and no remote content. Two message channels are accepted from the
  page: `choice`, which takes four fixed words, and `menu`, whose vocabulary
  is listed in `handleMenu()`. Every branch touches one of a fixed set of
  files or does nothing. The page cannot name a file, and it cannot name a
  playlist: it is sent names, it answers with an index, and Swift resolves
  the index against the list it just read.
- The overlay's write list: `.tomato-choice`, `.tomato-alive` (its
  heartbeat), `.tomato-spotify-want`, `.tomato-spotify-cmd`,
  `.tomato-reminder`, and `.tomato-found` (the easter egg has been opened).
  All fixed names in the same validated directory. It launches nothing;
  `pomodoro-watch.sh` is the only thing that turns one of those files into a
  running process.
- The watcher never writes `state` or the log. It owns `~/.timetrack/pomodoro`,
  and `action.sh` re-validates its contents before flushing them into a row.

## 3d. Break-time media pausing. LOW, but it reaches outside

`pause-media.sh` (run through `TimeTracker Media.app` when the tomato lands)
sends Apple Events to other applications and, in browsers, runs one line of
JavaScript in the active tab of each window.

- What that buys an attacker is the script, not the events. Anything that can
  write `~/.timetrack/bin/pause-media.sh` inherits whatever Automation grants
  you have made. The grants are per app, prompted, listed under System
  Settings, Privacy & Security, Automation, and revocable there. Browsers
  additionally need "Allow JavaScript from Apple Events" on.
- Nothing untrusted goes into the AppleScript. The app names and the
  JavaScript are fixed constants. The JavaScript contains no double quote and
  no backslash, which keeps it inside AppleScript's string quoting.
- The JavaScript also posts two fixed pause messages to every iframe in the
  tab, so an embedded YouTube or Vimeo player on another origin can be paused.
  A frame that does not understand them ignores them. Nothing is read back.
- It cannot start anything. Every command is a pause, guarded by `pgrep` so an
  app that is not running is never named.
- Failures are swallowed on purpose, so a revoked grant shows up as media
  that keeps playing.

## 3e. The break menu. LOW, two more grants

`spotify.sh` (through `<verb> spotify.app`) and the Reminders helper (through
`TimeTracker Reminders.app`).

- Exactly one bundle may talk to Spotify. An Automation grant belongs to the
  app responsible for the process that sent the event; a second bundle would
  be a second grant to audit.
- Nothing untrusted goes into the AppleScript. A playlist URI is checked
  against `^spotify:[a-z]{4,12}:[A-Za-z0-9]{16,40}$` in Swift and again in
  `spotify.sh`, then passed to `osascript` as argv. The command file is
  validated on read as well, because it sits in a directory the user can
  write.
- The agent is short-lived. It exits when the pomodoro file goes, when the
  panel closes, or after three hours. Every command except an explicit play
  is guarded by `pgrep`. Playing may launch Spotify, and does so with
  `open -g -j` (background, hidden) before sending the event, so no window
  appears; it is the one command a person clicked.
- Reminders access is broader than the feature. EventKit has no write-only
  tier for reminders, so a capture box that never reads anything still needs
  a grant that could read every reminder you have. The helper is a separate
  bundle that reads a fixed-name file, writes one reminder, and exits.
- The note text never becomes an argument or a script. It reaches the helper
  as file content.

## 3f. Break chat. MEDIUM, the one thing that talks to the internet

`TimeTracker Chat.app` (`ttchat.swift`), started by the watcher when a break
begins, and gone when it ends. Off by default (`chat` in settings).

What leaves the machine, and to whom. Every message, and every "I am on a
break", is posted over HTTPS to one relay, ntfy.sh unless `chat-relay` names
another. Nothing listens: the helper only connects out, so there is no port
for anyone to reach and no firewall prompt.

| The relay sees | The relay never sees |
|---|---|
| Your IP address, and your friend's | Names, yours or theirs |
| When you are on a break, to the second | What you write |
| That two addresses share a topic, i.e. who your friends are | Anything from the log |
| Message sizes | The codes |

Controls:

| Control | Blocks |
|---|---|
| A 32-byte secret per friendship; topic and key derived from it by HKDF-SHA256 | A stranger finding a friendship: the topic is 192 random bits |
| Every message sealed with ChaChaPoly, the topic as associated data | The relay, or anyone who learns a topic, reading or forging anything |
| Authentication before parsing. The relay's own JSON envelope is the only thing read before it, and only two fields of it | Malformed input reaching any parser we wrote |
| Freshness (±120 s), a replay set, a version, a fixed set of kinds | Captured messages replayed, or old ones arriving late |
| `Cache: no` on every post | The relay storing anything; also why a message to a friend who is not on a break reaches nobody |
| `Firebase: no` on every post | ntfy.sh copying the ciphertext to Google for its Android app |
| 500 characters, one line, no control or bidi characters, 20 messages in 10 s | A friend's buggy or hostile client flooding or spoofing your break screen |
| `https://` only, plain `http://` only to loopback | The topic crossing a network in the clear |
| Ephemeral URLSession: no cache, no cookies | Anything about a conversation reaching disk |

Where the codes are. `friends.tsv`, mode 600, written only by the chat helper
and read by nothing else in TimeTracker. The overlay names friends by an
eight-digit id that is not a secret. When you make a code, the helper puts it
straight onto the clipboard, marked concealed so clipboard managers that
honour nspasteboard.org skip it; the page never holds it. The only code the
page ever holds is one you paste into it, on its way to the helper.

Where friend text goes. Into the helper's state file, which the overlay reads,
rebuilds field by field, and hands to the page, which sets it with
`textContent`. It never becomes an argument, a script, a file name or HTML.
Behind that, two things a mistake would have to get past as well. The page
has a Content-Security-Policy that lets it load and connect to nothing. And
the installed copy allows one script, its own, by a hash install.sh takes:
tried against the installed page, an injected `<img onerror>` does not run,
where under the source's `'unsafe-inline'` it did, and sent a message.

Residual risks:

- No forward secrecy. Both friends hold the same key for as long as the
  friendship lasts. Whoever records the relay's traffic (its operator can)
  and later obtains a code can read everything that code ever sealed. Keep
  codes in Signal and `friends.tsv` only; if one leaks, remove the friend on
  both sides and make a new code.
- The relay learns your break schedule and your friends' addresses. That is
  the price of a relay, and the owner decided it was acceptable. Self-hosting
  ntfy moves it to a relay you run, by changing `chat-relay`.
- ntfy.sh allows 250 posts a day per IP address. Behind a NAT shared with
  other ntfy users (a campus network can be), the allowance is shared too.
  Anyone who learns a topic can flood it; their posts fail authentication and
  are dropped, but they can crowd out delivery.
- "Only while both are on a break" is enforced on your own Mac. A modified
  client could listen all day; it would still only receive what you send
  during your own breaks.
- A friend can put rude text on your break screen. Remove them: the code
  stops working on your side at once.
- A clock more than two minutes wrong drops every message as stale.
- The bundle is user-writable code that makes network connections: section 1
  applies to it as to every bundle here.

Rule to keep: nothing but a sealed blob goes to the relay. No title, no tags,
no plaintext header. Friend text never reaches a shell, AppleScript, argv, a
path, or `innerHTML`.

## 4. Launcher name-squatting. MEDIUM

Any app on the system can name itself `time stop`. If it outranks yours in
the launcher, muscle memory runs attacker code, and its notification could
mimic the real one.

- Bundle-id collisions among your own apps are prevented by the hash suffix.
- Cross-app squatting is inherent to the launcher.
- Detection: `mdfind "kMDItemDisplayName == 'time*'c"` and confirm every hit
  lives in `~/Applications/TimeTracker`.

## 5. Environment variables are trusted. LOW

`TIMETRACK_DIR`, `TIMETRACK_APPS_DIR`, `TIMETRACK_BID_PREFIX` and
`TIMETRACK_VERB` are read from the environment and used for writes. A process
that controls your environment could redirect those writes. Controlling your
environment already implies code execution as you, so this is defence in
depth.

- Never point `TIMETRACK_DIR` at a world-writable directory on a shared
  machine; `mktemp` plus `mv` there invites a symlink race.
- The variables exist so a second install cannot touch the real one. Keep
  them.

## 6. Data sensitivity. LOW

`sessions.tsv` is a precise record of when you are awake and working and on
what, in plain text. The data directory is mode 700. It is not encrypted
beyond FileVault, and it goes into Time Machine and any cloud backup of your
home directory. A shared repository or a dashboard screenshot shares it.

`friends.tsv` is the one secret in the directory: each code in it is a
friendship (3f). The same backups carry it.

## 7. The lock reaper has a narrow race. LOW

The stale-lock reaper deletes any lock older than 30 seconds. Two processes
could both judge the same lock stale and proceed together. It needs a real
30-second stall plus near-simultaneous retries; the failure is a duplicate
row, not corruption.

## 8. No fsync on append. LOW

Rows are appended with a single redirect, which is atomic against
interleaving but not flushed to disk. A hard power loss could lose the last
row.

## Not problems

- AppleScript injection via notifications. `notify.sh` passes the message as
  argv, never into the script source.
- TSV injection via category names. Tabs and newlines are stripped before
  anything is written.
- XSS in the dashboard. All values are inserted through an escaping helper,
  never as raw HTML, and CSP forbids remote loads.
- Privilege escalation. Nothing runs as root, nothing is setuid, the installer
  touches only your home directory, and `sudo` is never required.
