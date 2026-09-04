// TimeTracker prompt & pomodoro overlay. One app, two modes:
//
//   ttprompt prompt <question> <subtitle> <answer_path> [ticked]
//       Start prompt: question, subtitle, text field, and a real "Pomodoro
//       mode" checkbox, ticked to start iff [ticked] is "1" (the caller reads
//       the pomodoro_default setting). Skip / Save; Enter = Save, Esc = Skip,
//       120s timeout = Skip. Always exits, and always writes the answer file:
//       "POMODORO<TAB><text>" or "<TAB><text>" (empty on skip).
//
//   ttprompt overlay <choice_path> <long_break_every> [auto_accept_seconds]
//                     [easter_egg] [menu_features]
//       The full-screen tomato. ONE process covers a whole visible stretch
//       of the cycle — tomato, then break, then break-over — rather than one
//       process per phase: it polls the `pomodoro` file beside the choice
//       file and pushes each state into the page, which crossfades in place.
//       That is what stops a phase change from flashing the desktop. It
//       exits once the cycle returns to silent work, or the file goes away.
//       Choices are written to the choice file; the watcher owns the state
//       machine and answers by rewriting `pomodoro`.
//
// Files: like the calendar helper, this app writes nothing except its own
// result files — a handed path whose basename isn't .prompt-answer /
// .tomato-choice is ignored and the standard location in ~/.timetrack used
// instead, so `open -a "TimeTracker Prompt" notes.txt` can't overwrite
// notes.txt. The overlay also touches .tomato-alive beside the choice file
// (its visibility heartbeat, which is how the watcher tells "on screen" from
// "running but invisible") and *reads* `pomodoro` and `.tomato-audio` from
// that directory.
//
// The break menu adds three more writes to that list and no more, all with
// fixed names in the same validated directory: .tomato-spotify-want (exists
// while the music panel is open), .tomato-spotify-cmd (one command for the
// Spotify agent) and .tomato-reminder (one note for the EventKit helper). It
// reads .tomato-spotify, .tomato-reminder-result, spotify-playlists.tsv and
// reminders-list from the same place. It still launches nothing and still
// touches no network: every action leaves here as a file, and pomodoro-watch.sh
// is the only thing that turns a file into a running process.
// tomato.html is bundled; no network is ever touched.
//
// !! Careful when editing !!  An earlier revision of this file was a false
// positive for XProtect: macOS refused to execute it ("Malware Blocked and
// Moved to Bin") and deleted the binary seconds after launch. Bisecting
// showed none of the individual behaviours below are the problem — the
// full-screen screen-saver-level panel, the re-assert loop, the WebView, the
// JS injection and the heartbeat all pass on their own — so the trigger was
// something about the old file's overall shape, which we never pinned down
// exactly. This structure is the one verified to run. If you restructure it,
// re-check that a fresh build actually starts (the heartbeat file appearing
// is the proof) rather than assuming a running-looking process means it did.

import AppKit
import WebKit

func resultPath(_ arg: String?, expected: String) -> String {
    if let p = arg, p.hasPrefix("/"),
       (p as NSString).lastPathComponent == expected { return p }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/.timetrack/\(expected)"
}
func writeResult(_ s: String, to path: String) {
    try? s.write(toFile: path, atomically: true, encoding: .utf8)
}

// One row of spotify-playlists.tsv. The URI never reaches the page — the page
// is sent names and picks by index, and the index is resolved back to a URI
// here — so a page that somehow started saying things it shouldn't still can
// only ever name a playlist the user put in that file themselves.
struct Playlist {
    let uri: String
    let name: String
    let work: Bool
}

// The shape spotify.sh will accept, checked here as well so a malformed row in
// the TSV is dropped at the first opportunity rather than the last.
func validSpotifyURI(_ u: String) -> Bool {
    let parts = u.components(separatedBy: ":")
    guard parts.count == 3, parts[0] == "spotify" else { return false }
    let kind = parts[1], id = parts[2]
    guard (4...12).contains(kind.count),
          kind.allSatisfy({ $0.isASCII && $0.isLowercase }) else { return false }
    guard (16...40).contains(id.count),
          id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
    else { return false }
    return true
}

