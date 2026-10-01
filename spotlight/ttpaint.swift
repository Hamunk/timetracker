// TimeTracker calendar painter.
//
// Writes the sessions you actually logged into a calendar of their own, so a
// week you planned and a week you had can be looked at side by side. It
// replaced a reader that did the opposite — watched the calendar and started
// timers off it — and the reason that went is worth keeping: guessing what you
// are doing from what you scheduled is a guess, and a wrong guess costs more
// than it saves now that a session can simply be corrected afterwards.
//
// Like every EventKit user here it lives in an app bundle carrying
// NSCalendarsUsageDescription, because macOS only grants calendar access to a
// bundle launched through LaunchServices. Exec'ing the binary directly is
// denied without a prompt.
//
//   Tomat Calendar.app --args <dir>/.paint-request.tsv    paint it, or, with
//                                       no such file there, list calendars
//   Tomat Calendar.app                                    list, into ~/.timetrack
//
// The request file, tab separated, written by paint-calendar.sh:
//
//   CAL     <calendar title>
//   WINDOW  <from_epoch>  <to_epoch>
//   ID      <this install's six-letter mark>
//   LEGACY  1                       (a calendar an older version painted)
//   S       <start_epoch> <end_epoch>  <title>  <notes>
//
// Notes carry their line breaks as \x1f, because the request is a TSV and a
// TSV has one row per line — the same trick sync-apps.sh uses to read a file
// whose fields may be empty.
//
// It **reconciles** rather than appends: every run brings its own events in
// the window into line with the log, so it is safe to run after every single
// session close, and a correction in History reaches the calendar with nothing
// having to remember what was done last time. What counts as its own is
// decided in paintplan.swift — events carrying its mark, untouched since it
// wrote them — and is the reason any calendar, the one you actually use
// included, can be chosen. Everything else in it is never updated and never
// removed.
//
// Two more rules:
//
// 1. It only ever touches the one calendar it was told to, and it will not go
//    looking for one. A title that matches nothing is an error, never a
//    "close enough" match and never a calendar created behind your back — a
//    silently-created local calendar would look like it worked while syncing
//    nowhere.
// 2. It only ever touches the window it was given, which never extends into
//    the future. Tomorrow's plans are not this program's business.
//
// Built joined to paintplan.swift into one file (see install.sh): Swift lets
// only one file of a build have top-level code.

import EventKit
import Foundation

// Same containment rule as the other helpers: this app may be handed a path,
// never a name. LaunchServices passes its own arguments on a plain launch, and
// `open -a "TimeTracker Calendar" notes.txt` must not make this program read —
// or, through the result file beside it, overwrite — notes.txt.
let requestName = ".paint-request.tsv"
let resultName = ".paint-result.tsv"
let listName = ".paint-calendars.tsv"
// Which sessions have been painted, per calendar: how an event you deleted is
// told from one never painted (rule 3 in paintplan.swift).
let ledgerName = ".paint-ledger.tsv"

func requestPath() -> String? {
    for arg in CommandLine.arguments.dropFirst()
    where arg.hasPrefix("/") && (arg as NSString).lastPathComponent == requestName {
        return arg
    }
    return nil
}

// The path names the data folder even when there is no request in it: that is
// how a listing knows where to put its answer. It used to be launched bare for
// a listing, and fell back to ~/.timetrack — so a scratch install's "Allow"
// wrote its answer into the real install's folder and then waited, for ever,
// for one in its own.
let request = requestPath()
let dir = (request as NSString?)?.deletingLastPathComponent
    ?? "\(FileManager.default.homeDirectoryForCurrentUser.path)/.timetrack"
let listing = request.map { !FileManager.default.fileExists(atPath: $0) } ?? true

func write(_ text: String, _ name: String) {
    try? text.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
}

func finish(_ fields: [String], code: Int32) -> Never {
    let line = fields.map {
        $0.replacingOccurrences(of: "\t", with: " ")
          .replacingOccurrences(of: "\n", with: " ")
    }.joined(separator: "\t")
    write(line + "\n", resultName)
    // The request is consumed either way. Leaving it behind would have the
    // next run repaint a window it was already asked about, for ever.
    if let p = request { try? FileManager.default.removeItem(atPath: p) }
    exit(code)
}

// --- permission --------------------------------------------------------------

let store = EKEventStore()
let sem = DispatchSemaphore(value: 0)
var granted = false

// Full access, not write-only: reconciling means reading back what is already
// in the window, so "write-only" would be a lie that could not work. The
// calendar it reads is the one it wrote.
if #available(macOS 14.0, *) {
    store.requestFullAccessToEvents { g, _ in granted = g; sem.signal() }
} else {
    store.requestAccess(to: .event) { g, _ in granted = g; sem.signal() }
}
// Long enough for a person to read a dialog and decide. Nothing blocks on
// this — the paint is fire-and-forget — so a patient timeout only ever costs
// a helper that outlives an ignored prompt.
_ = sem.wait(timeout: .now() + 60)

if !granted { finish(["denied", ""], code: 1) }

// --- no request: list what there is ------------------------------------------
// What the app's Calendar switch runs: it raises the permission prompt at a
// calm moment and dumps the calendars you could paint into, which is what the
// settings page offers you to choose from. It writes nothing to any calendar.

if listing {
    var out = "STATUS\tok\n"
    for cal in store.calendars(for: .event) where cal.allowsContentModifications {
        let title = cal.title.replacingOccurrences(of: "\t", with: " ")
        let source = cal.source?.title.replacingOccurrences(of: "\t", with: " ") ?? ""
        out += "CAL\t\(title)\t\(source)\n"
    }
    write(out, listName)
    write("ok\tlisted\n", resultName)
    exit(0)
}

