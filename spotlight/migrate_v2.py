#!/usr/bin/env python3
"""One-time migration to the keyed category model.

Before: categories.tsv was `name<TAB>last_used`, and sessions.tsv stored the
full category *name* in its category column. Renaming a course orphaned all
its history.

After: categories.tsv is `key<TAB>name<TAB>keywords<TAB>last_used`, and
sessions.tsv stores the stable `key`. The name and keywords become display and
search concerns only, so you can rename a course or add a nickname without
touching a single logged row.

Both files are backed up before anything is rewritten. Safe to re-run: if
categories.tsv is already in the new format, only seeding happens.
"""
import os
import re
import shutil
import sys
import time

DATA_DIR = os.environ.get("TIMETRACK_DIR") or os.path.expanduser("~/.timetrack")
CAT_FILE = os.path.join(DATA_DIR, "categories.tsv")
CAT_TRASH_FILE = os.path.join(DATA_DIR, "categories.deleted.tsv")
SESS_FILE = os.path.join(DATA_DIR, "sessions.tsv")
STATE_FILE = os.path.join(DATA_DIR, "state")

CAT_HEADER = "key\tname\tkeywords\tlast_used_epoch\thidden"
COURSE_CODE = re.compile(r"([A-ZÆØÅ]{2,4}\s?\d{4})", re.IGNORECASE)

# Example categories, used only to give a brand-new install something to look
# at — they are not a course list anyone is expected to keep. Replace them,
# or just delete them once your own are in: `time new` adds, `time categories`
# edits, and a deleted key is remembered so it never comes back on an upgrade.
#
# The shape is what matters: a stable key, an official name, and whatever you
# actually type to reach it.
SEED = [
    ("BØK2100", "Bærekraftig økonomistyring 2", "økstyr2,økstyr"),
    ("INF1050", "Digitale systemer", "øksys,digsys"),
    ("MAT2300", "Optimering og modellering", "optmod,optimering"),
    ("LED2200", "Prosjektledelse", "prosjled,ledelse"),
]


def course_code(text):
    m = COURSE_CODE.search(text or "")
    return m.group(1).replace(" ", "").upper() if m else None


def key_for(name):
    """Key for a legacy category name: its course code, else the name itself."""
    return course_code(name) or name.strip()


