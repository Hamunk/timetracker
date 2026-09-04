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
//   TimeTracker Calendar.app --args <dir>/.paint-request.tsv    paint
//   TimeTracker Calendar.app                                    list calendars
//
// The request file, tab separated, written by paint-calendar.sh:
//
//   CAL     <calendar title>
//   WINDOW  <from_epoch>  <to_epoch>
//   STRICT  1                       (only on the first paint into a calendar)
//   S       <start_epoch> <end_epoch>  <title>  <notes>
//
// Notes carry their line breaks as \x1f, because the request is a TSV and a
// TSV has one row per line — the same trick sync-apps.sh uses to read a file
// whose fields may be empty.
//
// It **reconciles** rather than appends, and that is the whole design. Every
// run makes the window match the log exactly: sessions with no event get one,
// events with no session are removed, and an event whose notes have changed is
// updated in place. That is what makes it safe to run after every single
// session close — the tenth run over the same week does nothing at all — and
// it is also what makes a correction in the dashboard show up in the calendar
// without anything having to remember what it did last time.
//
// Two rules keep the reconcile from being dangerous:
//
// 1. It only ever touches the one calendar it was told to, and it will not go
//    looking for one. A title that matches nothing is an error, never a
//    "close enough" match and never a calendar created behind your back — a
//    silently-created local calendar would look like it worked while syncing
//    nowhere.
// 2. It only ever touches the window it was given, which never extends into
//    the future. Tomorrow's plans are not this program's business.
// 3. The first paint into a calendar refuses to delete anything. Reconciling
//    means removing events that no longer match a session, which is safe only
//    because everything in the calendar was put there by a previous run — and
//    that is a claim which is exactly false the first time. So a calendar that
//    already has something in the window is reported and left completely
//    alone, and the shell only records the calendar as adopted once a paint
//    has actually succeeded. Without this, picking your real calendar out of a
//    dropdown by mistake would silently delete a fortnight of your life.

import EventKit
import Foundation

// Same containment rule as the other helpers: this app may be handed a path,
// never a name. LaunchServices passes its own arguments on a plain launch, and
// `open -a "TimeTracker Calendar" notes.txt` must not make this program read —
// or, through the result file beside it, overwrite — notes.txt.
let requestName = ".paint-request.tsv"
let resultName = ".paint-result.tsv"
let listName = ".paint-calendars.tsv"

func requestPath() -> String? {
    for arg in CommandLine.arguments.dropFirst()
    where arg.hasPrefix("/") && (arg as NSString).lastPathComponent == requestName {
        return arg
    }
    return nil
}

let request = requestPath()
let dir = (request as NSString?)?.deletingLastPathComponent
    ?? "\(FileManager.default.homeDirectoryForCurrentUser.path)/.timetrack"

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
// This is the "time calendar" launch, and the only reason the app is worth
// running by hand: it answers the permission prompt at a calm moment and dumps
// the calendars you could paint into, which is what the settings page offers
// you to choose from. It writes nothing to any calendar.

if request == nil {
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

struct Session {
    let start: Date
    let end: Date
    let title: String
    let notes: String
    // Identity for the reconcile. Deliberately *not* including the notes: a
    // reworded plan should update the event it belongs to, not delete it and
    // make a new one — and a server that rewraps a description on the way back
    // would otherwise have this rewriting the same week for ever.
    var key: String {
        return "\(Int(start.timeIntervalSince1970))|\(Int(end.timeIntervalSince1970))|\(title)"
    }
}

guard let raw = try? String(contentsOfFile: request!, encoding: .utf8) else {
    finish(["error", "could not read the request"], code: 1)
}

var calTitle = ""
var from: Date? = nil
var to: Date? = nil
var strict = false
var wanted: [String: Session] = [:]

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
    case "STRICT" where f.count >= 2:
        strict = f[1] == "1"
    case "S" where f.count >= 4:
        guard let a = Double(f[1]), let b = Double(f[2]), b > a else { continue }
        let title = f[3].trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { continue }
        let notes = f.count > 4
            ? f[4].replacingOccurrences(of: "\u{1f}", with: "\n") : ""
        let s = Session(start: Date(timeIntervalSince1970: a),
                        end: Date(timeIntervalSince1970: b),
                        title: title, notes: notes)
        // Two sessions cannot share a key without being the same session.
        wanted[s.key] = s
    default:
        continue
    }
}

guard !calTitle.isEmpty, let windowStart = from, let windowEnd = to,
      windowEnd > windowStart else {
    finish(["error", "malformed request"], code: 1)
}

// Rule 1: the named calendar, or nothing. No nearest match, no new calendar.
let target = store.calendars(for: .event).first {
    $0.allowsContentModifications
        && $0.title.compare(calTitle, options: .caseInsensitive) == .orderedSame
}
guard let calendar = target else {
    finish(["nocal", calTitle], code: 1)
}

// --- reconcile ---------------------------------------------------------------

let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd,
                                         calendars: [calendar])
let existing = store.events(matching: predicate)

// Rule 3. Counted before a single change is made, and nothing is committed on
// the way out — a refusal must leave the calendar exactly as it was found.
if strict {
    var strangers = 0
    for ev in existing {
        guard let s = ev.startDate, let e = ev.endDate else { continue }
        let key = "\(Int(s.timeIntervalSince1970))|\(Int(e.timeIntervalSince1970))|\(ev.title ?? "")"
        if wanted[key] == nil { strangers += 1 }
    }
    if strangers > 0 {
        finish(["notempty", calendar.title, String(strangers)], code: 1)
    }
}

var seen = Set<String>()
var removed = 0, updated = 0, created = 0
var failure: String? = nil

for ev in existing {
    guard let s = ev.startDate, let e = ev.endDate else { continue }
    let key = "\(Int(s.timeIntervalSince1970))|\(Int(e.timeIntervalSince1970))|\(ev.title ?? "")"
    if let want = wanted[key], !seen.contains(key) {
        seen.insert(key)
        // Same slot, same name: keep the event and its identity — which is
        // what stops every paint from churning the whole week through the
        // server — and only correct the description if it has drifted.
        if (ev.notes ?? "") != want.notes {
            ev.notes = want.notes.isEmpty ? nil : want.notes
            do { try store.save(ev, span: .thisEvent, commit: false); updated += 1 }
            catch { failure = failure ?? error.localizedDescription }
        }
    } else {
        // Either the session behind it was edited or deleted, or it is a
        // duplicate of one already matched. Rule 2 keeps this inside the
        // window, and the calendar is ours alone, so there is nothing here
        // that was not put here by a previous run.
        do { try store.remove(ev, span: .thisEvent, commit: false); removed += 1 }
        catch { failure = failure ?? error.localizedDescription }
    }
}

for (key, s) in wanted where !seen.contains(key) {
    let ev = EKEvent(eventStore: store)
    ev.calendar = calendar
    ev.title = s.title
    ev.startDate = s.start
    ev.endDate = s.end
    ev.timeZone = TimeZone.current
    if !s.notes.isEmpty { ev.notes = s.notes }
    // A record of what already happened should never buzz, and should never
    // make you look busy to anyone reading your availability.
    ev.alarms = nil
    if calendar.allowsContentModifications { ev.availability = .free }
    do { try store.save(ev, span: .thisEvent, commit: false); created += 1 }
    catch { failure = failure ?? error.localizedDescription }
}

do {
    try store.commit()
} catch {
    finish(["error", error.localizedDescription], code: 1)
}

if let f = failure {
    finish(["error", f], code: 1)
}
finish(["ok", calendar.title, String(created), String(updated), String(removed)],
       code: 0)
