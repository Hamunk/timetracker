#!/usr/bin/env python3
"""TimeTracker live dashboard.

Serves a small web page on 127.0.0.1 that polls the TSV files and re-renders,
so totals stay correct while a timer is still running (the in-flight segment
isn't in sessions.tsv yet, so it's added on the fly).

The page can also fix a closed session (edit its times/category/notes) or
delete it — because forgetting to stop the timer is the one mistake this tool
can't prevent. The settings page additionally retires a category, by hiding it
or deleting it. Those mutations (plus settings writes) are the *only* ones,
they are POST-only, and they don't write anything themselves: they shell out
to action.sh, which stays the single writer and holds the lock. Nothing here
can start or stop a timer.

Hardening, since this listens on a socket:
  * binds 127.0.0.1 only, on an ephemeral port
  * requires a random per-run token on every request
  * validates the Host header (blocks DNS-rebinding from a web page)
  * mutations are POST-only and additionally require the token in a custom
    header, a JSON content type, and a matching Origin — a cross-origin page
    can send none of those without a preflight, and no preflight is answered
  * no directory serving, no user input reaching the filesystem
  * exits on its own after a period with no polls, so nothing lingers
"""
import datetime
import http.server
import json
import os
import secrets
import socketserver
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request

DATA_DIR = os.environ.get("TIMETRACK_DIR") or os.path.expanduser("~/.timetrack")
SESS_FILE = os.path.join(DATA_DIR, "sessions.tsv")
STATE_FILE = os.path.join(DATA_DIR, "state")
CAT_FILE = os.path.join(DATA_DIR, "categories.tsv")
HANDOFF_FILE = os.path.join(DATA_DIR, ".dashboard")
POMO_FILE = os.path.join(DATA_DIR, "pomodoro")
# The break menu's two lists. Read here, written only by action.sh.
PLAYLIST_FILE = os.path.join(DATA_DIR, "spotify-playlists.tsv")
REMLIST_FILE = os.path.join(DATA_DIR, "reminders-list")
# Which calendar the log gets painted onto, and the list of ones it could be.
# The list is a dump the helper refreshes; this server never asks EventKit
# anything itself, because it has no calendar permission and should not.
PAINTCAL_FILE = os.path.join(DATA_DIR, "paint-calendar")
PAINTLIST_FILE = os.path.join(DATA_DIR, ".paint-calendars.tsv")
PAINT_SH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "paint-calendar.sh")
# Two markers, both written by something other than this server. The overlay
# helper touches the first the moment the easter egg is opened, and the
# settings page shows the game's own section only once it exists: a settings
# page is not the place to learn there is a game. action.sh writes the second
# when the first-run setup finishes, and until it does the dashboard opens
# on the setup page.
TOMATO_FOUND_FILE = os.path.join(DATA_DIR, ".tomato-found")
SETUP_DONE_FILE = os.path.join(DATA_DIR, ".setup-done")
# Where the app bundles are. Only ever used to open the three permission
# helpers by their fixed names; nothing from a request reaches this path.
APPS_DIR = (os.environ.get("TIMETRACK_APPS_DIR")
            or os.path.expanduser("~/Applications/TimeTracker"))
VERB = os.environ.get("TIMETRACK_VERB") or "time"
# All writes go through action.sh, which lives next to this file.
ACTION_SH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "action.sh")
# Retiring a category also has to rebuild the launcher bundles, the same way
# newcat.sh does after adding one. It takes no arguments, ever.
SYNC_APPS = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "sync-apps.sh")
# The settings defaults/ranges table lives in settings.sh and nowhere else;
# this server reads it by sourcing the helper, never by duplicating the table.
SETTINGS_SH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "settings.sh")

MAX_BODY = 8192  # a mutation request is a few hundred bytes; cap it well below

IDLE_TIMEOUT = 600  # seconds without a request before the server exits
POLL_MS = 2000

_last_request = time.time()


# --------------------------------------------------------------------------
# data
# --------------------------------------------------------------------------

def fmtdur(s):
    s = int(s)
    sign = "-" if s < 0 else ""
    s = abs(s)
    if s < 60:
        return f"{sign}{s}s"
    m, h = s // 60, s // 3600
    m %= 60
    if h:
        return f"{sign}{h}h {m:02d}m"
    return f"{sign}{m}m"


def read_categories():
    """key -> (name, keywords, hidden). Display only; the log stores keys.

    A row written before the hidden column existed has four fields, which
    means not hidden — the same reading every other script here uses.
    """
    cats = {}
    try:
        with open(CAT_FILE, encoding="utf-8") as f:
            for i, line in enumerate(f):
                p = line.rstrip("\n").split("\t")
                if i == 0 and p and p[0] == "key":
                    continue
                if len(p) >= 4 and p[0]:
                    cats[p[0]] = (p[1], p[2], len(p) > 4 and p[4] == "1")
    except OSError:
        pass
    return cats


def read_playlists():
    """The break menu's Spotify rows, in file order.

    A row is {uri, name, work}. Anything that isn't a spotify: URI and a name
    is dropped, which disposes of the header line without counting lines —
    the same reading the overlay does.
    """
    out = []
    try:
        with open(PLAYLIST_FILE, encoding="utf-8") as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) < 2 or not p[0].startswith("spotify:") or not p[1]:
                    continue
                out.append({"uri": p[0], "name": p[1],
                            "work": len(p) > 2 and p[2] == "work"})
    except OSError:
        pass
    return out


def read_reminders_list():
    """Which Reminders list a break note goes to. The default is the helper's."""
    try:
        with open(REMLIST_FILE, encoding="utf-8") as f:
            name = f.readline().strip()
        if name:
            return name
    except OSError:
        pass
    return "Pause Notes"


def read_paint_calendar():
    """The chosen calendar's title, or "" when none has been picked."""
    try:
        with open(PAINTCAL_FILE, encoding="utf-8") as f:
            return f.readline().strip()
    except OSError:
        return ""


def read_paint_choices():
    """Calendars the helper last reported as writable: [{title, source}].

    Empty until "time calendar" has run once — this server cannot ask
    EventKit, and should not: the permission belongs to the helper bundle.
    """
    out = []
    try:
        with open(PAINTLIST_FILE, encoding="utf-8") as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) >= 2 and p[0] == "CAL" and p[1]:
                    out.append({"title": p[1],
                                "source": p[2] if len(p) > 2 else ""})
    except OSError:
        pass
    return out


def label_for(key, cats):
    name = cats.get(key, ("", "", False))[0]
    return f"{key}: {name}" if name else key


def read_state():
    try:
        with open(STATE_FILE, encoding="utf-8") as f:
            line = f.readline().rstrip("\n")
    except OSError:
        return None
    if not line:
        return None
    parts = line.split("\t")
    if len(parts) < 3:
        return None
    status, category, start = parts[0], parts[1], parts[2]
    plan = parts[3] if len(parts) > 3 else ""
    # RUNNING is the only live status; anything else is corrupt, not a timer.
    if status != "RUNNING" or not category:
        return None
    try:
        start = int(start)
    except ValueError:
        return None
    return {"status": status, "category": category, "start": start,
            "plan": plan}


def parse_iso(value):
    """Epoch for a logged timestamp, or None if it doesn't parse.

    Only used to make a row editable; a row that fails here still displays.
    """
    try:
        return int(datetime.datetime.strptime(
            value, "%Y-%m-%dT%H:%M:%S%z").timestamp())
    except (ValueError, TypeError):
        return None


def read_sessions():
    rows = []
    try:
        with open(SESS_FILE, encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f):
                if i == 0:
                    continue
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 4:
                    continue
                try:
                    dur = int(parts[2])
                except ValueError:
                    continue
                rows.append({
                    "start": parts[0],
                    "end": parts[1],
                    "dur": dur,
                    "category": parts[3],
                    "note": parts[4] if len(parts) > 4 else "",
                    # Rows logged before notes existed simply have fewer fields.
                    "plan": parts[5] if len(parts) > 5 else "",
                    "recap": parts[6] if len(parts) > 6 else "",
                    # Empty = pomodoro mode was off for this row.
                    "pomodoros": parts[7] if len(parts) > 7 else "",
                    "overrun": parts[8] if len(parts) > 8 else "",
                    "start_ep": parse_iso(parts[0]),
                    "end_ep": parse_iso(parts[1]),
                })
    except OSError:
        pass
    return rows


def read_pomodoro(state):
    """The live pomodoro cycle, or None.

    Only reported while it matches the running timer's key and segment —
    a stale file from a killed watcher is not a live cycle.
    """
    if not state or state["status"] != "RUNNING":
        return None
    try:
        with open(POMO_FILE, encoding="utf-8") as f:
            parts = f.readline().rstrip("\n").split("\t")
    except OSError:
        return None
    if len(parts) < 7 or parts[0] not in ("WORK", "BREAK"):
        return None
    try:
        seg, target = int(parts[2]), int(parts[3])
        completed, overrun = int(parts[4]), int(parts[5])
    except ValueError:
        return None
    if parts[1] != state["category"] or seg != state["start"]:
        return None
    return {"phase": parts[0], "target": target,
            "completed": completed, "overrun": overrun,
            "cycle": setting_int("long_break_every", 4)}


def setting_int(key, default):
    """One numeric setting via settings.sh (the table's single home)."""
    for s in read_settings():
        if s["key"] == key:
            try:
                return int(s["value"])
            except ValueError:
                return default
    return default


def build_payload():
    now = int(time.time())
    today = datetime.date.today()
    week_start = today - datetime.timedelta(days=today.weekday())

    rows = read_sessions()
    state = read_state()
    cats = read_categories()

    today_t, week_t, all_t = {}, {}, {}
    for r in rows:
        cat, dur = r["category"], r["dur"]
        all_t[cat] = all_t.get(cat, 0) + dur
        day_str = r["start"][:10]
        try:
            day = datetime.date.fromisoformat(day_str)
        except ValueError:
            continue
        if day == today:
            today_t[cat] = today_t.get(cat, 0) + dur
        if day >= week_start:
            week_t[cat] = week_t.get(cat, 0) + dur

    # Fold the still-open segment into the totals so the page matches reality.
    running = None
    if state and state["status"] == "RUNNING":
        elapsed = max(0, now - state["start"])
        cat = state["category"]
        today_t[cat] = today_t.get(cat, 0) + elapsed
        week_t[cat] = week_t.get(cat, 0) + elapsed
        all_t[cat] = all_t.get(cat, 0) + elapsed
        running = {"category": cat, "elapsed": elapsed,
                   "plan": state.get("plan", "")}

    keys = sorted(set(all_t) | set(today_t), key=lambda c: -all_t.get(c, 0))
    table = [{
        "category": label_for(k, cats),
        "key": k,
        "today": today_t.get(k, 0),
        "week": week_t.get(k, 0),
        "all": all_t.get(k, 0),
        "running": bool(running and running["category"] == k),
    } for k in keys]

    def decorate(r):
        d = dict(r)
        d["key"] = r["category"]          # identity; the log stores keys
        d["category"] = label_for(r["category"], cats)
        return d

    # EDITED is a provenance mark, not a problem — a row you already fixed by
    # hand shouldn't keep nagging from "needs attention".
    flagged = [decorate(r) for r in rows
               if r["note"] and r["note"] != "EDITED"][-25:]
    # Sorted by start rather than by file order, so a row whose start time was
    # corrected lands where it belongs instead of at the end of the log.
    by_start = sorted(rows, key=lambda r: (r["start_ep"] is None, r["start_ep"] or 0))
    recent = [decorate(r) for r in by_start[-25:]][::-1]

    known = sorted(set(cats) | {r["category"] for r in rows})
    categories = [{"key": k, "label": label_for(k, cats)} for k in known]

    return {
        "status": state["status"] if state else "IDLE",
        "category": label_for(state["category"], cats) if state else None,
        "running": running,
        "pomodoro": read_pomodoro(state),
        "table": table,
        "totals": {
            "today": sum(today_t.values()),
            "week": sum(week_t.values()),
            "all": sum(all_t.values()),
        },
        "recent": recent,
        "flagged": flagged,
        "categories": categories,
        "editable": os.access(ACTION_SH, os.X_OK),
        "generated": datetime.datetime.now().strftime("%H:%M:%S"),
    }