def already_v2(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.readline().startswith("key\t")
    except OSError:
        return False


def read_legacy(path):
    rows = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 2 and parts[0] and parts[1].strip().isdigit():
                    rows.append((parts[0], int(parts[1])))
    except OSError:
        pass
    return rows


def read_v2(path):
    cats = {}
    try:
        with open(path, encoding="utf-8") as f:
            for i, line in enumerate(f):
                if i == 0 and line.startswith("key\t"):
                    continue
                p = line.rstrip("\n").split("\t")
                if len(p) >= 4 and p[0]:
                    # The hidden flag rides through: this function feeds
                    # write_cats, which rewrites the file in full.
                    cats[p[0]] = [p[0], p[1], p[2], p[3],
                                  p[4] if len(p) > 4 else ""]
    except OSError:
        pass
    return cats


def deleted_keys():
    """Keys retired with "action.sh delcat".

    Seeding must not resurrect them — install.sh runs this script every time,
    and a course you deleted coming back on the next upgrade is a bug.
    """
    keys = set()
    try:
        with open(CAT_TRASH_FILE, encoding="utf-8") as f:
            for i, line in enumerate(f):
                p = line.rstrip("\n").split("\t")
                if i == 0 and p and p[0] == "key":
                    continue
                if p and p[0]:
                    keys.add(p[0])
    except OSError:
        pass
    return keys


def write_cats(cats):
    tmp = CAT_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(CAT_HEADER + "\n")
        for row in sorted(cats.values(), key=lambda r: -int(r[3] or 0)):
            f.write("\t".join(row) + "\n")
    os.replace(tmp, CAT_FILE)


def main():
    if not os.path.isdir(DATA_DIR):
        sys.exit(f"No data dir at {DATA_DIR}")

    stamp = time.strftime("%Y%m%d-%H%M%S")
    name_to_key = {}

    if already_v2(CAT_FILE):
        cats = read_v2(CAT_FILE)
        print(f"categories.tsv already keyed ({len(cats)} entries)")
    else:
        legacy = read_legacy(CAT_FILE)
        if legacy:
            shutil.copy2(CAT_FILE, f"{CAT_FILE}.bak-{stamp}")
            print(f"backed up categories.tsv -> categories.tsv.bak-{stamp}")
        cats = {}
        for name, last in legacy:
            k = key_for(name)
            name_to_key[name] = k
            # A non-course category keys on its own name; don't repeat it as
            # the display name or the title reads "jobbsøking – jobbsøking".
            display = "" if k == name.strip() else name
            cats[k] = [k, display, "", str(last)]
        print(f"converted {len(legacy)} legacy categories")

    # Seed the examples, but only into an install that has no categories at
    # all. SEED used to be the real course list, and refreshing existing rows
    # from it was right then; now that it is placeholder data, doing so would
    # rename a real course to "Eksempelfag" on the next upgrade. A fresh
    # install still gets something to look at, which is all the seed is for.
    now = int(time.time())
    retired = deleted_keys()
    touched = 0
    seed = SEED if not cats else []
    if cats:
        print("categories present. Skipping the example seed")
    for key, name, keywords in seed:
        if key in retired and key not in cats:
            continue
        touched += 1
        if key in cats:
            row = cats[key]
            old_name = row[1]
            row[1] = name
            merged = [k for k in row[2].split(",") if k.strip()]
            for k in keywords.split(","):
                if k.strip() and k.strip().lower() not in [m.lower() for m in merged]:
                    merged.append(k.strip())
            # A legacy display name you were used to typing stays searchable.
            if old_name and old_name != name and course_code(old_name):
                stripped = COURSE_CODE.sub("", old_name).strip()
                if stripped and stripped.lower() not in [m.lower() for m in merged]:
                    merged.append(stripped)
            row[2] = ",".join(merged)
        else:
            cats[key] = [key, name, keywords, str(now - 10_000_000), ""]
    if seed:
        print(f"seeded {touched} example categories"
              + (f" ({len(seed) - touched} left deleted)" if touched < len(seed) else ""))

    write_cats(cats)

    # Rewrite the log's category column from names to keys.
    if name_to_key and os.path.isfile(SESS_FILE):
        shutil.copy2(SESS_FILE, f"{SESS_FILE}.bak-{stamp}")
        print(f"backed up sessions.tsv -> sessions.tsv.bak-{stamp}")
        out, changed = [], 0
        with open(SESS_FILE, encoding="utf-8") as f:
            for i, line in enumerate(f):
                if i == 0:
                    out.append(line.rstrip("\n"))
                    continue
                p = line.rstrip("\n").split("\t")
                if len(p) >= 4 and p[3] in name_to_key:
                    p[3] = name_to_key[p[3]]
                    changed += 1
                out.append("\t".join(p))
        tmp = SESS_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("\n".join(out) + "\n")
        os.replace(tmp, SESS_FILE)
        print(f"rewrote {changed} session rows to keys")

    # The running timer holds a category too.
    if name_to_key and os.path.isfile(STATE_FILE):
        try:
            with open(STATE_FILE, encoding="utf-8") as f:
                parts = f.readline().rstrip("\n").split("\t")
        except OSError:
            parts = []
        if len(parts) >= 3 and parts[1] in name_to_key:
            parts[1] = name_to_key[parts[1]]
            tmp = STATE_FILE + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write("\t".join(parts) + "\n")
            os.replace(tmp, STATE_FILE)
            print("rewrote running timer state to key")

    # sessions.tsv gained plan/recap and then pomodoro columns. Old rows
    # simply have fewer fields, which every reader tolerates — but the header
    # has to advertise the full width or pandas will refuse the wider rows.
    new_header = ("start_iso\tend_iso\tduration_sec\tcategory\tnote"
                  "\tplan\trecap\tpomodoros\tbreak_overrun_sec")
    try:
        with open(SESS_FILE, encoding="utf-8") as f:
            lines = f.read().split("\n")
        if lines and lines[0].startswith("start_iso") and lines[0] != new_header:
            lines[0] = new_header
            tmp = SESS_FILE + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write("\n".join(lines))
            os.replace(tmp, SESS_FILE)
            print("upgraded sessions.tsv header with plan/recap columns")
    except OSError:
        pass

    print("\nDone. Categories now:")
    for row in sorted(read_v2(CAT_FILE).values(), key=lambda r: r[0]):
        print(f"  {row[0]:<9} {row[1][:44]:<46} [{row[2]}]")


if __name__ == "__main__":
    main()
