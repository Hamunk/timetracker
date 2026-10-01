// TimeTracker chat. The one program in TimeTracker that talks to the
// internet, and it talks to exactly one place: the relay, ntfy.sh unless
// chat-relay says otherwise, outbound, over HTTPS. Nothing listens. There is
// no socket here for anybody to connect to, which is the difference between
// this and every peer-to-peer design that was considered first.
//
// Why a relay at all, when the brief was "no server": two Macs on two
// eduroams, or behind two home routers, can neither find nor reach each other
// on their own. Signal has the same problem and answers it the same way —
// every message goes through a server, and the server can read none of them.
// The relay here is a dumb pipe. It sees two IP addresses, when each of them
// changes phase, and base64. It keeps what it is given for twelve hours and
// then forgets it, and anything it could invent fails authentication before a
// byte of it is parsed.
//
// The twelve hours are the point. A message written to a friend who is
// working waits there, sealed, and arrives when their next break starts; so
// does where you are in your cycle. Nothing here runs during a work session
// except, at each change of phase, a moment's post of that change.
//
// A friendship is one 32-byte secret. Everything else is derived from it: the
// topic both use, and the key every message is sealed with. Nothing that says
// who you are is ever outside the seal.
//
// How the two Macs come to share it is the part that changed. It used to be
// made on one Mac and carried to the other by hand, as a code of fifty-odd
// characters: copied from a break screen that covers the whole display, sent
// some other way, pasted into a break screen on the other side. It was secure
// and nearly impossible to explain. Now each Mac has a username and a
// Curve25519 key, and a friend request is a public key left at a mailbox the
// other's username names:
//
//   1. You add "malin". Your public key, and your username, go to the topic
//      derived from "malin" — her inbox.
//   2. Her Mac finds the request there. She accepts; her Mac derives the
//      secret from her private key and yours, and leaves her public key in
//      your inbox.
//   3. Your Mac finds that, and derives the same secret from your private key
//      and hers.
//
// The relay sees two public keys and two usernames, and can make nothing of
// them: Diffie-Hellman is exactly the problem of getting from those to the
// secret. What it does not stop is somebody who knows both usernames sending
// a request that claims to come from one of them, which is why a request is
// something you accept, not something that happens to you. SECURITY.md has
// the rest. Friends made with a code before this are untouched: the secret is
// the same kind of thing either way, and friends.tsv stores it the same way.
//
//   ttchat break <dir>           the break's chat, started by pomodoro-watch.sh
//                                when a break begins; exits when it ends
//   ttchat status <dir> <phase> <since> <until>
//                                post where you are in your cycle to every
//                                friend, look in your inbox, and exit. The
//                                watcher's, at each change of phase
//   ttchat list <dir>            friends, requests and your username, as JSON;
//                                reads files only. The app's
//   ttchat setname <dir> <name>  your username
//   ttchat add <dir> <user>      ask somebody to be friends
//   ttchat accept|ignore <dir> <request id>
//   ttchat rename <dir> <id> <name>
//   ttchat forget <dir> <id>
//   ttchat inbox <dir>           collect requests and answers, and exit
//                                (all six print one line for the app to show,
//                                and exit 1 when it says no)
//   ttchat code                  a fresh pairing code, on stdout
//   ttchat peer <relay> <code>   one friendship, headless: a friend on a break,
//                                in a terminal. Each stdin line is sent, except
//                                /work [min], /break [min] and /off, which say
//                                where this friend is; events are TSV lines on
//                                stdout. What chat.test.py and dev.sh drive.
//   ttchat seal <code> <json>    seal one raw envelope; prints topic<TAB>blob.
//                                For the tests only: a stale, replayed or
//                                malformed message that is nevertheless
//                                correctly encrypted is the only way to show it
//                                is refused for the right reason. It can make
//                                nothing the holder of the code could not.
//
// Break mode's files, all in <dir>, all fixed names, all 600, all written by
// this program and no other:
//
//   friends.tsv          id, name, code, added, username. The codes are the
//                        friendships; nothing else in TimeTracker reads one.
//                        The name is yours to change; the username is theirs.
//   chat-requests.tsv    requests waiting: in (asking you) and out (yours)
//   chat-name            your username
//   chat-key             your Curve25519 private key, made once
//   .chat-book.lock      held while friends.tsv or the requests change: the
//                        app and a break's chat can both change them
//   chat-log.tsv         what you and your friends have said, the latest few
//                        hundred lines per friend
//   chat-sync.tsv        per friend: how far into the relay's history this Mac
//                        has read, what you have read, and where they are
//   chat-self            this Mac's sender id, so it knows its own messages
//                        when the relay hands them back
//   chat-relay           optional, and the one written by you: the relay, one
//                        URL. Absent means ntfy.sh.
//   .tomato-chat-cmd     one command from the overlay, consumed here
//   .tomato-chat         what the overlay shows. Deleted when the break ends.
//   .tomato-chat.lock    one break chat per data directory, ever
//
// Peer-mode events, one per line:
//
//   open                                  subscribed
//   text   <sender> <text> <id> <time>    they said something
//   status <sender> <phase> <since> <until> <time>
//   sent   <kind>                         the relay accepted one of ours
//   drop   <reason>                       something arrived and was refused
//   down   <detail>                       the stream broke; retrying
//   error  <detail>                       the relay refused something we sent

import CryptoKit
import Foundation

// Friend text is capped where a break note is capped. ntfy delivers a longer
// body as an attachment, never as a message, so nothing of ours is ever
// larger than maxWire.
let maxText = 500
let maxWire = 4096
// How old a message may be and still be believed. The relay keeps one for
// twelve hours, so a message can honestly arrive that late — a friend wrote
// while you were working — and not later than the relay would have kept it;
// the hour on top is for clocks. Older than that is a replay, whatever it says.
let maxAge = 13.0 * 3600
// How far ahead. Two Macs on NTP agree to well inside this.
let maxAhead = 120.0
// How far back a friendship's first subscription reaches: everything the
// relay still has.
let backlog = 12 * 3600
// One stream per friend, and ntfy.sh allows thirty per address.
let maxFriends = 20
let maxName = 40
// Lines of history kept per friend. Never fewer than the relay's twelve
// hours, whatever the count: those ids are the replay check.
let keepPerFriend = 200
// Lines per friend handed to the overlay. The conversation, not the archive.
let showPerFriend = 60
// 2: messages wait on the relay, and "status" replaced presence. A version-1
// helper and this one refuse each other's messages outright, which is the
// right failure: two friends on mismatched installs see nothing rather than
// half of something.
let wireVersion = 2
let kinds: Set<String> = ["text", "status"]
let phases: Set<String> = ["work", "break", "off"]
let codePrefix = "tt1-"
let wirePrefix = "tt1:"
let defaultRelay = "https://ntfy.sh"
let badCode = "not a pairing code, or one that lost a character on the way"

func now() -> Int { return Int(Date().timeIntervalSince1970) }

func b64url(_ d: Data) -> String {
    return d.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func unb64url(_ s: String) -> Data? {
    var t = s.replacingOccurrences(of: "-", with: "+")
             .replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t += "=" }
    return Data(base64Encoded: t)
}

// "tt1-" + base64url(secret ‖ the first two bytes of its SHA-256). The check
// bytes are for the paste that lost its last character: without them a
// truncated code is simply a different secret, and the symptom would be a
// friend who never hears from you, forever, with nothing to say why. Nobody
// pastes one any more, but friends.tsv still stores every friendship this
// way, the ones made by name included.
func codeFor(_ secret: Data) -> String {
    return codePrefix + b64url(secret + Data(SHA256.hash(data: secret).prefix(2)))
}