def build_categories():
    """The settings page's category list — every key, and what it holds.

    The counts come from the log rather than from categories.tsv, because the
    only question worth answering before retiring a category is how many hours
    are already filed under it. Keys that exist *only* in the log are listed
    too, unactionable: that is where a deleted category's history goes, and
    this is the one page that admits it.
    """
    cats = read_categories()
    state = read_state()
    running = state["category"] if state else None

    counts, totals = {}, {}
    for r in read_sessions():
        k = r["category"]
        counts[k] = counts.get(k, 0) + 1
        totals[k] = totals.get(k, 0) + r["dur"]

    out = []
    for key in set(cats) | set(counts):
        orphan = key not in cats
        hidden = bool(cats.get(key, ("", "", False))[2])
        out.append({
            "key": key,
            "label": label_for(key, cats),
            "hidden": hidden,
            "orphan": orphan,
            "sessions": counts.get(key, 0),
            "total": totals.get(key, 0),
            "running": key == running,
        })
    # Live first, then the ones you can still act on, then the leftovers.
    out.sort(key=lambda c: (not c["running"], c["orphan"], c["hidden"],
                            c["key"]))
    return out


def read_settings():
    """Current settings via settings.sh — the same logic tt_setting uses.

    Returns a list of {key, value, default, min, max}; min/max are None for
    the on/off setting. An empty list means the helper is missing or broken,
    which the page reports instead of guessing at defaults here.
    """
    script = (
        '. "$1" || exit 1\n'
        'for k in $(tt_setting_keys); do\n'
        '  tt_setting_spec "$k"\n'
        '  printf "%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n" \\\n'
        '    "$k" "$(tt_setting "$k")" "$TT_DEF" "$TT_MIN" "$TT_MAX" "$TT_FRAC" "$TT_KEY"\n'
        'done\n'
    )
    try:
        # The helper's path is passed as an argument, never interpolated.
        proc = subprocess.run(["/bin/bash", "-c", script, "bash", SETTINGS_SH],
                              capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return []
    if proc.returncode != 0:
        return []
    def num(x):
        """A bound as a number — some are fractional, so not just isdigit()."""
        try:
            v = float(x)
        except ValueError:
            return None
        return int(v) if v == int(v) else v

    out = []
    for line in proc.stdout.splitlines():
        p = line.split("\t")
        if len(p) != 7 or not p[0]:
            continue
        frac = bool(p[5])
        kind = "key" if p[6] else ("number" if p[3] else "onoff")
        out.append({"key": p[0], "value": p[1], "default": p[2],
                    "min": num(p[3]), "max": num(p[4]),
                    "step": 0.1 if frac else 1, "kind": kind})
    return out


# --------------------------------------------------------------------------
# page
# --------------------------------------------------------------------------

# Shared between the dashboard page and the settings page, so the two look
# like the same application.
THEME_CSS = """
:root{color-scheme:light dark;
--bg:#fbfbfd;--fg:#1d1d1f;--mut:#6e6e73;--line:#e3e3e8;--card:#fff;
--accent:#0a84ff;--live:#30a14e;--warn:#bf5700;}
@media (prefers-color-scheme:dark){:root{
--bg:#161618;--fg:#f2f2f7;--mut:#9a9aa0;--line:#2c2c30;--card:#1f1f22;
--accent:#4da3ff;--live:#4ac26b;--warn:#ff9f45;}}
*{box-sizing:border-box}
body{margin:0;padding:28px 20px 60px;background:var(--bg);color:var(--fg);
font:15px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",Segoe UI,sans-serif}
.wrap{max-width:860px;margin:0 auto}
h1{font-size:19px;margin:0 0 2px;letter-spacing:-.01em}
.sub{color:var(--mut);font-size:13px;margin-bottom:22px}
.sub a{color:var(--accent);text-decoration:none}
.mut{color:var(--mut)}
.btn{font:inherit;font-size:12px;padding:3px 8px;border-radius:7px;cursor:pointer;
background:transparent;color:var(--accent);border:1px solid var(--line);margin-left:5px}
.btn:hover{border-color:var(--accent)}
.btn[disabled]{opacity:.4;cursor:default;color:var(--mut);border-color:var(--line)}
.btn.danger{color:var(--warn)}
.btn.primary{background:var(--accent);border-color:var(--accent);color:#fff}
.msg{display:none;position:fixed;z-index:20;top:14px;right:16px;
max-width:min(520px,calc(100vw - 32px));
border:1px solid var(--line);background:var(--card);border-radius:10px;
padding:10px 14px;font-size:13px;box-shadow:0 6px 24px rgba(0,0,0,.22)}
.msg.bad{border-color:var(--warn);color:var(--warn)}
"""

PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>TimeTracker</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>__CSS__
.hero{background:var(--card);border:1px solid var(--line);border-radius:14px;
padding:18px 20px;margin-bottom:18px;display:flex;align-items:center;gap:14px}
.dot{width:10px;height:10px;border-radius:50%;flex:none;background:var(--mut)}
.dot.run{background:var(--live);animation:p 1.6s ease-in-out infinite}
@keyframes p{0%,100%{opacity:1}50%{opacity:.35}}
.hero .who{font-weight:600;font-size:16px}
.hero .st{color:var(--mut);font-size:13px}
.hero .pomo{color:var(--mut);font-size:13px;margin-top:2px;
font-variant-numeric:tabular-nums}
.pomotag{font-size:11px}
.clock{margin-left:auto;font-variant-numeric:tabular-nums;font-size:26px;
font-weight:250;letter-spacing:-.02em}
.cards{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-bottom:22px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:13px 15px}
.card .k{color:var(--mut);font-size:11px;text-transform:uppercase;letter-spacing:.05em}
.card .v{font-size:21px;font-weight:500;font-variant-numeric:tabular-nums;margin-top:3px}
h2{font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:var(--mut);
margin:26px 0 9px;font-weight:600}
.tw{overflow-x:auto;background:var(--card);border:1px solid var(--line);border-radius:12px}
table{width:100%;border-collapse:collapse;font-size:14px}
th{text-align:left;font-weight:500;color:var(--mut);font-size:11px;
text-transform:uppercase;letter-spacing:.05em;padding:11px 12px;border-bottom:1px solid var(--line)}
td{padding:10px 12px;border-bottom:1px solid var(--line)}
tr:last-child td{border-bottom:0}
td.n{text-align:right;font-variant-numeric:tabular-nums}
th.n{text-align:right}
.live{color:var(--live);font-weight:600}
.tag{display:inline-block;font-size:10px;padding:2px 6px;border-radius:5px;
background:var(--warn);color:#fff;margin-left:7px;vertical-align:middle;letter-spacing:.03em}
/* Six columns get cramped: pin the fixed-width ones and let the free-text
   note columns take whatever is left. */
.note{font-size:13px;color:var(--fg);opacity:.85;min-width:110px}
td.when{white-space:nowrap;font-variant-numeric:tabular-nums}
td.cat{min-width:120px}
.edited{font-size:10px}
#recent td.n{white-space:nowrap}
.empty{padding:22px 15px;color:var(--mut);font-size:14px}
footer{margin-top:30px;color:var(--mut);font-size:12px;text-align:center}
/* editing */
td.acts,th.acts{white-space:nowrap;text-align:right;width:1%;padding-left:4px}
td.editcell{background:var(--bg);padding:14px 15px}
.edit{display:grid;grid-template-columns:repeat(3,1fr);gap:10px 12px}
.edit label{display:flex;flex-direction:column;gap:4px;font-size:11px;font-weight:600;
text-transform:uppercase;letter-spacing:.05em;color:var(--mut)}
.edit label.wide{grid-column:span 3}
/* font:inherit would drag the label's uppercase 11px/600 down into the field. */
.edit input,.edit select{font:inherit;font-size:14px;font-weight:400;
text-transform:none;letter-spacing:normal;padding:6px 8px;width:100%;
color:var(--fg);background:var(--card);border:1px solid var(--line);border-radius:7px}
.edit input:focus,.edit select:focus{outline:2px solid var(--accent);outline-offset:-1px}
.editfoot{grid-column:span 3;display:flex;align-items:center;gap:2px;
border-top:1px solid var(--line);padding-top:11px}
.editfoot .spacer{flex:1}
#e-dur{font-size:13px;font-variant-numeric:tabular-nums}
@media (max-width:640px){.edit{grid-template-columns:1fr}
.edit label.wide,.editfoot{grid-column:span 1}}
</style></head><body><div class="wrap">
<h1>TimeTracker</h1>
<div class="sub">Updates while a timer runs. Sessions can be corrected below.
&middot; <a id="nav-settings" href="#">Settings</a>
&middot; <a id="nav-guide" href="#">Guide</a></div>
<div class="hero"><div class="dot" id="dot"></div>
<div><div class="who" id="who">&nbsp;</div><div class="st" id="st"></div>
<div class="pomo" id="pomo" style="display:none"></div></div>
<div class="clock" id="clock"></div></div>
<div class="msg" id="msg"></div>
<div class="cards">
<div class="card"><div class="k">Today</div><div class="v" id="t-today">&nbsp;</div></div>
<div class="card"><div class="k">This week</div><div class="v" id="t-week">&nbsp;</div></div>
<div class="card"><div class="k">All time</div><div class="v" id="t-all">&nbsp;</div></div>
</div>
<h2>By category</h2>
<div class="tw"><table><thead><tr><th>Category</th>
<th class="n">Today</th><th class="n">Week</th><th class="n">All time</th>
</tr></thead><tbody id="rows"></tbody></table></div>
<h2>Recent sessions</h2>
<div class="tw"><table><thead><tr><th>Start</th><th>Category</th>
<th class="n">Duration</th><th>Planned</th><th>Actually did</th><th class="acts"></th>
</tr></thead><tbody id="recent"></tbody></table></div>
<div id="flagwrap" style="display:none">
<h2>Needs attention</h2>
<div class="tw"><table><thead><tr><th>Start</th><th>Category</th>
<th class="n">Duration</th><th>Note</th><th class="acts"></th>
</tr></thead><tbody id="flagged"></tbody></table></div></div>
<footer id="foot"></footer>
</div><script>
const TOKEN=new URLSearchParams(location.search).get("t")||"";
const $=i=>document.getElementById(i);
$("nav-settings").href="/settings?t="+encodeURIComponent(TOKEN);
$("nav-guide").href="/guide?t="+encodeURIComponent(TOKEN);
let tick=null,elapsed=0,POMO=null;
// Rows currently on screen, addressed by a throwaway id the buttons carry.
let LAST=null,ROWS={},nrow=0,editing=null,msgTimer=null;
function dur(s){const g=s<0?"-":"";s=Math.abs(s|0);
if(s<60)return g+s+"s";const h=(s/3600)|0,m=((s%3600)/60)|0;
return h?g+h+"h "+String(m).padStart(2,"0")+"m":g+m+"m";}
function clock(s){const h=(s/3600)|0,m=((s%3600)/60)|0,x=s%60;
return String(h).padStart(2,"0")+":"+String(m).padStart(2,"0")+":"+String(x).padStart(2,"0");}
function mmss(s){s=Math.max(0,s|0);
return String((s/60)|0).padStart(2,"0")+":"+String(s%60).padStart(2,"0");}
// Live pomodoro line in the hero: phase, ticking countdown, cycle dots,
// accumulated break overrun. Recomputed from the wall clock each second.
function pomoLine(){
  const el=$("pomo");
  if(!POMO){el.style.display="none";return;}
  const now=Math.floor(Date.now()/1000),remain=POMO.target-now;
  const cyc=Math.max(1,POMO.cycle||4),filled=POMO.completed%cyc;
  let s;
  if(POMO.phase==="WORK")
    s=remain>0?"🍅 Work · "+mmss(remain)+" to break"
              :"🍅 Work · tomato due";
  else
    s=remain>0?"🍅 Break · "+mmss(remain)+" left"
              :"🍅 Break over · +"+mmss(now-POMO.target);
  s+=" · "+"🍅".repeat(filled)+"○".repeat(cyc-filled);
  if(POMO.completed)s+=" ×"+POMO.completed;
  if(POMO.overrun)s+=" · overrun "+dur(POMO.overrun);
  el.textContent=s;el.style.display="";
}
function esc(t){const d=document.createElement("div");d.textContent=t==null?"":t;return d.innerHTML;}
// esc() leaves quotes alone, which is fine between tags and not fine inside an
// attribute — anything going into one goes through escA.
function escA(t){return esc(t).replace(/"/g,"&quot;");}
function pad(n){return String(n).padStart(2,"0");}
function localInput(ep){const d=new Date(ep*1000);
return d.getFullYear()+"-"+pad(d.getMonth()+1)+"-"+pad(d.getDate())+"T"+
pad(d.getHours())+":"+pad(d.getMinutes())+":"+pad(d.getSeconds());}
function note(text,bad){const m=$("msg");m.textContent=text;
m.className="msg"+(bad?" bad":"");m.style.display="block";
if(msgTimer)clearTimeout(msgTimer);
msgTimer=setTimeout(()=>{m.style.display="none";},bad?8000:4000);}
function reg(r){const id="r"+(nrow++);ROWS[id]=r;return id;}
function acts(r,id){
  if(!LAST||!LAST.editable)return"";
  const canEdit=r.start_ep!=null&&r.end_ep!=null;
  return '<td class="acts">'+
    '<button class="btn" data-act="edit" data-id="'+id+'"'+
      (canEdit?"":' disabled title="timestamp does not parse"')+">Edit</button>"+
    '<button class="btn danger" data-act="del" data-id="'+id+'">Delete</button></td>';
}
function render(d){
  $("t-today").textContent=dur(d.totals.today);
  $("t-week").textContent=dur(d.totals.week);
  $("t-all").textContent=dur(d.totals.all);
  const dot=$("dot");dot.className="dot";
  if(tick){clearInterval(tick);tick=null;}
  POMO=d.pomodoro||null;pomoLine();
  if(d.status==="RUNNING"){dot.classList.add("run");
    $("who").textContent=d.category;
    $("st").textContent=(d.running&&d.running.plan)?("Running: "+d.running.plan):"Running";
    elapsed=d.running.elapsed;$("clock").textContent=clock(elapsed);
    tick=setInterval(()=>{elapsed++;$("clock").textContent=clock(elapsed);pomoLine();},1000);
  }else{$("who").textContent="Idle";$("st").textContent="No timer running";$("clock").textContent="";}
  $("rows").innerHTML=d.table.length?d.table.map(r=>
    "<tr><td>"+esc(r.category)+(r.running?' <span class="live">● live</span>':"")+
    '</td><td class="n">'+dur(r.today)+'</td><td class="n">'+dur(r.week)+
    '</td><td class="n">'+dur(r.all)+"</td></tr>").join(""):
    '<tr><td colspan="4" class="empty">Nothing logged yet.</td></tr>';
  ROWS={};nrow=0;
  $("recent").innerHTML=d.recent.length?d.recent.map(r=>{const id=reg(r);
    return '<tr data-row="'+id+'"><td class="mut when">'+
    esc(r.start.slice(0,16).replace("T"," "))+
    (r.note==="EDITED"?' <span class="mut edited">·edited</span>':"")+
    '</td><td class="cat">'+esc(r.category)+'</td><td class="n">'+dur(r.dur)+
    (r.pomodoros!==""?'<div class="mut pomotag">🍅×'+esc(r.pomodoros)+
      ((+r.overrun||0)>0?" +"+dur(+r.overrun):"")+"</div>":"")+
    '</td><td class="note">'+(r.plan?esc(r.plan):'<span class="mut">&nbsp;</span>')+
    '</td><td class="note">'+(r.recap?esc(r.recap):'<span class="mut">&nbsp;</span>')+
    "</td>"+acts(r,id)+"</tr>";}).join(""):
    '<tr><td colspan="6" class="empty">No sessions yet.</td></tr>';
  if(d.flagged.length){$("flagwrap").style.display="";
    $("flagged").innerHTML=d.flagged.map(r=>{const id=reg(r);
      return '<tr data-row="'+id+'"><td class="mut when">'+
      esc(r.start.slice(0,16).replace("T"," "))+"</td><td>"+
      esc(r.category)+'</td><td class="n">'+dur(r.dur)+'</td><td><span class="tag">'+
      esc(r.note)+"</span></td>"+acts(r,id)+"</tr>";}).join("");
  }else{$("flagwrap").style.display="none";}
  $("foot").textContent="Updated "+d.generated;
}
function formHTML(r){
  const opts=(LAST.categories||[]).map(c=>'<option value="'+escA(c.key)+'"'+
    (c.key===r.key?" selected":"")+">"+esc(c.label)+"</option>").join("");
  return '<div class="edit">'+
    '<label>Start<input type="datetime-local" step="1" id="e-start" value="'+
      escA(localInput(r.start_ep))+'"></label>'+
    '<label>End<input type="datetime-local" step="1" id="e-end" value="'+
      escA(localInput(r.end_ep))+'"></label>'+
    '<label>Category<select id="e-cat">'+opts+"</select></label>"+
    '<label class="wide">Planned<input type="text" id="e-plan" maxlength="500" value="'+
      escA(r.plan)+'"></label>'+
    '<label class="wide">Actually did<input type="text" id="e-recap" maxlength="500" value="'+
      escA(r.recap)+'"></label>'+
    '<div class="editfoot"><span id="e-dur" class="mut"></span><span class="spacer"></span>'+
    '<button class="btn" data-act="cancel">Cancel</button>'+
    '<button class="btn primary" data-act="save">Save</button></div></div>';
}
function epochOf(id){const v=$(id).value;
  const t=v?new Date(v).getTime():NaN;
  return Number.isFinite(t)?Math.floor(t/1000):null;}
function showDur(){const a=epochOf("e-start"),b=epochOf("e-end");
  $("e-dur").textContent=(a==null||b==null)?"":
    (b<a?"end is before start":"Duration "+dur(b-a));}
function startEdit(id){
  const r=ROWS[id],tr=document.querySelector('tr[data-row="'+id+'"]');
  if(!r||!tr||r.start_ep==null||r.end_ep==null)return;
  editing=id;
  // Polling keeps running (it holds the server open) but stops touching the
  // DOM, so a half-typed correction can't be wiped by a refresh.
  tr.innerHTML='<td class="editcell" colspan="'+tr.cells.length+'">'+formHTML(r)+"</td>";
  showDur();$("e-start").addEventListener("input",showDur);
  $("e-end").addEventListener("input",showDur);$("e-end").focus();
}
function stopEdit(){editing=null;poll();}
async function post(path,body){
  const r=await fetch(path+"?t="+encodeURIComponent(TOKEN),{
    method:"POST",cache:"no-store",
    headers:{"Content-Type":"application/json","X-TimeTracker-Token":TOKEN},
    body:JSON.stringify(body)});
  let j=null;try{j=await r.json();}catch(e){}
  return{ok:!!(j&&j.ok),msg:(j&&(j.message||j.error))||("HTTP "+r.status)};
}
function sel(r){return{start:r.start,dur:r.dur,key:r.key};}
async function save(){
  const r=ROWS[editing];if(!r)return;
  const a=epochOf("e-start"),b=epochOf("e-end");
  if(a==null||b==null){note("Enter a valid start and end time.",true);return;}
  const body=Object.assign(sel(r),{new_start:a,new_end:b,
    new_key:$("e-cat").value,plan:$("e-plan").value,recap:$("e-recap").value});
  const res=await post("/api/session/update",body);
  note(res.msg,!res.ok);
  if(res.ok)stopEdit();
}
async function del(id){
  const r=ROWS[id];if(!r)return;
  const nl="\\n";
  if(!confirm("Delete this session?"+nl+nl+r.category+", "+dur(r.dur)+
    nl+"Started "+r.start.slice(0,16).replace("T"," ")+nl+nl+
    "It is moved to sessions.deleted.tsv, not shredded."))return;
  const res=await post("/api/session/delete",sel(r));
  note(res.msg,!res.ok);
  if(res.ok&&editing===id)editing=null;
  poll();
}
document.addEventListener("click",e=>{
  const b=e.target.closest("button[data-act]");if(!b)return;
  const act=b.dataset.act;
  if(act==="edit"){if(editing)stopEdit();startEdit(b.dataset.id);}
  else if(act==="del"){del(b.dataset.id);}
  else if(act==="cancel"){stopEdit();}
  else if(act==="save"){save();}
});
document.addEventListener("keydown",e=>{
  if(!editing)return;
  if(e.key==="Escape")stopEdit();
  else if(e.key==="Enter"&&e.target.tagName!=="BUTTON")save();
});
async function poll(){try{const r=await fetch("/api/data?t="+encodeURIComponent(TOKEN),
  {cache:"no-store"});
  if(r.ok){const d=await r.json();LAST=d;
    if(editing){$("foot").textContent="Editing; updates paused";return;}
    render(d);}
  else $("foot").textContent="Server rejected request.";}
  catch(e){$("foot").textContent="Dashboard server stopped.";if(tick)clearInterval(tick);}}
poll();setInterval(poll,__POLL__);
</script></body></html>
"""

SETTINGS_PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>TimeTracker Settings</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>__CSS__
.wrap{max-width:600px}
/* section chips at the top: one per panel, scroll on click */
.toc{display:flex;flex-wrap:wrap;gap:6px;margin:0 0 6px}
.toc a{font-size:12px;padding:4px 10px;border-radius:999px;border:1px solid var(--line);
color:var(--fg);text-decoration:none;background:var(--card)}
.toc a:hover{border-color:var(--accent);color:var(--accent)}
section{margin-top:30px;scroll-margin-top:16px}
h2{font-size:13px;text-transform:uppercase;letter-spacing:.06em;color:var(--mut);
margin:0 0 4px;font-weight:600}
.lead{color:var(--mut);font-size:12px;margin:0 0 9px;line-height:1.5}
.lead a{color:var(--accent);text-decoration:none}
.panel{background:var(--card);border:1px solid var(--line);border-radius:14px;
padding:2px 20px}
.panel+.panel,.panel+.addform,.panel+.onerow{margin-top:10px}
.row{display:grid;grid-template-columns:1fr 150px;gap:2px 16px;
padding:14px 0;border-bottom:1px solid var(--line)}
.row:last-child{border-bottom:0}
.row .name{font-weight:600;font-size:14px}
.row .hint{color:var(--mut);font-size:12px}
.row input,.row select{grid-column:2;grid-row:1/span 2;align-self:center;
font:inherit;font-size:14px;padding:6px 8px;width:100%;
color:var(--fg);background:var(--bg);border:1px solid var(--line);border-radius:7px}
.row input.key{text-align:center;font-family:ui-monospace,Menlo,monospace}
.row input:focus,.row select:focus{outline:2px solid var(--accent);outline-offset:-1px}
/* An unsaved row says so, and its field takes the accent border. */
.row.changed input,.row.changed select{border-color:var(--accent)}
.row.changed .name::after{content:"unsaved";display:inline-block;font-size:10px;
padding:1px 6px;border-radius:5px;border:1px solid var(--accent);
color:var(--accent);margin-left:8px;vertical-align:middle;letter-spacing:.04em;
text-transform:uppercase;font-weight:600}
/* the one Save for every value on the page, kept in view */
.foot{position:sticky;bottom:0;display:flex;align-items:center;gap:10px;
padding:12px 0;margin-top:30px;background:var(--bg);border-top:1px solid var(--line)}
.foot .spacer{flex:1}
.foot #stat{font-size:12px;text-align:right}
.warn{color:var(--warn)}
.empty{padding:22px 0;color:var(--mut);font-size:14px}
/* playlist rows and the two small forms */
.prow{display:grid;grid-template-columns:auto 1fr auto;gap:2px 12px;
align-items:center;padding:11px 0;border-bottom:1px solid var(--line)}
.prow:last-child{border-bottom:0}
.psw{width:26px;height:26px;border-radius:5px;grid-row:1/span 2}
.pname{font-weight:600;font-size:14px;min-width:0;overflow:hidden;
text-overflow:ellipsis;white-space:nowrap}
.puri{grid-column:2;font-size:11px;color:var(--mut);font-family:ui-monospace,
Menlo,monospace;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.pacts{grid-column:3;grid-row:1/span 2;white-space:nowrap;text-align:right}
.prow.work .pname{color:var(--live)}
.addform{display:flex;gap:8px;padding:10px 0 4px;flex-wrap:wrap}
.addform input{flex:1 1 150px;min-width:0;font:inherit;font-size:14px;
padding:6px 8px;color:var(--fg);background:var(--bg);
border:1px solid var(--line);border-radius:7px}
.addform input:focus{outline:2px solid var(--accent);outline-offset:-1px}
.addform .btn{flex:none}
.onerow{display:flex;gap:8px;align-items:center;padding:10px 0 4px}
.onerow input,.onerow select{flex:1;min-width:0;font:inherit;font-size:14px;
padding:6px 8px;color:var(--fg);background:var(--bg);
border:1px solid var(--line);border-radius:7px}
.onerow input:focus,.onerow select:focus{outline:2px solid var(--accent);
outline-offset:-1px}
.onerow select,.row select{-webkit-appearance:none;appearance:none;
padding-right:26px;cursor:pointer;
background-image:url("data:image/svg+xml;charset=utf-8,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 6'%3E%3Cpath d='M1 1l4 4 4-4' fill='none' stroke='%236e6e73' stroke-width='1.6' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E");
background-repeat:no-repeat;background-position:right 9px center;
background-size:10px 6px}
@media (prefers-color-scheme:dark){.onerow select,.row select{
background-image:url("data:image/svg+xml;charset=utf-8,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 6'%3E%3Cpath d='M1 1l4 4 4-4' fill='none' stroke='%239a9aa0' stroke-width='1.6' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E")}}
.onerow .btn{flex:none}
.crow{display:grid;grid-template-columns:1fr auto;gap:2px 12px;
padding:12px 0;border-bottom:1px solid var(--line)}
.crow:last-child{border-bottom:0}
.crow .cname{font-weight:600;font-size:14px}
.crow .hint{color:var(--mut);font-size:12px}
.crow.off .cname{color:var(--mut);font-weight:500}
.crow.pending{opacity:.45}
.cacts{grid-column:2;grid-row:1/span 2;align-self:center;white-space:nowrap;
text-align:right}
.badge{display:inline-block;font-size:10px;padding:1px 6px;border-radius:5px;
border:1px solid var(--line);color:var(--mut);margin-left:7px;
vertical-align:middle;letter-spacing:.04em;text-transform:uppercase}
.badge.on{border-color:var(--live);color:var(--live)}
@media (max-width:480px){.row{grid-template-columns:1fr 110px}
.crow{grid-template-columns:1fr}
.cacts{grid-column:1;grid-row:auto;text-align:left;margin-top:7px}
.cacts .btn{margin:0 5px 0 0}}
</style></head><body><div class="wrap">
<h1>Settings</h1>
<div class="sub"><a id="nav-back" href="#">&larr; Dashboard</a> &middot;
<a id="nav-guide" href="#">Guide</a></div>
<div class="toc" id="toc"></div>
<div class="msg" id="msg"></div>

<section id="s-timer"><h2>Timer</h2>
<div class="lead">Lengths in minutes. The two short ones accept decimals.</div>
<div class="panel" data-sec="timer"><div class="empty">Loading&hellip;</div></div></section>

<section id="s-screen"><h2>Break screen</h2>
<div class="lead">What happens when the tomato takes the screen, and which keys
work on it. A key is one letter or digit, or Tab or Space.</div>
<div class="panel" data-sec="screen"><div class="empty">Loading&hellip;</div></div></section>

<section id="s-spotify"><h2>Spotify</h2>
<div class="lead">The break menu can play your playlists in the Spotify app.
Add a playlist by pasting its link (Share &rarr; Copy link in Spotify) and
giving it a name. Mark one as <b>work</b> and it plays when the break ends
instead of the break music.</div>
<div class="panel" data-sec="spotify"><div class="empty">Loading&hellip;</div></div>
<div class="panel" id="pls"><div class="empty">Loading&hellip;</div></div>
<div class="addform">
  <input id="pl-name" type="text" placeholder="Name" maxlength="60">
  <input id="pl-uri" type="text" placeholder="Spotify link" maxlength="300">
  <button class="btn primary" id="pl-add">Add</button>
</div></section>

<section id="s-reminders"><h2>Reminders</h2>
<div class="lead">The break menu can file a note into Apple Reminders. The list
is created when the first note is saved.</div>
<div class="panel" data-sec="reminders"><div class="empty">Loading&hellip;</div></div>
<div class="onerow">
  <input id="rl-name" type="text" placeholder="List name" maxlength="60">
  <button class="btn" id="rl-save">Save list</button>
</div></section>

<section id="s-calendar"><h2>Calendar</h2>
<div class="lead">Every logged session can be written to a calendar. Use an
empty calendar of its own: everything in it from the last
<span id="pd-days">14</span> days is rewritten to match the log. To see it on
your phone, create the calendar in Google Calendar and enable it under
<a href="https://calendar.google.com/calendar/syncselect" target="_blank"
rel="noreferrer">sync settings</a>.</div>
<div class="panel" data-sec="calendar"><div class="empty">Loading&hellip;</div></div>
<div class="onerow">
  <select id="pc-name"><option value="">Loading&hellip;</option></select>
  <button class="btn" id="pc-refresh">Refresh</button>
  <button class="btn" id="pc-save">Save calendar</button>
</div>
<div class="lead" id="pc-note"></div></section>

<section id="s-categories"><h2>Categories</h2>
<div class="lead">Hide removes a category from the launcher and can be undone.
Delete removes it for good. Logged hours are kept either way.</div>
<div class="panel" id="cats"><div class="empty">Loading&hellip;</div></div></section>

<section id="s-tomato" hidden><h2>Tomato game</h2>
<div class="lead">You found it.</div>
<div class="panel" data-sec="tomato"><div class="empty">Loading&hellip;</div></div></section>

<div class="foot"><span class="spacer"></span><span class="mut" id="stat"></span>
<button class="btn primary" id="save" disabled>Save</button></div>
</div><script>
const TOKEN=new URLSearchParams(location.search).get("t")||"";
const $=i=>document.getElementById(i);
$("nav-back").href="/?t="+encodeURIComponent(TOKEN);
$("nav-guide").href="/guide?t="+encodeURIComponent(TOKEN);
// Which panel each setting belongs to. Keys, defaults and ranges come from
// the server; a key not listed here lands in the Timer panel by its name.
const SEC={
 timer:["pomodoro_minutes","break_minutes","long_break_minutes","long_break_every",
   "snooze_minutes","auto_accept_seconds","pomodoro_default"],
 screen:["sound","pause_media","key_menu","key_spotify","key_reminder"],
 spotify:["spotify","spotify_resume_work","spotify_pause_on_overrun"],
 reminders:["reminders"],
 calendar:["paint_calendar","paint_days","paint_min_minutes"],
 tomato:["easter_egg"]};
const META={
 pomodoro_minutes:["Work session","Minutes of work before the tomato"],
 break_minutes:["Short break",""],
 long_break_minutes:["Long break",""],
 long_break_every:["Long break every","Every Nth pomodoro gets the long break"],
 snooze_minutes:["Snooze","Minutes a snoozed tomato waits"],
 auto_accept_seconds:["No-answer timeout",
   "Seconds before an unanswered tomato takes the break"],
 pomodoro_default:["Pomodoro on by default",
   "Start the plan prompt with Pomodoro mode ticked"],
 sound:["Sound","Play a sound when the tomato appears"],
 pause_media:["Pause media","Pause video and music when the tomato appears"],
 key_menu:["Menu key","Opens and closes the break menu"],
 key_spotify:["Spotify key","Opens the Spotify panel from the menu"],
 key_reminder:["Reminder key","Opens the note panel from the menu"],
 easter_egg:["Playable tomato","Let the tomato on the break screen open the game"],
 spotify:["Spotify panel","Show Spotify in the break menu"],
 spotify_resume_work:["Work playlist after a break",
   "Play the work playlist when the break ends, if music was playing"],
 spotify_pause_on_overrun:["Pause when the break runs over",
   "Pause music you started when the break passes its end"],
 reminders:["Reminders panel","Show Add Reminder in the break menu"],
 paint_calendar:["Write sessions to the calendar",""],
 paint_days:["Days to keep in sync","How far back each update reaches"],
 paint_min_minutes:["Shortest session to write",
   "Shorter sessions are left off the calendar"]};
const TOC=[["s-timer","Timer"],["s-screen","Break screen"],["s-spotify","Spotify"],
 ["s-reminders","Reminders"],["s-calendar","Calendar"],["s-categories","Categories"],
 ["s-tomato","Tomato game"]];
let CUR={},CATS=[],SEEN="",BUSY=false,SAVING=false,msgTimer=null,statTimer=null;
function esc(t){const d=document.createElement("div");d.textContent=t==null?"":t;return d.innerHTML;}
function escA(t){return esc(t).replace(/"/g,"&quot;");}
function note(text,bad){const m=$("msg");m.textContent=text;
m.className="msg"+(bad?" bad":"");m.style.display="block";
if(msgTimer)clearTimeout(msgTimer);
msgTimer=setTimeout(()=>{m.style.display="none";},bad?8000:4000);}
function rowHTML(s){
  const m=META[s.key]||[s.key,""];
  let hint,field;
  if(s.kind==="key"){
    hint="default "+esc(s.default);
    field='<input type="text" class="key" id="f-'+escA(s.key)+'" maxlength="5" value="'+escA(s.value)+'">';
  }else if(s.kind==="number"){
    hint=s.min+" to "+s.max+", default "+esc(s.default);
    field='<input type="number" id="f-'+escA(s.key)+'" min="'+s.min+'" max="'+s.max+
      '" step="'+(s.step||1)+'" value="'+escA(s.value)+'">';
  }else{
    hint="default "+esc(s.default);
    field='<select id="f-'+escA(s.key)+'">'+
      '<option value="on"'+(s.value==="on"?" selected":"")+'>On</option>'+
      '<option value="off"'+(s.value==="off"?" selected":"")+'>Off</option></select>';
  }
  return '<div class="row"><span class="name">'+esc(m[0])+'</span>'+field+
    '<span class="hint">'+(m[1]?esc(m[1])+". ":"")+hint+'</span></div>';
}
function render(list,found){
  CUR={};
  const by={};
  for(const s of list){CUR[s.key]=s.value;by[s.key]=s;}
  const placed=new Set();
  for(const sec in SEC){
    const panel=document.querySelector('.panel[data-sec="'+sec+'"]');
    const rows=SEC[sec].filter(k=>by[k]).map(k=>{placed.add(k);return rowHTML(by[k]);});
    panel.innerHTML=rows.join("")||'<div class="empty">Nothing here.</div>';
  }
  // Anything the server knows and this page does not: still editable.
  const rest=list.filter(s=>!placed.has(s.key)).map(rowHTML).join("");
  if(rest)document.querySelector('.panel[data-sec="timer"]').innerHTML+=rest;
  if(!list.length)document.querySelector('.panel[data-sec="timer"]').innerHTML=
    '<div class="empty">Could not load settings. Is settings.sh installed?</div>';
  $("s-tomato").hidden=!found;
  $("toc").innerHTML=TOC.filter(t=>!$(t[0]).hidden)
    .map(t=>'<a href="#'+t[0]+'">'+t[1]+'</a>').join("");
  dirty();
}
function stat(text,bad,hold){
  const s=$("stat");s.textContent=text;s.className=bad?"warn":"mut";
  if(statTimer){clearTimeout(statTimer);statTimer=null;}
  if(hold)statTimer=setTimeout(()=>{statTimer=null;dirty();},hold);
}
function pending(){
  const changes={};
  for(const k in CUR){const f=$("f-"+k);
    if(f&&String(f.value)!==CUR[k])changes[k]=String(f.value);}
  return changes;
}
function dirty(){
  const ch=pending(),n=Object.keys(ch).length;
  for(const k in CUR){const f=$("f-"+k);
    if(f&&f.closest(".row"))f.closest(".row").classList.toggle("changed",k in ch);}
  if(!SAVING){
    $("save").disabled=!n;
    $("save").textContent="Save";
    if(!statTimer)stat(n?n+(n===1?" unsaved change":" unsaved changes"):"");
  }
  return ch;
}
async function load(){
  try{
    const r=await fetch("/api/settings?t="+encodeURIComponent(TOKEN),{cache:"no-store"});
    if(!r.ok){note("Server rejected request.",true);return;}
    const d=await r.json();render(d.settings||[],!!d.tomato_found);
  }catch(e){note("Dashboard server stopped.",true);}
}
async function save(){
  if(SAVING)return;
  const changes=pending();
  if(!Object.keys(changes).length)return;
  SAVING=true;
  $("save").disabled=true;$("save").textContent="Saving…";
  stat("Saving…");
  let j=null,ok=false;
  try{
    const r=await fetch("/api/setconf?t="+encodeURIComponent(TOKEN),{
      method:"POST",cache:"no-store",
      headers:{"Content-Type":"application/json","X-TimeTracker-Token":TOKEN},
      body:JSON.stringify({changes})});
    try{j=await r.json();}catch(e){}
    ok=!!(j&&j.ok);
    note((j&&(j.message||j.error))||("HTTP "+r.status),!ok);
  }catch(e){note("Dashboard server stopped.",true);}
  SAVING=false;$("save").textContent="Save";
  if(ok){await load();stat("Saved",false,4000);}
  else{dirty();stat("Not saved",true);}
}
// --- playlists, reminders list, calendar -----------------------------------
let PLS=[],PSEEN="",RLNAME="";
function plHue(t){let h=0;for(let i=0;i<t.length;i++)h=(h*31+t.charCodeAt(i))%360;return h;}
function plTile(t){const h=plHue(t);
  return "linear-gradient(145deg,hsl("+h+",40%,33%),hsl("+((h+40)%360)+",36%,17%))";}
function plRow(p){
  return '<div class="prow'+(p.work?" work":"")+'">'+
    '<span class="psw" style="background:'+plTile(p.name)+'"></span>'+
    '<span class="pname">'+esc(p.name)+
      (p.work?' <span class="badge on">work</span>':"")+'</span>'+
    '<span class="pacts">'+
      '<button class="btn" data-pl="work" data-uri="'+escA(p.uri)+'">'+
        (p.work?"Unset work":"Set as work")+'</button>'+
      '<button class="btn danger" data-pl="del" data-uri="'+escA(p.uri)+'">Remove</button>'+
    '</span>'+
    '<span class="puri">'+esc(p.uri)+'</span></div>';
}
async function loadBreak(force){
  try{
    const r=await fetch("/api/breakmenu?t="+encodeURIComponent(TOKEN),{cache:"no-store"});
    if(!r.ok){note("Server rejected request.",true);return;}
    const d=await r.json();
    PLS=d.playlists||[];
    RLNAME=d.reminders_list||"";
    paintRender(d);
    if(d.paint_days)$("pd-days").textContent=String(d.paint_days);
    const rl=$("rl-name");
    if(document.activeElement!==rl&&!rl.dataset.touched)rl.value=RLNAME;
    const j=JSON.stringify(PLS);
    if(!force&&j===PSEEN)return;
    PSEEN=j;
    $("pls").innerHTML=PLS.length?PLS.map(plRow).join("")
      :'<div class="empty">No playlists yet.</div>';
  }catch(e){note("Dashboard server stopped.",true);}
}
async function breakPost(path,body,verb){
  if(BUSY)return;
  BUSY=true;
  note(verb+"…");
  let j=null;
  try{
    const r=await fetch(path+"?t="+encodeURIComponent(TOKEN),{
      method:"POST",cache:"no-store",
      headers:{"Content-Type":"application/json","X-TimeTracker-Token":TOKEN},
      body:JSON.stringify(body)});
    try{j=await r.json();}catch(e){}
    note((j&&(j.message||j.error))||("HTTP "+r.status),!(j&&j.ok));
  }catch(e){note("Dashboard server stopped.",true);}
  BUSY=false;
  loadBreak(true);
  return !!(j&&j.ok);
}
document.addEventListener("click",async e=>{
  const b=e.target.closest("button[data-pl]");
  if(!b)return;
  const uri=b.dataset.uri;
  const p=PLS.find(x=>x.uri===uri);
  if(b.dataset.pl==="del"){
    if(!confirm("Remove "+(p?p.name:"this playlist")+"?"))return;
    breakPost("/api/playlist/delete",{uri},"Removing");
  }else{
    breakPost("/api/playlist/work",{uri:(p&&p.work)?"-":uri},"Saving");
  }
});
$("pl-add").addEventListener("click",async()=>{
  const name=$("pl-name").value.trim(),uri=$("pl-uri").value.trim();
  if(!name||!uri){note("Enter a name and a Spotify link.",true);return;}
  if(await breakPost("/api/playlist/add",{name,uri},"Adding")){
    $("pl-name").value="";$("pl-uri").value="";$("pl-name").focus();
  }
});
function paintRender(d){
  const sel=$("pc-name"),chosen=d.paint_calendar||"",list=d.paint_choices||[];
  if(document.activeElement===sel||sel.dataset.touched)return;
  sel.innerHTML="";
  const none=document.createElement("option");
  none.value="";none.textContent=list.length?"None":"Press Refresh";
  sel.appendChild(none);
  let found=false;
  for(const c of list){
    const o=document.createElement("option");
    o.value=c.title;
    o.textContent=c.source?c.title+"  ("+c.source+")":c.title;
    if(c.title===chosen){o.selected=true;found=true;}
    sel.appendChild(o);
  }
  if(chosen&&!found){
    const o=document.createElement("option");
    o.value=chosen;o.textContent=chosen+"  (not found)";o.selected=true;
    sel.appendChild(o);
  }
  const n=$("pc-note");
  if(!list.length)n.textContent="Press Refresh, then allow calendar access when macOS asks.";
  else if(chosen&&!found)n.textContent="“"+chosen+"” is no longer a calendar you can write to. Nothing is being written.";
  else if(!chosen)n.textContent="Nothing is written until a calendar is chosen.";
  else n.textContent="";
}
$("pc-name").addEventListener("change",()=>{$("pc-name").dataset.touched="1";});
$("pc-save").addEventListener("click",async()=>{
  const name=$("pc-name").value;
  if(await breakPost("/api/paint/calendar",{name},name?"Saving":"Clearing"))
    $("pc-name").dataset.touched="";
});
$("pc-refresh").addEventListener("click",async()=>{
  const b=$("pc-refresh");
  b.disabled=true;b.textContent="Asking…";
  await breakPost("/api/paint/refresh",{},"Reading your calendars");
  b.disabled=false;b.textContent="Refresh";
  $("pc-name").dataset.touched="";
  loadBreak(true);
});
$("rl-save").addEventListener("click",async()=>{
  const name=$("rl-name").value.trim();
  if(!name){note("Enter a list name.",true);return;}
  if(await breakPost("/api/reminders/list",{name},"Saving"))
    $("rl-name").dataset.touched="";
});
$("rl-name").addEventListener("input",()=>{$("rl-name").dataset.touched="1";});
for(const id of ["pl-name","pl-uri"])
  $(id).addEventListener("keydown",e=>{
    if(e.key==="Enter"){e.preventDefault();e.stopPropagation();$("pl-add").click();}});
$("rl-name").addEventListener("keydown",e=>{
  if(e.key==="Enter"){e.preventDefault();e.stopPropagation();$("rl-save").click();}});
// --- categories ------------------------------------------------------------
function dur(s){s=Math.abs(s|0);
if(s<60)return s+"s";const h=(s/3600)|0,m=((s%3600)/60)|0;
return h?h+"h "+String(m).padStart(2,"0")+"m":m+"m";}
function catRow(c){
  const live=c.running?' disabled title="running: stop the timer first"':"";
  const acts=c.orphan?'<span class="mut">&nbsp;</span>':
    '<button class="btn" data-cat="hide" data-key="'+escA(c.key)+'"'+live+">"+
      (c.hidden?"Show":"Hide")+"</button>"+
    '<button class="btn danger" data-cat="del" data-key="'+escA(c.key)+'"'+live+
      ">Delete</button>";
  const bits=[c.sessions
    ?c.sessions+(c.sessions===1?" session":" sessions")+", "+dur(c.total)
    :"nothing logged"];
  if(c.orphan)bits.push("deleted, history only");
  else if(c.hidden)bits.push("hidden from the launcher");
  return '<div class="crow'+(c.hidden||c.orphan?" off":"")+'">'+
    '<span class="cname">'+esc(c.label)+
      (c.running?' <span class="badge on">live</span>':"")+
      (c.hidden?' <span class="badge">hidden</span>':"")+"</span>"+
    '<span class="cacts">'+acts+"</span>"+
    '<span class="hint">'+esc(bits.join(", "))+"</span></div>";
}
async function loadCats(force){
  try{
    const r=await fetch("/api/categories?t="+encodeURIComponent(TOKEN),{cache:"no-store"});
    if(!r.ok){note("Server rejected request.",true);return;}
    const d=await r.json();
    const j=JSON.stringify(d.categories||[]);
    CATS=d.categories||[];
    if(!force&&j===SEEN)return;
    SEEN=j;
    $("cats").innerHTML=CATS.length?CATS.map(catRow).join("")
      :'<div class="empty">No categories yet. Create one with “__VERB__ new”.</div>';
  }catch(e){note("Dashboard server stopped.",true);}
}
async function catPost(path,body,btn,verb,c){
  BUSY=true;
  const row=btn.closest(".crow");
  if(row)row.classList.add("pending");
  document.querySelectorAll("#cats button").forEach(x=>{x.disabled=true;});
  btn.textContent=verb+"…";
  note(verb+" "+c.label+"…");
  let j=null;
  try{
    const r=await fetch(path+"?t="+encodeURIComponent(TOKEN),{
      method:"POST",cache:"no-store",
      headers:{"Content-Type":"application/json","X-TimeTracker-Token":TOKEN},
      body:JSON.stringify(body)});
    try{j=await r.json();}catch(e){}
    note((j&&(j.message||j.error))||("HTTP "+r.status),!(j&&j.ok));
  }catch(e){note("Dashboard server stopped.",true);}
  BUSY=false;
  loadCats(true);
}
document.addEventListener("click",e=>{
  const b=e.target.closest("button[data-cat]");if(!b||BUSY)return;
  const c=CATS.find(x=>x.key===b.dataset.key);if(!c)return;
  if(b.dataset.cat==="hide"){
    catPost("/api/category/hide",{key:c.key,hidden:!c.hidden},b,
      c.hidden?"Showing":"Hiding",c);return;}
  const nl="\\n";
  let w="Delete "+c.label+"?"+nl+nl+
    "Its launcher entry is removed and the row moves to categories.deleted.tsv.";
  if(c.sessions)w+=nl+nl+c.sessions+" logged session(s) keep their hours"+
    (c.label!==c.key?" but will show as "+c.key+".":".");
  w+=nl+nl+"Hide it instead if you only want it out of the launcher.";
  if(!confirm(w))return;
  catPost("/api/category/delete",{key:c.key},b,"Deleting",c);
});
document.addEventListener("input",e=>{if(e.target.closest(".panel[data-sec]"))dirty();});
document.addEventListener("change",e=>{if(e.target.closest(".panel[data-sec]"))dirty();});
$("save").addEventListener("click",save);
document.addEventListener("keydown",e=>{
  if(e.key==="Enter"&&e.target.tagName!=="BUTTON"&&e.target.closest(".panel[data-sec]"))save();});
load();loadCats();loadBreak();
setInterval(()=>{if(!BUSY){loadCats();loadBreak();}},__POLL__);
</script></body></html>
"""


SETUP_PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>TimeTracker Setup</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>__CSS__
.wrap{max-width:600px}
.step{margin-top:30px}
.step h2{font-size:13px;text-transform:uppercase;letter-spacing:.06em;color:var(--mut);
margin:0 0 4px;font-weight:600}
.step h2 .n{display:inline-block;width:20px;height:20px;border-radius:50%;
background:var(--accent);color:#fff;text-align:center;line-height:20px;
font-size:11px;margin-right:8px;letter-spacing:0}
.lead{color:var(--mut);font-size:13px;margin:0 0 10px;line-height:1.55}
.lead b{color:var(--fg)}
.panel{background:var(--card);border:1px solid var(--line);border-radius:14px;
padding:2px 20px}
.panel+.addform{margin-top:8px}
kbd{display:inline-block;font:inherit;font-size:12px;padding:1px 7px;border-radius:5px;
border:1px solid var(--line);background:var(--bg)}
.addform{display:flex;gap:8px;padding:10px 0 4px;flex-wrap:wrap}
.addform input{flex:1 1 130px;min-width:0;font:inherit;font-size:14px;
padding:6px 8px;color:var(--fg);background:var(--bg);
border:1px solid var(--line);border-radius:7px}
.addform input:focus{outline:2px solid var(--accent);outline-offset:-1px}
.addform .btn{flex:none}
.crow{display:grid;grid-template-columns:1fr auto;gap:2px 12px;padding:11px 0;
border-bottom:1px solid var(--line)}
.crow:last-child{border-bottom:0}
.crow .cname{font-weight:600;font-size:14px}
.crow .hint{color:var(--mut);font-size:12px}
.row{display:grid;grid-template-columns:1fr 150px;gap:2px 16px;padding:12px 0;
border-bottom:1px solid var(--line)}
.row:last-child{border-bottom:0}
.row .name{font-weight:600;font-size:14px}
.row .hint{color:var(--mut);font-size:12px}
.row input,.row select{grid-column:2;grid-row:1/span 2;align-self:center;
font:inherit;font-size:14px;padding:6px 8px;width:100%;
color:var(--fg);background:var(--bg);border:1px solid var(--line);border-radius:7px}
.row select{-webkit-appearance:none;appearance:none;padding-right:26px;cursor:pointer;
background-image:url("data:image/svg+xml;charset=utf-8,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 6'%3E%3Cpath d='M1 1l4 4 4-4' fill='none' stroke='%236e6e73' stroke-width='1.6' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E");
background-repeat:no-repeat;background-position:right 9px center;background-size:10px 6px}
.grow{display:grid;grid-template-columns:1fr auto;gap:2px 12px;padding:12px 0;
border-bottom:1px solid var(--line);align-items:center}
.grow:last-child{border-bottom:0}
.grow .gname{font-weight:600;font-size:14px}
.grow .hint{color:var(--mut);font-size:12px;grid-column:1}
.grow .btn{grid-column:2;grid-row:1/span 2}
.foot{display:flex;align-items:center;gap:10px;padding:14px 0;margin-top:30px;
border-top:1px solid var(--line)}
.foot .spacer{flex:1}
.empty{padding:16px 0;color:var(--mut);font-size:14px}
.ok{color:var(--live)}
</style></head><body><div class="wrap">
<h1>Welcome to TimeTracker</h1>
<div class="sub">Five short steps. Everything here can be changed later in
<a id="nav-settings" href="#">Settings</a>.</div>
<div class="msg" id="msg"></div>

<div class="step"><h2><span class="n">1</span>How it works</h2>
<div class="lead">Open your launcher (<kbd>&#8984;</kbd><kbd>Space</kbd> for Spotlight, or
Alfred), type <b>__VERB__</b> followed by a category, press Enter. The timer starts and
asks what you plan to do. Type <b>__VERB__</b> on its own to stop, and it asks what you
did. Both answers are optional. Everything is logged to a text file you can open
any time with <b>__VERB__ data</b>.</div></div>

<div class="step"><h2><span class="n">2</span>Categories</h2>
<div class="lead">A category is what you track time against: a course, a project, a
client. The <b>key</b> is its permanent identity and the only thing the log stores.
The <b>name</b> and <b>keywords</b> are what you type to find it, and you can change
them freely later.</div>
<div class="panel" id="cats"><div class="empty">Loading&hellip;</div></div>
<div class="addform">
  <input id="c-key" type="text" placeholder="Key, e.g. TDT4100" maxlength="60">
  <input id="c-name" type="text" placeholder="Name" maxlength="120">
  <input id="c-kw" type="text" placeholder="Keywords, comma separated" maxlength="200">
  <button class="btn primary" id="c-add">Add</button>
</div></div>

<div class="step"><h2><span class="n">3</span>Pomodoro</h2>
<div class="lead">With Pomodoro mode on, a full-screen tomato appears after each work
session and offers a break. Music and video are paused when it appears. You choose
per session; this sets the starting position of that choice.</div>
<div class="panel" id="pomo"><div class="empty">Loading&hellip;</div></div>
<div class="addform"><span class="spacer" style="flex:1"></span>
  <button class="btn" id="p-save" disabled>Save</button></div></div>

<div class="step"><h2><span class="n">4</span>Permissions</h2>
<div class="lead">Three optional tools each need one macOS permission. Granting them
now means no prompt appears in the middle of a break. Each button opens a small
helper that asks for its permission and reports back; nothing else happens.</div>
<div class="panel">
  <div class="grow"><span class="gname">Spotify</span>
    <button class="btn" data-grant="spotify">Grant</button>
    <span class="hint">Play your playlists from the break screen. Needs Automation
    access to Spotify.</span></div>
  <div class="grow"><span class="gname">Reminders</span>
    <button class="btn" data-grant="reminders">Grant</button>
    <span class="hint">Save a note from the break screen into Apple Reminders.</span></div>
  <div class="grow"><span class="gname">Calendar</span>
    <button class="btn" data-grant="calendar">Grant</button>
    <span class="hint">Write your logged sessions onto a calendar of their own.
    Choose which calendar in Settings afterwards.</span></div>
</div></div>

<div class="step"><h2><span class="n">5</span>Done</h2>
<div class="lead">Try it: <kbd>&#8984;</kbd><kbd>Space</kbd>, <b>__VERB__</b>, the name of a
category, Enter. The guide covers everything else.</div></div>

<div class="foot"><span class="spacer"></span>
<a class="btn" id="nav-guide" href="#">Read the guide</a>
<button class="btn primary" id="done">Finish setup</button></div>
</div><script>
const TOKEN=new URLSearchParams(location.search).get("t")||"";
const $=i=>document.getElementById(i);
$("nav-settings").href="/settings?t="+encodeURIComponent(TOKEN);
$("nav-guide").href="/guide?t="+encodeURIComponent(TOKEN);
let msgTimer=null,CUR={};
function esc(t){const d=document.createElement("div");d.textContent=t==null?"":t;return d.innerHTML;}
function escA(t){return esc(t).replace(/"/g,"&quot;");}
function note(text,bad){const m=$("msg");m.textContent=text;
m.className="msg"+(bad?" bad":"");m.style.display="block";
if(msgTimer)clearTimeout(msgTimer);
msgTimer=setTimeout(()=>{m.style.display="none";},bad?8000:4000);}
async function post(path,body){
  let j=null;
  try{
    const r=await fetch(path+"?t="+encodeURIComponent(TOKEN),{
      method:"POST",cache:"no-store",
      headers:{"Content-Type":"application/json","X-TimeTracker-Token":TOKEN},
      body:JSON.stringify(body)});
    try{j=await r.json();}catch(e){}
    return {ok:!!(j&&j.ok),msg:(j&&(j.message||j.error))||("HTTP "+r.status)};
  }catch(e){return {ok:false,msg:"Dashboard server stopped."};}
}
// --- categories ---
async function loadCats(){
  try{
    const r=await fetch("/api/categories?t="+encodeURIComponent(TOKEN),{cache:"no-store"});
    if(!r.ok)return;
    const d=await r.json(),cs=(d.categories||[]).filter(c=>!c.orphan&&!c.hidden);
    $("cats").innerHTML=cs.length?cs.map(c=>'<div class="crow"><span class="cname">'+
      esc(c.label)+'</span><span class="hint">'+esc(c.key)+'</span></div>').join("")
      :'<div class="empty">No categories yet. Add your first one below.</div>';
  }catch(e){}
}
$("c-add").addEventListener("click",async()=>{
  const key=$("c-key").value.trim(),name=$("c-name").value.trim(),kw=$("c-kw").value.trim();
  if(!key){note("A key is required.",true);$("c-key").focus();return;}
  const b=$("c-add");b.disabled=true;b.textContent="Adding…";
  const res=await post("/api/category/add",{key,name,keywords:kw});
  b.disabled=false;b.textContent="Add";
  note(res.msg,!res.ok);
  if(res.ok){$("c-key").value="";$("c-name").value="";$("c-kw").value="";$("c-key").focus();loadCats();}
});
for(const id of ["c-key","c-name","c-kw"])
  $(id).addEventListener("keydown",e=>{if(e.key==="Enter"){e.preventDefault();$("c-add").click();}});
// --- pomodoro ---
const PM={pomodoro_default:["Pomodoro on by default","The tomato is offered unless you untick it"],
  pomodoro_minutes:["Work session","Minutes"],break_minutes:["Short break","Minutes"]};
async function loadPomo(){
  try{
    const r=await fetch("/api/settings?t="+encodeURIComponent(TOKEN),{cache:"no-store"});
    if(!r.ok)return;
    const d=await r.json(),by={};
    for(const s of d.settings||[])by[s.key]=s;
    CUR={};
    $("pomo").innerHTML=Object.keys(PM).filter(k=>by[k]).map(k=>{
      const s=by[k];CUR[k]=s.value;
      const field=s.kind==="number"
        ?'<input type="number" id="f-'+k+'" min="'+s.min+'" max="'+s.max+'" step="'+(s.step||1)+'" value="'+escA(s.value)+'">'
        :'<select id="f-'+k+'"><option value="on"'+(s.value==="on"?" selected":"")+'>On</option>'+
         '<option value="off"'+(s.value==="off"?" selected":"")+'>Off</option></select>';
      return '<div class="row"><span class="name">'+esc(PM[k][0])+'</span>'+field+
        '<span class="hint">'+esc(PM[k][1])+'</span></div>';
    }).join("");
  }catch(e){}
}
function pending(){const ch={};for(const k in CUR){const f=$("f-"+k);
  if(f&&String(f.value)!==CUR[k])ch[k]=String(f.value);}return ch;}
$("pomo").addEventListener("input",()=>{$("p-save").disabled=!Object.keys(pending()).length;});
$("pomo").addEventListener("change",()=>{$("p-save").disabled=!Object.keys(pending()).length;});
$("p-save").addEventListener("click",async()=>{
  const ch=pending();if(!Object.keys(ch).length)return;
  const res=await post("/api/setconf",{changes:ch});
  note(res.msg,!res.ok);
  if(res.ok){await loadPomo();$("p-save").disabled=true;}
});
// --- permissions ---
document.addEventListener("click",async e=>{
  const b=e.target.closest("button[data-grant]");if(!b)return;
  b.disabled=true;b.textContent="Asking…";
  const res=await post("/api/grant",{tool:b.dataset.grant});
  note(res.msg,!res.ok);
  b.disabled=false;b.textContent=res.ok?"Grant again":"Grant";
});
// --- done ---
$("done").addEventListener("click",async()=>{
  const res=await post("/api/setup/done",{});
  if(!res.ok){note(res.msg,true);return;}
  location.href="/guide?t="+encodeURIComponent(TOKEN);
});
loadCats();loadPomo();
</script></body></html>
"""

GUIDE_PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>TimeTracker Guide</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>__CSS__
.wrap{max-width:640px}
.toc{display:flex;flex-wrap:wrap;gap:6px;margin:0 0 6px}
.toc a{font-size:12px;padding:4px 10px;border-radius:999px;border:1px solid var(--line);
color:var(--fg);text-decoration:none;background:var(--card)}
.toc a:hover{border-color:var(--accent);color:var(--accent)}
section{margin-top:30px;scroll-margin-top:16px}
h2{font-size:13px;text-transform:uppercase;letter-spacing:.06em;color:var(--mut);
margin:0 0 8px;font-weight:600}
p{margin:0 0 10px;line-height:1.55;font-size:14px}
.panel{background:var(--card);border:1px solid var(--line);border-radius:14px;
padding:4px 20px;margin-bottom:10px}
table{width:100%;border-collapse:collapse;font-size:14px}
td{padding:9px 0;border-bottom:1px solid var(--line);vertical-align:top}
tr:last-child td{border-bottom:0}
td:first-child{white-space:nowrap;padding-right:18px;width:1%}
code,kbd{font-family:ui-monospace,Menlo,monospace;font-size:13px}
kbd{display:inline-block;padding:1px 7px;border-radius:5px;border:1px solid var(--line);
background:var(--bg)}
b{font-weight:600}
</style></head><body><div class="wrap">
<h1>Guide</h1>
<div class="sub"><a id="nav-back" href="#">&larr; Dashboard</a> &middot;
<a id="nav-settings" href="#">Settings</a> &middot; <a id="nav-setup" href="#">Setup</a></div>
<div class="toc">
<a href="#g-launcher">Launcher</a><a href="#g-timer">Timer</a><a href="#g-pomodoro">Pomodoro</a>
<a href="#g-break">Break screen</a><a href="#g-dashboard">Dashboard</a>
<a href="#g-data">Your data</a><a href="#g-remove">Removing it</a></div>

<section id="g-launcher"><h2>Launcher</h2>
<p>Every command is typed into Spotlight or Alfred. They all start with
<b>__VERB__</b>.</p>
<div class="panel"><table>
<tr><td><code>__VERB__</code></td><td>Stop the running timer, or start the most recent category if nothing is running.</td></tr>
<tr><td><code>__VERB__ &lt;category&gt;</code></td><td>Start that category, or switch to it. Type its key, its name, or any of its keywords.</td></tr>
<tr><td><code>__VERB__ new</code></td><td>Create a category. The timer does not start.</td></tr>
<tr><td><code>__VERB__ dashboard</code></td><td>Today, this week, all time, and the recent sessions, in your browser.</td></tr>
<tr><td><code>__VERB__ settings</code></td><td>Durations, keys, Spotify, Reminders, the calendar, and your categories.</td></tr>
<tr><td><code>__VERB__ guide</code></td><td>This page.</td></tr>
<tr><td><code>__VERB__ categories</code></td><td>Edit names and keywords in a text editor.</td></tr>
<tr><td><code>__VERB__ data</code></td><td>Open the folder the log lives in.</td></tr>
<tr><td><code>__VERB__ spotify</code>, <code>__VERB__ reminders</code>, <code>__VERB__ calendar</code></td>
<td>Ask for that tool's permission and report what it can see. Nothing is changed.</td></tr>
</table></div></section>

<section id="g-timer"><h2>Timer</h2>
<p>Starting asks what you plan to do. Stopping asks what you did. Both answers are
optional and both are stored with the session. Switching categories stops one session
and starts the next, with one question for each.</p>
<p>A timer left running is stopped after eight hours and marked in the dashboard,
where you can correct its end time. There is no pause: a break is part of the session,
not an interruption of it.</p></section>

<section id="g-pomodoro"><h2>Pomodoro</h2>
<p>Tick <b>Pomodoro mode</b> when a session starts. After the work session a tomato
takes the whole screen and offers a break: <kbd>&crarr;</kbd> takes it,
<kbd>Esc</kbd> snoozes it, and Skip counts the pomodoro and starts the next work
session at once. With no answer, the break starts by itself after a minute.</p>
<p>Every fourth break is long. A break ends when you press <kbd>&crarr;</kbd> or
<b>I'm back</b>; time past the scheduled end is logged as overrun on that session.
The number of pomodoros and the overrun appear on the session in the dashboard.</p>
<p>When the tomato appears, music and video that can be reached are paused. A video
inside an embedded player may not be reachable; the screen says so and
<kbd>F8</kbd> pauses it by hand.</p></section>

<section id="g-break"><h2>Break screen</h2>
<p>A menu sits behind the button in the top left, or behind <kbd>Tab</kbd>. It holds
two tools, each of which appears only when it is on in Settings and its permission has
been granted.</p>
<div class="panel"><table>
<tr><td><b>Spotify</b></td><td>Your break playlists, transport buttons, and volume. Choosing a
playlist opens Spotify if it is closed. When the break ends the work playlist starts, if
you marked one, and otherwise the music is paused. If the break runs over while music you
started is playing, the music is paused.</td></tr>
<tr><td><b>Add Reminder</b></td><td>A note that is saved to a list of its own in Apple
Reminders. <kbd>&#8984;</kbd><kbd>&crarr;</kbd> saves it. A draft survives the break.</td></tr>
</table></div>
<p>Inside the menu, <kbd>s</kbd> opens Spotify and <kbd>n</kbd> the note; <kbd>Esc</kbd>
goes back and a click outside closes it. All three keys can be changed in Settings.</p></section>

<section id="g-dashboard"><h2>Dashboard</h2>
<p>Totals for today, this week and all time, a table per category, and the recent
sessions. A session can be edited, to fix an end time you forgot, or deleted. Deleted
sessions are moved to a file beside the log, not destroyed.</p>
<p>The dashboard is a small local web page. It runs only while you have it open, listens
only on this computer, and closes itself after ten idle minutes.</p></section>

<section id="g-data"><h2>Your data</h2>
<p>Everything is in <code>~/.timetrack</code>, readable only by your user, and every
file is plain text. Nothing is sent anywhere.</p>
<div class="panel"><table>
<tr><td><code>sessions.tsv</code></td><td>The log: start, end, duration, category, plan, recap, pomodoros, overrun.</td></tr>
<tr><td><code>categories.tsv</code></td><td>Key, name, keywords, last used, hidden.</td></tr>
<tr><td><code>settings.tsv</code></td><td>Only the settings you changed from the defaults.</td></tr>
<tr><td><code>spotify-playlists.tsv</code></td><td>Break playlists, and which one is for work.</td></tr>
<tr><td><code>paint-calendar</code>, <code>reminders-list</code></td><td>The calendar and the Reminders list the two tools write to.</td></tr>
</table></div>
<p>The calendar tool rewrites the last fourteen days of the chosen calendar to match the log
whenever a session changes, so give it an empty calendar of its own.</p></section>

<section id="g-remove"><h2>Removing it</h2>
<p>Run <code>uninstall.sh</code> from the folder you installed from. It removes the
launcher entries and the scripts and keeps your log; <code>--purge-data</code> removes
the log too. The three permissions stay listed in System Settings until you revoke them
there.</p></section>
</div><script>
const TOKEN=new URLSearchParams(location.search).get("t")||"";
const $=i=>document.getElementById(i);
$("nav-back").href="/?t="+encodeURIComponent(TOKEN);
$("nav-settings").href="/settings?t="+encodeURIComponent(TOKEN);
$("nav-setup").href="/setup?t="+encodeURIComponent(TOKEN);
</script></body></html>
"""


# --------------------------------------------------------------------------
# server
# --------------------------------------------------------------------------

class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "TimeTracker"
    token = ""

    def log_message(self, *_args):
        pass  # don't spam the console

    def _deny(self, code=403):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def _host_ok(self):
        # Only accept loopback Host values, so a public website can't point a
        # DNS name at 127.0.0.1 and read the page from the user's browser.
        host = (self.headers.get("Host") or "").split(":")[0]
        return host in ("127.0.0.1", "localhost", "[::1]", "::1")

    def do_GET(self):
        global _last_request
        _last_request = time.time()

        if not self._host_ok():
            return self._deny()

        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        supplied = (params.get("t") or [""])[0]
        if not secrets.compare_digest(supplied, self.token):
            return self._deny()

        if parsed.path == "/":
            body = (PAGE.replace("__CSS__", THEME_CSS)
                    .replace("__POLL__", str(POLL_MS)).encode("utf-8"))
            ctype = "text/html; charset=utf-8"
        elif parsed.path == "/settings":
            body = (SETTINGS_PAGE.replace("__CSS__", THEME_CSS)
                    .replace("__POLL__", str(POLL_MS))
                    .replace("__VERB__", VERB).encode("utf-8"))
            ctype = "text/html; charset=utf-8"
        elif parsed.path in ("/setup", "/guide"):
            page = SETUP_PAGE if parsed.path == "/setup" else GUIDE_PAGE
            body = (page.replace("__CSS__", THEME_CSS)
                    .replace("__VERB__", VERB).encode("utf-8"))
            ctype = "text/html; charset=utf-8"
        elif parsed.path == "/api/data":
            body = json.dumps(build_payload()).encode("utf-8")
            ctype = "application/json"
        elif parsed.path == "/api/settings":
            body = json.dumps({
                "settings": read_settings(),
                "tomato_found": os.path.exists(TOMATO_FOUND_FILE),
            }).encode("utf-8")
            ctype = "application/json"
        elif parsed.path == "/api/breakmenu":
            body = json.dumps({"playlists": read_playlists(),
                               "reminders_list": read_reminders_list(),
                               "paint_calendar": read_paint_calendar(),
                               "paint_choices": read_paint_choices(),
                               "paint_days": setting_int("paint_days", 14),
                               }).encode("utf-8")
            ctype = "application/json"
        elif parsed.path == "/api/categories":
            body = json.dumps(
                {"categories": build_categories()}).encode("utf-8")
            ctype = "application/json"
        else:
            return self._deny(404)

        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy",
                         "default-src 'none'; style-src 'unsafe-inline'; "
                         "script-src 'unsafe-inline'; connect-src 'self'")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(body)


    # ----- mutations --------------------------------------------------
    # Everything below exists so that one specific mistake — forgetting to stop
    # the timer — is fixable from the page you're already looking at.

    def _origin_ok(self):
        port = self.server.server_address[1]
        allowed = (f"http://127.0.0.1:{port}", f"http://localhost:{port}")
        # Browsers send Origin on every POST, same-origin included, so a
        # missing one means the request didn't come from the page.
        return (self.headers.get("Origin") or "") in allowed

    def _read_body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return None
        if length <= 0 or length > MAX_BODY:
            return None
        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return None

    def _run_action(self, args):
        """Hand the write to action.sh — argv list, never a shell string."""
        if not os.access(ACTION_SH, os.X_OK):
            return False, "action.sh not found next to dashboard.py"
        try:
            # errors="replace": a stray non-UTF-8 byte in action.sh's output
            # must garble one character, not kill the request thread.
            proc = subprocess.run([ACTION_SH] + [str(a) for a in args],
                                  capture_output=True, text=True,
                                  errors="replace", timeout=20)
        except (OSError, subprocess.SubprocessError) as exc:
            return False, f"could not run action.sh ({exc.__class__.__name__})"
        msg = (proc.stdout or "").strip() or (proc.stderr or "").strip()
        return proc.returncode == 0, msg or "done"

    def _sync_apps(self):
        """Rebuild the launcher bundles; returns a warning, or "" on success.

        Called only after action.sh has already accepted a category change.
        It takes no arguments — nothing from the request reaches it — and a
        failure here is cosmetic (a stale app in Spotlight), never data loss,
        so it degrades to a message instead of failing the mutation.
        """
        if not os.access(SYNC_APPS, os.X_OK):
            return "launcher not rebuilt (sync-apps.sh missing)"
        try:
            proc = subprocess.run([SYNC_APPS], capture_output=True, text=True,
                                  errors="replace", timeout=120)
        except (OSError, subprocess.SubprocessError):
            return "launcher not rebuilt; run sync-apps.sh by hand"
        if proc.returncode != 0:
            return "launcher may be stale; run sync-apps.sh by hand"
        return ""

    def do_POST(self):
        global _last_request
        _last_request = time.time()

        if not self._host_ok():
            return self._deny()

        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        supplied = (params.get("t") or [""])[0]
        if not secrets.compare_digest(supplied, self.token):
            return self._deny()

        # Three CSRF checks, each independently sufficient: a cross-origin page
        # can't set a custom header or a JSON content type without a preflight,
        # and OPTIONS is never answered here.
        header_token = self.headers.get("X-TimeTracker-Token") or ""
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip()
        if (not secrets.compare_digest(header_token, self.token)
                or ctype != "application/json"
                or not self._origin_ok()):
            return self._deny()

        body = self._read_body()
        if not isinstance(body, dict):
            return self._json(400, {"ok": False, "error": "bad request body"})

        def text(name, limit=500):
            v = body.get(name, "")
            return v[:limit] if isinstance(v, str) else ""

        def whole(name):
            v = body.get(name)
            return v if isinstance(v, int) and not isinstance(v, bool) else None

        if parsed.path == "/api/setconf":
            # One action.sh run per changed key, exactly like the session
            # mutations: the table in settings.sh is the authority, not this
            # server, and its message is passed through on rejection.
            changes = body.get("changes")
            if (not isinstance(changes, dict) or not changes
                    or len(changes) > 32):
                return self._json(400, {"ok": False, "error": "bad fields"})
            for k, v in changes.items():
                if (not isinstance(k, str) or not isinstance(v, str)
                        or not k or len(k) > 64 or len(v) > 64):
                    return self._json(400, {"ok": False, "error": "bad fields"})
            msgs = []
            for k, v in changes.items():
                ok, msg = self._run_action(["setconf", k, v])
                if not ok:
                    return self._json(409, {"ok": False, "message": msg})
                msgs.append(msg)
            return self._json(200, {"ok": True, "message": ". ".join(msgs)})

        if parsed.path == "/api/category/add":
            # The setup page's way of making a category; "time new" is the
            # other. Same writer, then the same rebuild of the launcher.
            cat_key = text("key", 60)
            if not cat_key:
                return self._json(400, {"ok": False, "error": "bad fields"})
            ok, msg = self._run_action(
                ["addcat", cat_key, text("name", 120), text("keywords", 200)])
            if ok:
                warn = self._sync_apps()
                if warn:
                    msg = f"{msg}. {warn}"
            return self._json(200 if ok else 409, {"ok": ok, "message": msg})

        if parsed.path == "/api/setup/done":
            ok, msg = self._run_action(["setupdone"])
            return self._json(200 if ok else 409, {"ok": ok, "message": msg})

        if parsed.path == "/api/grant":
            # Opens the launcher verb for one of the three tools, which is
            # exactly what typing it would do: the helper asks macOS for its
            # permission and reports back in a dialog. The bundle name is
            # built from a fixed list; nothing from the request is a path.
            tool = text("tool", 20)
            if tool not in ("spotify", "reminders", "calendar"):
                return self._json(400, {"ok": False, "error": "bad tool"})
            bundle = os.path.join(APPS_DIR, f"{VERB} {tool}.app")
            if not os.path.isdir(bundle):
                return self._json(409, {"ok": False,
                                        "message": f"The {tool} helper is not installed."})
            try:
                subprocess.run(["/usr/bin/open", "-g", bundle], check=False,
                               timeout=20)
            except (OSError, subprocess.SubprocessError):
                return self._json(409, {"ok": False,
                                        "message": f"Could not open the {tool} helper."})
            return self._json(200, {"ok": True,
                                    "message": "Asked. Answer the macOS prompt if one appears."})

        if parsed.path == "/api/paint/refresh":
            # Runs the helper so it can re-dump the calendar list — and, the
            # first time, so macOS can ask about calendar access. It takes no
            # arguments; nothing from the request reaches it.
            if not os.access(PAINT_SH, os.X_OK):
                return self._json(409, {"ok": False,
                                        "message": "paint-calendar.sh missing"})
            try:
                proc = subprocess.run([PAINT_SH, "--list"], capture_output=True,
                                      text=True, errors="replace", timeout=90)
            except (OSError, subprocess.SubprocessError):
                return self._json(409, {"ok": False,
                                        "message": "could not run the calendar helper"})
            msg = (proc.stdout or "").strip() or "done"
            return self._json(200, {"ok": proc.returncode == 0, "message": msg})

        if parsed.path == "/api/paint/calendar":
            # "" clears the choice, which is the honest way to turn painting
            # off without touching the setting.
            cal_name = text("name", 200)
            ok, msg = self._run_action(["setpaintcal", cal_name or "-"])
            return self._json(200 if ok else 409, {"ok": ok, "message": msg})

        if parsed.path in ("/api/playlist/add", "/api/playlist/delete",
                           "/api/playlist/work", "/api/reminders/list"):
            # The break menu's two lists. Same shape as every other mutation
            # here: validate the field is a plausible string, hand it to
            # action.sh, pass its message back unchanged. action.sh owns the
            # question of what a Spotify link is — this server does not parse
            # one, so it cannot disagree with the thing that stores it.
            if parsed.path == "/api/playlist/add":
                pl_name, pl_uri = text("name", 60), text("uri", 300)
                if not pl_name or not pl_uri:
                    return self._json(400, {"ok": False, "error": "bad fields"})
                ok, msg = self._run_action(["addplaylist", pl_name, pl_uri])
            elif parsed.path == "/api/playlist/delete":
                pl_uri = text("uri", 300)
                if not pl_uri:
                    return self._json(400, {"ok": False, "error": "bad fields"})
                ok, msg = self._run_action(["delplaylist", pl_uri])
            elif parsed.path == "/api/playlist/work":
                pl_uri = text("uri", 300)
                if not pl_uri:
                    return self._json(400, {"ok": False, "error": "bad fields"})
                ok, msg = self._run_action(["workplaylist", pl_uri])
            else:
                rl_name = text("name", 60)
                if not rl_name:
                    return self._json(400, {"ok": False, "error": "bad fields"})
                ok, msg = self._run_action(["setremlist", rl_name])
            return self._json(200 if ok else 409, {"ok": ok, "message": msg})

        if parsed.path in ("/api/category/hide", "/api/category/delete"):
            # Retiring a category is a two-step write: action.sh owns the TSV,
            # sync-apps.sh owns the bundles. Only the first can fail the
            # request; the second is reported and moved past.
            cat_key = text("key", 120)
            if not cat_key:
                return self._json(400, {"ok": False, "error": "bad category"})
            if parsed.path == "/api/category/hide":
                want = body.get("hidden")
                if not isinstance(want, bool):
                    return self._json(400, {"ok": False, "error": "bad fields"})
                ok, msg = self._run_action(
                    ["hidecat", cat_key, "on" if want else "off"])
            else:
                ok, msg = self._run_action(["delcat", cat_key])
            if ok:
                warn = self._sync_apps()
                if warn:
                    msg = f"{msg}. {warn}"
            return self._json(200 if ok else 409, {"ok": ok, "message": msg})

        sel_start, sel_key = text("start", 40), text("key", 120)
        sel_dur = whole("dur")
        if not sel_start or not sel_key or sel_dur is None or sel_dur < 0:
            return self._json(400, {"ok": False, "error": "bad session selector"})

        if parsed.path == "/api/session/delete":
            ok, msg = self._run_action(
                ["delsession", sel_start, sel_dur, sel_key])
        elif parsed.path == "/api/session/update":
            new_start, new_end = whole("new_start"), whole("new_end")
            new_key = text("new_key", 120)
            if new_start is None or new_end is None or not new_key:
                return self._json(400, {"ok": False, "error": "bad fields"})
            ok, msg = self._run_action(
                ["editsession", sel_start, sel_dur, sel_key,
                 new_start, new_end, new_key, text("plan"), text("recap")])
        else:
            return self._deny(404)

        return self._json(200 if ok else 409, {"ok": ok, "message": msg})


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def existing_server():
    """(port, token) of an already-running dashboard, if it still answers."""
    try:
        with open(HANDOFF_FILE, encoding="utf-8") as f:
            port, token = f.read().split()
    except (OSError, ValueError):
        return None
    try:
        req = urllib.request.Request(f"http://127.0.0.1:{port}/api/data?t={token}")
        with urllib.request.urlopen(req, timeout=0.6) as resp:
            if resp.status == 200:
                return port, token
    except Exception:
        return None
    return None


def open_browser(url):
    # subprocess with an argv list, never a shell string: the URL must never be
    # word-split or interpreted by a shell, whatever ends up in it.
    subprocess.run(["/usr/bin/open", url], check=False)


def idle_reaper(httpd):
    while True:
        time.sleep(15)
        if time.time() - _last_request > IDLE_TIMEOUT:
            httpd.shutdown()
            return


def main(page="/"):
    existing = existing_server()
    if existing:
        # Already running (e.g. "time dashboard" invoked twice) — just refocus,
        # on whichever page this launch asked for.
        port, token = existing
        if "--no-open" not in sys.argv[1:]:
            open_browser(f"http://127.0.0.1:{port}{page}?t={token}")
        return

    token = secrets.token_urlsafe(24)
    Handler.token = token

    httpd = Server(("127.0.0.1", 0), Handler)
    port = httpd.socket.getsockname()[1]

    old = os.umask(0o077)  # token file is readable only by this user
    try:
        with open(HANDOFF_FILE, "w", encoding="utf-8") as f:
            f.write(f"{port} {token}\n")
    finally:
        os.umask(old)

    url = f"http://127.0.0.1:{port}{page}?t={token}"
    threading.Thread(target=idle_reaper, args=(httpd,), daemon=True).start()
    if "--no-open" not in sys.argv[1:]:
        open_browser(url)

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        try:
            os.remove(HANDOFF_FILE)
        except OSError:
            pass


def first_run():
    """No setup marker and no categories: nothing has been set up yet.

    Either one ends it. Finishing the setup page writes the marker; making a
    category any other way means the person found their way without it, and
    the page must not keep appearing in front of someone who did.
    """
    return not os.path.exists(SETUP_DONE_FILE) and not read_categories()


if __name__ == "__main__":
    if not os.path.isdir(DATA_DIR):
        sys.exit(f"No data directory at {DATA_DIR}. Run install.sh first.")
    # The launcher verbs pass one of these; the path is fixed here and never
    # comes from user input.
    args = sys.argv[1:]
    if "--settings" in args:
        start = "/settings"
    elif "--guide" in args:
        start = "/guide"
    elif "--setup" in args:
        start = "/setup"
    else:
        start = "/setup" if first_run() else "/"
    main(start)
