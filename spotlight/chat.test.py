#!/usr/bin/env python3
"""Cases for the chat. Run: python3 spotlight/chat.test.py [--live]

Compiles ttchat, starts chat-relay.py on a loopback port, and drives headless
peers and a break's chat through it — the two ends of a friendship, on one
Mac, which is all a relay needs to be tested with: it cannot tell Trondheim
from Bergen, and does not try.

Most of the cases are refusals. A chat that delivers messages is easy to
demonstrate and says little; what makes it safe is everything that arrives and
is thrown away before it is read, and each of those is shown here arriving
correctly encrypted, so that it is refused for the reason given and not for
some earlier accident.

Nothing leaves the machine unless --live, which holds one short conversation
through ntfy.sh itself, and leaves one message waiting there: about a dozen
posts of the 250 a day it allows this IP address, the same address the real
install chats from. Not something to run in a loop.

TTCHAT_BIN=<path> skips the compile.
"""
import json
import os
import queue
import re
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CODE = re.compile(r"^tt1-[A-Za-z0-9_-]{46}$")

BIN = None
failed = 0
total = 0


def check(label, ok):
    global failed, total
    total += 1
    if ok:
        print("  ok    %s" % label)
    else:
        failed += 1
        print("  FAIL  %s" % label)


def build():
    b = os.environ.get("TTCHAT_BIN")
    if b:
        return b
    out = os.path.join(tempfile.mkdtemp(prefix="ttchat."), "ttchat")
    print("Compiling ttchat...", flush=True)
    subprocess.run(["swiftc", "-O", os.path.join(HERE, "ttchat.swift"), "-o", out],
                   check=True)
    return out


def start_relay(**env):
    p = subprocess.Popen([sys.executable, os.path.join(HERE, "chat-relay.py"), "0"],
                         stdout=subprocess.PIPE, text=True,
                         env=dict(os.environ, RELAY_KEEPALIVE="2", **env))
    return p, "http://127.0.0.1:%d" % int(p.stdout.readline().split()[1])


def new_code():
    return subprocess.run([BIN, "code"], capture_output=True, text=True,
                          check=True).stdout.strip()


def seal(code, envelope):
    raw = envelope if isinstance(envelope, str) else json.dumps(envelope)
    out = subprocess.run([BIN, "seal", code, raw], capture_output=True, text=True,
                         check=True).stdout.strip()
    topic, blob = out.split("\t")
    return topic, blob


# A forged sender: nobody's Mac, so a refusal can only be for the reason under
# test and never because it looked like an echo.
def envelope(kind="text", x=None, t=None, v=2, **more):
    e = {"v": v, "s": "0123456789abcdef", "i": os.urandom(8).hex(),
         "t": int(time.time()) if t is None else t, "k": kind}
    if x is not None:
        e["x"] = x
    e.update(more)
    return e


def post(relay, topic, body, keep=True):
    headers = {} if keep else {"Cache": "no"}
    req = urllib.request.Request("%s/%s" % (relay, topic), data=body.encode(),
                                 method="POST", headers=headers)
    urllib.request.urlopen(req, timeout=5).read()


def refused_at_start(relay, code):
    p = subprocess.run([BIN, "peer", relay, code], stdin=subprocess.DEVNULL,
                       capture_output=True, text=True, timeout=10)
    return p.returncode == 2


class Peer:
    """One headless ttchat: a friend on a break, its events queued."""

    def __init__(self, relay, code):
        self.p = subprocess.Popen([BIN, "peer", relay, code], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  text=True, bufsize=1)
        self.q = queue.Queue()
        self.log = []
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.p.stdout:
            self.q.put(line.rstrip("\n").split("\t"))

    def next(self, want, timeout=10):
        """The next event `want` accepts, or None. Everything passed over on
        the way is kept in the log, for saw()."""
        deadline = time.time() + timeout
        while True:
            left = deadline - time.time()
            if left <= 0:
                return None
            try:
                ev = self.q.get(timeout=left)
            except queue.Empty:
                return None
            self.log.append(ev)
            if want(ev):
                return ev

    def saw(self, ev, timeout=5):
        return ev in self.log or self.next(lambda e: e == ev, timeout) is not None

    def say(self, text):
        self.p.stdin.write(text + "\n")
        self.p.stdin.flush()

    def close(self):
        try:
            self.p.stdin.close()
        except OSError:
            pass

    def kill(self):
        if self.p.poll() is None:
            self.p.kill()