func newCode() -> String {
    return codeFor(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
}

func parseCode(_ s: String) -> Data? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.hasPrefix(codePrefix),
          let d = unb64url(String(t.dropFirst(codePrefix.count))), d.count == 34
    else { return nil }
    let secret = Data(d.prefix(32))
    guard Data(SHA256.hash(data: secret).prefix(2)) == Data(d.suffix(2)) else { return nil }
    return secret
}

// The topic and the key, from one secret, by two labels. The topic is 192
// bits of base64url — ntfy's own topic alphabet, so it needs no escaping in a
// path — because it is the one thing that lets a stranger post to a
// friendship at all, and posting is all they could then do: anything they
// send fails to open.
func derive(_ secret: Data) -> (topic: String, key: SymmetricKey) {
    let ikm = SymmetricKey(data: secret)
    let salt = Data("timetracker-chat-v1".utf8)
    let t = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                   info: Data("topic".utf8), outputByteCount: 24)
    let k = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                   info: Data("message".utf8), outputByteCount: 32)
    return ("tt" + b64url(t.withUnsafeBytes { Data($0) }), k)
}

// https anywhere; plain http only to this machine, which is the dev relay. The
// messages are sealed either way, but the topic is in the path, and a topic
// sent in the clear across a café's Wi-Fi is a friendship anybody there can
// flood.
func relayURL(_ s: String) -> URL? {
    guard let c = URLComponents(string: s), let host = c.host?.lowercased(),
          !host.isEmpty, c.query == nil, c.fragment == nil,
          c.user == nil, c.password == nil else { return nil }
    let loopback = host == "127.0.0.1" || host == "localhost"
    guard c.scheme == "https" || (c.scheme == "http" && loopback) else { return nil }
    return c.url
}

func relayFor(_ dir: String) -> URL? {
    let raw = (try? String(contentsOfFile: dir + "/chat-relay", encoding: .utf8))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    return relayURL(raw.isEmpty ? defaultRelay : raw)
}

func randomID() -> String {
    var g = SystemRandomNumberGenerator()
    return String(format: "%016llx", g.next() as UInt64)
}

func isHex(_ s: String, _ n: Int) -> Bool {
    return s.count == n && s.allSatisfy { "0123456789abcdef".contains($0) }
}

func isID(_ s: String) -> Bool { return isHex(s, 16) }

// Friend text is the first thing in this program that was written on somebody
// else's machine. One line; no control characters; and none of the
// bidirectional overrides and isolates, which can make a line read on screen
// as something other than what it says.
func clean(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for u in s.unicodeScalars {
        switch u.value {
        case 0x09, 0x0A, 0x0D, 0x85, 0x2028, 0x2029: out.append(" ")
        case 0x00...0x1F, 0x7F...0x9F, 0x202A...0x202E, 0x2066...0x2069: continue
        default: out.append(u)
        }
    }
    return String(String(out).trimmingCharacters(in: .whitespaces).prefix(maxText))
}

func quiet() -> URLSessionConfiguration {
    // Nothing about a relay conversation belongs on disk: no cache, no
    // cookies, no credential store.
    let c = URLSessionConfiguration.ephemeral
    c.urlCache = nil
    c.httpCookieStorage = nil
    c.httpShouldSetCookies = false
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    // ntfy keeps an idle stream alive with a line every 45 seconds, so a
    // stream silent for much longer than that has died without saying so.
    c.timeoutIntervalForRequest = 150
    return c
}

func writePrivate(_ path: String, _ data: Data) {
    // Written beside the target and renamed over it, so a reader never sees
    // half a file; created 600, because these hold codes, or what your
    // friends said to you, or both.
    let tmp = path + ".\(getpid()).tmp"
    guard FileManager.default.createFile(atPath: tmp, contents: data,
                                         attributes: [.posixPermissions: 0o600])
    else { return }
    if rename(tmp, path) != 0 { unlink(tmp) }
}