// --- the request -------------------------------------------------------------

guard let raw = try? String(contentsOfFile: request!, encoding: .utf8) else {
    finish(["error", "could not read the request"], code: 1)
}

var calTitle = ""
var from: Date? = nil
var to: Date? = nil
var installID = ""
var legacy = false
var wants: [Want] = []

for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
    let f = line.components(separatedBy: "\t")
    switch f[0] {
    case "CAL" where f.count >= 2:
        calTitle = f[1].trimmingCharacters(in: .whitespaces)
    case "WINDOW" where f.count >= 3:
        if let a = Double(f[1]), let b = Double(f[2]) {
            from = Date(timeIntervalSince1970: a)
            to = Date(timeIntervalSince1970: b)
        }
    case "ID" where f.count >= 2:
        installID = f[1]
    case "LEGACY" where f.count >= 2:
        legacy = f[1] == "1"
    case "S" where f.count >= 4:
        guard let a = Int(f[1]), let b = Int(f[2]), b > a else { continue }
        let title = f[3].trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { continue }
        let body = f.count > 4 ? f[4].replacingOccurrences(of: "\u{1f}", with: "\n") : ""
        wants.append(Want(start: a, end: b, title: title, body: body))
    default:
        continue
    }
}

guard !calTitle.isEmpty, let windowStart = from, let windowEnd = to,
      windowEnd > windowStart else {
    finish(["error", "malformed request"], code: 1)
}
// No mark, no paint: an event written without one could never be told from
// yours again, and so could never be corrected or removed.
guard isInstallID(installID) else {
    finish(["error", "no install mark"], code: 1)
}

// Rule 1: the named calendar, or nothing. No nearest match, no new calendar.
let target = store.calendars(for: .event).first {
    $0.allowsContentModifications
        && $0.title.compare(calTitle, options: .caseInsensitive) == .orderedSame
}
guard let calendar = target else {
    finish(["nocal", calTitle], code: 1)
}

// --- the ledger ----------------------------------------------------------------
// One line per painted session: calendar title, then the session's start.
// Other calendars' lines ride through untouched.

let ledgerPath = dir + "/" + ledgerName
var ledgerOthers: [String] = []
var ledger = Set<Int>()
if let text = try? String(contentsOfFile: ledgerPath, encoding: .utf8) {
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let f = line.components(separatedBy: "\t")
        if f.count == 2, f[0] == calendar.title, let sid = Int(f[1]) {
            ledger.insert(sid)
        } else {
            ledgerOthers.append(String(line))
        }
    }
}

// --- reconcile ---------------------------------------------------------------

let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd,
                                         calendars: [calendar])
// All-day events are never this program's: a session has a start and an end.
let existing = store.events(matching: predicate).filter { !$0.isAllDay }
let seen: [Seen] = existing.enumerated().compactMap { i, ev in
    guard let s = ev.startDate, let e = ev.endDate else { return nil }
    return Seen(ref: i, start: Int(s.timeIntervalSince1970), end: Int(e.timeIntervalSince1970),
                title: ev.title ?? "", notes: ev.notes ?? "")
}
var wantBySid: [Int: Want] = [:]
for w in wants where wantBySid[w.sid] == nil { wantBySid[w.sid] = w }

let decided = plan(wants: wants, seen: seen, id: installID, legacy: legacy, ledger: ledger)

var removed = 0, updated = 0, created = 0
var failure: String? = nil

func fill(_ ev: EKEvent, _ w: Want) {
    ev.title = w.title
    ev.startDate = Date(timeIntervalSince1970: TimeInterval(w.start))
    ev.endDate = Date(timeIntervalSince1970: TimeInterval(w.end))
    ev.notes = notes(installID, w)
}

for act in decided.acts {
    switch act {
    case .create(let sid):
        guard let w = wantBySid[sid] else { continue }
        let ev = EKEvent(eventStore: store)
        ev.calendar = calendar
        ev.timeZone = TimeZone.current
        fill(ev, w)
        // A record of what already happened should never buzz, and should
        // never make you look busy to anyone reading your availability.
        ev.alarms = nil
        ev.availability = .free
        do { try store.save(ev, span: .thisEvent, commit: false); created += 1 }
        catch { failure = failure ?? error.localizedDescription }
    case .update(let ref, let sid):
        guard let w = wantBySid[sid] else { continue }
        let ev = existing[ref]
        fill(ev, w)
        do { try store.save(ev, span: .thisEvent, commit: false); updated += 1 }
        catch { failure = failure ?? error.localizedDescription }
    case .remove(let ref):
        do { try store.remove(existing[ref], span: .thisEvent, commit: false); removed += 1 }
        catch { failure = failure ?? error.localizedDescription }
    }
}

do {
    try store.commit()
} catch {
    finish(["error", error.localizedDescription], code: 1)
}

if let f = failure {
    finish(["error", f], code: 1)
}
// Written only once the calendar has the events: a ledger that ran ahead of
// a failed commit would read as sessions you had deleted, and never repaint
// them.
let mine = decided.ledger.sorted().map { "\(calendar.title)\t\($0)" }
try? ((ledgerOthers + mine).joined(separator: "\n") + "\n")
    .write(toFile: ledgerPath, atomically: true, encoding: .utf8)

finish(["ok", calendar.title, String(created), String(updated), String(removed)],
       code: 0)