def kind(*kinds):
    return lambda e: e[0] in kinds


def text(x):
    return lambda e: e[0] == "text" and e[2] == x


def status(ph):
    return lambda e: e[0] == "status" and e[2] == ph


# Either it got through, or it was refused — and never for being our own echo,
# which is noise from the peer's own sends rather than an answer to the case.
def verdict(e):
    return e[0] in ("text", "status") or (e[0] == "drop" and e[1] != "echo")


class Tap:
    """What the relay sees: another subscriber to the topic, holding no key."""

    def __init__(self, relay, topic):
        self.bodies = []
        self.opened = threading.Event()
        self.p = subprocess.Popen(["curl", "-sN", "--max-time", "300",
                                   "%s/%s/json" % (relay, topic)],
                                  stdout=subprocess.PIPE, text=True)
        threading.Thread(target=self._read, daemon=True).start()
        self.opened.wait(10)

    def _read(self):
        for line in self.p.stdout:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("event") == "open":
                self.opened.set()
            elif e.get("event") == "message":
                self.bodies.append(e.get("message", ""))

    def kill(self):
        self.p.kill()


def conversation(relay, code, tap, plain, settle=0):
    """Arrive, see where the other is, talk both ways. Shared by the local
    run and --live, where `settle` waits out ntfy.sh's lag in writing its
    history."""
    a = Peer(relay, code)
    check("a subscribes", a.next(kind("open")) is not None)
    time.sleep(settle)
    b = Peer(relay, code)
    check("b subscribes", b.next(kind("open")) is not None)
    sa = b.next(status("break"), 15)
    check("b, arriving after a, is handed where a is from the relay's history",
          sa is not None)
    sb = a.next(status("break"))
    check("a hears where b is as b arrives", sb is not None)
    sid_a = sa[1] if sa else "?"
    sid_b = sb[1] if sb else "?"

    msg = "hei fra Trondheim — æøå 🍅"
    a.say(msg)
    ev = b.next(kind("text"))
    check("a → b arrives, unicode intact", ev is not None and ev[:3] == ["text", sid_a, msg])
    b.say("hei fra Bergen")
    ev = a.next(kind("text"))
    check("b → a arrives", ev is not None and ev[:3] == ["text", sid_b, "hei fra Bergen"])
    check("a's own message comes back to it and is dropped as an echo",
          a.saw(["drop", "echo"]))
    check("nothing a received claimed to be from a",
          not any(e[0] in ("text", "status") and e[1] == sid_a for e in a.log))
    a.say("/work 25")
    ev = b.next(status("work"))
    check("a goes back to work: b sees it, with a planned end 25 minutes on",
          ev is not None and int(ev[4]) - int(ev[3]) == 1500)
    time.sleep(0.5)
    check("the relay saw sealed blobs, and never the text",
          len(tap.bodies) >= 5
          and all(x.startswith("tt1:") for x in tap.bodies)
          and not any(p in x for x in tap.bodies for p in plain))
    return a, b, sid_a


