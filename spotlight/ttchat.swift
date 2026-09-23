// TimeTracker break chat. The one program in TimeTracker that talks to the
// internet, and it talks to exactly one place: the relay, ntfy.sh unless told
// otherwise, outbound, over HTTPS. Nothing listens. There is no socket here for
// anybody to connect to, which is the difference between this and every
// peer-to-peer design that was considered first.
//
// Why a relay at all, when the brief was "no server": two Macs on two
// eduroams, or behind two home routers, can neither find nor reach each other
// on their own. Signal has the same problem and answers it the same way —
// every message goes through a server, and the server can read none of them.
// The relay here is a dumb pipe. It sees two IP addresses, when they are on a
// break together, and base64. It keeps nothing: every message is sent
// `Cache: no`, so it reaches whoever is subscribed at that moment and is
// stored nowhere, and that is also what makes "only friends who are on a
// break" true — a message to someone who is working has nobody to arrive at.
//
// A friendship is one 32-byte secret, made on one Mac by `ttchat code` and
// carried to the other over something both people already trust — Signal.
// Everything else is derived from it: the topic both subscribe to, and the
// key every message is sealed with. Nothing that says who you are is ever
// outside the seal, and the relay cannot forge anything that opens.
//
//   ttchat code                  a fresh pairing code, on stdout
//   ttchat peer <relay> <code>   one friendship, headless: each stdin line is
//                                sent, each event is a TSV line on stdout, and
//                                stdin closing says goodbye and exits. What
//                                chat.test.py drives.
//   ttchat seal <code> <json>    seal one raw envelope; prints topic<TAB>blob.
//                                For the tests only: a stale, replayed or
//                                malformed message that is nevertheless
//                                correctly encrypted is the only way to show it
//                                is refused for the right reason. It can make
//                                nothing the holder of the code could not.
//
// Events, one per line:
//
//   open                     subscribed; "hello" has been sent
//   here  <session>          a friend is on a break
//   gone  <session>          ...and no longer is
//   text  <session> <text>   they said something
//   sent  <kind>             the relay accepted one of ours
//   drop  <reason>           something arrived and was refused
//   error <detail>           the relay, or the network, said no

import CryptoKit
import Foundation

