#!/usr/bin/env python3
"""TimeTracker's local server: the app's window onto the data.

    dashboard.py --app        what TimeTracker.app runs: prints "<port> <token>"
                              and serves until the app that started it is gone
    dashboard.py [--page P]   without the app (no compiler, so none was built):
                              opens the same page in the browser instead

It serves one page, app.html, and the JSON that page draws from, on
127.0.0.1. It reads the TSV files directly — totals have to include the
segment still running, which is not in the log yet — and it writes nothing
itself: every change is handed to action.sh, which holds the lock and is the
only writer of the log, the categories and the settings. Starting goes
through start.sh, so a session started from the window arms its pomodoro
exactly as one started from the launcher. Friends go through the chat
helper, the only program that touches friends.tsv.

It used to be the dashboard, a page in the browser that could correct the
log but not start or stop a timer. It can now, because the window it serves
is meant to be the whole program for whoever never learns the launcher. The
reasoning that kept it read-only was that a page should not be able to start
work behind your back; the protections below are what make that hold for the
page that is meant to:

  * binds 127.0.0.1 only, on an ephemeral port
  * requires a random per-run token on every request
  * validates the Host header (blocks DNS-rebinding from a web page)
  * mutations are POST-only and additionally require the token in a custom
    header, a JSON content type, and a matching Origin — a cross-origin page
    can send none of those without a preflight, and no preflight is answered
  * no directory serving, no user input reaching the filesystem or a shell
  * exits with the app that started it, or, in the browser, after ten
    minutes without a request
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
HERE = os.path.dirname(os.path.abspath(__file__))
SESS_FILE = os.path.join(DATA_DIR, "sessions.tsv")
STATE_FILE = os.path.join(DATA_DIR, "state")
CAT_FILE = os.path.join(DATA_DIR, "categories.tsv")
HANDOFF_FILE = os.path.join(DATA_DIR, ".dashboard")
POMO_FILE = os.path.join(DATA_DIR, "pomodoro")
BACKUP_DIR = os.path.join(DATA_DIR, "backups")
# The break menu's two lists. Read here, written only by action.sh.
PLAYLIST_FILE = os.path.join(DATA_DIR, "spotify-playlists.tsv")
REMLIST_FILE = os.path.join(DATA_DIR, "reminders-list")
# Which calendar the log gets painted onto, and the list of ones it could be.
# The list is a dump the helper refreshes; this server never asks EventKit
# anything itself, because it has no calendar permission and should not.
PAINTCAL_FILE = os.path.join(DATA_DIR, "paint-calendar")
PAINTLIST_FILE = os.path.join(DATA_DIR, ".paint-calendars.tsv")
# Two markers, both written by something other than this server. The overlay
# touches the first the moment the easter egg is opened, and the settings
# show the game's own switch only once it exists: a settings page is not the
# place to learn there is a game. action.sh writes the second when the
# first-run setup finishes.
TOMATO_FOUND_FILE = os.path.join(DATA_DIR, ".tomato-found")
SETUP_DONE_FILE = os.path.join(DATA_DIR, ".setup-done")
APPS_DIR = (os.environ.get("TIMETRACK_APPS_DIR")
            or os.path.expanduser("~/Applications/TimeTracker"))
VERB = os.environ.get("TIMETRACK_VERB") or "time"

# Everything this runs lives beside it, and takes its arguments as argv.
ACTION_SH = os.path.join(HERE, "action.sh")
START_SH = os.path.join(HERE, "start.sh")
SYNC_APPS = os.path.join(HERE, "sync-apps.sh")
SETTINGS_SH = os.path.join(HERE, "settings.sh")
PAINT_SH = os.path.join(HERE, "paint-calendar.sh")
UPDATE_SH = os.path.join(HERE, "update.sh")
APP_HTML = os.path.join(HERE, "app.html")
VERSION_FILE = os.path.join(HERE, "VERSION")
CHAT_BIN = os.path.join(APPS_DIR, "TimeTracker Chat.app", "Contents", "MacOS", "ttchat")

MAX_BODY = 8192  # a mutation request is a few hundred bytes; cap it well below
IDLE_TIMEOUT = 600  # browser mode: seconds without a request before exiting

_last_request = time.time()


# --------------------------------------------------------------------------
# data
# --------------------------------------------------------------------------

def read_categories():
    """key -> {name, keywords, last, hidden}. The log stores keys only.

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
                    try:
                        last = int(p[3])
                    except ValueError:
                        last = 0
                    cats[p[0]] = {"name": p[1], "keywords": p[2], "last": last,
                                  "hidden": len(p) > 4 and p[4] == "1"}
    except OSError:
        pass
    return cats