def local():
    relay_p, relay = start_relay()
    peers, tap = [], None
    try:
        code, other = new_code(), new_code()
        topic = seal(code, "{}")[0]

        print("codes and relays")
        check("a code has the documented shape, and two codes differ",
              CODE.match(code) and CODE.match(other) and code != other)
        check("a paste that lost its last character is refused",
              refused_at_start(relay, code[:-1]))
        mid = len(code) // 2
        changed = code[:mid] + ("A" if code[mid] != "A" else "B") + code[mid + 1:]
        check("a paste with one character changed is refused",
              refused_at_start(relay, changed))
        check("plain http to another machine is refused as a relay",
              refused_at_start("http://example.com", code))

        print("a conversation")
        tap = Tap(relay, topic)
        a, b, sid_a = conversation(relay, code, tap, ["Trondheim", "Bergen"])
        peers += [a, b]

        print("what b refuses")

        def refused(body, reason, label):
            post(relay, topic, body)
            check(label, b.next(verdict) == ["drop", reason])

        def accepted(body, label, want):
            post(relay, topic, body)
            ev = b.next(verdict)
            check(label, ev is not None and ev[0] == want[0] and ev[2] == want[1])

        _, good = seal(code, envelope(x="tampered with"))
        mid = len(good) // 2
        refused(good[:mid] + ("A" if good[mid] != "A" else "B") + good[mid + 1:],
                "auth", "a blob with one character changed")
        refused(seal(other, envelope(x="wrong key"))[1], "auth",
                "a blob sealed under another friendship's key")
        refused("tt1:!!!!", "auth", "garbage after the prefix")
        refused("anyone here?", "foreign", "plain text posted to the topic")
        refused(seal(code, "not json")[1], "malformed",
                "a sealed blob that is not an object")
        refused(seal(code, envelope(x="from the old helper", v=1))[1], "malformed",
                "a version-1 message: mismatched installs refuse each other outright")
        refused(seal(code, envelope(kind="run", x="open -a Calculator"))[1], "malformed",
                "an unknown kind of message")
        refused(seal(code, envelope(x="x" * 501))[1], "malformed",
                "a text over 500 characters (refused, not cut)")
        refused(seal(code, envelope(kind="status", ph="asleep", since=0, until=0))[1],
                "malformed", "a status that is not work, break or off")
        now = int(time.time())
        refused(seal(code, envelope(kind="status", ph="work", since=now, until=now - 60))[1],
                "malformed", "a status that ends before it begins")
        refused(seal(code, envelope(x="fourteen hours ago", t=now - 14 * 3600))[1],
                "stale", "a message older than the relay would have kept it")
        refused(seal(code, envelope(x="ten minutes ahead", t=now + 600))[1],
                "stale", "a message ten minutes in the future")
        accepted(seal(code, envelope(x="written while you worked", t=now - 3 * 3600))[1],
                 "a message that waited three hours on the relay is accepted",
                 ["text", "written while you worked"])

        _, once = seal(code, envelope(x="only once"))
        accepted(once, "a correctly sealed message from a third sender is accepted",
                 ["text", "only once"])
        refused(once, "replay", "the same message again")

        accepted(seal(code, envelope(x="‮evil\x07\nnext\tline"))[1],
                 "control characters and bidi overrides are removed, breaks become spaces",
                 ["text", "evil next line"])

        print("leaving")
        a.close()
        check("b sees a stop", b.next(status("off")) is not None)
        check("a exits cleanly", a.p.wait(timeout=5) == 0)

        print("floods, and what waited")
        # b's second look at the relay's history (see lag()) hands back
        # everything above ten seconds after b arrived, all of it refused a
        # second time. Those refusals are not what is being counted here.
        b.next(lambda e: False, 11)
        for n in range(25):
            post(relay, topic, seal(code, envelope(x="flood %d" % n))[1])
        got = [b.next(verdict) for _ in range(25)]
        texts = sum(1 for e in got if e and e[0] == "text")
        rated = sum(1 for e in got if e == ["drop", "rate"])
        check("at most twenty arriving now get through in ten seconds; the rest "
              "are dropped (%d through, %d dropped)" % (texts, rated),
              texts <= 20 and rated >= 5 and texts + rated == 25)
        b.next(lambda e: False, 10)
        for n in range(25):
            post(relay, topic, seal(code, envelope(x="waited %d" % n, t=now - 1800))[1])
        got = [b.next(verdict) for _ in range(25)]
        through = sum(1 for e in got if e and e[0] == "text")
        check("twenty-five that waited half an hour all arrive: what built up "
              "while you worked is not a flood (%d of 25; %s)"
              % (through, sorted(set(tuple(e[:2]) for e in got if e and e[0] != "text"))),
              through == 25)
        b.close()
        b.p.wait(timeout=5)

        break_mode(relay, peers)
    finally:
        for p in peers:
            p.kill()
        if tap:
            tap.kill()
        relay_p.kill()
    lag(peers)


