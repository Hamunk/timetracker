#!/usr/bin/env python3
"""Cases for migrate.py. Run: python3 spotlight/migrate.test.py

Each case builds a data folder the way some past version left it, runs the
migration the way install.sh does, and checks what came out. The log is the
one file here that cannot be regenerated, so most of the checks are about it
surviving byte for byte wherever nothing was meant to change.
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SESS9 = ("start_iso\tend_iso\tduration_sec\tcategory\tnote"
         "\tplan\trecap\tpomodoros\tbreak_overrun_sec")
CAT5 = "key\tname\tkeywords\tlast_used_epoch\thidden"

failed = 0
total = 0


def check(label, ok):
    global failed, total
    total += 1
    print(("  ok    " if ok else "  FAIL  ") + label)
    if not ok:
        failed += 1


def folder(files):
    d = tempfile.mkdtemp(prefix="ttmigrate.")
    for name, text in files.items():
        with open(os.path.join(d, name), "w", encoding="utf-8") as f:
            f.write(text)
    return d


def run(d, *args):
    env = dict(os.environ, TIMETRACK_DIR=d)
    return subprocess.run([sys.executable, os.path.join(HERE, "migrate.py")] + list(args),
                          env=env, capture_output=True, text=True)


def read(d, name):
    with open(os.path.join(d, name), encoding="utf-8") as f:
        return f.read()


def backups(d):
    b = os.path.join(d, "backups")
    return sorted(os.listdir(b)) if os.path.isdir(b) else []


def legacy():
    print("legacy names become keys")
    d = folder({
        "categories.tsv": "TDT4100 Objektorientert programmering\t1700000000\n"
                          "jobbsøking\t1700000500\n",
        "sessions.tsv": "start_iso\tend_iso\tduration_sec\tcategory\tnote\n"
                        "2024-01-01T10:00:00+0100\t2024-01-01T11:00:00+0100\t3600"
                        "\tTDT4100 Objektorientert programmering\t\n"
                        "2024-01-01T12:00:00+0100\t2024-01-01T12:30:00+0100\t1800"
                        "\tjobbsøking\t\n",
        "state": "",
    })
    r = run(d, "--install", "1.0.0", "2.0.0")
    check("exits 0", r.returncode == 0)
    cats = read(d, "categories.tsv").splitlines()
    check("header is the full width", cats[0] == CAT5)
    check("course keyed on its code", any(l.startswith("TDT4100\tTDT4100 Objekt") for l in cats))
    check("plain name keys on itself, no repeated name",
          any(l.startswith("jobbsøking\t\t") for l in cats))
    log = read(d, "sessions.tsv").splitlines()
    check("log header widened", log[0] == SESS9)
    check("log rows rewritten to keys", log[1].split("\t")[3] == "TDT4100"
          and log[2].split("\t")[3] == "jobbsøking")
    check("durations untouched", [l.split("\t")[2] for l in log[1:]] == ["3600", "1800"])
    check("a snapshot was taken first", len(backups(d)) == 1
          and "TDT4100 Objektorientert" in read(os.path.join(d, "backups", backups(d)[0]),
                                                "categories.tsv"))
    check("data-version written", read(d, "data-version").strip() == "2")


def current():
    print("current data is left byte for byte")
    log = (SESS9 + "\n2026-09-01T10:00:00+0200\t2026-09-01T10:25:00+0200\t1500"
           "\tTDT4100\t\tplan\trecap\t1\t0\n"
           "2026-09-01T11:00:00+0200\t2026-09-01T11:05:00+0200\t300\tTDT4100\n")
    cats = CAT5 + "\nTDT4100\tOOP\toop,java\t1756720000\t\n"
    d = folder({"sessions.tsv": log, "categories.tsv": cats,
                "settings.tsv": "sound\toff\n", "friends.tsv": "id\tname\tcode\tadded\n",
                ".tomato-alive": "", ".setup-done": ""})
    r = run(d, "--install", "2.0.0", "2.0.0")
    check("exits 0", r.returncode == 0)
    check("log unchanged", read(d, "sessions.tsv") == log)
    check("categories unchanged", read(d, "categories.tsv") == cats)
    snap = os.path.join(d, "backups", backups(d)[0])
    kept = sorted(os.listdir(snap))
    check("snapshot holds the data and the markers", kept == [
        ".setup-done", "categories.tsv", "friends.tsv", "sessions.tsv", "settings.tsv"])
    check("snapshot skips a break in progress", ".tomato-alive" not in kept)
    check("snapshot is private", oct(os.stat(snap).st_mode & 0o777) == "0o700")


def short_headers():
    print("short headers are widened, rows are not")
    log = ("start_iso\tend_iso\tduration_sec\tcategory\tnote\tplan\trecap\n"
           "2026-01-01T10:00:00+0100\t2026-01-01T11:00:00+0100\t3600\tX\t\tp\tr\n")
    d = folder({"sessions.tsv": log,
                "categories.tsv": "key\tname\tkeywords\tlast_used_epoch\nX\t\t\t1767000000\n"})
    run(d, "--install", "1.0.0", "2.0.0")
    out = read(d, "sessions.tsv").splitlines()
    check("sessions header widened", out[0] == SESS9)
    check("row kept as it was", out[1] == log.splitlines()[1])
    check("categories header widened", read(d, "categories.tsv").splitlines()[0] == CAT5)


def foreign_header():
    print("a header that is not ours is left alone")
    log = "date\thours\n2026-01-01\t3\n"
    d = folder({"sessions.tsv": log})
    run(d, "--install", "1.0.0", "2.0.0")
    check("untouched", read(d, "sessions.tsv") == log)


def newer():
    print("data from a newer version is refused")
    log = SESS9 + "\n"
    d = folder({"sessions.tsv": log, "data-version": "9\n"})
    r = run(d, "--install", "2.0.0", "2.0.0")
    check("exits 3", r.returncode == 3)
    check("says why", "newer TimeTracker" in r.stdout)
    check("takes no snapshot", backups(d) == [])
    check("leaves data-version", read(d, "data-version") == "9\n")


def fresh():
    print("a fresh install gets no example categories")
    d = folder({"categories.tsv": CAT5 + "\n", "sessions.tsv": SESS9 + "\n"})
    run(d, "--install", "none", "2.0.0")
    check("still empty", read(d, "categories.tsv") == CAT5 + "\n")


def pruning():
    print("ten snapshots are kept")
    d = folder({"sessions.tsv": SESS9 + "\n"})
    os.makedirs(os.path.join(d, "backups"))
    for i in range(12):
        os.makedirs(os.path.join(d, "backups", "2025010%d-0000%02d-old" % (1 + i // 10, i)))
    os.makedirs(os.path.join(d, "backups", "mine"))
    run(d, "--install", "2.0.0", "2.0.0")
    b = backups(d)
    check("ten dated ones", len([x for x in b if x[0].isdigit()]) == 10)
    check("the oldest went", "20250101-000000-old" not in b)
    check("the new one stayed", any(x.endswith("2.0.0-to-2.0.0") for x in b))
    check("a folder not named like ours is not ours", "mine" in b)


for case in (legacy, current, short_headers, foreign_header, newer, fresh, pruning):
    case()
print("\n%d of %d passed" % (total - failed, total))
sys.exit(1 if failed else 0)