let a = CommandLine.arguments
let choicePath = resultPath(a.count > 2 ? a[2] : nil, expected: ".tomato-choice")
let dir = (choicePath as NSString).deletingLastPathComponent
let cyc = a.count > 3 ? (Int(a[3]) ?? 4) : 4
let secs = a.count > 4 ? (Int(a[4]) ?? 60) : 60
let egg = a.count > 5 ? (a[5] != "off") : true
// Which break-menu entries the watcher says are actually usable — it has
// already checked the settings, the app bundles and whether Spotify is even
// installed, so this is a list of things that work, not of things enabled.
let feat = a.count > 6 ? a[6] : "-"
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

final class P: NSPanel { override var canBecomeKey: Bool { true } }

final class D: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    let dir: String; let cyc: Int; let secs: Int; let egg: Bool; let feat: String
    var panel: NSPanel!; var wv: WKWebView!
    var loaded = false; var pending = false
    // The playlist file is re-read only when it changes. It is read on the
    // 0.5s sync tick, and parsing the same twenty rows twice a second for a
    // whole break is work nobody asked for.
    var playlists: [Playlist] = []
    var plStamp: Date? = nil
    var plSeen = false
    init(dir: String, cyc: Int, secs: Int, egg: Bool, feat: String) {
        self.dir = dir; self.cyc = cyc; self.secs = secs; self.egg = egg
        self.feat = feat
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { loaded = true; sync() }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? String else { return }
        if m.name == "menu" { handleMenu(body); return }
        guard ["accept","snooze","skip","back-to-work"].contains(body) else { return }
        pending = true
        writeResult(body, to: choicePath)
    }

    func path(_ name: String) -> String { return dir + "/" + name }

    // The break menu's whole vocabulary. Every branch either touches a
    // fixed-name file or does nothing: the page cannot name a file, cannot
    // name a playlist (it picks by index into the list it was sent), and
    // cannot ask for a tool the watcher did not say was usable. What it *can*
    // supply freely is the text of a note, and that reaches a helper as file
    // content — never as an argument, and never as script source.
    func handleMenu(_ body: String) {
        let fm = FileManager.default
        let spotify = feat.contains("spotify")
        switch body {
        case "sp.open":
            guard spotify else { return }
            fm.createFile(atPath: path(".tomato-spotify-want"), contents: Data())
            return
        case "sp.close":
            // Not gated on `spotify`: cleaning up after yourself must work
            // even if the feature was switched off while the panel was open.
            try? fm.removeItem(atPath: path(".tomato-spotify-want"))
            return
        case "sp.playpause", "sp.next", "sp.prev":
            guard spotify else { return }
            spotifyCommand(String(body.dropFirst(3)))
            return
        case "note.clear":
            try? fm.removeItem(atPath: path(".tomato-reminder-result"))
            return
        default:
            break
        }
        if body.hasPrefix("sp.vol.") {
            guard spotify, let v = Int(body.dropFirst(7)),
                  (0...100).contains(v) else { return }
            spotifyCommand("vol \(v)")
        } else if body.hasPrefix("sp.play.") {
            guard spotify, let i = Int(body.dropFirst(8)),
                  i >= 0, i < playlists.count,
                  validSpotifyURI(playlists[i].uri) else { return }
            spotifyCommand("uri \(playlists[i].uri)")
        } else if body.hasPrefix("note.save.") {
            guard feat.contains("reminders") else { return }
            saveNote(String(body.dropFirst(10)))
        }
    }

    func spotifyCommand(_ cmd: String) {
        writeResult(cmd + "\n", to: path(".tomato-spotify-cmd"))
    }

    // One note, filed as a request the EventKit helper will pick up. The list
    // name is read here rather than compiled in so that changing it in
    // Settings takes effect on the next break, not the next rebuild.
    func saveNote(_ raw: String) {
        let text = String(oneLine(raw).prefix(500))
        guard !text.isEmpty else { return }
        var list = "Pause Notes"
        if let n = try? String(contentsOfFile: path("reminders-list"), encoding: .utf8) {
            let t = oneLine(n)
            if !t.isEmpty { list = String(t.prefix(60)) }
        }
        // Last break's verdict must not sit under this break's note.
        try? FileManager.default.removeItem(atPath: path(".tomato-reminder-result"))
        writeResult("LIST\t\(list)\nTEXT\t\(text)\n", to: path(".tomato-reminder"))
    }

    // spotify-playlists.tsv, re-read only when its mtime moves. A row that
    // isn't a valid URI and a name is dropped, which also disposes of the
    // header line without having to count lines.
    func loadPlaylists() {
        let p = path("spotify-playlists.tsv")
        let stamp = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
        if plSeen && stamp == plStamp { return }
        plSeen = true
        plStamp = stamp
        playlists = []
        guard let raw = try? String(contentsOfFile: p, encoding: .utf8) else { return }
        for line in raw.split(separator: "\n") {
            let f = line.components(separatedBy: "\t")
            guard f.count >= 2, validSpotifyURI(f[0]) else { continue }
            let name = oneLine(f[1])
            guard !name.isEmpty else { continue }
            playlists.append(Playlist(uri: f[0], name: String(name.prefix(60)),
                                      work: f.count > 2 && f[2] == "work"))
        }
    }

    // One tab-separated line out of a file the watcher wrote, or nil.
    func firstFields(_ name: String) -> [String]? {
        guard let raw = try? String(contentsOfFile: path(name), encoding: .utf8),
              let first = raw.split(separator: "\n", omittingEmptySubsequences: false).first
        else { return nil }
        let f = first.components(separatedBy: "\t")
        return f.isEmpty || f[0].isEmpty ? nil : f
    }

    func beat() { try? Data().write(to: URL(fileURLWithPath: dir + "/.tomato-alive")) }

    func bye() {
        try? FileManager.default.removeItem(atPath: dir + "/.tomato-alive")
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.26
            self.panel.animator().alphaValue = 0
        }, completionHandler: { NSApp.terminate(nil) })
    }

    func sync() {
        guard let raw = try? String(contentsOfFile: dir + "/pomodoro", encoding: .utf8)
        else { NSApp.terminate(nil); return }
        let f = raw.split(separator: "\n", maxSplits: 1)[0].components(separatedBy: "\t")
        guard f.count >= 6, f[0] == "WORK" || f[0] == "BREAK",
              let target = Int(f[3]), let done = Int(f[4]), let over = Int(f[5])
        else { NSApp.terminate(nil); return }
        if f[0] == "WORK" && Int(Date().timeIntervalSince1970) < target {
            if pending { bye() } else { NSApp.terminate(nil) }
            return
        }
        pending = false
        guard loaded else { return }
        // The watcher creates .tomato-audio while sound is actually coming
        // out of the speakers, and removes it a few seconds after it stops.
        // Read here rather than pushed through `pomodoro`, whose seven
        // tab-separated fields are parsed by three other readers with a
        // plain `read`, where an eighth field would land inside the pid.
        let audio = FileManager.default.fileExists(atPath: dir + "/.tomato-audio")
        // f[2] is the watcher's own `seg`: the epoch the whole cycle began,
        // fixed across every WORK/BREAK segment of it. The garden's passive
        // growth (tomato.html's accrue()) uses it to refuse credit for any
        // stretch before this cycle existed.
        let cycleStart = Int(f[2]) ?? 0
        // Built as a dictionary and serialised rather than concatenated, which
        // it used to be: everything above is a number this file produced, but
        // everything the menu adds below is somebody else's text — a playlist
        // you named, a track title, a Reminders error message. One unescaped
        // quotation mark in any of them would turn the whole push into a
        // syntax error, and the overlay would simply stop updating.
        var payload: [String: Any] = [
            "phase": f[0], "target": target, "completed": done, "overrun": over,
            "cycle": cyc, "autosec": secs, "audio": audio, "egg": egg,
            "cycleStart": cycleStart, "menu": feat
        ]
        if feat.contains("spotify") {
            loadPlaylists()
            payload["pl"] = playlists.map { ["n": $0.name, "w": $0.work] as [String: Any] }
            if let g = firstFields(".tomato-spotify"), g.count >= 4 {
                payload["sp"] = ["state": g[0], "vol": Int(g[1]) ?? 0,
                                 "track": g[2], "artist": g[3]] as [String: Any]
            }
        }
        if feat.contains("reminders") {
            if let g = firstFields(".tomato-reminder-result") {
                payload["rem"] = ["status": g[0],
                                  "detail": g.count > 1 ? g[1] : ""] as [String: Any]
            }
            // A request still on disk is one the helper has not answered yet,
            // which is exactly what the panel's spinner means.
            payload["sending"] = FileManager.default
                .fileExists(atPath: path(".tomato-reminder"))
            // Where a note will land, so the panel can say so before you type.
            var list = "Pause Notes"
            if let n = try? String(contentsOfFile: path("reminders-list"),
                                   encoding: .utf8) {
                let t = oneLine(n)
                if !t.isEmpty { list = String(t.prefix(60)) }
            }
            payload["remlist"] = list
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var json = String(data: data, encoding: .utf8) else { return }
        // Legal in JSON, fatal inside a JavaScript source string — and this
        // JSON is about to be pasted into one. A track title is quite capable
        // of containing either.
        json = json.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                   .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        wv.evaluateJavaScript("window.ttSetState(" + json + ")", completionHandler: nil)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        guard let s = NSScreen.main else { return }
        panel = P(contentRect: s.frame, styleMask: [.borderless],
                  backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .black
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "choice")
        cfg.userContentController.add(self, name: "menu")
        wv = WKWebView(frame: s.frame, configuration: cfg)
        wv.navigationDelegate = self
        panel.contentView = wv
        let rdir = Bundle.main.resourceURL!
        wv.loadFileURL(rdir.appendingPathComponent("tomato.html"),
                       allowingReadAccessTo: rdir)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        beat()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in self.sync() }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            if !self.panel.isVisible || !self.panel.isOnActiveSpace {
                self.panel.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
            } else {
                self.panel.orderFrontRegardless()
                self.beat()
            }
            if !self.panel.isKeyWindow { self.panel.makeKey() }
        }
    }
}