def title_of(key, cats):
    """What a category is called on screen: its name, or its key if it has none.

    The key is a course code more often than not, which is how its owner
    thinks of it in a launcher and not how anybody reads a list.
    """
    c = cats.get(key)
    return (c and c["name"]) or key


def read_playlists():
    """The break menu's Spotify rows, in file order: {uri, name, work}."""
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


def first_line(path, default=""):
    try:
        with open(path, encoding="utf-8") as f:
            return f.readline().strip() or default
    except OSError:
        return default


def read_paint_choices():
    """Calendars the helper last reported as writable: [{title, source}].

    Empty until the calendar helper has run once — this server cannot ask
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


def read_state():
    line = first_line(STATE_FILE)
    parts = line.split("\t")
    # RUNNING is the only live status; anything else is corrupt, not a timer.
    if len(parts) < 3 or parts[0] != "RUNNING" or not parts[1]:
        return None
    try:
        start = int(parts[2])
    except ValueError:
        return None
    return {"key": parts[1], "start": start,
            "plan": parts[3] if len(parts) > 3 else ""}


def parse_iso(value):
    """Epoch for a logged timestamp, or None if it doesn't parse."""
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
                p = line.rstrip("\n").split("\t")
                if len(p) < 4:
                    continue
                try:
                    dur = int(p[2])
                except ValueError:
                    continue
                # Rows logged before a column existed simply have fewer fields.
                rows.append({
                    "start": p[0], "end": p[1], "dur": dur, "key": p[3],
                    "note": p[4] if len(p) > 4 else "",
                    "plan": p[5] if len(p) > 5 else "",
                    "recap": p[6] if len(p) > 6 else "",
                    "pomodoros": p[7] if len(p) > 7 else "",
                    "overrun": p[8] if len(p) > 8 else "",
                    "start_ep": parse_iso(p[0]),
                    "end_ep": parse_iso(p[1]),
                })
    except OSError:
        pass
    return rows


def read_pomodoro(state):
    """The live cycle, or None — only while it matches the running segment.

    A stale file from a killed watcher is not a live cycle.
    """
    if not state:
        return None
    p = first_line(POMO_FILE).split("\t")
    if len(p) < 7 or p[0] not in ("WORK", "BREAK"):
        return None
    try:
        seg, target, done, over = int(p[2]), int(p[3]), int(p[4]), int(p[5])
    except ValueError:
        return None
    if p[1] != state["key"] or seg != state["start"]:
        return None
    return {"phase": p[0], "target": target, "completed": done, "overrun": over}


