#!/usr/bin/env python3
"""A stand-in for ntfy.sh, for the chat tests and the scratch install.

The chat helper talks to one relay, and the real one is shared in a way no
environment variable can separate: ntfy.sh allows 250 messages a day per IP
address, and a test run spends them from the same address the real install
chats from. A test suite pointed at ntfy.sh would, on a busy day, be what kept
a real message from arriving. So tests talk to this instead, and nothing they
do leaves the machine.

It implements the part of ntfy the helper uses, and nothing else:

  GET  /<topic>/json   a stream, one JSON object per line: "open" once
                       subscribed, "message" for each message, "keepalive"
                       now and then so a dead peer is noticed
  POST /<topic>        hand the body to everyone subscribed right now

Every message is treated as `Cache: no` — delivered to whoever is listening,
stored nowhere — because that is the only way the helper ever sends, and a
relay more forgiving than the real one would hide the day it stopped doing so.

    python3 spotlight/chat-relay.py [port]     prints "port N", then serves

Loopback only, like the dashboard. It has no token because it holds nothing:
anyone on this machine who can reach it can already read ~/.timetrack.
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

TOPIC = re.compile(r"^/([-_A-Za-z0-9]{1,64})(/json)?$")
# ntfy's own limit. Past it, ntfy turns the body into an attachment, which the
# helper never reads; refusing is the nearest honest imitation.
MAX_BODY = 4096
# ntfy.sh sends one every 45 seconds. The tests set it lower so that a peer
# that has gone is noticed, and its stream dropped, within the test's patience.
KEEPALIVE = float(os.environ.get("RELAY_KEEPALIVE", "45"))

subs = {}
lock = threading.Lock()


def event(kind, topic, message=None):
    e = {"id": secrets.token_urlsafe(9), "time": int(time.time()),
         "event": kind, "topic": topic}
    if message is not None:
        e["message"] = message
    return (json.dumps(e) + "\n").encode()


class Relay(http.server.BaseHTTPRequestHandler):
    server_version = "chat-relay"

    def log_message(self, *args):
        pass

    def do_GET(self):
        m = TOPIC.match(self.path)
        if not m or not m.group(2):
            return self.send_error(404)
        topic = m.group(1)
        q = queue.Queue()
        # Registered before "open" is written, so that anything posted after a
        # subscriber has seen "open" is guaranteed to reach it. The helper
        # sends its hello on "open", and depends on exactly that.
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
            self.wfile.write(event("open", topic))
            self.wfile.flush()
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
            with lock:
                s = subs.get(topic)
                if s is not None:
                    s.discard(q)
                    if not s:
                        del subs[topic]

    def do_POST(self):
        m = TOPIC.match(self.path)
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
        line = event("message", topic, text)
        with lock:
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
