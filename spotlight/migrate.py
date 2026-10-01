#!/usr/bin/env python3
"""Brings the data directory up to the format this version reads.

    migrate.py --install <from> <to>     what install.sh runs, every time

One command, three jobs, in an order that is the whole point of having one
command:

  1. Refuse data written by a newer version. A newer TimeTracker may have
     added a column this one would silently drop on its next rewrite, and an
     update that loses a column of somebody's log is the one failure an
     updater must not have. Exit 3, nothing touched.
  2. Snapshot the data into backups/<stamp>-<from>-to-<to>/ before a byte of
     it is rewritten, and keep the newest ten. A reinstall of the same
     version snapshots too: it is cheap, and "the update did something" is
     a claim worth being able to check against what was there before.
  3. Run every step this version knows, in order, then write the number of
     the last one to data-version.

Every step is idempotent and decides for itself whether there is anything to
do, by looking at the data rather than at data-version. That file is a
ceiling for step 1, not a cursor: installs that predate it have none, and a
step that trusted it would skip work an older install still needs.

Steps:

  1  keyed categories. categories.tsv was `name<TAB>last_used` and the log
     stored the full name, so renaming a course orphaned its history. Now
     the log stores a stable key, and the name is display only.
  2  full-width headers. sessions.tsv gained plan, recap and the pomodoro
     columns, and categories.tsv the hidden one. Old rows keep fewer fields,
     which every reader tolerates; the header has to advertise the full width
     or a spreadsheet will refuse the wider rows.

There used to be a seed here: four example courses for a fresh install to
look at. It was removed because an install with categories never opens its
setup page, so the seed hid the one screen that would have explained it, and
a new user's first job became deleting somebody else's courses.
"""
import os
import re
import shutil
import sys
import time

DATA_DIR = os.environ.get("TIMETRACK_DIR") or os.path.expanduser("~/.timetrack")
CAT_FILE = os.path.join(DATA_DIR, "categories.tsv")
SESS_FILE = os.path.join(DATA_DIR, "sessions.tsv")
STATE_FILE = os.path.join(DATA_DIR, "state")
VERSION_FILE = os.path.join(DATA_DIR, "data-version")
BACKUP_DIR = os.path.join(DATA_DIR, "backups")

# The number of the last step below. Raise it with every step added, and
# never reuse one.
DATA_VERSION = 2
KEEP_BACKUPS = 10

CAT_HEADER = "key\tname\tkeywords\tlast_used_epoch\thidden"
SESS_HEADER = ("start_iso\tend_iso\tduration_sec\tcategory\tnote"
               "\tplan\trecap\tpomodoros\tbreak_overrun_sec")
COURSE_CODE = re.compile(r"([A-ZÆØÅ]{2,4}\s?\d{4})", re.IGNORECASE)

# Dotfiles worth keeping. The rest of the dotfiles are a break in progress —
# the overlay's heartbeat, a command on its way to a helper, a server's
# token — and restoring one of those would restore a moment, not data.
KEEP_DOTFILES = {".setup-done", ".tomato-found", ".paint-adopted",
                 ".paint-calendars.tsv"}
MAX_BACKUP_FILE = 50 << 20


def say(msg):
    print(msg, flush=True)


def write_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


# --------------------------------------------------------------------------
# the ceiling
# --------------------------------------------------------------------------

def data_version():
    try:
        with open(VERSION_FILE, encoding="utf-8") as f:
            return int(f.read().strip() or 0)
    except (OSError, ValueError):
        return 0


# --------------------------------------------------------------------------
# the snapshot
# --------------------------------------------------------------------------

def backup(label):
    """Copy the data, not the program, into backups/. Returns the folder."""
    names = []
    for name in sorted(os.listdir(DATA_DIR)):
        path = os.path.join(DATA_DIR, name)
        if not os.path.isfile(path) or os.path.islink(path):
            continue
        if name.startswith(".") and name not in KEEP_DOTFILES:
            continue
        if name.endswith(".tmp") or os.path.getsize(path) > MAX_BACKUP_FILE:
            continue
        names.append(name)
    if not names:
        return None
    safe = re.sub(r"[^A-Za-z0-9._-]+", "_", label)[:60]
    base = os.path.join(BACKUP_DIR, time.strftime("%Y%m%d-%H%M%S") + "-" + safe)
    dest, n = base, 1
    while os.path.exists(dest):
        n += 1
        dest = f"{base}-{n}"
    os.makedirs(dest, mode=0o700)
    os.chmod(BACKUP_DIR, 0o700)
    for name in names:
        shutil.copy2(os.path.join(DATA_DIR, name), os.path.join(dest, name))
    prune()
    return dest


