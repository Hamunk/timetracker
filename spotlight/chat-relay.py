#!/usr/bin/env python3
"""A stand-in for ntfy.sh, for the chat tests and the scratch install.

The chat helper talks to one relay, and the real one is shared in a way no
environment variable can separate: ntfy.sh allows 250 messages a day per IP
address, and a test run spends them from the same address the real install
chats from. A test suite pointed at ntfy.sh would, on a busy day, be what kept
a real message from arriving. So tests talk to this instead, and nothing they
do leaves the machine.

It implements the part of ntfy the helper uses, and nothing else:

  GET  /<topic>/json[?since=..]   a stream, one JSON object per line: "open"
                                  once subscribed, then every kept message
                                  since the given time, then each new message
                                  as it comes, and "keepalive" now and then
  GET  /<topic>/json?poll=1&since=..   the kept messages, and the end
  POST /<topic>                   keep the body for twelve hours, unless sent
                                  `Cache: no`, and hand it to everyone
                                  subscribed right now

`since` is a Unix time, a duration like 12h, or `all`, as on ntfy.sh.

RELAY_CACHE_DELAY makes a kept message visible to `since` only that many
seconds after it arrived, while still delivering it live at once. ntfy.sh
behaves like that — its history is written a few seconds behind — and a relay
kinder than the real one would hide the day the helper stopped allowing for
it.

    python3 spotlight/chat-relay.py [port]     prints "port N", then serves

Loopback only, like the dashboard. It has no token because it holds nothing
that is not sealed: anyone on this machine who can reach it can already read
~/.timetrack.
"""
import http.server
import json
import os
import queue
import re
import secrets
import sys
import threading
import time
import urllib.parse

TOPIC = re.compile(r"^/([-_A-Za-z0-9]{1,64})(/json)?$")
# ntfy's own limit. Past it, ntfy turns the body into an attachment, which the
# helper never reads; refusing is the nearest honest imitation.
MAX_BODY = 4096
KEEP = 12 * 3600
# ntfy.sh sends one every 45 seconds. The tests set it lower so that a peer
# that has gone is noticed, and its stream dropped, within the test's patience.
KEEPALIVE = float(os.environ.get("RELAY_KEEPALIVE", "45"))
DELAY = float(os.environ.get("RELAY_CACHE_DELAY", "0"))

subs = {}
kept = {}          # topic -> [(time, visible_from, line)]
lock = threading.Lock()


def event(kind, topic, message=None, at=None):
    e = {"id": secrets.token_urlsafe(9), "time": int(at or time.time()),
         "event": kind, "topic": topic}
    if message is not None:
        e["message"] = message
        e["expires"] = e["time"] + KEEP
    return (json.dumps(e) + "\n").encode()


def since_of(query):
    """The earliest message time asked for, or None for "only new ones"."""
    raw = (query.get("since") or [None])[0]
    if raw is None:
        return None
    if raw == "all":
        return 0
    if raw.isdigit():
        return int(raw)
    m = re.fullmatch(r"(\d+)([smhd])", raw)
    if m:
        unit = {"s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)]
        return int(time.time()) - int(m.group(1)) * unit
    return None


def history(topic, since):
    now = time.time()
    with lock:
        return [line for (t, vis, line) in kept.get(topic, ())
                if t >= since and vis <= now]


class Relay(http.server.BaseHTTPRequestHandler):
    server_version = "chat-relay"

    def log_message(self, *args):
        pass

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        m = TOPIC.match(url.path)
        if not m or not m.group(2):
            return self.send_error(404)
        topic = m.group(1)
        query = urllib.parse.parse_qs(url.query)
        since = since_of(query)
        poll = (query.get("poll") or [""])[0] == "1"
        q = queue.Queue()
        if not poll:
            # Registered before anything is written, so that whatever is
            # posted after a subscriber has seen "open" is sure to reach it.
            # It may reach it twice, from history and live; so it can on
            # ntfy.sh, and the helper drops the second by its id.
            with lock:
                subs.setdefault(topic, set()).add(q)
        try:
            self.send_response(200)
            # Without a declared type, URLSession holds back the first 512
            # bytes to sniff one, and a stream of short lines sits unread.
            self.send_header("Content-Type", "application/x-ndjson; charset=utf-8")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if not poll:
                self.wfile.write(event("open", topic))
            if since is not None:
                for line in history(topic, since):
                    self.wfile.write(line)
            self.wfile.flush()
            if poll:
                return
            while True:
                try:
                    line = q.get(timeout=KEEPALIVE)
                except queue.Empty:
                    line = event("keepalive", topic)
                self.wfile.write(line)
                self.wfile.flush()
        except OSError:
            pass
        finally:
            if not poll:
                with lock:
                    s = subs.get(topic)
                    if s is not None:
                        s.discard(q)
                        if not s:
                            del subs[topic]

    def do_POST(self):
        m = TOPIC.match(urllib.parse.urlsplit(self.path).path)
        if not m or m.group(2):
            return self.send_error(404)
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return self.send_error(400)
        if n < 0:
            return self.send_error(400)
        if n > MAX_BODY:
            return self.send_error(413)
        try:
            text = self.rfile.read(n).decode("utf-8")
        except UnicodeDecodeError:
            return self.send_error(400)
        topic = m.group(1)
        now = time.time()
        line = event("message", topic, text, at=now)
        keep = (self.headers.get("Cache") or self.headers.get("X-Cache") or "").lower() != "no"
        with lock:
            if keep:
                kept.setdefault(topic, []).append((int(now), now + DELAY, line))
                kept[topic] = [k for k in kept[topic] if k[0] > now - KEEP]
            targets = list(subs.get(topic, ()))
        for q in targets:
            q.put(line)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(line)))
        self.end_headers()
        self.wfile.write(line)

    do_PUT = do_POST


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), Relay)
    srv.daemon_threads = True
    print("port %d" % srv.server_address[1], flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