# --- break mode ---------------------------------------------------------------
# The helper as the watcher runs it: a data directory with a cycle in it, a
# command file the overlay would write, a state file the overlay would read,
# and the files that are kept between breaks. The friend is a headless peer
# holding the code the room made.

def pomo(d, phase, watcher="424242"):
    now = int(time.time())
    with open(os.path.join(d, "pomodoro"), "w") as f:
        f.write("%s\tKEY\t%d\t%d\t1\t0\t%s\n" % (phase, now - 60, now + 300, watcher))


def command(d, line):
    """Written the way the overlay writes it — whole, by rename — and only
    once the last one has been taken, the way its outbox waits."""
    path = os.path.join(d, ".tomato-chat-cmd")
    deadline = time.time() + 5
    while os.path.exists(path) and time.time() < deadline:
        time.sleep(0.05)
    with open(path + ".t", "w") as f:
        f.write(line + "\n")
    os.rename(path + ".t", path)


def state(d, want=lambda s: True, timeout=8):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with open(os.path.join(d, ".tomato-chat")) as f:
                s = json.load(f)
            if want(s):
                return s
        except (OSError, ValueError):
            pass
        time.sleep(0.1)
    return None


def friend(s, name):
    return next((f for f in s["friends"] if f["n"] == name), None)


def room(d):
    return subprocess.Popen([BIN, "break", d], stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL,
                            env=dict(os.environ, TTCHAT_CLIPBOARD="off"))


def rows(d, name):
    with open(os.path.join(d, name)) as f:
        return [l.rstrip("\n").split("\t") for l in f][1:]


def private(d, name):
    return os.stat(os.path.join(d, name)).st_mode & 0o077 == 0


def new_room_dir(relay):
    d = tempfile.mkdtemp(prefix="ttchat-room.")
    with open(os.path.join(d, "chat-relay"), "w") as f:
        f.write(relay + "\n")
    return d