def read_settings():
    """Every setting via settings.sh, the table's one home.

    A list of {key, value, default, min, max, step, kind}. Empty means the
    helper is missing or broken, which the page says rather than guessing.
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
        proc = subprocess.run(["/bin/bash", "-c", script, "bash", SETTINGS_SH],
                              capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return []
    if proc.returncode != 0:
        return []

    def num(x):
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
        kind = "key" if p[6] else ("number" if p[3] else "onoff")
        out.append({"key": p[0], "value": p[1], "default": p[2],
                    "min": num(p[3]), "max": num(p[4]),
                    "step": 0.1 if p[5] else 1, "kind": kind})
    return out


def setting(key, default=""):
    for s in read_settings():
        if s["key"] == key:
            return s["value"]
    return default


def backups():
    try:
        names = sorted(d for d in os.listdir(BACKUP_DIR)
                       if os.path.isdir(os.path.join(BACKUP_DIR, d)) and d[:1].isdigit())
    except OSError:
        names = []
    return {"count": len(names), "newest": names[-1][:8] if names else ""}


def needs_setup():
    """No setup marker and no categories: nothing has been set up yet.

    Either one ends it. Finishing the setup writes the marker; making a
    category some other way means the person found their way without it.
    """
    return not os.path.exists(SETUP_DONE_FILE) and not read_categories()


# --------------------------------------------------------------------------
# payloads
# --------------------------------------------------------------------------

def subjects(cats, rows, running_key):
    """Every category, with what is logged under it.

    Keys that exist only in the log — a deleted category's history — are
    listed too, as such: this is the one place that admits where it went.
    """
    counts, totals = {}, {}
    for r in rows:
        counts[r["key"]] = counts.get(r["key"], 0) + 1
        totals[r["key"]] = totals.get(r["key"], 0) + r["dur"]
    out = []
    for key in set(cats) | set(counts):
        c = cats.get(key)
        out.append({
            "key": key,
            "title": title_of(key, cats),
            "name": c["name"] if c else "",
            "keywords": c["keywords"] if c else "",
            "hidden": bool(c and c["hidden"]),
            "orphan": c is None,
            "last": c["last"] if c else 0,
            "sessions": counts.get(key, 0),
            "total": totals.get(key, 0),
            "running": key == running_key,
        })
    out.sort(key=lambda s: -s["last"])
    return out


def build_state():
    now = int(time.time())
    today = datetime.date.today()
    week_start = today - datetime.timedelta(days=today.weekday())
    rows = read_sessions()
    state = read_state()
    cats = read_categories()

    day_t = week_t = 0
    for r in rows:
        try:
            day = datetime.date.fromisoformat(r["start"][:10])
        except ValueError:
            continue
        if day == today:
            day_t += r["dur"]
        if day >= week_start:
            week_t += r["dur"]

    running = None
    if state:
        elapsed = max(0, now - state["start"])
        day_t += elapsed
        week_t += elapsed
        running = {"key": state["key"], "title": title_of(state["key"], cats),
                   "start": state["start"], "elapsed": elapsed,
                   "plan": state["plan"]}

    return {
        "running": running,
        "pomodoro": read_pomodoro(state),
        "cycle": int(setting("long_break_every", "4") or 4),
        "pomodoro_default": setting("pomodoro_default", "off") == "on",
        "today": day_t,
        "week": week_t,
        "subjects": subjects(cats, rows, state and state["key"]),
        "setup": needs_setup(),
        "verb": VERB,
        "now": now,
    }


def build_history():
    now = int(time.time())
    today = datetime.date.today()
    week_start = today - datetime.timedelta(days=today.weekday())
    rows = read_sessions()
    state = read_state()
    cats = read_categories()

    by = {}
    totals = {"today": 0, "week": 0, "all": 0}

    def add(key, dur, day):
        t = by.setdefault(key, {"key": key, "title": title_of(key, cats),
                                "today": 0, "week": 0, "all": 0})
        t["all"] += dur
        totals["all"] += dur
        if day == today:
            t["today"] += dur
            totals["today"] += dur
        if day and day >= week_start:
            t["week"] += dur
            totals["week"] += dur

    for r in rows:
        try:
            day = datetime.date.fromisoformat(r["start"][:10])
        except ValueError:
            day = None
        add(r["key"], r["dur"], day)
    if state:
        add(state["key"], max(0, now - state["start"]), today)

    # Sorted by start rather than by file order, so a row whose start was
    # corrected lands where it belongs instead of at the end of the log.
    ordered = sorted(rows, key=lambda r: (r["start_ep"] is None, r["start_ep"] or 0))
    recent = []
    for r in ordered[-200:][::-1]:
        d = dict(r)
        d["title"] = title_of(r["key"], cats)
        recent.append(d)
    return {
        "totals": totals,
        "table": sorted(by.values(), key=lambda t: -t["all"]),
        "sessions": recent,
        "choices": [{"key": k, "title": title_of(k, cats)}
                    for k in sorted(set(cats) | {r["key"] for r in rows})],
        "running": state["key"] if state else None,
    }


def build_settings():
    return {
        "settings": read_settings(),
        "found": os.path.exists(TOMATO_FOUND_FILE),
        "playlists": read_playlists(),
        "reminders_list": first_line(REMLIST_FILE, "Pause Notes"),
        "paint_calendar": first_line(PAINTCAL_FILE),
        "paint_choices": read_paint_choices(),
        "version": first_line(VERSION_FILE, "unknown"),
        "backups": backups(),
        "data_dir": DATA_DIR.replace(os.path.expanduser("~"), "~", 1),
    }


# --------------------------------------------------------------------------
# the launcher bundles
# --------------------------------------------------------------------------
# A category change has to rebuild the launcher bundles, and sync-apps.sh
# rebuilds all of them: a few seconds with a dozen categories. Run once per
# change, the onboarding's five new subjects were half a minute of it, and a
# second run could start before the first had finished. So changes only ask,
# and the rebuild happens once, a moment after the last of them.

_sync_lock = threading.Lock()
_sync_timer = None


def _sync_now():
    global _sync_timer
    with _sync_lock:
        _sync_timer = None
    if os.access(SYNC_APPS, os.X_OK):
        try:
            subprocess.run([SYNC_APPS], capture_output=True, timeout=300)
        except (OSError, subprocess.SubprocessError):
            pass


def schedule_sync():
    global _sync_timer
    with _sync_lock:
        if _sync_timer:
            _sync_timer.cancel()
        _sync_timer = threading.Timer(1.5, _sync_now)
        _sync_timer.daemon = True
        _sync_timer.start()


def flush_sync():
    """Run a rebuild still waiting, before the process goes."""
    with _sync_lock:
        pending = _sync_timer
        if pending:
            pending.cancel()
    if pending:
        _sync_now()


# --------------------------------------------------------------------------
# server
# --------------------------------------------------------------------------

def run(argv, timeout=30):
    """Run one of the scripts beside this file — argv list, never a shell."""
    try:
        # errors="replace": a stray non-UTF-8 byte in the output must garble
        # one character, not kill the request thread.
        proc = subprocess.run([str(a) for a in argv], capture_output=True,
                              text=True, errors="replace", timeout=timeout)
    except (OSError, subprocess.SubprocessError) as exc:
        return False, f"could not run {os.path.basename(str(argv[0]))} ({exc.__class__.__name__})"
    msg = (proc.stdout or "").strip() or (proc.stderr or "").strip()
    return proc.returncode == 0, msg


def action(*args):
    if not os.access(ACTION_SH, os.X_OK):
        return False, "action.sh is missing"
    ok, msg = run([ACTION_SH] + list(args))
    return ok, msg or "Done"


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "TimeTracker"
    token = ""

    def log_message(self, *_args):
        pass

    def _deny(self, code=403):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        # img-src data: is for the <select> arrow and the subject marks,
        # drawn as inline SVG. A data: image carries its bytes with it, so
        # this admits nothing from the network, and an SVG used as an image
        # runs no script and loads nothing further.
        self.send_header("Content-Security-Policy",
                         "default-src 'none'; style-src 'unsafe-inline'; "
                         "script-src 'unsafe-inline'; connect-src 'self'; "
                         "img-src data:; base-uri 'none'; form-action 'none'")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj).encode("utf-8"), "application/json")

    def _host_ok(self):
        # Only loopback Host values, so a public website can't point a DNS
        # name at 127.0.0.1 and read the page from the user's browser.
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0]
        return host in ("127.0.0.1", "localhost", "[::1]")

    def _token_ok(self, parsed):
        supplied = (urllib.parse.parse_qs(parsed.query).get("t") or [""])[0]
        return secrets.compare_digest(supplied, self.token)

    def do_GET(self):
        global _last_request
        _last_request = time.time()
        parsed = urllib.parse.urlparse(self.path)
        if not self._host_ok() or not self._token_ok(parsed):
            return self._deny()
        if parsed.path == "/":
            try:
                with open(APP_HTML, "rb") as f:
                    body = f.read()
            except OSError:
                return self._send(500, b"app.html is missing", "text/plain")
            return self._send(200, body, "text/html; charset=utf-8")
        if parsed.path == "/api/state":
            return self._json(200, build_state())
        if parsed.path == "/api/history":
            return self._json(200, build_history())
        if parsed.path == "/api/settings":
            return self._json(200, build_settings())
        if parsed.path == "/api/friends":
            return self._json(200, friends_list())
        return self._deny(404)

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

    def do_POST(self):
        global _last_request
        _last_request = time.time()
        parsed = urllib.parse.urlparse(self.path)
        if not self._host_ok() or not self._token_ok(parsed):
            return self._deny()
        # Three CSRF checks, each independently sufficient: a cross-origin page
        # can't set a custom header or a JSON content type without a preflight,
        # and OPTIONS is never answered here.
        header_token = self.headers.get("X-TimeTracker-Token") or ""
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip()
        if (not secrets.compare_digest(header_token, self.token)
                or ctype != "application/json" or not self._origin_ok()):
            return self._deny()
        body = self._read_body()
        if not isinstance(body, dict):
            return self._json(400, {"ok": False, "message": "Bad request"})

        def text(name, limit=500):
            v = body.get(name, "")
            return v[:limit] if isinstance(v, str) else ""

        def whole(name):
            v = body.get(name)
            return v if isinstance(v, int) and not isinstance(v, bool) else None

        handler = POSTS.get(parsed.path)
        if not handler:
            return self._deny(404)
        result = handler(text, whole, body)
        ok, msg = result[0], result[1]
        extra = result[2] if len(result) > 2 else {}
        return self._json(200 if ok else 409, dict({"ok": ok, "message": msg}, **extra))


# --- the mutations -----------------------------------------------------------
# Each returns (ok, message[, extra]). Each validates that a field is a
# plausible string or number and hands it on; the script it hands it to is
# the authority on what the field may be, and its message is passed through.

def post_start(text, whole, body):
    key = text("key", 120)
    if not key:
        return False, "No subject"
    if not os.access(START_SH, os.X_OK):
        return False, "start.sh is missing"
    pomo = "1" if body.get("pomodoro") is True else "0"
    ok, msg = run([START_SH, key, "--answer", pomo, text("plan"), text("recap")])
    return ok, msg or "Started"


def post_stop(text, whole, body):
    return action("stop", text("recap"))


def post_plan(text, whole, body):
    return action("plan", text("plan"))


def post_setconf(text, whole, body):
    # One action.sh run per changed key: the table in settings.sh is the
    # authority, not this server, and its message is passed on when it says no.
    changes = body.get("changes")
    if not isinstance(changes, dict) or not changes or len(changes) > 32:
        return False, "Bad fields"
    for k, v in changes.items():
        if not isinstance(k, str) or not isinstance(v, str) or not k or len(k) > 64 or len(v) > 64:
            return False, "Bad fields"
    msgs = []
    for k, v in changes.items():
        ok, msg = action("setconf", k, v)
        if not ok:
            return False, msg
        msgs.append(msg)
    return True, ". ".join(msgs)


def post_category_add(text, whole, body):
    key = text("key", 60)
    if not key:
        return False, "A subject needs a name"
    ok, msg = action("addcat", key, text("name", 120), text("keywords", 200))
    if ok:
        schedule_sync()
    return ok, msg


def post_category_edit(text, whole, body):
    ok, msg = action("editcat", text("key", 120), text("name", 120), text("keywords", 200))
    if ok:
        schedule_sync()
    return ok, msg


def post_category_hide(text, whole, body):
    want = body.get("hidden")
    if not isinstance(want, bool):
        return False, "Bad fields"
    ok, msg = action("hidecat", text("key", 120), "on" if want else "off")
    if ok:
        schedule_sync()
    return ok, msg


def post_category_delete(text, whole, body):
    ok, msg = action("delcat", text("key", 120))
    if ok:
        schedule_sync()
    return ok, msg


def post_setup_done(text, whole, body):
    return action("setupdone")


def selector(text, whole):
    start, key, dur = text("start", 40), text("key", 120), whole("dur")
    if not start or not key or dur is None or dur < 0:
        return None
    return start, dur, key


def post_session_update(text, whole, body):
    sel = selector(text, whole)
    ns, ne, nk = whole("new_start"), whole("new_end"), text("new_key", 120)
    if not sel or ns is None or ne is None or not nk:
        return False, "Bad fields"
    return action("editsession", *sel, ns, ne, nk, text("plan"), text("recap"))


def post_session_delete(text, whole, body):
    sel = selector(text, whole)
    if not sel:
        return False, "Bad fields"
    return action("delsession", *sel)


def post_playlist_add(text, whole, body):
    return action("addplaylist", text("name", 60), text("uri", 300))


def post_playlist_delete(text, whole, body):
    return action("delplaylist", text("uri", 300))


def post_playlist_work(text, whole, body):
    return action("workplaylist", text("uri", 300) or "-")


def post_reminders_list(text, whole, body):
    return action("setremlist", text("name", 60))


def post_paint_calendar(text, whole, body):
    # "" clears the choice, which turns painting off without the setting.
    return action("setpaintcal", text("name", 200) or "-")


def post_paint_refresh(text, whole, body):
    # Runs the helper so it can list the calendars again, and the first time
    # so macOS can ask about access. Nothing from the request reaches it.
    if not os.access(PAINT_SH, os.X_OK):
        return False, "The calendar helper is missing"
    ok, msg = run([PAINT_SH, "--list"], timeout=90)
    return ok, msg or "Done"


def post_grant(text, whole, body):
    # Opens the launcher verb for one tool, which is exactly what typing it
    # would do: the helper asks macOS for its permission and reports back.
    # The bundle name is built from a fixed list.
    tool = text("tool", 20)
    if tool not in ("spotify", "reminders", "calendar"):
        return False, "Unknown tool"
    bundle = os.path.join(APPS_DIR, f"{VERB} {tool}.app")
    if not os.path.isdir(bundle):
        return False, "That helper is not installed"
    ok, _ = run(["/usr/bin/open", "-g", bundle], timeout=20)
    return ok, "Answer the macOS prompt if one appears" if ok else "Could not open the helper"


def post_open_data(text, whole, body):
    ok, _ = run(["/usr/bin/open", DATA_DIR], timeout=20)
    return ok, "Opened" if ok else "Could not open the folder"


def post_update_check(text, whole, body):
    if not os.access(UPDATE_SH, os.X_OK):
        return False, "The updater is missing"
    ok, out = run([UPDATE_SH, "--check"], timeout=60)
    installed, _, latest = out.partition("\t")
    if not latest:
        return False, "Could not check for updates", {"installed": installed}
    return True, "", {"installed": installed, "latest": latest}


def post_update_run(text, whole, body):
    # Detached, and in a session of its own: the installer stops this server
    # and replaces the app it belongs to, and the update must outlive both.
    # The app notices its server went and its version changed, and relaunches.
    if not os.access(UPDATE_SH, os.X_OK):
        return False, "The updater is missing"
    try:
        subprocess.Popen([UPDATE_SH, "--yes"], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    except OSError:
        return False, "Could not start the update"
    return True, "Updating"


# --- friends -----------------------------------------------------------------
# The chat helper owns friends.tsv and everything else Messages keeps; this
# only asks it things. "list" reads files and touches no network; the rest
# reach the relay, and only when somebody pressed something.

def chat(*args, timeout=30):
    if not os.access(CHAT_BIN, os.X_OK):
        return False, "Messages is not installed"
    return run([CHAT_BIN] + list(args), timeout=timeout)


def friends_list():
    on = setting("chat", "off") == "on"
    ok, out = chat("list", DATA_DIR)
    try:
        data = json.loads(out) if ok else {}
    except ValueError:
        data = {}
    if not isinstance(data, dict):
        data = {}
    data["on"] = on
    data["installed"] = os.access(CHAT_BIN, os.X_OK)
    return data


def post_friends(verb, *fields):
    def handler(text, whole, body):
        args = [text(f, 60) for f in fields]
        if any(not a for a in args):
            return False, "Bad fields"
        return chat(verb, DATA_DIR, *args)
    return handler


def post_friends_refresh(text, whole, body):
    if setting("chat", "off") != "on":
        return True, ""
    ok, msg = chat("inbox", DATA_DIR)
    return ok, msg


POSTS = {
    "/api/start": post_start,
    "/api/stop": post_stop,
    "/api/plan": post_plan,
    "/api/setconf": post_setconf,
    "/api/category/add": post_category_add,
    "/api/category/edit": post_category_edit,
    "/api/category/hide": post_category_hide,
    "/api/category/delete": post_category_delete,
    "/api/setup/done": post_setup_done,
    "/api/session/update": post_session_update,
    "/api/session/delete": post_session_delete,
    "/api/playlist/add": post_playlist_add,
    "/api/playlist/delete": post_playlist_delete,
    "/api/playlist/work": post_playlist_work,
    "/api/reminders/list": post_reminders_list,
    "/api/paint/calendar": post_paint_calendar,
    "/api/paint/refresh": post_paint_refresh,
    "/api/grant": post_grant,
    "/api/open/data": post_open_data,
    "/api/update/check": post_update_check,
    "/api/update/run": post_update_run,
    "/api/friends/name": post_friends("setname", "name"),
    "/api/friends/add": post_friends("add", "user"),
    "/api/friends/accept": post_friends("accept", "id"),
    "/api/friends/ignore": post_friends("ignore", "id"),
    "/api/friends/rename": post_friends("rename", "id", "name"),
    "/api/friends/remove": post_friends("forget", "id"),
    "/api/friends/refresh": post_friends_refresh,
}


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def existing_server():
    """(port, token) of an already-running browser-mode server, if it answers."""
    try:
        with open(HANDOFF_FILE, encoding="utf-8") as f:
            port, token = f.read().split()
    except (OSError, ValueError):
        return None
    try:
        req = urllib.request.Request(f"http://127.0.0.1:{port}/api/state?t={token}")
        with urllib.request.urlopen(req, timeout=0.6) as resp:
            if resp.status == 200:
                return port, token
    except Exception:
        return None
    return None


def reaper(httpd, app_mode):
    """Shut down with the app that started this, or after ten idle minutes.

    In the app the page polls every two seconds while its window is open,
    and the window closing quits the app, so the parent going away is the
    signal; a quiet minute is not, because a hidden window polls less.
    """
    parent = os.getppid()
    while True:
        time.sleep(2)
        if app_mode:
            if os.getppid() != parent:
                break
        elif time.time() - _last_request > IDLE_TIMEOUT:
            break
    httpd.shutdown()


def main(app_mode, page):
    if not app_mode:
        existing = existing_server()
        if existing:
            port, token = existing
            subprocess.run(["/usr/bin/open", f"http://127.0.0.1:{port}/?t={token}#{page}"],
                           check=False)
            return
    token = secrets.token_urlsafe(24)
    Handler.token = token
    httpd = Server(("127.0.0.1", 0), Handler)
    port = httpd.socket.getsockname()[1]
    threading.Thread(target=reaper, args=(httpd, app_mode), daemon=True).start()
    if app_mode:
        # The app reads this one line and loads the page; nothing else is
        # ever written here.
        print(f"{port} {token}", flush=True)
    else:
        old = os.umask(0o077)  # the token file is readable only by this user
        try:
            with open(HANDOFF_FILE, "w", encoding="utf-8") as f:
                f.write(f"{port} {token}\n")
        finally:
            os.umask(old)
        # argv, never a shell string: the URL is never word-split.
        subprocess.run(["/usr/bin/open", f"http://127.0.0.1:{port}/?t={token}#{page}"],
                       check=False)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        flush_sync()
        if not app_mode:
            try:
                os.remove(HANDOFF_FILE)
            except OSError:
                pass


PAGES = ("now", "history", "subjects", "friends", "settings", "help")

if __name__ == "__main__":
    if not os.path.isdir(DATA_DIR):
        sys.exit(f"No data folder at {DATA_DIR}. Install TimeTracker first.")
    args = sys.argv[1:]
    page = "now"
    if "--page" in args:
        i = args.index("--page")
        if i + 1 < len(args) and args[i + 1] in PAGES:
            page = args[i + 1]
    main("--app" in args, page)
