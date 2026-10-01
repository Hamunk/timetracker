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
CAT6 = CAT5 + "\tcode"

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
    check("header is the full width", cats[0] == CAT6)
    check("course keyed on its code, and shown with it",
          "TDT4100\tTDT4100 Objektorientert programmering\t\t1700000000\t\tTDT4100" in cats)
    check("plain name keys on itself, named and without a code",
          "jobbsøking\tjobbsøking\t\t1700000500\t\t" in cats)
    log = read(d, "sessions.tsv").splitlines()
    check("log header widened", log[0] == SESS9)
    check("log rows rewritten to keys", log[1].split("\t")[3] == "TDT4100"
          and log[2].split("\t")[3] == "jobbsøking")
    check("durations untouched", [l.split("\t")[2] for l in log[1:]] == ["3600", "1800"])
    check("a snapshot was taken first", len(backups(d)) == 1
          and "TDT4100 Objektorientert" in read(os.path.join(d, "backups", backups(d)[0]),
                                                "categories.tsv"))
    check("data-version written", read(d, "data-version").strip() == "3")


def current():
    print("current data is left byte for byte")
    log = (SESS9 + "\n2026-09-01T10:00:00+0200\t2026-09-01T10:25:00+0200\t1500"
           "\tTDT4100\t\tplan\trecap\t1\t0\n"
           "2026-09-01T11:00:00+0200\t2026-09-01T11:05:00+0200\t300\tTDT4100\n")
    cats = (CAT6 + "\nTDT4100\tOOP\toop,java\t1756720000\t\tTDT4100\n"
            "med5 patologi\tpatologi\t\t1756720000\t1\tmed5\n"
            "Lesing\tLesing\t\t1756720000\t\t\n")
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
    out = read(d, "categories.tsv").splitlines()
    check("categories header widened", out[0] == CAT6)
    check("a nameless row is named for its key", out[1] == "X\tX\t\t1767000000\t\t")


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
    check("says why", "newer Tomat" in r.stdout)
    check("takes no snapshot", backups(d) == [])
    check("leaves data-version", read(d, "data-version") == "9\n")


def fresh():
    print("a fresh install gets no example categories, and no backup of nothing")
    d = folder({"categories.tsv": CAT6 + "\n", "sessions.tsv": SESS9 + "\n",
                "settings.tsv": "", "state": ""})
    r = run(d, "--install", "none", "2.0.0")
    check("still empty", read(d, "categories.tsv") == CAT6 + "\n")
    check("no snapshot, and nothing said about one",
          backups(d) == [] and "Backed up" not in r.stdout)
    print("data kept through an uninstall is backed up when installed again")
    d = folder({"categories.tsv": CAT5 + "\nX\t\t\t1767000000\t\n", "sessions.tsv": SESS9 + "\n"})
    run(d, "--install", "none", "2.0.0")
    check("snapshot taken though there was no previous version", len(backups(d)) == 1)


def pruning():
    print("ten snapshots are kept")
    d = folder({"sessions.tsv": SESS9 + "\n2026-01-01T10:00:00+0100\t"
                "2026-01-01T11:00:00+0100\t3600\tX\n"})
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


def codes():
    print("2.0 subjects get the code they were shown with")
    log = (SESS9 + "\n2026-09-01T10:00:00+0200\t2026-09-01T10:25:00+0200\t1500"
           "\tTIØ4162\t\t\t\t1\t0\n")
    d = folder({"sessions.tsv": log, "data-version": "2\n", "categories.tsv": CAT5 + "\n"
                "TIØ4162\tOrganisasjon og teknologi 2\torgtek2,orgtek\t1790751441\t\n"
                "jobbsøking\t\t\t1790153260\t\n"
                "TIØ4566\tStrategisk forsyningsledelse\temne\t1788184777\t1\n"
                "MAT1\tMatte\t\t1788000000\n"})
    r = run(d, "--install", "2.0.0", "2.1.0")
    check("exits 0", r.returncode == 0)
    out = read(d, "categories.tsv").splitlines()
    check("header has the code", out[0] == CAT6)
    check("a course keeps its key and is shown with it as its code",
          out[1] == "TIØ4162\tOrganisasjon og teknologi 2\torgtek2,orgtek\t1790751441\t\tTIØ4162")
    check("a plain name is its own name, with no code",
          out[2] == "jobbsøking\tjobbsøking\t\t1790153260\t\t")
    check("archived stays archived", out[3].split("\t")[4:] == ["1", "TIØ4566"])
    check("a four-field row is filled out", out[4] == "MAT1\tMatte\t\t1788000000\t\tMAT1")
    check("the log is not touched", read(d, "sessions.tsv") == log)
    check("data-version raised", read(d, "data-version").strip() == "3")
    once = read(d, "categories.tsv")
    run(d, "--install", "2.1.0", "2.1.0")
    check("a second run changes nothing", read(d, "categories.tsv") == once)
    print("a file seeded half old, half new comes out whole")
    d = folder({"categories.tsv": CAT6 + "\n"
                "med5 patologi\tpatologi\t\t1790859949\t\tmed5\n"
                "Lesing\tLesing\t\t1790859949\t\t\n"
                "BØK2100\tØkonomistyring\t\t1790000000\t\n"})
    run(d, "--install", "2.1.0", "2.1.0")
    out = read(d, "categories.tsv").splitlines()
    check("new rows untouched, an empty code included",
          out[1:3] == ["med5 patologi\tpatologi\t\t1790859949\t\tmed5",
                       "Lesing\tLesing\t\t1790859949\t\t"])
    check("the old row gets its code", out[3] == "BØK2100\tØkonomistyring\t\t1790000000\t\tBØK2100")


for case in (legacy, current, short_headers, foreign_header, newer, fresh, pruning, codes):
    case()
print("\n%d of %d passed" % (total - failed, total))
sys.exit(1 if failed else 0)