// This Mac's sender id, made once. Once, and not per run, because the relay
// hands everything back — your own messages included, hours later — and a
// message from yesterday's run has to be recognised as yours. Created with
// O_EXCL because two helpers can come up in the same second (the break's
// chat and a status post) and they must not each invent one: the loser would
// read its own status back as a friend's.
func selfID(_ dir: String) -> String {
    let p = dir + "/chat-self"
    for _ in 0..<2 {
        if let s = try? String(contentsOfFile: p, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if isID(t) { return t }
            unlink(p)
        }
        let fd = open(p, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        if fd >= 0 {
            let id = randomID()
            _ = (id + "\n").withCString { write(fd, $0, strlen($0)) }
            close(fd)
            return id
        }
    }
    return randomID()
}

struct Friend {
    let id: String
    var name: String
    let code: String
    let secret: Data
    let added: Int
    // Their username, for a friend made by name; empty for one made with a
    // code, who never had one as far as this Mac knows.
    let user: String
}

func loadFriends(_ dir: String) -> [Friend] {
    guard let raw = try? String(contentsOfFile: dir + "/friends.tsv", encoding: .utf8)
    else { return [] }
    var out: [Friend] = []
    for line in raw.split(separator: "\n") {
        // The header, and any row this program did not write, fall out here:
        // an id that is not eight hex digits, or a code that fails its check.
        let f = line.components(separatedBy: "\t")
        guard f.count >= 3, isHex(f[0], 8), let s = parseCode(f[2]) else { continue }
        let name = String(clean(f[1]).prefix(maxName))
        guard !name.isEmpty,
              !out.contains(where: { $0.id == f[0] || $0.secret == s }) else { continue }
        out.append(Friend(id: f[0], name: name,
                          code: f[2].trimmingCharacters(in: .whitespaces), secret: s,
                          added: f.count > 3 ? Int(f[3]) ?? 0 : 0,
                          user: f.count > 4 ? normUser(f[4]) ?? "" : ""))
        if out.count == maxFriends { break }
    }
    return out
}

func saveFriends(_ dir: String, _ friends: [Friend]) {
    var s = "id\tname\tcode\tadded\tusername\n"
    for f in friends { s += "\(f.id)\t\(f.name)\t\(f.code)\t\(f.added)\t\(f.user)\n" }
    writePrivate(dir + "/friends.tsv", Data(s.utf8))
}

// One friendship.
//
// Every message is one JSON object, sealed with ChaChaPoly under the
// friendship's key, with the topic as associated data so a blob cannot be
// lifted from one friendship into another:
//
//   {"v":2, "s":sender, "i":message id, "t":unix seconds, "k":kind, ...}
//
//   s  this Mac, for good (chat-self). The relay hands every message to every
//      subscriber, the sender included, and hands back hours of them on each
//      subscription; this is how a Mac knows its own.
//   i  random per message: the replay check, and the log's key.
//   t  the staleness check.
//   k  text   {"x": what was said}
//      status {"ph": work|break|off, "since": when it began,
//              "until": when it is planned to end, 0 for off}
final class Chat: NSObject, URLSessionDataDelegate {
    let relay: URL
    let topic: String
    let key: SymmetricKey
    let me: String
    let emit: ([String]) -> Void

    // Where in the relay's history to subscribe from, by the relay's clock,
    // and the newest message this has seen by that same clock.
    var since: Int
    var newest = 0
    var stream: URLSessionDataTask?
    var why: String?
    var slow = false
    var buf = Data()
    var backoff = 2.0
    var stopping = false
    var seen: Set<String>
    var seenOrder: [String] = []
    var heard: [Date] = []
    var said: [Date] = []

    // Two sessions: the stream wants a delegate, and a post wants a
    // completion handler, and one URLSession delivers a task's data to one or
    // the other, never both.
    lazy var listen = URLSession(configuration: quiet(), delegate: self,
                                 delegateQueue: OperationQueue.main)
    let post = URLSession(configuration: quiet())

    init(relay: URL, secret: Data, me: String, since: Int, seen: Set<String> = [],
         emit: @escaping ([String]) -> Void) {
        self.relay = relay
        (topic, key) = derive(secret)
        self.me = me
        self.since = since
        self.seen = seen
        self.emit = emit
    }

    func url(from: Int, poll: Bool) -> URL {
        var c = URLComponents(url: relay.appendingPathComponent(topic)
                                         .appendingPathComponent("json"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "since", value: String(from))]
            + (poll ? [URLQueryItem(name: "poll", value: "1")] : [])
        return c.url!
    }

    func start() { subscribe() }

    func subscribe() {
        guard !stopping else { return }
        why = nil
        slow = false
        buf = Data()
        stream = listen.dataTask(with: url(from: since, poll: false))
        stream?.resume()
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200 { completionHandler(.allow); return }
        why = "the relay answered \(code)"
        slow = code == 429
        completionHandler(.cancel)
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === stream else { return }
        buf.append(data)
        while let nl = buf.firstIndex(of: 0x0A) {
            let line = Data(buf[buf.startIndex..<nl])
            buf = Data(buf[buf.index(after: nl)...])
            relayLine(line)
        }
        // ntfy's lines are a few kilobytes at most. A relay that sends a
        // megabyte without a newline is not ntfy, and is not buffered.
        if buf.count > 65536 {
            why = "the relay sent a line too long to be a message"
            dataTask.cancel()
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === stream else { return }
        stream = nil
        if stopping { return }
        emit(["down", clean(why ?? error?.localizedDescription ?? "the relay closed the stream")])
        // Picked up where it left off, with a minute's overlap: what arrives
        // twice is dropped by its id, what arrived in the gap is not lost.
        since = max(since, newest - 60)
        let wait = slow ? 60 : backoff
        backoff = min(backoff * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.subscribe() }
    }

    // The relay's own envelope is the one thing parsed before authentication,
    // because it has to be: it is how the sealed blob is found. Three fields
    // are read out of it, and anything else a newer relay adds is ignored.
    func relayLine(_ line: Data) {
        guard !line.isEmpty,
              let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let ev = o["event"] as? String else { return }
        if ev == "open" {
            backoff = 2
            emit(["open"])
            // ntfy.sh writes its history a few seconds behind what it sends
            // live. A message posted in those seconds before this stream
            // opened is in neither: too late for the history this stream was
            // given, too early for the stream itself. So the history is asked
            // for again once it has caught up. Anything read twice is
            // dropped by its id.
            let from = now() - 60
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.repoll(from)
            }
        } else if ev == "message", let m = o["message"] as? String {
            if let t = o["time"] as? Int, t > newest { newest = t }
            receive(m)
        }
    }

    func repoll(_ from: Int) {
        guard !stopping else { return }
        post.dataTask(with: url(from: from, poll: true)) { [weak self] data, resp, _ in
            guard let data = data, data.count < 4 << 20,
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            DispatchQueue.main.async {
                guard let self = self, !self.stopping else { return }
                for line in data.split(separator: 0x0A) { self.relayLine(Data(line)) }
            }
        }.resume()
    }

    func drop(_ reason: String) { emit(["drop", reason]) }

    // The order is the argument. Nothing is decoded until it has been shown
    // to come from somebody holding the code; nothing is acted on until it is
    // shown to be recent enough, new, and well-formed; and even then it is a
    // friend's input — no longer anonymous, still not trusted.
    func receive(_ m: String) {
        guard m.hasPrefix(wirePrefix) else { return drop("foreign") }
        guard m.utf8.count <= maxWire,
              let raw = Data(base64Encoded: String(m.dropFirst(wirePrefix.count))),
              let box = try? ChaChaPoly.SealedBox(combined: raw),
              let plain = try? ChaChaPoly.open(box, using: key,
                                               authenticating: Data(topic.utf8))
        else { return drop("auth") }
        guard let o = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any],
              (o["v"] as? Int) == wireVersion,
              let s = o["s"] as? String, isID(s),
              let i = o["i"] as? String, isID(i),
              let t = o["t"] as? Int,
              let k = o["k"] as? String, kinds.contains(k)
        else { return drop("malformed") }
        if s == me { return drop("echo") }
        let age = Date().timeIntervalSince1970 - Double(t)
        if age > maxAge || -age > maxAhead { return drop("stale") }
        if seen.contains(i) { return drop("replay") }
        seen.insert(i)
        seenOrder.append(i)
        if seenOrder.count > 5000 { seen.remove(seenOrder.removeFirst()) }
        // A flood is something arriving now. What waited on the relay while
        // this Mac was working arrives all at once by design, and is bounded
        // by the relay's twelve hours rather than by this.
        if age < 60 {
            let d = Date()
            heard = heard.filter { d.timeIntervalSince($0) < 10 }
            if heard.count >= 20 { return drop("rate") }
            heard.append(d)
        }
        if k == "text" {
            // Refused rather than cut: nothing of ours sends more, so a longer
            // text was not written by this program, and a shortened sentence
            // can say something its author did not.
            guard let x = o["x"] as? String, x.count <= maxText else { return drop("malformed") }
            let c = clean(x)
            guard !c.isEmpty else { return drop("malformed") }
            emit(["text", s, c, i, String(t)])
        } else {
            guard let ph = o["ph"] as? String, phases.contains(ph),
                  let a = o["since"] as? Int, let b = o["until"] as? Int,
                  a <= t + Int(maxAhead), b == 0 || b >= a
            else { return drop("malformed") }
            emit(["status", s, ph, String(a), String(b), String(t)])
        }
    }

    // The message's id, or nil if it was not sent at all.
    @discardableResult
    func send(_ raw: String, then done: ((Bool) -> Void)? = nil) -> String? {
        let x = clean(raw)
        guard !x.isEmpty, !stopping else { done?(false); return nil }
        let d = Date()
        said = said.filter { d.timeIntervalSince($0) < 10 }
        guard said.count < 10 else { emit(["error", "slow down"]); done?(false); return nil }
        said.append(d)
        return say("text", ["x": x], then: done)
    }

    func status(_ ph: String, since a: Int, until b: Int, then done: ((Bool) -> Void)? = nil) {
        say("status", ["ph": ph, "since": a, "until": b], then: done)
    }

    @discardableResult
    func say(_ kind: String, _ fields: [String: Any],
             then done: ((Bool) -> Void)? = nil) -> String? {
        let id = randomID()
        var env: [String: Any] = ["v": wireVersion, "s": me, "i": id, "t": now(), "k": kind]
        for (k, v) in fields { env[k] = v }
        guard let plain = try? JSONSerialization.data(withJSONObject: env),
              let box = try? ChaChaPoly.seal(plain, using: key,
                                             authenticating: Data(topic.utf8))
        else { done?(false); return nil }
        var req = URLRequest(url: relay.appendingPathComponent(topic))
        req.httpMethod = "POST"
        req.httpBody = Data((wirePrefix + box.combined.base64EncodedString()).utf8)
        // Kept by the relay, sealed, for twelve hours: that is how a message
        // reaches a friend who is working, and how their next break learns
        // where you are. No Cache: no, on purpose.
        //
        // ntfy.sh otherwise copies every message to Firebase for its Android
        // app. Ours is ciphertext, but there is no reason for Google to hold it.
        req.setValue("no", forHTTPHeaderField: "Firebase")
        req.timeoutInterval = 15
        post.dataTask(with: req) { [weak self] _, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                guard let self = self else { return }
                if code == 200 {
                    self.emit(["sent", kind])
                } else if code == 429 {
                    self.emit(["error", "the relay is rate-limiting this address"])
                } else {
                    self.emit(["error", clean(err?.localizedDescription
                                              ?? "the relay answered \(code)")])
                }
                done?(code == 200)
            }
        }.resume()
        return id
    }

    func stop() {
        stopping = true
        stream?.cancel()
    }
}

// --- usernames, keys and the inbox -------------------------------------------
// See the top of this file for the exchange; this is its machinery.
//
// A username is two to twenty-four of a-z, 0-9, dot, dash and underscore,
// compared without case. It names a topic, so it is also the address strangers
// can write to, and nothing about it is secret: anybody who knows it can find
// your inbox, read what is waiting there, and leave a request in it.