// Friend text is capped where a break note is capped. ntfy delivers a longer
// body as an attachment, never as a message, so nothing of ours is ever
// larger than maxWire.
let maxText = 500
let maxWire = 4096
// Two Macs on NTP agree to well inside this. It is what makes a replay of an
// old message, captured off the relay, arrive as nothing.
let window = 120.0
// A friend whose lid closed mid-break never says goodbye. Two missed
// heartbeats and a bit is long enough to be sure, short enough that a name
// does not linger through the next work block.
let liveEvery = 120.0
let goneAfter = 300.0
let kinds: Set<String> = ["hello", "here", "live", "text", "bye"]
let codePrefix = "tt1-"
let wirePrefix = "tt1:"
let badCode = "not a pairing code, or one that lost a character on the way"

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
// friend who is never on a break, forever, with nothing to say why.
func newCode() -> String {
    let raw = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    return codePrefix + b64url(raw + Data(SHA256.hash(data: raw).prefix(2)))
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

func randomID() -> String {
    var g = SystemRandomNumberGenerator()
    return String(format: "%016llx", g.next() as UInt64)
}

func isID(_ s: String) -> Bool {
    return s.count == 16 && s.allSatisfy { "0123456789abcdef".contains($0) }
}

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

// One friendship, for as long as one break lasts.
//
// Every message is one JSON object, sealed with ChaChaPoly under the
// friendship's key, with the topic as associated data so a blob cannot be
// lifted from one friendship into another:
//
//   {"v":1, "s":session, "i":message id, "t":unix seconds, "k":kind, "x":text}
//
//   s  random per run. The relay hands every message to every subscriber, the
//      sender included; this is how a peer tells its own echo from a friend.
//   i  random per message: the replay check.
//   t  the staleness check.
//   k  hello (I just arrived) | here (so am I) | live (still here) | text | bye
final class Chat: NSObject, URLSessionDataDelegate {
    let relay: URL
    let topic: String
    let key: SymmetricKey
    let me = randomID()
    let emit: (String) -> Void

    var stream: URLSessionDataTask?
    var why: String?
    var slow = false
    var buf = Data()
    var backoff = 2.0
    var stopping = false
    var timer: DispatchSourceTimer?
    var lastSaid = Date()

    var present: [String: Date] = [:]
    var answered: Set<String> = []
    var seen: Set<String> = []
    var seenOrder: [String] = []
    var heard: [Date] = []
    var said: [Date] = []

    // Two sessions: the stream wants a delegate, and a publish wants a
    // completion handler, and one URLSession delivers a task's data to one or
    // the other, never both.
    lazy var listen = URLSession(configuration: quiet(), delegate: self,
                                 delegateQueue: OperationQueue.main)
    let post = URLSession(configuration: quiet())

    init(relay: URL, secret: Data, emit: @escaping (String) -> Void) {
        self.relay = relay
        (topic, key) = derive(secret)
        self.emit = emit
    }

    func start() {
        subscribe()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    // Heartbeats only while somebody is there to hear them. With `Cache: no`
    // a message to an empty topic goes nowhere, and ntfy.sh allows 250 a day
    // from one address: presence nobody receives is spent for nothing.
    func tick() {
        let now = Date()
        for (s, at) in present where now.timeIntervalSince(at) > goneAfter { leave(s) }
        if !present.isEmpty && now.timeIntervalSince(lastSaid) >= liveEvery { say("live") }
    }

    func subscribe() {
        guard !stopping else { return }
        why = nil
        slow = false
        buf = Data()
        stream = listen.dataTask(with: relay.appendingPathComponent(topic)
                                            .appendingPathComponent("json"))
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
        emit("error\t" + clean(why ?? error?.localizedDescription ?? "the relay closed the stream"))
        let wait = slow ? 60 : backoff
        backoff = min(backoff * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.subscribe() }
    }

    // The relay's own envelope is the one thing parsed before authentication,
    // because it has to be: it is how the sealed blob is found. Two fields are
    // read out of it, and anything else a newer relay adds is ignored.
    func relayLine(_ line: Data) {
        guard !line.isEmpty,
              let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let ev = o["event"] as? String else { return }
        if ev == "open" {
            backoff = 2
            emit("open")
            say("hello")
        } else if ev == "message", let m = o["message"] as? String {
            receive(m)
        }
    }

    func drop(_ reason: String) { emit("drop\t" + reason) }

    // The order is the argument. Nothing is decoded until it has been shown
    // to come from somebody holding the code; nothing is acted on until it is
    // shown to be fresh, new and well-formed; and even then it is a friend's
    // input — no longer anonymous, still not trusted.
    func receive(_ m: String) {
        guard m.hasPrefix(wirePrefix) else { return drop("foreign") }
        guard m.utf8.count <= maxWire,
              let raw = Data(base64Encoded: String(m.dropFirst(wirePrefix.count))),
              let box = try? ChaChaPoly.SealedBox(combined: raw),
              let plain = try? ChaChaPoly.open(box, using: key,
                                               authenticating: Data(topic.utf8))
        else { return drop("auth") }
        guard let o = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any],
              (o["v"] as? Int) == 1,
              let s = o["s"] as? String, isID(s),
              let i = o["i"] as? String, isID(i),
              let t = o["t"] as? Int,
              let k = o["k"] as? String, kinds.contains(k)
        else { return drop("malformed") }
        if s == me { return drop("echo") }
        if abs(Date().timeIntervalSince1970 - Double(t)) > window { return drop("stale") }
        if seen.contains(i) { return drop("replay") }
        seen.insert(i)
        seenOrder.append(i)
        if seenOrder.count > 2000 { seen.remove(seenOrder.removeFirst()) }
        // A friend's Mac with a bug in it is still a flood on your break
        // screen. Twenty in ten seconds is more than anybody types.
        let now = Date()
        heard = heard.filter { now.timeIntervalSince($0) < 10 }
        if heard.count >= 20 { return drop("rate") }
        heard.append(now)
        switch k {
        case "hello":
            arrive(s)
            // Answered once per session, not once per hello: a friend whose
            // stream keeps reconnecting says hello each time, and every answer
            // is one of this address's 250.
            if answered.insert(s).inserted { say("here") }
        case "here", "live":
            arrive(s)
        case "text":
            // Refused rather than cut: nothing of ours sends more, so a longer
            // text was not written by this program, and a shortened sentence
            // can say something its author did not.
            guard let x = o["x"] as? String, x.count <= maxText else { return drop("malformed") }
            let c = clean(x)
            guard !c.isEmpty else { return drop("malformed") }
            arrive(s)
            emit("text\t\(s)\t\(c)")
        default:
            leave(s)
        }
    }

    func arrive(_ s: String) {
        if present[s] == nil { emit("here\t" + s) }
        present[s] = Date()
    }

    func leave(_ s: String) {
        if present.removeValue(forKey: s) != nil { emit("gone\t" + s) }
    }

    func send(_ raw: String) {
        let x = clean(raw)
        guard !x.isEmpty, !stopping else { return }
        let now = Date()
        said = said.filter { now.timeIntervalSince($0) < 10 }
        guard said.count < 10 else { emit("error\tslow down"); return }
        said.append(now)
        say("text", x)
    }

    func say(_ kind: String, _ text: String? = nil, then done: ((Bool) -> Void)? = nil) {
        var env: [String: Any] = ["v": 1, "s": me, "i": randomID(),
                                  "t": Int(Date().timeIntervalSince1970), "k": kind]
        if let x = text { env["x"] = x }
        guard let plain = try? JSONSerialization.data(withJSONObject: env),
              let box = try? ChaChaPoly.seal(plain, using: key,
                                             authenticating: Data(topic.utf8))
        else { done?(false); return }
        lastSaid = Date()
        var req = URLRequest(url: relay.appendingPathComponent(topic))
        req.httpMethod = "POST"
        req.httpBody = Data((wirePrefix + box.combined.base64EncodedString()).utf8)
        // Delivered to whoever is subscribed now, and stored nowhere.
        req.setValue("no", forHTTPHeaderField: "Cache")
        // ntfy.sh otherwise copies every message to Firebase for its Android
        // app. Ours is ciphertext, but there is no reason for Google to hold it.
        req.setValue("no", forHTTPHeaderField: "Firebase")
        req.timeoutInterval = 15
        post.dataTask(with: req) { [weak self] _, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                guard let self = self else { return }
                if code == 200 {
                    self.emit("sent\t" + kind)
                } else if code == 429 {
                    self.emit("error\tthe relay is rate-limiting this address")
                } else {
                    self.emit("error\t" + clean(err?.localizedDescription
                                                ?? "the relay answered \(code)"))
                }
                done?(code == 200)
            }
        }.resume()
    }

    // Goodbye only if somebody is there to hear it, and never at the cost of
    // hanging on a relay that has stopped answering.
    func stop(_ done: @escaping () -> Void) {
        if stopping { return }
        stopping = true
        timer?.cancel()
        stream?.cancel()
        guard !present.isEmpty else { done(); return }
        var finished = false
        let finish = { if !finished { finished = true; done() } }
        say("bye") { _ in finish() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: finish)
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments

func usage() -> Never {
    fputs("usage: ttchat code | peer <relay> <code> | seal <code> <json>\n", stderr)
    exit(2)
}

func need<T>(_ v: T?, _ why: String) -> T {
    guard let v = v else { fputs(why + "\n", stderr); exit(2) }
    return v
}

switch args.count > 1 ? args[1] : "" {
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
    let chat = Chat(relay: relay, secret: need(parseCode(args[3]), badCode)) { print($0) }
    chat.start()
    let quit = { chat.stop { exit(0) } }
    Thread {
        while let line = readLine() { DispatchQueue.main.async { chat.send(line) } }
        DispatchQueue.main.async(execute: quit)
    }.start()
    var signals: [DispatchSourceSignal] = []
    for n in [SIGTERM, SIGINT] {
        signal(n, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: n, queue: .main)
        src.setEventHandler(handler: quit)
        src.resume()
        signals.append(src)
    }
    dispatchMain()
default:
    usage()
}
