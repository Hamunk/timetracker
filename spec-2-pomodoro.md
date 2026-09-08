# Spec 2. Pomodoro mode

**Read `README.md` first.** Builds on **Spec 1** (`spec-1-settings.md`):
all durations below come from `tt_setting` in `settings.sh`. If Spec 1 isn't
merged yet, hardcode its defaults behind the same function name and note it.

**Core invariants to preserve** (these are the project's soul):
- All writes to state/log go through `action.sh`. Pomodoro adds **no new
  timer verbs**; the course timer runs continuously through the whole
  cycle, breaks included.
- A dialog or overlay must never block, delay, or corrupt the underlying
  timer. Killing any pomodoro process at any moment leaves the log valid.
- The log stays a flat list of closed intervals: **one work block with N
  pomodoros is still one row.** Breaks are part of the logged time.

## Design decisions (settled; do not re-litigate)

- **Breaks count as category time.** The timer never pauses; a 4-pomodoro
  block is one `sessions.tsv` row.
- **`pause`/`resume` are removed entirely** (see "Removal" below). They are
  unused by any app and pomodoro does not need them.
- **A break ends only when the user explicitly ends it.** The configured
  break length is when the sound plays and the overlay flips to "break
  over", not when work silently resumes. This is what makes an overrun
  break (lid closed, went to fetch water, got caught up) both possible and
  measurable.
- **Nothing auto-cancels on sleep/overrun.** Only stopping or switching the
  course timer cancels a pomodoro cycle. The 8h guard is the backstop.
- Every `long_break_every`-th completed pomodoro (default 4) gets
  `long_break_minutes` instead of `break_minutes`. Skips count as
  completed.

## UX summary

Opting in at start runs a **silent** work session (default 25 min). When it
elapses, a huge unmissable tomato fills the screen:

1. **Accept break** (default; Enter; 60s no-input timeout): overlay switches
   to break mode; tomato + live countdown. At the scheduled end a sound
   plays (if `sound` is `on`) and the overlay flips to a prominent
   **"Back to work"** state; clicking it (or Enter) starts the next silent
   work session. Time past the scheduled end is accumulated as break
   overrun and logged (see data model).
2. **Snooze**: tomato goes away, returns after `snooze_minutes`.
   Repeatable. The pomodoro doesn't count as completed until its break is
   accepted or skipped.
3. **Nuclear skip**: the tomato **explodes** (see below) and the next
   silent work session starts immediately. Counts as completed.

## Removal of `pause`/`resume`

Delete the verbs and every trace of the PAUSED state:
- `action.sh`: `pause` and `resume` cases; PAUSED branches in state
  reading/recovery and in `stop`.
- `toggle.sh`: the PAUSED branch (toggle becomes RUNNING→stop, else→start).
- `dashboard.py`: any PAUSED rendering.
- `README.md`: the "verbs still exist in action.sh" paragraph and the
  PAUSED example under "Data model → state", plus every other mention.
- `sync-apps.sh` already retires old pause/resume apps; leave that list
  as is (it cleans up old installs).

The `state` file keeps its 4-field format; `PAUSED` simply never occurs and
is treated as corrupt if encountered.

## Data model changes

`sessions.tsv` gains two columns, appended after `recap`:

| column | meaning |
|---|---|
| `pomodoros` | empty = pomodoro mode was off for this session; integer (0, 1, 2, …) = mode was on, N pomodoros completed in this row |
| `break_overrun_sec` | empty = mode off; integer = total seconds breaks ran past their scheduled length in this row (0 = none) |

- Extend `SESS_HEADER` in `action.sh`. Existing files keep working: readers
  already tolerate rows shorter than the header (established convention , 
  see README on `plan`/`recap`). At install, if the existing file's header
  line matches the old header exactly, rewrite that one line to the new
  header.
- **`close_segment` fills the columns**: at close (stop, switch, or
  autoclose), `action.sh` reads the `pomodoro` file; if its `key` and
  `seg_start` match the segment being closed, write `completed_count` and
  `overrun_sec` into the row and delete the `pomodoro` file. No match →
  both columns empty. This keeps action.sh the single writer; the watcher
  never touches `sessions.tsv`.
- `editsession` must **carry the two columns through unchanged** (the
  dashboard edit form doesn't expose them).

## Opting in: Swift prompt window with a real checkbox

Replace the AppleScript plan prompt in `start.sh` with a native window from
the Swift helper (below), **prompt mode**: question, subtitle, text field,
and a checkbox labeled **"Pomodoro mode"** directly under the text field.
Buttons Skip / Save; Enter = Save, Esc = Skip; 120s timeout = Skip. It must
preserve every property of `prompt.sh` documented in the README: always
exits, empty answer on skip/cancel/timeout, never blocks the timer (the
timer has already started when the prompt shows).

- Result reaches `start.sh` via an atomically-written file in `$DATA_DIR`
  (e.g. `.prompt-answer`: `POMODORO<TAB><text>` or `<TAB><text>`), since
  stdout of an `open`ed app isn't capturable. `start.sh` launches it with
  `open -W`.
- The recap prompt ("what did you work on?") in `start.sh`/`toggle.sh` may
  either keep using `prompt.sh` or use prompt mode without the checkbox , 
  builder's choice; visual consistency is nice but not required.
- `newcat.sh` keeps its existing prompts.
- Fallback: if the compiled helper is missing (no `swiftc` at install),
  `start.sh` falls back to `prompt.sh` with a third button
  `{Skip, Save, Save 🍅}` so pomodoro remains reachable.
  **Built, then removed; see the note at the end of this spec.**
- Calendar auto-starts never prompt and are therefore never pomodoro , 
  correct, leave as is.

The first work session is measured from the timer's start (`pressed_at`),
not from when the prompt is answered.

## State: `~/.timetrack/pomodoro`

Single line, tab-separated:

```
phase	key	seg_start	target_epoch	completed_count	overrun_sec	watcher_pid
WORK	BØK2100	1787225000	1787226500	2	140	48123
```

`phase` ∈ `WORK` | `BREAK`. `seg_start` ties the cycle to one specific
timer segment; it's how `action.sh` matches at close. `target_epoch` is
the current phase's scheduled end. `overrun_sec` accumulates across all
breaks in the cycle. Created when armed, deleted by `action.sh` at segment
close or by the watcher on cancel. Written atomically (mktemp + mv). A line
that doesn't parse → delete it and exit, like corrupt `state` handling.

## The watcher: `spotlight/pomodoro-watch.sh`

Detached with `nohup` from `start.sh` when armed (same pattern as the
dashboard server). On arming, kill any live previous `watcher_pid` and
replace the file. Loop: sleep ~10s, then read `state` + `pomodoro` and
reconcile:

| phase | `state` says | action |
|---|---|---|
| any | RUNNING, same key, same seg_start | continue below |
| any | anything else (stopped, switched, new seg_start) | **cancel**: delete `pomodoro` (unless action.sh already consumed it), exit silently |
| WORK | `now >= target_epoch` | fire the tomato; even if long overdue (lid was closed mid-work: the tomato simply appears at wake) |
| BREAK | `now >= target_epoch` | break-over nudge: play sound once, flip overlay to "Back to work" state; keep waiting for the user |

Short sleeps + wall-clock comparison, **never** one long `sleep`; macOS
suspends sleeping processes across system sleep, wall-clock math survives
it. **There is no overdue-cancellation and no timeout on an overrunning
break**: sleep and long breaks are normal life; the 8h guard is the only
backstop.

Transitions on overlay choice:
- **accept** → phase=BREAK, target = now + (long break if the *next*
  completed count hits the `long_break_every` cycle, else short break).
- **snooze** → target += `snooze_minutes` × 60, stay WORK.
- **skip** → `completed_count`+1; phase=WORK, target = now +
  `pomodoro_minutes` × 60.
- **back-to-work** (ends a break) → `completed_count`+1;
  `overrun_sec` += max(0, now − scheduled_break_end); phase=WORK,
  target = now + `pomodoro_minutes` × 60. (Ending a break *early* is
  allowed and simply has 0 overrun.)

If the overlay process dies without writing a choice (crash, force-quit),
the watcher relaunches it on the next tick.

## The Swift helper: `TimeTracker Prompt.app` (one app, three modes)

A second compiled Swift helper, following the calendar helper's precedent
(`ttcal.swift`: compiled by the install script, ad-hoc signed so
permissions/quirks survive rebuilds). Mode is chosen by argument. It always
exits after writing its result file. LaunchServices refuses to relaunch a
running app.

- **prompt mode**; the start prompt with checkbox, described above. A
  normal small centred window, activated to front.
- **tomato mode**; borderless full-screen `NSPanel` on the main screen at
  `.screenSaver` window level, activated to front: genuinely unmissable.
  Content is a `WKWebView` loading a **bundled local `tomato.html`** (no
  network): huge tomato, three buttons (Accept break / Snooze / Skip
  break). Buttons post to Swift via `WKScriptMessageHandler`; the choice is
  written to `$DATA_DIR/.tomato-choice` atomically. Enter = accept,
  Esc = snooze, 60s no input = accept.
- **break mode**; same full-screen panel: tomato + live countdown +
  a "Back to work early" button. At scheduled end (passed as an argument)
  it flips to the break-over state: prominent **"Back to work"** button,
  overrun counting up. Enter or click writes `back-to-work` and exits.
  **No timeout; it waits.** If the user closes/quits it, the watcher
  relaunches it next tick, so it also survives sleep, login, or a crash.
- **Explosion (skip)** must land; tomato swells briefly (anticipation),
  bursts into ~20–40 physics-ish particles (chunks, seeds, juice splatter)
  with gravity and fade, ~0.8–1.2s, then the window closes itself. CSS
  transforms + a spot of JS in `tomato.html`; no libraries.
- Sound via `afplay` of a system sound (e.g.
  `/System/Library/Sounds/Glass.aiff`), gated on `tt_setting sound`; play
  from the watcher, not the helper, so the sound logic lives in one place.
- Pass `TIMETRACK_DIR` through like the generated bundles do. The helper
  writes nothing except its two result files in `$DATA_DIR` (mirror the
  calendar helper's path-refusal caution).

## Dashboard

Pomodoro is **in scope** for the dashboard:

- **Status card**: while a cycle is live (the `pomodoro` file exists and
  matches the running timer), show phase (work / break), a client-side
  ticking countdown to `target_epoch`, completed count as tomato dots
  (e.g. 🍅🍅○○ against `long_break_every`), and accumulated break overrun.
  Include the `pomodoro` file's contents in the existing poll JSON.
- **Recent sessions**: show `pomodoros` (e.g. `🍅×3`) and break overrun on
  rows that have them.
- Edit form: does not expose the new columns; `editsession` preserves them
  (see data model).

## Install / uninstall / docs

- `install.sh`: copy the new scripts + `tomato.html`; compile the helper
  (skip gracefully with a message if `swiftc` is missing; the prompt then
  falls back to the 3-button AppleScript and the tomato degrades to
  notifications, **since removed**); perform the one-line sessions header
  upgrade.
- `uninstall.sh`: remove them; kill a live watcher.
- No new launcher app; pomodoro is reached from the start prompt.
- `README.md`: document the checkbox, the cycle, the two new columns, the
  break-ends-when-you-end-it rule, and remove all pause/resume material.

## Edge cases

- **Lid closed during a break**: watcher and overlay both freeze and thaw
  with the machine; wall-clock math means on wake the overlay is either
  still counting down or already in break-over state. Overrun (sleep
  included) is logged. The cycle survives.
- **Lid closed during work**: on wake, if the target passed, the tomato
  appears immediately; the user accepts, snoozes, or skips as usual.
- Watcher killed / reboot mid-cycle: stale `pomodoro` file with dead pid.
  `action.sh` still flushes its counts if the same segment closes normally;
  arming a new cycle replaces it. Nothing crashes.
- Autoclose (8h guard) during a cycle: `close_segment` flushes the counts
  like any close; watcher cancels on next tick.
- Row edited in the dashboard mid-cycle: unrelated rows; no interaction.
  The live segment can't be edited (existing rule).

## Acceptance criteria

Test in a sandbox with `setconf pomodoro_minutes 1`, `break_minutes 1`,
`snooze_minutes 1`, `long_break_every 2`:

1. Starting a course shows the Swift prompt with a working checkbox under
   the text field; Esc/timeout/Skip start the timer with pomodoro off and
   an empty plan; timings per the README's "a dialog can never block a
   timer" rules.
2. With the checkbox on: after 1 min the tomato fills the screen. Enter
   accepts; break countdown shows; at 1 min the sound plays and the overlay
   flips to "Back to work"; waiting ~30s before clicking logs ~30s of
   overrun. The timer ran the whole time.
3. Stop after two full pomodoros → **exactly one row**, duration spanning
   the whole block including breaks, `pomodoros`=2, `break_overrun_sec`
   as measured.
4. Snooze → tomato returns ~1 min later; that pomodoro is not yet counted.
5. Skip → explosion plays; next tomato ~1 min later; count incremented.
6. With `long_break_every 2`, the 2nd completed pomodoro's break uses the
   long length.
7. Stopping or switching mid-cycle cancels it; the closing row still gets
   the counts accrued so far; no tomato appears afterwards.
8. `kill -9` the watcher, or force-quit the overlay, at any point: log and
   state stay valid; overlay relaunches (watcher alive) or cycle dies
   quietly (watcher dead).
9. Close the laptop lid during a break, reopen after the break's end: the
   overlay shows break-over, clicking resumes the cycle, overrun includes
   the lid-closed time.
10. Starting with the checkbox off behaves exactly as today, and the new
    columns are empty on such rows.
11. `pause`/`resume` are gone: `action.sh pause` says unknown action;
    `toggle.sh` has no PAUSED branch; README no longer mentions them; a
    hand-written PAUSED state line is discarded as corrupt.
12. Dashboard shows the live status card (phase, countdown, 🍅 dots,
    overrun) within its normal ~2s poll, and `🍅×N` on logged rows.
13. Editing a pomodoro row in the dashboard preserves its two pomodoro
    columns.
14. `sound off` silences the break-over sound.

## Non-goals (possible follow-ups, do not build now)

Menu-bar countdown; per-course pomodoro defaults; a sticky "default
checkbox state" setting; pomodoro statistics/aggregates beyond the columns.

---

## Amendment: the no-`swiftc` fallbacks were removed

Both were built as specified above and both are gone. They were not a smaller
version of pomodoro mode; they were a different feature wearing its name , 
the tomato never appeared, breaks advanced on their own, and overrun was
never measured; reachable only on machines where nobody would ever exercise
them. (One such path had been spinning a shell loop at 100% CPU for the
length of every break, unnoticed, which is the argument in miniature.)

What replaced them: the checkbox is not offered without the helper, and a
cycle that finds itself running without one plays its sound, says
"Pomodoro needs the Xcode tools", drops `~/.timetrack/pomodoro` and exits.
That last part is not hypothetical. XProtect once deleted the helper binary
seconds after launch (see the header of `ttprompt.swift`).

Unchanged by any of this: the tracker, the log, the plan and recap prompts,
and the dashboard all work identically with or without `swiftc`.