let userChars = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")
let inboxPrefix = "tt3:"
let maxRequests = 40

func normUser(_ s: String) -> String? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard (2...24).contains(t.count), t.allSatisfy({ userChars.contains($0) }),
          let first = t.first, first.isLetter || first.isNumber else { return nil }
    return t
}

func readName(_ dir: String) -> String? {
    return (try? String(contentsOfFile: dir + "/chat-name", encoding: .utf8)).flatMap(normUser)
}

// This Mac's private key, made once and kept. Made with O_EXCL for the same
// reason chat-self is: the app and a break's chat can both be the first to
// need it, and two keys would answer one request two different ways. One that
// will not read is replaced, which costs only the requests still waiting on
// it — the friendships themselves keep the secret, not the key.
func myKey(_ dir: String) -> Curve25519.KeyAgreement.PrivateKey? {
    let p = dir + "/chat-key"
    for _ in 0..<3 {
        if let s = try? String(contentsOfFile: p, encoding: .utf8) {
            if let d = Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines)),
               let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: d) { return k }
            unlink(p)
        }
        let fd = open(p, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        if fd >= 0 {
            let k = Curve25519.KeyAgreement.PrivateKey()
            let line = k.rawRepresentation.base64EncodedString() + "\n"
            _ = line.withCString { write(fd, $0, strlen($0)) }
            close(fd)
            return k
        }
        usleep(50_000)
    }
    return nil
}

// A username's inbox: the topic it names, and a key to seal what is left
// there. The key keeps the relay from reading requests at a glance, and no
// more than that — it is derived from the username, which is not a secret.
func inboxFor(_ user: String) -> (topic: String, key: SymmetricKey) {
    let ikm = SymmetricKey(data: Data(("user:" + user).utf8))
    let salt = Data("timetracker-inbox-v1".utf8)
    let t = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                   info: Data("topic".utf8), outputByteCount: 18)
    let k = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                   info: Data("key".utf8), outputByteCount: 32)
    return ("tu" + b64url(t.withUnsafeBytes { Data($0) }), k)
}

// The friendship's secret, from my private key and their public one. Both
// public keys go into the derivation, in an order both sides agree on, so the
// secret belongs to this pair of keys and to no other. A public key that
// makes the shared value all zeros (the small-subgroup points X25519 lets
// through) is refused: every such request would share one secret.
func pairSecret(_ mine: Curve25519.KeyAgreement.PrivateKey, _ theirs: Data) -> Data? {
    guard theirs.count == 32,
          let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirs),
          let shared = try? mine.sharedSecretFromKeyAgreement(with: pub),
          shared.withUnsafeBytes({ $0.contains { $0 != 0 } }) else { return nil }
    let a = mine.publicKey.rawRepresentation
    let info = a.lexicographicallyPrecedes(theirs) ? a + theirs : theirs + a
    return shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                                          salt: Data("timetracker-pair-v1".utf8),
                                          sharedInfo: info, outputByteCount: 32)
        .withUnsafeBytes { Data($0) }
}

// Four symbols from the secret, the same on both Macs. A request names who it
// is from but cannot prove it, so somebody who knows both usernames could
// answer one before its rightful owner does; the two Macs would then hold
// different secrets, and these would differ. Compared side by side, or read
// out over a call, they settle it. Nobody has to: they are there for the
// friend you are not sure of.
let checkSymbols = Array("🍅🌲🚲🐟🍋🐝🌙🎈🔑🧦🍄🐢🦊🐳🍉🍇🥕🌵🌻🍁🐞🦉🐙🦀🐸🐧🎸🥁📚🧲🚀🚂🌋🔥💧🌈🍪🧀🍩🥨🍿🧩🎲🎯🔔📷💡🧭🧸🎩👟🧤🎒🛶🐌🦋🐘🦒🍒🥝🥑🌽🍞🧁")

func checkFor(_ secret: Data) -> String {
    let h = Array(SHA256.hash(data: Data("timetracker-check".utf8) + secret))
    return (0..<4).map { String(checkSymbols[Int(h[$0]) % checkSymbols.count]) }
        .joined(separator: " ")
}

// One synchronous request, for the commands that run and exit. Fifteen
// seconds, the same as a post from a break.
func fetchSync(_ req: URLRequest) -> (Int, Data?) {
    let done = DispatchSemaphore(value: 0)
    var code = 0
    var body: Data?
    URLSession(configuration: quiet()).dataTask(with: req) { d, r, _ in
        code = (r as? HTTPURLResponse)?.statusCode ?? 0
        body = d
        done.signal()
    }.resume()
    if done.wait(timeout: .now() + 20) == .timedOut { return (0, nil) }
    return (code, body)
}

// A request ("req") or an answer ("ok") into somebody's inbox:
//   {"v":3, "k":req|ok, "u":my username, "p":my public key, "i":id, "t":now,
//    "re": the request an answer answers}
func inboxSend(_ relay: URL, to user: String, _ fields: [String: Any]) -> Bool {
    let (topic, key) = inboxFor(user)
    var env: [String: Any] = ["v": 3, "i": randomID(), "t": now()]
    for (k, v) in fields { env[k] = v }
    guard let plain = try? JSONSerialization.data(withJSONObject: env),
          let box = try? ChaChaPoly.seal(plain, using: key, authenticating: Data(topic.utf8))
    else { return false }
    var req = URLRequest(url: relay.appendingPathComponent(topic))
    req.httpMethod = "POST"
    req.httpBody = Data((inboxPrefix + box.combined.base64EncodedString()).utf8)
    req.setValue("no", forHTTPHeaderField: "Firebase")
    req.timeoutInterval = 15
    return fetchSync(req).0 == 200
}

struct InboxNote {
    let kind: String     // req or ok
    let user: String
    let pub: Data
    let id: String
    let re: String
    let t: Int
}

// Everything still in my inbox: the relay's twelve hours of it. Refused, and
// quietly, is anything that does not open, does not parse, is not one of the
// two kinds, or claims a time the relay could not have kept it until.
func inboxRead(_ relay: URL, me: String) -> [InboxNote]? {
    let (topic, key) = inboxFor(me)
    var c = URLComponents(url: relay.appendingPathComponent(topic).appendingPathComponent("json"),
                          resolvingAgainstBaseURL: false)!
    c.queryItems = [URLQueryItem(name: "poll", value: "1"),
                    URLQueryItem(name: "since", value: String(now() - backlog))]
    var req = URLRequest(url: c.url!)
    req.timeoutInterval = 15
    let (code, data) = fetchSync(req)
    guard code == 200, let data = data, data.count < 4 << 20 else { return nil }
    var out: [InboxNote] = []
    for line in data.split(separator: 0x0A) {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              (o["event"] as? String) == "message", let m = o["message"] as? String,
              m.hasPrefix(inboxPrefix), m.utf8.count <= maxWire,
              let raw = Data(base64Encoded: String(m.dropFirst(inboxPrefix.count))),
              let box = try? ChaChaPoly.SealedBox(combined: raw),
              let plain = try? ChaChaPoly.open(box, using: key, authenticating: Data(topic.utf8)),
              let e = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any],
              (e["v"] as? Int) == 3,
              let k = e["k"] as? String, k == "req" || k == "ok",
              let u = (e["u"] as? String).flatMap(normUser), u != me,
              let p = (e["p"] as? String).flatMap({ Data(base64Encoded: $0) }), p.count == 32,
              let i = e["i"] as? String, isID(i),
              let t = e["t"] as? Int else { continue }
        let age = Date().timeIntervalSince1970 - Double(t)
        guard age <= maxAge, -age <= maxAhead else { continue }
        let re = (e["re"] as? String).flatMap { isID($0) ? $0 : nil } ?? ""
        out.append(InboxNote(kind: k, user: u, pub: p, id: i, re: re, t: t))
    }
    return out.sorted { $0.t < $1.t }
}