def break_mode(relay, peers):
    d = new_room_dir(relay)

    print("break mode: when it runs")
    pomo(d, "WORK")
    p = room(d)
    check("started outside a break, it exits at once and writes nothing",
          p.wait(timeout=5) == 0 and not os.path.exists(os.path.join(d, ".tomato-chat")))

    pomo(d, "BREAK")
    r = room(d)
    s = state(d)
    check("on a break it comes up: no friends yet, relay fine",
          s is not None and s["friends"] == [] and s["relay"]["ok"])
    second = room(d)
    check("a second one in the same directory exits, leaving the first",
          second.wait(timeout=5) == 0 and r.poll() is None)
    with open(os.path.join(d, "chat-self")) as f:
        me = f.read().strip()
    check("this Mac's sender id is made once, and kept private",
          re.fullmatch(r"[0-9a-f]{16}", me) is not None and private(d, "chat-self"))

    print("break mode: pairing, and writing any time")
    command(d, "invite\tKari")
    s = state(d, lambda s: s["note"] and s["note"]["k"] == "invited")
    kari = s["note"]["id"] if s else "?"
    check("making a code adds the friend, by a non-secret id",
          s is not None and [f["n"] for f in s["friends"]] == ["Kari"]
          and re.fullmatch(r"[0-9a-f]{8}", kari) is not None)
    fr = rows(d, "friends.tsv")
    check("friends.tsv holds the code, and only its owner can read it",
          len(fr) == 1 and CODE.match(fr[0][2]) and private(d, "friends.tsv"))
    command(d, "send\t%s\tvelkommen, Kari" % kari)
    check("a message to Kari before Kari has even pasted the code is accepted",
          state(d, lambda s: any(m["x"] == "velkommen, Kari" and m["s"] == "sent"
                                 for m in s["log"])) is not None)
    check("the state file the overlay reads carries no code",
          "tt1-" not in open(os.path.join(d, ".tomato-chat")).read())

    k = Peer(relay, fr[0][2])
    peers.append(k)
    check("Kari pastes the code, and finds the message waiting",
          k.next(text("velkommen, Kari"), 10) is not None)
    s = state(d, lambda s: friend(s, "Kari")["ph"] == "break")
    check("you see Kari on a break, since a moment ago",
          s is not None and 0 <= time.time() - friend(s, "Kari")["since"] < 30)
    k.say("takk! pause nå?")
    s = state(d, lambda s: friend(s, "Kari")["unread"] == 1)
    check("Kari's answer is in your log, against Kari's id, unread",
          s is not None and any(m["x"] == "takk! pause nå?" and m["f"] == kari
                                and not m["me"] for m in s["log"]))
    top = max(m["q"] for m in s["log"]) if s else 0
    command(d, "read\t%s\t%d" % (kari, top))
    check("reading it clears the count",
          state(d, lambda s: friend(s, "Kari")["unread"] == 0) is not None)
    k.say("/work 25")
    s = state(d, lambda s: friend(s, "Kari")["ph"] == "work")
    check("Kari goes back to work: you see it, and when the work is planned to end",
          s is not None and friend(s, "Kari")["until"] - friend(s, "Kari")["since"] == 1500)

    other = new_code()
    command(d, "join\tOla\t%s" % other)
    s = state(d, lambda s: s["note"]["k"] == "joined")
    ola = s["note"]["id"] if s else "?"
    check("pasting a friend's code adds them",
          s is not None and [f["n"] for f in s["friends"]] == ["Kari", "Ola"])
    command(d, "send\t%s\tfor Ola, whenever" % ola)
    check("a message to Ola, who is nowhere, is sent all the same",
          state(d, lambda s: any(m["x"] == "for Ola, whenever" and m["s"] == "sent"
                                 for m in s["log"])) is not None)
    time.sleep(0.5)
    o = Peer(relay, other)
    peers.append(o)
    check("Ola turns up later, and it is waiting",
          o.next(text("for Ola, whenever"), 10) is not None)
    o.close()
    command(d, "join\tOla again\t%s" % other)
    s = state(d, lambda s: s["note"]["k"] == "bad")
    check("the same code twice is refused, by name",
          s is not None and "Ola" in s["note"]["x"] and len(s["friends"]) == 2)
    command(d, "join\tHalf\t%s" % other[:30])
    s = state(d, lambda s: s["note"]["k"] == "bad" and "whole" in s["note"]["x"])
    check("half a code is refused", s is not None and len(s["friends"]) == 2)

    for junk in ("send\tnot-an-id\thei", "run\topen -a Calculator", "copy\t../../x",
                 "forget\tKari", "read\t%s\tlots" % kari, "\t\t\t"):
        command(d, junk)
    time.sleep(0.6)
    s = state(d)
    check("commands it does not know, or ids that are not ids, change nothing",
          r.poll() is None and s is not None and len(s["friends"]) == 2)

    command(d, "forget\t%s" % ola)
    s = state(d, lambda s: s["note"]["k"] == "forgot")
    check("removing a friend removes their row, and what was said with them",
          s is not None and [f["n"] for f in s["friends"]] == ["Kari"]
          and len(rows(d, "friends.tsv")) == 1
          and not any(row[1] == ola for row in rows(d, "chat-log.tsv")))

    print("break mode: your own status, handed back")
    k.say("/break 5")
    state(d, lambda s: friend(s, "Kari")["ph"] == "break")
    t = int(time.time())
    one = subprocess.run([BIN, "status", d, "work", str(t), str(t + 1500)], timeout=20)
    got = k.next(status("work"), 10)
    check("a status post reaches Kari with what it was given",
          one.returncode == 0 and got is not None and got[3:5] == [str(t), str(t + 1500)])
    time.sleep(1.5)
    check("and when the relay hands it back to you, it is not taken for Kari's",
          friend(state(d), "Kari")["ph"] == "break")

    print("break mode: the end of the break, and the next one")
    pomo(d, "WORK")
    check("back to work: it exits, taking only what the overlay was shown",
          r.wait(timeout=6) == 0 and not os.path.exists(os.path.join(d, ".tomato-chat")))
    check("history and friends are kept, 600",
          len(rows(d, "friends.tsv")) == 1 and private(d, "chat-log.tsv")
          and private(d, "chat-sync.tsv")
          and any(row[6] == "takk! pause nå?" for row in rows(d, "chat-log.tsv")))
    k.say("skrev mens du jobbet")
    time.sleep(0.5)
    pomo(d, "BREAK")
    r = room(d)
    s = state(d, lambda s: any(m["x"] == "skrev mens du jobbet" for m in s["log"]))
    check("next break: what Kari wrote while you worked is there, unread",
          s is not None and friend(s, "Kari")["unread"] == 1)
    check("and nothing from before arrived twice",
          s is not None and sum(1 for m in s["log"] if m["x"] == "takk! pause nå?") == 1)
    with open(os.path.join(d, "chat-self")) as f:
        check("the sender id is the same one", f.read().strip() == me)

    t = int(time.time())
    empty = new_room_dir(relay)
    t0 = time.time()
    one = subprocess.run([BIN, "status", empty, "work", str(t), str(t + 60)], timeout=20)
    check("a status post with no friends does nothing, at once",
          one.returncode == 0 and time.time() - t0 < 2)

    # How the watcher ends it when it has not noticed by itself: SIGTERM.
    r.send_signal(15)
    check("SIGTERM: it exits, taking only what the overlay was shown",
          r.wait(timeout=6) == 0 and not os.path.exists(os.path.join(d, ".tomato-chat"))
          and os.path.exists(os.path.join(d, "chat-log.tsv")))
    k.close()


