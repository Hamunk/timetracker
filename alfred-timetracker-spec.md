# Build spec: "TimeTracker" Alfred workflow

Paste this whole file into Claude Code (or drop it in the repo and say `read alfred-timetracker-spec.md and build it`).

---

Build me a macOS Alfred workflow called **TimeTracker** for logging time spent per university course. Data collection only — no charts, no UI beyond Alfred. I will visualize the data later myself.

## Hard requirement: latency

Invoking the workflow must feel instantaneous (target: under ~20ms for the Script Filter script to produce output). This constrains implementation:

- The Script Filter script is **bash**. Do **not** use Python, Node, Ruby, `jq`, or any other interpreter or external dependency in the Script Filter path. Interpreter startup dominates and is disqualifying.
- Set **"Alfred filters results"** to true on the Script Filter so my script runs **once per invocation**, not once per keystroke. Alfred does the fuzzy matching against `match`/`title` in-process.
- Minimize forks. Target: the entire Script Filter is one `awk` invocation plus at most two `date` calls. Ideally read state, categories, and the log in a single `awk` program that emits the JSON directly.
- Do not use Alfred's Script Filter result caching — state changes between invocations.
- Set Script Filter Run Behaviour to "Terminate previous script" / run immediately.

## Data model

All data lives in `~/.timetrack/`. Create the directory and files on first run if missing.

### `sessions.tsv` — the log (append-only, never rewritten)

Tab-separated, with a header row:

```
start_iso	end_iso	duration_sec	category	note
2026-08-20T09:14:03+0200	2026-08-20T10:41:55+0200	5272	TDT4136 AI	
```

- One row per **closed segment**. A row is only ever appended, never edited.
- `start_iso` / `end_iso`: `%Y-%m-%dT%H:%M:%S%z` local time. Human-readable and unambiguous.
- `duration_sec`: integer, precomputed so analysis never has to parse dates.
- `category`: free text, no tabs (strip/reject tabs on category creation).
- `note`: usually empty. Set to `AUTOCLOSED` for the guard case below.
- Total time on a course = sum of its `duration_sec`. Pausing and resuming just produces two rows. This is the whole point of the design: **the log is a flat list of closed intervals with no state to interpret.**

### `state` — current timer (single line, or empty file)

```
RUNNING	TDT4136 AI	1755678843
PAUSED	TDT4136 AI	0
```

Fields: `status`, `category`, `segment_start_epoch`. Empty file = idle, nothing paused.

### `categories.tsv`

```
TDT4136 AI	1755678843
TMA4145 Linear Methods	1755600000
```

Fields: `name`, `last_used_epoch`. Used to sort the menu by recency. Rewritten in full on each update (the file is tiny).

## Interface

### Keyword `time` — Script Filter, argument optional

**When idle and nothing is paused**, list every category, sorted by `last_used_epoch` descending:

- title: `TDT4136 AI`
- subtitle: `Start timer · 1h 47m today` (omit the "today" clause if zero)
- arg: `start:TDT4136 AI`
- `uid`: the category name, so Alfred's own selection learning also kicks in
- `match`: the category name

**When idle but a category is paused**, prepend one item:

- title: `▶ Resume — TDT4136 AI`, subtitle `2h 03m logged today`, arg `resume`, and put it first.

**When a timer is RUNNING**, prepend two items, then list the categories below with `Switch to …` as the subtitle and arg `switch:<name>`:

1. `⏹ Stop — TDT4136 AI` / subtitle `Running 23m · 2h 10m today` / arg `stop`
2. `⏸ Pause — TDT4136 AI` / subtitle `Running 23m` / arg `pause`

"Today" totals come from one `awk` pass over `sessions.tsv`, comparing `start_iso` against today's date string (compare the leading 10 characters — no date math needed). Include the currently running segment in the running category's total.

If `categories.tsv` is empty, emit a single item explaining `time+ <name>` creates one, with `valid: false`.

Duration formatting: `45s`, `12m`, `1h 47m`. No seconds once past a minute.

The Script Filter must JSON-escape titles/subtitles (backslash, double quote, control chars) — course names may contain punctuation.

### Keyword `time+` — Keyword input, argument required

`time+ TMA4145 Linear Methods` → creates the category and **immediately starts a timer on it**. If a timer is already running, it closes that segment first. Reject names containing a tab; trim surrounding whitespace; if the name already exists, just start it rather than duplicating.

### Keyword `timestat` — optional convenience

Prints today's per-category totals plus the week's totals to Alfred's Large Type. This one may be Python since it is not in the hot path.

## Action script

The Script Filter connects to a single **Run Script** action (bash) that receives `{query}` and dispatches on the prefix: `start:`, `switch:`, `stop`, `pause`, `resume`. Writes are confined to this script; the Script Filter is strictly read-only. That separation matters — the read path stays fast and can never corrupt state.

Behaviour:

- `start:<cat>` — if RUNNING, close the current segment first. Write `RUNNING <cat> <now>` to state. Bump `last_used_epoch`.
- `switch:<cat>` — identical to `start:`.
- `stop` — append the closed row, clear `state` to empty.
- `pause` — append the closed row, write `PAUSED <cat> 0` to state.
- `resume` — write `RUNNING <cat> <now>` to state.

Every branch outputs a short line for Alfred's **Post Notification** output object: `Started TDT4136 AI`, `Stopped TDT4136 AI — 1h 12m`, `Paused TDT4136 AI — 23m`, `Resumed TDT4136 AI`.

Appends to `sessions.tsv` must be atomic-ish: single `>>` redirect of one fully-formed line. State writes go to a temp file then `mv` into place.

## Forgot-to-stop guard

I will forget to stop the timer and go to bed. On any action, if the running segment exceeds **8 hours**, close it at `start + 8h`, set `note` to `AUTOCLOSED`, and say so in the notification. Never silently discard time and never silently log a 14-hour study session — I need to be able to find and fix those rows later.

## Packaging

Do not hand-write `info.plist` as raw XML. Write a `build.py` that constructs it with Python's `plistlib` and zips the bundle into `TimeTracker.alfredworkflow`, which I can double-click to install. The bundle contains the Script Filter, the Keyword input, the Run Script actions, and the Post Notification objects, wired together.

Also write `README.md` with:
- install instructions,
- the exact click-by-click Alfred setup as a fallback if the generated bundle fails to import,
- the `sessions.tsv` schema,
- a three-line pandas snippet for loading the log later.

## Verification before you hand it back

1. Time the Script Filter: `time ./scriptfilter.sh` with 20 categories and a 2000-row log. Report the number. If it exceeds ~25ms, reduce forks and tell me what you changed.
2. Pipe its output through `python3 -m json.tool` in all four states (no categories / idle / running / paused) to prove the JSON is valid.
3. Exercise a full cycle via the action script — start, pause, resume, switch, stop — and print the resulting `sessions.tsv` so I can eyeball the rows.
4. Confirm a category name containing a double quote and one containing an apostrophe both round-trip correctly.

Ask me before deviating from the data schema. Everything else is yours to decide.