// --- the address book ----------------------------------------------------------
// friends.tsv and chat-requests.tsv, and the only code that changes either.
// The app changes them through the commands at the bottom of this file, and
// a break's chat through the overlay, possibly in the same second — so every
// change is a read, a change and a write under one lock, never a write of a
// copy that was read a while ago.

struct Request {
    let dir: String      // in: they asked; out: you asked
    let user: String
    let pub: Data        // theirs, for an incoming one; empty for yours
    let id: String
    let t: Int
}

func withBook<T>(_ dir: String, _ body: () -> T) -> T {
    let fd = open(dir + "/.chat-book.lock", O_CREAT | O_RDWR, 0o600)
    if fd >= 0 { flock(fd, LOCK_EX) }
    defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
    return body()
}

func loadRequests(_ dir: String) -> [Request] {
    guard let raw = try? String(contentsOfFile: dir + "/chat-requests.tsv", encoding: .utf8)
    else { return [] }
    var out: [Request] = []
    for line in raw.split(separator: "\n") {
        let f = line.components(separatedBy: "\t")
        guard f.count == 5, f[0] == "in" || f[0] == "out", let u = normUser(f[1]),
              isID(f[3]), let t = Int(f[4]) else { continue }
        let pub = Data(base64Encoded: f[2]) ?? Data()
        guard f[0] == "out" || pub.count == 32 else { continue }
        out.append(Request(dir: f[0], user: u, pub: pub, id: f[3], t: t))
    }
    return Array(out.suffix(maxRequests))
}

func saveRequests(_ dir: String, _ reqs: [Request]) {
    var s = "dir\tuser\tkey\tid\ttime\n"
    for r in reqs.suffix(maxRequests) {
        s += "\(r.dir)\t\(r.user)\t\(r.pub.base64EncodedString())\t\(r.id)\t\(r.t)\n"
    }
    writePrivate(dir + "/chat-requests.tsv", Data(s.utf8))
}

func newFriendID(_ friends: [Friend]) -> String {
    while true {
        let id = String(format: "%08x", UInt32.random(in: .min ... .max))
        if !friends.contains(where: { $0.id == id }) { return id }
    }
}

// Adds a friend from a key agreement, unless the secret is already a friend.
// Returns the friend either way, or nil if there is no room.
@discardableResult
func befriend(_ dir: String, user: String, secret: Data) -> Friend? {
    var friends = loadFriends(dir)
    if let f = friends.first(where: { $0.secret == secret }) { return f }
    guard friends.count < maxFriends else { return nil }
    let f = Friend(id: newFriendID(friends), name: user, code: codeFor(secret),
                   secret: secret, added: now(), user: user)
    friends.append(f)
    saveFriends(dir, friends)
    return f
}

enum BookResult {
    case ok(String)
    case no(String)
}

func bookSetName(_ dir: String, _ raw: String) -> BookResult {
    guard let u = normUser(raw) else {
        return .no("Use 2 to 24 letters, digits, dots, dashes or underscores")
    }
    writePrivate(dir + "/chat-name", Data((u + "\n").utf8))
    return .ok("Your username is \(u)")
}

// Asking somebody. If they have already asked you, this is accepting them
// instead — the two requests have crossed, and either is consent.
func bookAdd(_ dir: String, _ raw: String) -> BookResult {
    guard let me = readName(dir) else { return .no("Choose your username first") }
    guard let u = normUser(raw) else { return .no("That is not a username") }
    guard u != me else { return .no("That is your own username") }
    guard let relay = relayFor(dir), let key = myKey(dir) else {
        return .no("Messages cannot reach the relay")
    }
    if loadFriends(dir).contains(where: { $0.user == u }) {
        return .no("You are already friends with \(u)")
    }
    if let mine = loadRequests(dir).last(where: { $0.dir == "in" && $0.user == u }) {
        return bookAccept(dir, mine.id)
    }
    guard inboxSend(relay, to: u, ["k": "req", "u": me,
                                   "p": key.publicKey.rawRepresentation.base64EncodedString()])
    else { return .no("Could not reach the relay. Try again") }
    withBook(dir) {
        var reqs = loadRequests(dir).filter { !($0.dir == "out" && $0.user == u) }
        reqs.append(Request(dir: "out", user: u, pub: Data(), id: randomID(), t: now()))
        saveRequests(dir, reqs)
    }
    return .ok("Request sent to \(u)")
}

func bookAccept(_ dir: String, _ id: String) -> BookResult {
    guard let me = readName(dir) else { return .no("Choose your username first") }
    guard let relay = relayFor(dir), let key = myKey(dir) else {
        return .no("Messages cannot reach the relay")
    }
    guard let r = loadRequests(dir).first(where: { $0.dir == "in" && $0.id == id }) else {
        return .no("That request is gone")
    }
    guard let secret = pairSecret(key, r.pub) else { return .no("That request is broken") }
    // Answered before anything is written: an answer that never left would
    // be a friend on this side only, waiting for ever.
    guard inboxSend(relay, to: r.user, ["k": "ok", "u": me, "re": r.id,
                                        "p": key.publicKey.rawRepresentation.base64EncodedString()])
    else { return .no("Could not reach the relay. Try again") }
    let f: Friend? = withBook(dir) {
        let f = befriend(dir, user: r.user, secret: secret)
        saveRequests(dir, loadRequests(dir).filter { !($0.user == r.user) })
        return f
    }
    guard let friend = f else { return .no("That is \(maxFriends) friends, the most there is room for") }
    return .ok("You and \(friend.name) are friends")
}

func bookIgnore(_ dir: String, _ id: String) -> BookResult {
    withBook(dir) { saveRequests(dir, loadRequests(dir).filter { !($0.dir == "in" && $0.id == id) }) }
    return .ok("Ignored")
}

func bookRename(_ dir: String, _ id: String, _ raw: String) -> BookResult {
    let n = String(clean(raw).prefix(maxName))
    guard !n.isEmpty else { return .no("Give them a name") }
    let found: Bool = withBook(dir) {
        var friends = loadFriends(dir)
        guard let k = friends.firstIndex(where: { $0.id == id }) else { return false }
        friends[k].name = n
        saveFriends(dir, friends)
        return true
    }
    return found ? .ok("Renamed to \(n)") : .no("That friend is gone")
}

// Unfriending is deleting the row. The secret stops working here at once; on
// their side it keeps its row until they remove it too, and until then they
// simply never hear from you. What was said is dropped from chat-log.tsv by
// the next break, which reads only the lines of friends it still has.
func bookForget(_ dir: String, _ id: String) -> BookResult {
    let gone: Friend? = withBook(dir) {
        var friends = loadFriends(dir)
        guard let k = friends.firstIndex(where: { $0.id == id }) else { return nil }
        let f = friends.remove(at: k)
        saveFriends(dir, friends)
        return f
    }
    return gone.map { .ok("Removed \($0.name)") } ?? .no("That friend is gone")
}