def lag(peers):
    """ntfy.sh writes its history a few seconds behind what it sends live, so
    a message posted just before a break's chat subscribes is in neither the
    history it is handed nor the stream. The stand-in is made that slow here,
    and the message still arrives."""
    print("a relay slow to write its history")
    relay_p, relay = start_relay(RELAY_CACHE_DELAY="4")
    try:
        d = new_room_dir(relay)
        pomo(d, "BREAK")
        code = new_code()
        r = room(d)
        state(d)
        command(d, "join\tPer\t%s" % code)
        state(d, lambda s: s["note"] and s["note"]["k"] == "joined")
        r.send_signal(15)
        r.wait(timeout=6)
        p = Peer(relay, code)
        peers.append(p)
        p.next(kind("open"))
        p.say("rett før pausen din")
        time.sleep(0.3)
        r = room(d)
        s = state(d, lambda s: any(m["x"] == "rett før pausen din" for m in s["log"]),
                  timeout=20)
        check("a message posted in the lag still arrives, from the second look",
              s is not None)
        p.close()
        r.send_signal(15)
        r.wait(timeout=6)
    finally:
        relay_p.kill()


def live():
    relay = "https://ntfy.sh"
    code = new_code()
    topic = seal(code, "{}")[0]
    print("through %s, topic %s" % (relay, topic))
    tap = Tap(relay, topic)
    a, b, sid_a = conversation(relay, code, tap, ["Trondheim", "Bergen"], settle=6)
    a.close()
    check("b sees a stop", b.next(status("off"), 15) is not None)
    b.say("venter på deg")
    b.close()
    for p in (a, b):
        p.p.wait(timeout=10)
    time.sleep(6)
    c = Peer(relay, code)
    check("a message left while nobody was there is handed to the next to arrive",
          c.next(text("venter på deg"), 20) is not None)
    c.close()
    c.p.wait(timeout=10)
    errors = [e for p in (a, b, c) for e in p.log if e[0] in ("error", "down")]
    check("no errors from the relay", not errors)
    for e in errors:
        print("          %s" % "\t".join(e))
    time.sleep(1)
    tap.kill()
    print("\nwhat ntfy.sh carried (%d messages):" % len(tap.bodies))
    for body in tap.bodies:
        print("  %s…" % body[:72])


def main():
    global BIN
    BIN = build()
    if "--live" in sys.argv[1:]:
        live()
    else:
        local()
    print("\n%d cases, %d failed" % (total, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
