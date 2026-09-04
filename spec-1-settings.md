# Spec 1 — Settings infrastructure + `time settings` app

**Read `README.md` and `SECURITY.md` first.** This spec adds a settings file,
a validated write path, a reader helper, and a `time settings` launcher app.
It is a prerequisite for Spec 2 (pomodoro mode) but must work standalone.

**Do not change the data model of `sessions.tsv`, `categories.tsv` or `state`.**

## The settings file

`~/.timetrack/settings.tsv` (honouring `TIMETRACK_DIR`, like every other data
file). Format: `key<TAB>value`, one per line, no header. Unknown keys are
preserved on rewrite; missing file means "all defaults" and is not an error.

| key | default | valid range | meaning |
|---|---|---|---|
| `pomodoro_minutes` | `25` | 1–180 | length of one pomodoro work session |
| `break_minutes` | `5` | 1–60 | short break length |
| `long_break_minutes` | `15` | 1–120 | long break length |
| `long_break_every` | `4` | 1–12 | every Nth completed pomodoro gets the long break |
| `snooze_minutes` | `5` | 1–60 | how long "snooze" postpones the tomato |
| `sound` | `on` | `on` / `off` | play a sound with pomodoro notifications |

## Reader: `spotlight/settings.sh`

A small sourceable helper installed to `~/.timetrack/bin/` alongside the
others (add it to the copy list in `install.sh`). Provides:

```bash
tt_setting <key>   # prints the value, or the default if missing/invalid
```

Rules:
- Missing file, missing key, or a value outside the valid range → print the
  default. Never fail, never print an error. Callers must be able to trust
  the output blindly.
- Parse with awk; do **not** `source` the file (user-editable content must
  never be executed).
- Defaults and ranges live in this one file only. `action.sh` may source it
  for validation so the table is never duplicated.

## Writer: new `action.sh` verb

```
action.sh setconf <key> <value>
```

- Runs under the existing lock like every other verb (it already will —
  the lock is taken unconditionally at the top).
- Rejects unknown keys and out-of-range values with a clear message and
  `action_rc=1`. `value` goes through `sanitize_field`.
- Rewrite is atomic: mktemp in `$DATA_DIR` + `mv -f`, same pattern as
  `add_category`. Other keys and unknown lines are preserved.
- This is the **only** code path that writes `settings.tsv`, keeping the
  "all writes go through action.sh" invariant from the README.

## UI: settings page on the dashboard

Extend `dashboard.py` with a **Settings** page (e.g. `/settings`, linked
from the main page):

- Number inputs for the four durations and the cycle length, a toggle for
  `sound`. Show the valid range next to each field. Current values come from
  the same defaults logic as `tt_setting` (missing → default shown).
- Saving POSTs to a new endpoint (e.g. `/api/setconf`) that shells out to
  `action.sh setconf` per changed key — exactly like the existing edit/delete
  endpoints. Reuse the same protections: POST-only, token in the custom
  header, JSON content type, `Origin` check. Surface `action.sh`'s message
  on rejection.
- Client-side validation is a convenience only; `action.sh` is the authority.

## Launcher app

In `sync-apps.sh`, add a fixed control app **`time settings`** (bundle-id
suffix `settings`) next to the existing ones. It starts the dashboard exactly
the way `time dashboard` does (reuse the same detached-`nohup` body — the
server already reuses an existing instance) but opens the browser at the
settings page. The cleanest mechanism: pass an argument or env var through to
`dashboard.py` telling it which path to open. The app must exit immediately
(LaunchServices relaunch rule — see README).

## Documentation

Add a short **Settings** section to `README.md`: the `time settings` command,
the file location and format, and the defaults table.

## Acceptance criteria

Verify in a sandbox (`TIMETRACK_DIR`/`TIMETRACK_APPS_DIR` set — see
"Verification" in README):

1. With no `settings.tsv`, `tt_setting pomodoro_minutes` prints `25`; every
   key prints its default.
2. `action.sh setconf pomodoro_minutes 30` creates/updates the file;
   `tt_setting` then prints `30`.
3. `setconf pomodoro_minutes 0`, `setconf pomodoro_minutes abc`, and
   `setconf nonsense_key 5` are all rejected with rc 1 and a message; the
   file is unchanged.
4. A hand-corrupted value in the file (e.g. `pomodoro_minutes<TAB>-3`) reads
   back as the default, without error.
5. `time settings` (the generated app) opens the browser on the settings
   page; changing a value and saving round-trips through `action.sh` and
   survives a page reload.
6. Concurrent `setconf` calls don't corrupt the file (the lock covers this;
   just confirm the verb runs under it).
7. `sync-apps.sh` re-run is idempotent; `uninstall.sh` removes the new app.

## Non-goals

Any pomodoro behaviour (timers, tomato UI, watcher) — that is Spec 2, which
consumes `tt_setting`.