// The inbox, read and acted on. A request is kept until it is accepted or
// ignored, unless you had asked them too, in which case it is accepted now.
// An answer completes a request of yours and nothing else: an answer to a
// question you never asked is somebody trying to become your friend without
// asking, and is dropped. A request from somebody who is already your friend
// by that same key is answered again — their first answer went unread for
// twelve hours, and they asked again.
func bookInbox(_ dir: String) -> BookResult {
    guard let me = readName(dir) else { return .ok("") }
    guard let relay = relayFor(dir), let key = myKey(dir) else {
        return .no("Messages cannot reach the relay")
    }
    guard let notes = inboxRead(relay, me: me) else { return .no("Could not reach the relay") }
    var answer: [(String, String)] = []
    var added: [String] = []
    withBook(dir) {
        var reqs = loadRequests(dir)
        for n in notes {
            guard let secret = pairSecret(key, n.pub) else { continue }
            let known = loadFriends(dir).contains { $0.secret == secret }
            let asked = reqs.contains { $0.dir == "out" && $0.user == n.user }
            if n.kind == "ok" {
                guard asked, !known else { continue }
            } else if known {
                answer.append((n.user, n.id))
                continue
            } else if !asked {
                if !reqs.contains(where: { $0.dir == "in" && $0.user == n.user && $0.pub == n.pub }) {
                    reqs.append(Request(dir: "in", user: n.user, pub: n.pub, id: n.id, t: n.t))
                }
                continue
            } else {
                answer.append((n.user, n.id))
            }
            if befriend(dir, user: n.user, secret: secret) != nil {
                added.append(n.user)
                reqs.removeAll { $0.user == n.user }
            }
        }
        saveRequests(dir, reqs)
    }
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    for (user, re) in answer {
        _ = inboxSend(relay, to: user, ["k": "ok", "u": me, "re": re, "p": pub])
    }
    return .ok(added.isEmpty ? "" : "You and \(added.joined(separator: ", ")) are friends")
}

// --- break mode --------------------------------------------------------------
// Everything a break's chat is, for as long as the break lasts: one Chat per
// friend, the commands the overlay sends, the history, and the state file the
// overlay draws from.
//
// The overlay never holds a code. It names friends by an id that is not a
// secret, and requests by theirs; this program resolves both. A page that
// somehow began saying things it shouldn't could ask for a friend to be
// added or removed, as the person in front of it can, and could never read
// the secret a friendship is.

struct Entry {
    let q: Int          // this Mac's own order, and the read marker's unit
    let f: String       // the friend
    let i: String       // the message id, theirs or ours
    let t: Int          // when it was written, by the writer's clock
    let out: Bool       // ours
    var s: String       // ours only: sending, sent, failed
    let x: String
}

struct Sync {
    var since = 0       // the relay's clock: where the next subscription starts
    var read = 0        // the last q you have seen
    var ph = ""         // where they are: work, break, off; "" for no word yet
    var from = 0
    var until = 0
    var stamp = 0       // when they said so, so an older word never wins
}

final class Room {
    let dir: String
    let watcher: String
    let me: String
    let run = randomID()
    let started = Date()
    var relay: URL?
    var relayProblem: String?
    var friends: [Friend] = []
    var chats: [String: Chat] = [:]
    var down: [String: String] = [:]
    var log: [Entry] = []
    var sync: [String: Sync] = [:]
    var q = 0
    var note: [String: Any]?
    var queued = false
    var logDirty = false
    var syncDirty = false
    var leaving = false
    var timers: [DispatchSourceTimer] = []
    // friends.tsv as last read: the app can add, rename or remove a friend in
    // the middle of a break, and this notices within a second.
    var stamp: Date?
    var inboxBusy = false

    init(dir: String, watcher: String) {
        self.dir = dir
        self.watcher = watcher
        me = selfID(dir)
    }

    func path(_ name: String) -> String { return dir + "/" + name }

    func start() {
        relay = relayFor(dir)
        if relay == nil { relayProblem = "chat-relay names a relay that is not https://" }
        friends = loadFriends(dir)
        stamp = mtime(path("friends.tsv"))
        loadLog()
        loadSync()
        for f in friends { connect(f) }
        changed()
        every(0.25) { [weak self] in self?.poll() }
        every(1) { [weak self] in self?.watch() }
        // Requests wait in the inbox, not in a stream: a break looks once as
        // it begins, and then twice a minute.
        every(30) { [weak self] in self?.checkInbox() }
        checkInbox()
    }

    func mtime(_ p: String) -> Date? {
        return (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
    }

    func every(_ secs: Double, _ f: @escaping () -> Void) {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + secs, repeating: secs)
        t.setEventHandler(handler: f)
        t.resume()
        timers.append(t)
    }

    // The break is the lifetime. The same watcher's cycle, still in BREAK —
    // anything else, and this is over: back to work, a skipped break, a
    // stopped timer, a new cycle. Three hours is the backstop the Spotify
    // agent has too, for the case nothing here can see.
    func watch() {
        let f = (try? String(contentsOfFile: path("pomodoro"), encoding: .utf8))?
            .split(separator: "\n").first?.components(separatedBy: "\t") ?? []
        if f.count < 7 || f[0] != "BREAK" || f[6] != watcher
            || Date().timeIntervalSince(started) > 3 * 3600 { leave() }
        refresh()
    }

    // friends.tsv changed under us — the app, or one of the commands below.
    // New friends are connected, gone ones disconnected and their lines
    // dropped, and a renamed one renamed.
    func refresh() {
        let now = mtime(path("friends.tsv"))
        guard now != stamp else { return }
        stamp = now
        let fresh = loadFriends(dir)
        let ids = Set(fresh.map { $0.id })
        for f in friends where !ids.contains(f.id) {
            chats.removeValue(forKey: f.id)?.stop()
            down[f.id] = nil
            sync[f.id] = nil
            log.removeAll { $0.f == f.id }
            logDirty = true
            syncDirty = true
        }
        let had = Set(friends.map { $0.id })
        friends = fresh
        for f in fresh where !had.contains(f.id) { connect(f) }
        changed()
    }