def prune():
    try:
        kept = sorted(d for d in os.listdir(BACKUP_DIR)
                      if os.path.isdir(os.path.join(BACKUP_DIR, d))
                      and re.match(r"^\d{8}-\d{6}-", d))
    except OSError:
        return
    for d in kept[:-KEEP_BACKUPS]:
        shutil.rmtree(os.path.join(BACKUP_DIR, d), ignore_errors=True)


# --------------------------------------------------------------------------
# step 1: keyed categories
# --------------------------------------------------------------------------

def course_code(text):
    m = COURSE_CODE.search(text or "")
    return m.group(1).replace(" ", "").upper() if m else None


def key_for(name):
    """Key for a legacy category name: its course code, else the name itself."""
    return course_code(name) or name.strip()


def already_keyed():
    try:
        with open(CAT_FILE, encoding="utf-8") as f:
            first = f.readline()
    except OSError:
        return True             # nothing to convert is as good as converted
    return first.startswith("key\t") or not first.strip()


def read_legacy():
    rows = []
    with open(CAT_FILE, encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2 and parts[0] and parts[1].strip().isdigit():
                rows.append((parts[0], int(parts[1])))
    return rows


def step_keyed_categories(stamp):
    if already_keyed():
        return
    legacy = read_legacy()
    shutil.copy2(CAT_FILE, f"{CAT_FILE}.bak-{stamp}")
    name_to_key, cats = {}, {}
    for name, last in legacy:
        k = key_for(name)
        name_to_key[name] = k
        # A non-course category keys on its own name; don't repeat it as
        # the display name or the title reads "jobbsøking – jobbsøking".
        display = "" if k == name.strip() else name
        cats[k] = [k, display, "", str(last), ""]
    rows = sorted(cats.values(), key=lambda r: -int(r[3] or 0))
    write_atomic(CAT_FILE, CAT_HEADER + "\n"
                 + "".join("\t".join(r) + "\n" for r in rows))
    say(f"converted {len(legacy)} categories to keys")

    if name_to_key and os.path.isfile(SESS_FILE):
        shutil.copy2(SESS_FILE, f"{SESS_FILE}.bak-{stamp}")
        out, changed = [], 0
        with open(SESS_FILE, encoding="utf-8") as f:
            for i, line in enumerate(f):
                p = line.rstrip("\n").split("\t")
                if i and len(p) >= 4 and p[3] in name_to_key:
                    p[3] = name_to_key[p[3]]
                    changed += 1
                out.append("\t".join(p))
        write_atomic(SESS_FILE, "\n".join(out) + "\n")
        say(f"rewrote {changed} sessions to keys")

    # The running timer holds a category too.
    try:
        with open(STATE_FILE, encoding="utf-8") as f:
            parts = f.readline().rstrip("\n").split("\t")
    except OSError:
        parts = []
    if len(parts) >= 3 and parts[1] in name_to_key:
        parts[1] = name_to_key[parts[1]]
        write_atomic(STATE_FILE, "\t".join(parts) + "\n")


# --------------------------------------------------------------------------
# step 2: full-width headers
# --------------------------------------------------------------------------

def widen_header(path, prefix, header):
    """Replace a header line that is a shorter version of `header`.

    Only the first line, and only when it is recognisably ours: a file whose
    first line is something else entirely is left for a human to look at.
    """
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return False
    first, _, rest = text.partition("\n")
    if not first.startswith(prefix) or first == header:
        return False
    if not header.startswith(first):
        return False
    write_atomic(path, header + "\n" + rest)
    return True


def step_headers(_stamp):
    if widen_header(SESS_FILE, "start_iso\t", SESS_HEADER):
        say("widened the sessions.tsv header")
    if widen_header(CAT_FILE, "key\t", CAT_HEADER):
        say("widened the categories.tsv header")


STEPS = [
    (1, step_keyed_categories),
    (2, step_headers),
]


def install(old, new):
    found = data_version()
    if found > DATA_VERSION:
        say(f"This data was written by a newer TimeTracker (data format {found}; "
            f"this version reads up to {DATA_VERSION}).\n"
            "Install that version or a newer one. Nothing was changed.")
        return 3
    where = backup(f"{old}-to-{new}")
    if where:
        say(f"Backed up your data to {where}")
    stamp = time.strftime("%Y%m%d-%H%M%S")
    for number, step in STEPS:
        step(stamp)
    if found != DATA_VERSION:
        write_atomic(VERSION_FILE, f"{DATA_VERSION}\n")
    return 0


def main(argv):
    if not os.path.isdir(DATA_DIR):
        sys.exit(f"No data folder at {DATA_DIR}")
    if len(argv) == 3 and argv[0] == "--install":
        return install(argv[1] or "none", argv[2] or "unknown")
    if argv == ["--backup"]:
        where = backup("manual")
        say(where or "Nothing to back up.")
        return 0
    say(__doc__.strip().split("\n\n")[1])
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