func oneLine(_ s: String) -> String {
    return s.components(separatedBy: .newlines).joined(separator: " ")
        .replacingOccurrences(of: "\t", with: " ")
        .trimmingCharacters(in: .whitespaces)
}

final class Pr: NSObject, NSApplicationDelegate {
    let q: String; let sub: String; let path: String; let ticked: Bool
    var win: NSWindow!; var field: NSTextField!; var box: NSButton!
    var done = false
    init(q: String, sub: String, path: String, ticked: Bool) {
        self.q = q; self.sub = sub; self.path = path; self.ticked = ticked
    }
    func applicationDidFinishLaunching(_ n: Notification) {
        let w: CGFloat = 460
        let ql = NSTextField(wrappingLabelWithString: q)
        ql.font = .boldSystemFont(ofSize: 14)
        let sl = NSTextField(wrappingLabelWithString: sub)
        sl.font = .systemFont(ofSize: 12)
        sl.textColor = .secondaryLabelColor
        let f = NSTextField(string: ""); f.font = .systemFont(ofSize: 13); field = f
        box = NSButton(checkboxWithTitle: "Pomodoro mode", target: nil, action: nil)
        box.state = ticked ? .on : .off
        let skip = NSButton(title: "Skip", target: self, action: #selector(skipNow))
        skip.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(saveNow))
        save.keyEquivalent = "\r"
        let sp = NSView(); sp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [sp, skip, save]); row.orientation = .horizontal
        let stack = NSStackView(views: sub.isEmpty ? [ql, f, box, row] : [ql, sl, f, box, row])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        for v: NSView in [ql, sl, f, row] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: w - 40).isActive = true
        }
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: 10),
                       styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "TimeTracker"
        win.contentView = stack
        win.setContentSize(stack.fittingSize)
        win.center(); win.level = .floating
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.makeFirstResponder(f)
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in self?.skipNow() }
    }
    func finish(_ line: String) {
        if done { return }
        done = true
        writeResult(line, to: path)
        NSApp.terminate(nil)
    }
    @objc func skipNow() { finish("\t") }
    @objc func saveNow() {
        finish("\(box.state == .on ? "POMODORO" : "")\t\(oneLine(field.stringValue))")
    }
}

let mode = a.count > 1 ? a[1] : ""
var del: NSApplicationDelegate?
if mode == "prompt" {
    let q = a.count > 2 ? a[2] : "What are you planning to work on?"
    let sub = a.count > 3 ? a[3] : ""
    del = Pr(q: q, sub: sub,
             path: resultPath(a.count > 4 ? a[4] : nil, expected: ".prompt-answer"),
             ticked: a.count > 5 && a[5] == "1")
} else {
    del = D(dir: dir, cyc: cyc, secs: secs, egg: egg, feat: feat)
}
app.delegate = del
app.run()