    // The inbox, on a thread of its own: it waits on the network, and this
    // one draws the break screen.
    func checkInbox() {
        guard !inboxBusy, readName(dir) != nil else { return }
        inboxBusy = true
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let r = bookInbox(self.dir)
            DispatchQueue.main.async {
                self.inboxBusy = false
                if case .ok(let m) = r, !m.isEmpty { self.tell("added", x: m) }
                self.refresh()
                self.changed()
            }
        }
    }

    // Nothing to say goodbye with: where you are next is the watcher's to post.
    // What is kept is written down; what the overlay was shown is not.
    func leave() {
        if leaving { return }
        leaving = true
        for t in timers { t.cancel() }
        for c in chats.values { c.stop() }
        if logDirty { saveLog() }
        if syncDirty { saveSync() }
        unlink(path(".tomato-chat"))
        unlink(path(".tomato-chat-cmd"))
        exit(0)
    }

    // --- the two files that are kept ---

    func loadLog() {
        guard let raw = try? String(contentsOfFile: path("chat-log.tsv"), encoding: .utf8)
        else { return }
        let ids = Set(friends.map { $0.id })
        for line in raw.split(separator: "\n") {
            let f = line.components(separatedBy: "\t")
            guard f.count == 7, let n = Int(f[0]), ids.contains(f[1]), isID(f[2]),
                  let t = Int(f[3]), f[4] == "in" || f[4] == "out",
                  ["", "sending", "sent", "failed"].contains(f[5]) else { continue }
            let x = clean(f[6])
            guard !x.isEmpty else { continue }
            // A send that was still in flight when the last break ended never
            // heard back. Saying "sending" for ever would be a lie.
            let s = f[5] == "sending" ? "failed" : f[5]
            log.append(Entry(q: n, f: f[1], i: f[2], t: t, out: f[4] == "out", s: s, x: x))
            q = max(q, n)
        }
        log.sort { $0.q < $1.q }
    }

    func saveLog() {
        var s = "q\tfriend\tid\ttime\tdir\tstatus\ttext\n"
        for e in log {
            s += "\(e.q)\t\(e.f)\t\(e.i)\t\(e.t)\t\(e.out ? "out" : "in")\t\(e.s)\t\(e.x)\n"
        }
        writePrivate(path("chat-log.tsv"), Data(s.utf8))
    }

    func loadSync() {
        guard let raw = try? String(contentsOfFile: path("chat-sync.tsv"), encoding: .utf8)
        else { return }
        let ids = Set(friends.map { $0.id })
        for line in raw.split(separator: "\n") {
            let f = line.components(separatedBy: "\t")
            guard f.count == 7, ids.contains(f[0]), let since = Int(f[1]),
                  let read = Int(f[2]), f[3].isEmpty || phases.contains(f[3]),
                  let a = Int(f[4]), let b = Int(f[5]), let st = Int(f[6]) else { continue }
            sync[f[0]] = Sync(since: since, read: read, ph: f[3], from: a, until: b, stamp: st)
        }
    }

    func saveSync() {
        var s = "friend\tsince\tread\tphase\tfrom\tuntil\tstamp\n"
        for f in friends {
            let y = sync[f.id] ?? Sync()
            s += "\(f.id)\t\(y.since)\t\(y.read)\t\(y.ph)\t\(y.from)\t\(y.until)\t\(y.stamp)\n"
        }
        writePrivate(path("chat-sync.tsv"), Data(s.utf8))
    }

    // --- the relay ---

    func connect(_ f: Friend) {
        guard let relay = relay else { return }
        let id = f.id
        let from = sync[id].map { $0.since } ?? 0
        let c = Chat(relay: relay, secret: f.secret, me: me,
                     since: from > 0 ? from : now() - backlog,
                     seen: Set(log.filter { $0.f == id }.map { $0.i })) { [weak self] ev in
            self?.event(id, ev)
        }
        chats[id] = c
        c.start()
    }

    func event(_ id: String, _ ev: [String]) {
        switch ev[0] {
        case "open":
            down[id] = nil
        case "down":
            down[id] = ev.count > 1 ? ev[1] : "the relay is unreachable"
        case "error":
            tell("error", x: ev.count > 1 ? ev[1] : "the relay refused a message")
        case "text":
            guard ev.count > 4, let t = Int(ev[4]),
                  !log.contains(where: { $0.i == ev[3] }) else { return }
            append(Entry(q: 0, f: id, i: ev[3], t: t, out: false, s: "", x: ev[2]))
        case "status":
            guard ev.count > 5, let a = Int(ev[3]), let b = Int(ev[4]),
                  let st = Int(ev[5]) else { return }
            var y = sync[id] ?? Sync()
            // Arrival order is not the order they were said in, least of all
            // when twelve hours of them arrive at once. The latest word wins.
            guard st >= y.stamp else { return }
            y.ph = ev[2]; y.from = a; y.until = b; y.stamp = st
            sync[id] = y
            syncDirty = true
        default:
            return
        }
        // However it arrived, the relay's clock has moved, and the next
        // subscription to this friend can start from here.
        if let c = chats[id], c.newest - 60 > (sync[id]?.since ?? 0) {
            var y = sync[id] ?? Sync()
            y.since = c.newest - 60
            sync[id] = y
            syncDirty = true
        }
        changed()
    }

    func append(_ e: Entry) {
        q += 1
        log.append(Entry(q: q, f: e.f, i: e.i, t: e.t, out: e.out, s: e.s, x: e.x))
        // The oldest go first, but never one the relay could still hand back:
        // its id is what stops that becoming a second copy.
        let mine = log.filter { $0.f == e.f }.count
        if mine > keepPerFriend {
            var excess = mine - keepPerFriend
            let floor = now() - Int(maxAge)
            log.removeAll { x in
                if excess > 0 && x.f == e.f && x.t < floor { excess -= 1; return true }
                return false
            }
        }
        logDirty = true
    }

    func tell(_ kind: String, id: String? = nil, x: String = "") {
        q += 1
        var n: [String: Any] = ["q": q, "k": kind, "x": x]
        if let id = id, let f = friends.first(where: { $0.id == id }) {
            n["id"] = id
            n["n"] = f.name
        }
        note = n
    }

    // Many things can change in one pass through the run loop; the files are
    // written once, at the end of it.
    func changed() {
        if queued { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            self?.queued = false
            self?.writeState()
        }
    }

    func writeState() {
        if leaving { return }
        if logDirty { saveLog(); logDirty = false }
        if syncDirty { saveSync(); syncDirty = false }
        let problem = relayProblem ?? down.values.first
        var shown: [[String: Any]] = []
        for f in friends {
            for e in log.filter({ $0.f == f.id }).suffix(showPerFriend) {
                shown.append(["q": e.q, "f": e.f, "me": e.out, "x": e.x, "t": e.t, "s": e.s])
            }
        }
        shown.sort { ($0["q"] as! Int) < ($1["q"] as! Int) }
        let reqs = loadRequests(dir)
        let state: [String: Any] = [
            "v": 3, "run": run,
            "me": readName(dir) ?? "",
            "relay": ["ok": problem == nil, "x": problem ?? ""] as [String: Any],
            "friends": friends.map { f -> [String: Any] in
                let y = sync[f.id] ?? Sync()
                let unread = log.filter { !$0.out && $0.f == f.id && $0.q > y.read }.count
                return ["id": f.id, "n": f.name, "u": f.user, "ph": y.ph, "since": y.from,
                        "until": y.until, "st": y.stamp, "read": y.read, "unread": unread]
            },
            "requests": reqs.filter { $0.dir == "in" }.map { ["id": $0.id, "u": $0.user] },
            "pending": reqs.filter { $0.dir == "out" }.map { ["id": $0.id, "u": $0.user] },
            "log": shown,
            "note": note ?? NSNull()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state) else { return }
        writePrivate(path(".tomato-chat"), data)
    }

    // One command from the overlay. The file sits in a directory the user can
    // write, so every field is checked here again, however carefully the
    // overlay checked it before writing: this is the program holding the codes.
    func poll() {
        let p = path(".tomato-chat-cmd")
        guard let raw = try? String(contentsOfFile: p, encoding: .utf8) else { return }
        unlink(p)
        let f = (raw.split(separator: "\n").first.map(String.init) ?? "")
            .components(separatedBy: "\t")
        switch (f[0], f.count) {
        case ("send", 3) where isHex(f[1], 8):   sendText(f[1], f[2])
        case ("read", 3) where isHex(f[1], 8):   markRead(f[1], f[2])
        case ("setname", 2):                     book { bookSetName(self.dir, f[1]) }
        case ("add", 2):                         book { bookAdd(self.dir, f[1]) }
        case ("accept", 2) where isID(f[1]):     book { bookAccept(self.dir, f[1]) }
        case ("ignore", 2) where isID(f[1]):     book { bookIgnore(self.dir, f[1]) }
        case ("rename", 3) where isHex(f[1], 8): book { bookRename(self.dir, f[1], f[2]) }
        case ("forget", 2) where isHex(f[1], 8): book { bookForget(self.dir, f[1]) }
        default: return
        }
        changed()
    }

    // An address-book change, the same functions the app's commands call, on
    // a thread of their own because some of them wait on the relay. What they
    // say comes back as a note for the overlay; what they changed comes back
    // through friends.tsv, which refresh() reads.
    func book(_ job: @escaping () -> BookResult) {
        DispatchQueue.global().async { [weak self] in
            let r = job()
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch r {
                case .ok(let m): self.tell("done", x: m)
                case .no(let m): self.tell("bad", x: m)
                }
                self.refresh()
                self.changed()
            }
        }
    }

    // To anyone, at any time. A friend who is working reads it at their next
    // break; the relay holds it until then, for up to twelve hours.
    func sendText(_ id: String, _ raw: String) {
        let x = clean(raw)
        guard !x.isEmpty, friends.contains(where: { $0.id == id }) else { return }
        guard let c = chats[id] else {
            return tell("error", id: id, x: relayProblem ?? "Messages is not connected")
        }
        let n = q + 1
        guard let i = c.send(x, then: { [weak self] ok in self?.mark(n, ok ? "sent" : "failed") })
        else { return }
        append(Entry(q: 0, f: id, i: i, t: now(), out: true, s: "sending", x: x))
    }

    func mark(_ n: Int, _ s: String) {
        guard let k = log.firstIndex(where: { $0.q == n }) else { return }
        log[k].s = s
        logDirty = true
        changed()
    }

    func markRead(_ id: String, _ raw: String) {
        guard let n = Int(raw), friends.contains(where: { $0.id == id }) else { return }
        var y = sync[id] ?? Sync()
        let upto = min(n, q)
        guard upto > y.read else { return }
        y.read = upto
        sync[id] = y
        syncDirty = true
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments

func usage() -> Never {
    fputs("usage: ttchat break <dir> | status <dir> <work|break|off> <since> <until>\n"
        + "       | list|inbox <dir> | setname|add|accept|ignore|forget <dir> <arg>\n"
        + "       | rename <dir> <id> <name> | code | peer <relay> <code> | seal <code> <json>\n",
          stderr)
    exit(2)
}

// The answer to one of the app's commands: one line, and the exit status.
func answer(_ r: BookResult) -> Never {
    switch r {
    case .ok(let m): print(m); exit(0)
    case .no(let m): print(m); exit(1)
    }
}

// Where each friend is, from chat-sync.tsv, for `list`.
func readSync(_ dir: String) -> [String: Sync] {
    var out: [String: Sync] = [:]
    guard let raw = try? String(contentsOfFile: dir + "/chat-sync.tsv", encoding: .utf8)
    else { return out }
    for line in raw.split(separator: "\n") {
        let f = line.components(separatedBy: "\t")
        guard f.count == 7, isHex(f[0], 8), let since = Int(f[1]), let read = Int(f[2]),
              f[3].isEmpty || phases.contains(f[3]),
              let a = Int(f[4]), let b = Int(f[5]), let st = Int(f[6]) else { continue }
        out[f[0]] = Sync(since: since, read: read, ph: f[3], from: a, until: b, stamp: st)
    }
    return out
}

func need<T>(_ v: T?, _ why: String) -> T {
    guard let v = v else { fputs(why + "\n", stderr); exit(2) }
    return v
}

var signals: [DispatchSourceSignal] = []
func onSignal(_ f: @escaping () -> Void) {
    for n in [SIGTERM, SIGINT] {
        signal(n, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: n, queue: .main)
        src.setEventHandler(handler: f)
        src.resume()
        signals.append(src)
    }
}

switch args.count > 1 ? args[1] : "" {
case "break":
    // Handed a directory, never a file name, and only one that has a cycle in
    // it: double-clicking the bundle, or `open -a` with a stray path, starts
    // nothing.
    guard args.count == 3, args[2].hasPrefix("/") else { usage() }
    let dir = args[2]
    let f = (try? String(contentsOfFile: dir + "/pomodoro", encoding: .utf8))?
        .split(separator: "\n").first?.components(separatedBy: "\t") ?? []
    guard f.count >= 7, f[0] == "BREAK" else { exit(0) }
    // Two of these would read every message twice and fight over its files.
    let lock = open(dir + "/.tomato-chat.lock", O_CREAT | O_RDWR, 0o600)
    guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
    let room = Room(dir: dir, watcher: f[6])
    room.start()
    onSignal { room.leave() }
    dispatchMain()
case "status":
    // One post per friend, and gone. No friends, no network — except a look
    // in the inbox, if you have a username: that is how a friend who accepted
    // you while you worked is your friend by the next break, without the app
    // having been opened in between.
    guard args.count == 6, args[2].hasPrefix("/"), phases.contains(args[3]),
          let a = Int(args[4]), let b = Int(args[5]) else { usage() }
    let dir = args[2]
    if readName(dir) != nil { _ = bookInbox(dir) }
    let fr = loadFriends(dir)
    guard !fr.isEmpty, let relay = relayFor(dir) else { exit(0) }
    let me = selfID(dir)
    var left = fr.count
    var posts: [Chat] = []
    for f in fr {
        let c = Chat(relay: relay, secret: f.secret, me: me, since: 0) { _ in }
        posts.append(c)
        c.status(args[3], since: a, until: b) { _ in
            left -= 1
            if left == 0 { exit(0) }
        }
    }
    // A relay that does not answer does not get to keep a process alive.
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { exit(0) }
    dispatchMain()
case "list":
    // Files only: this is what the app draws its Friends page from, every few
    // seconds, and none of that may reach the relay.
    guard args.count == 3, args[2].hasPrefix("/") else { usage() }
    let dir = args[2]
    let sync = readSync(dir)
    let reqs = loadRequests(dir)
    let out: [String: Any] = [
        "me": readName(dir) ?? "",
        "friends": loadFriends(dir).map { f -> [String: Any] in
            let y = sync[f.id] ?? Sync()
            return ["id": f.id, "n": f.name, "u": f.user, "ph": y.ph, "since": y.from,
                    "until": y.until, "st": y.stamp, "check": checkFor(f.secret)]
        },
        "requests": reqs.filter { $0.dir == "in" }.map { ["id": $0.id, "u": $0.user, "t": $0.t] },
        "pending": reqs.filter { $0.dir == "out" }.map { ["id": $0.id, "u": $0.user, "t": $0.t] },
    ]
    // Sorted, so the same book prints the same bytes: the app redraws when
    // they change, and a dictionary's order is different every run.
    let data = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
case "setname", "add", "accept", "ignore", "forget", "inbox":
    let one = args[1] == "inbox"
    guard args.count == (one ? 3 : 4), args[2].hasPrefix("/") else { usage() }
    let dir = args[2]
    switch args[1] {
    case "setname": answer(bookSetName(dir, args[3]))
    case "add":     answer(bookAdd(dir, args[3]))
    case "accept":  answer(isID(args[3]) ? bookAccept(dir, args[3]) : .no("That request is gone"))
    case "ignore":  answer(isID(args[3]) ? bookIgnore(dir, args[3]) : .no("That request is gone"))
    case "forget":  answer(isHex(args[3], 8) ? bookForget(dir, args[3]) : .no("That friend is gone"))
    default:        answer(bookInbox(dir))
    }
case "rename":
    guard args.count == 5, args[2].hasPrefix("/") else { usage() }
    answer(isHex(args[3], 8) ? bookRename(args[2], args[3], args[4]) : .no("That friend is gone"))
case "code":
    print(newCode())
case "seal":
    guard args.count == 4 else { usage() }
    let (topic, key) = derive(need(parseCode(args[2]), badCode))
    let box = try! ChaChaPoly.seal(Data(args[3].utf8), using: key,
                                   authenticating: Data(topic.utf8))
    print(topic + "\t" + wirePrefix + box.combined.base64EncodedString())
case "peer":
    guard args.count == 4 else { usage() }
    let relay = need(relayURL(args[2]), "the relay must be https://, or http:// to this machine")
    let chat = Chat(relay: relay, secret: need(parseCode(args[3]), badCode),
                    me: randomID(), since: now() - backlog) {
        print($0.joined(separator: "\t"))
    }
    // A friend in a terminal is a friend on a break, until told otherwise.
    func where_(_ ph: String, _ mins: Int) {
        let t = now()
        chat.status(ph, since: t, until: ph == "off" ? 0 : t + mins * 60)
    }
    chat.start()
    where_("break", 5)
    let quit = {
        chat.status("off", since: now(), until: 0) { _ in exit(0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
    }
    Thread {
        while let line = readLine() {
            DispatchQueue.main.async {
                let w = line.split(separator: " ")
                switch w.first.map(String.init) ?? "" {
                case "/work":  where_("work", w.count > 1 ? Int(w[1]) ?? 25 : 25)
                case "/break": where_("break", w.count > 1 ? Int(w[1]) ?? 5 : 5)
                case "/off":   where_("off", 0)
                default:       chat.send(line)
                }
            }
        }
        DispatchQueue.main.async(execute: quit)
    }.start()
    onSignal(quit)
    dispatchMain()
default:
    usage()
}
