#!/usr/bin/env python3
"""Cases for the break chat. Run: python3 spotlight/chat.test.py [--live]

Compiles ttchat, starts chat-relay.py on a loopback port, and drives two
headless peers through it — the two ends of a friendship, on one Mac, which is
all a relay needs to be tested with: it cannot tell Trondheim from Bergen, and
does not try.

Most of the cases are refusals. A chat that delivers messages is easy to
demonstrate and says little; what makes it safe is everything that arrives and
is thrown away before it is read, and each of those is shown here arriving
correctly encrypted, so that it is refused for the reason given and not for
some earlier accident.

Nothing leaves the machine unless --live, which holds one short conversation
through ntfy.sh itself: six messages of the 250 a day it allows this IP
address, the same address the real install chats from. Not something to run
in a loop.

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


def new_code():
    return subprocess.run([BIN, "code"], capture_output=True, text=True,
                          check=True).stdout.strip()


def seal(code, envelope):
    raw = envelope if isinstance(envelope, str) else json.dumps(envelope)
    out = subprocess.run([BIN, "seal", code, raw], capture_output=True, text=True,
                         check=True).stdout.strip()
    topic, blob = out.split("\t")
    return topic, blob


# A forged sender: a session neither peer is running, so a refusal can only be
# for the reason under test and never because it looked like an echo.
def envelope(kind="text", x=None, t=None, v=1):
    e = {"v": v, "s": "0123456789abcdef", "i": os.urandom(8).hex(),
         "t": int(time.time()) if t is None else t, "k": kind}
    if x is not None:
        e["x"] = x
    return e


def post(relay, topic, body):
    req = urllib.request.Request("%s/%s" % (relay, topic), data=body.encode(),
                                 method="POST", headers={"Cache": "no"})
    urllib.request.urlopen(req, timeout=5).read()


def refused_at_start(relay, code):
    p = subprocess.run([BIN, "peer", relay, code], stdin=subprocess.DEVNULL,
                       capture_output=True, text=True, timeout=10)
    return p.returncode == 2


class Peer:
    """One headless ttchat, its events queued as they arrive."""

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


# Either it got through, or it was refused — and never for being our own echo,
# which is noise from the peer's own sends rather than an answer to the case.
def verdict(e):
    return e[0] == "text" or (e[0] == "drop" and e[1] != "echo")


class Tap:
    """What the relay sees: a third subscriber to the topic, holding no key."""

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


def conversation(relay, code, tap, plain):
    """Arrive, talk both ways, leave. Shared by the local run and --live."""
    a = Peer(relay, code)
    check("a subscribes", a.next(kind("open")) is not None)
    b = Peer(relay, code)
    check("b subscribes", b.next(kind("open")) is not None)
    ha = a.next(kind("here"))
    check("a sees b arrive (b's hello)", ha is not None)
    hb = b.next(kind("here"))
    check("b sees a (a's answer to it)", hb is not None)
    sid_a = hb[1] if hb else "?"
    sid_b = ha[1] if ha else "?"

    msg = "hei fra Trondheim — æøå 🍅"
    a.say(msg)
    ev = b.next(kind("text"))
    check("a → b arrives, unicode intact", ev == ["text", sid_a, msg])
    b.say("hei fra Bergen")
    ev = a.next(kind("text"))
    check("b → a arrives", ev == ["text", sid_b, "hei fra Bergen"])
    check("a's own message comes back to it and is dropped as an echo",
          a.saw(["drop", "echo"]))
    check("nothing a received as text claimed to be from a",
          not any(e[0] == "text" and e[1] == sid_a for e in a.log))
    time.sleep(0.5)
    check("the relay saw sealed blobs, and never the text",
          len(tap.bodies) >= 4
          and all(x.startswith("tt1:") for x in tap.bodies)
          and not any(p in x for x in tap.bodies for p in plain))
    return a, b, sid_a


def local():
    relay_p = subprocess.Popen([sys.executable, os.path.join(HERE, "chat-relay.py"), "0"],
                               stdout=subprocess.PIPE, text=True,
                               env=dict(os.environ, RELAY_KEEPALIVE="2"))
    relay = "http://127.0.0.1:%d" % int(relay_p.stdout.readline().split()[1])
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
        refused(seal(code, envelope(x="from the future", v=2))[1], "malformed",
                "an unknown protocol version")
        refused(seal(code, envelope(kind="run", x="open -a Calculator"))[1], "malformed",
                "an unknown kind of message")
        refused(seal(code, envelope(x="x" * 501))[1], "malformed",
                "a text over 500 characters (refused, not cut)")
        refused(seal(code, envelope(x="ten minutes ago", t=int(time.time()) - 600))[1],
                "stale", "a message ten minutes old")
        refused(seal(code, envelope(x="ten minutes ahead", t=int(time.time()) + 600))[1],
                "stale", "a message ten minutes in the future")

        def accepted(label, text):
            ev = b.next(verdict)
            check(label, ev is not None and ev[0] == "text" and ev[2:] == [text])

        _, once = seal(code, envelope(x="only once"))
        post(relay, topic, once)
        accepted("a correctly sealed message from a third session is accepted",
                 "only once")
        refused(once, "replay", "the same message again")

        post(relay, topic, seal(code, envelope(x="‮evil\x07\nnext\tline"))[1])
        accepted("control characters and bidi overrides are removed, "
                 "breaks become spaces", "evil next line")

        print("leaving")
        a.close()
        check("b sees a go when a's stdin closes", b.next(kind("gone")) == ["gone", sid_a])
        check("a exits cleanly", a.p.wait(timeout=5) == 0)

        print("flooding")
        for n in range(25):
            post(relay, topic, seal(code, envelope(x="flood %d" % n))[1])
        got = [b.next(verdict) for _ in range(25)]
        texts = sum(1 for e in got if e and e[0] == "text")
        rated = sum(1 for e in got if e == ["drop", "rate"])
        check("at most twenty in ten seconds get through; the rest are dropped "
              "(%d through, %d dropped)" % (texts, rated),
              texts <= 20 and rated >= 5 and texts + rated == 25)
        b.close()
        b.p.wait(timeout=5)
    finally:
        for p in peers:
            p.kill()
        if tap:
            tap.kill()
        relay_p.kill()


def live():
    relay = "https://ntfy.sh"
    code = new_code()
    topic = seal(code, "{}")[0]
    print("one conversation through %s, topic %s" % (relay, topic))
    tap = Tap(relay, topic)
    a, b, sid_a = conversation(relay, code, tap, ["Trondheim", "Bergen"])
    a.close()
    check("b sees a go", b.next(kind("gone"), timeout=15) == ["gone", sid_a])
    b.close()
    for p in (a, b):
        p.p.wait(timeout=10)
    errors = [e for p in (a, b) for e in p.log if e[0] == "error"]
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
