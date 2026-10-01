// What the calendar painter does, decided without EventKit.
//
// Given the sessions the log has in the window and the events the calendar
// already has there, this says which events to create, which to update and
// which to remove — and, the point of it all, which to leave alone. It sits
// apart from ttpaint.swift so that paintplan.test.swift can put every case to
// it with plain values and no calendar anywhere near: the cases that matter
// here are the ones where a mistake deletes somebody's dentist appointment.
//
// The painter used to own the whole calendar it was given. Every run made the
// window match the log, so anything else in it — an event you added, or one
// of its own you had moved — was deleted, and the only protection was a first
// paint that refused a calendar with anything in it. That made it unusable on
// the calendar people actually look at. Now it owns events, not a calendar:
//
// 1. Every event it creates ends with a mark — "Tomat · <install>-<session>-
//    <fingerprint>" — naming the install that made it, the session it shows,
//    and a fingerprint of exactly what was written. It updates or removes an
//    event only if the mark is its own *and* the fingerprint still matches.
//    Anything without the mark is somebody else's, whatever it looks like.
// 2. An event of its own that you have edited — moved, renamed, written in —
//    no longer matches its fingerprint, and from then on it is yours: never
//    updated, never removed, and still counted as showing its session, so a
//    second copy is not painted beside it.
// 3. An event of its own that you deleted stays deleted. The ledger remembers
//    which sessions were painted, and a painted session with no event left is
//    one somebody removed on purpose.
// 4. An unmarked event with exactly a session's time and title is taken to
//    show that session, so none is added beside it — but it is not touched.
//    The one exception is a calendar an older version painted, before there
//    were marks: there, such an event is that older version's work, and it is
//    taken over and marked, once, instead of being duplicated.
//
// The fingerprint is deliberately forgiving about whitespace and seconds,
// because servers rewrap descriptions and some drop the seconds from a time,
// and a fingerprint that broke on that would hand every event to rule 2 and
// leave the calendar stale for good. Stale is still the safe direction: every
// way this can be wrong leaves an event in place rather than taking one away.

import Foundation

/// A session the log has in the window.
struct Want {
    let sid: Int        // when it started, to the second: the session's identity
    let rawEnd: Int     // when it ended, to the second, as an older version painted it
    let start: Int      // to the minute, as painted now
    let end: Int
    let title: String
    let body: String    // plan, recap, note, counts — the notes without the mark

    init(start rawStart: Int, end rawEnd: Int, title: String, body: String) {
        sid = rawStart
        self.rawEnd = rawEnd
        start = rawStart - rawStart % 60
        let e = rawEnd - rawEnd % 60
        end = e > start ? e : start + 60
        self.title = title
        self.body = body
    }
}

/// An event the calendar has in the window.
struct Seen {
    let ref: Int        // the caller's index for it
    let start: Int
    let end: Int
    let title: String
    let notes: String   // whole, mark and all
}

enum Act: Equatable {
    case create(Int)            // the session with this sid
    case update(Int, Int)       // the event with this ref, to the session with this sid
    case remove(Int)            // the event with this ref
}

struct Plan {
    var acts: [Act] = []
    var ledger = Set<Int>()     // the sessions painted, to remember for next time
}

let markPrefix = "Tomat · "

func isInstallID(_ s: String) -> Bool {
    return s.count == 6 && s.unicodeScalars.allSatisfy {
        ("a"..."z").contains($0) || ("0"..."9").contains($0)
    }
}

/// FNV-1a: small, stable across runs and machines, and not trying to be a
/// secret. Nobody forges these; the danger it guards against is a coincidence.
func fnv(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
    return h
}

func fingerprint(title: String, start: Int, end: Int, body: String) -> String {
    func flat(_ s: String) -> String {
        return s.precomposedStringWithCanonicalMapping
            .unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(String.init).joined()
    }
    let input = "\(flat(title))|\(start / 60)|\(end / 60)|\(flat(body))"
    let h = String(fnv(input) & 0xffff_ffff, radix: 16)
    return String(repeating: "0", count: 8 - h.count) + h
}

func mark(_ id: String, _ w: Want) -> String {
    let fp = fingerprint(title: w.title, start: w.start, end: w.end, body: w.body)
    return "\(markPrefix)\(id)-\(String(w.sid, radix: 36))-\(fp)"
}

/// The notes an event is written with: the session's own text, then the mark.
func notes(_ id: String, _ w: Want) -> String {
    return w.body.isEmpty ? mark(id, w) : w.body + "\n\n" + mark(id, w)
}

struct Mark {
    let id: String
    let sid: Int
    let fp: String
    let body: String
}

/// The mark on the last line of some notes, and the text above it.
func readMark(_ notes: String) -> Mark? {
    var lines = notes.components(separatedBy: .newlines)
    while let last = lines.last,
          last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
    guard let line = lines.popLast()?.trimmingCharacters(in: .whitespaces),
          line.hasPrefix(markPrefix) else { return nil }
    let parts = line.dropFirst(markPrefix.count).split(separator: "-").map(String.init)
    guard parts.count == 3, isInstallID(parts[0]),
          let sid = Int(parts[1], radix: 36),
          parts[2].count == 8, UInt32(parts[2], radix: 16) != nil else { return nil }
    let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return Mark(id: parts[0], sid: sid, fp: parts[2], body: body)
}

func plan(wants: [Want], seen: [Seen], id: String, legacy: Bool,
          ledger: Set<Int>) -> Plan {
    var p = Plan()
    var want: [Int: Want] = [:]
    var order: [Int] = []
    for w in wants where want[w.sid] == nil {
        want[w.sid] = w
        order.append(w.sid)
    }
    // Unmarked twins are found by what they show, at either precision: to the
    // minute as painted now, to the second as an older version painted.
    var byMinute: [String: Int] = [:], bySecond: [String: Int] = [:]
    for w in want.values {
        byMinute["\(w.title)|\(w.start / 60)|\(w.end / 60)"] = w.sid
        bySecond["\(w.title)|\(w.sid)|\(w.rawEnd)"] = w.sid
    }

    var owned: [Int: (ref: Int, fp: String?)] = [:]   // ours, as we left it
    var held = Set<Int>()                              // shown by an event we do not own

    for e in seen {
        if let m = readMark(e.notes) {
            // Another install's mark — a scratch copy painting the same
            // calendar, say — is as much somebody else's as no mark at all.
            guard m.id == id else { continue }
            let now = fingerprint(title: e.title, start: e.start, end: e.end, body: m.body)
            if now != m.fp {
                held.insert(m.sid)                     // rule 2: edited, so yours
            } else if owned[m.sid] == nil {
                owned[m.sid] = (e.ref, m.fp)
            }
            // A second untouched copy of one of ours — a copy made in the
            // calendar app, or one a sync played twice — is left where it is.
            // Removing it would be right more often than not, and wrong the
            // one time it was somebody's.
            continue
        }
        let twin = byMinute["\(e.title)|\(e.start / 60)|\(e.end / 60)"]
            ?? bySecond["\(e.title)|\(e.start)|\(e.end)"]
        guard let sid = twin else { continue }         // rule 1: not ours, not looked at
        // A mark anywhere but the last line is one of ours with something
        // written under it: edited, and so not an older version's to take.
        if legacy && owned[sid] == nil && !e.notes.contains(markPrefix) {
            owned[sid] = (e.ref, nil)                  // rule 4's exception: taken over
        } else {
            held.insert(sid)                           // rule 4: shown, not touched
        }
    }

    for (sid, o) in owned.sorted(by: { $0.key < $1.key }) {
        guard let w = want[sid] else {
            p.acts.append(.remove(o.ref))              // its session is gone
            continue
        }
        let fp = fingerprint(title: w.title, start: w.start, end: w.end, body: w.body)
        if o.fp != fp { p.acts.append(.update(o.ref, sid)) }
        p.ledger.insert(sid)
    }
    for sid in order where owned[sid] == nil {
        if held.contains(sid) { p.ledger.insert(sid); continue }
        if ledger.contains(sid) { p.ledger.insert(sid); continue }   // rule 3
        p.acts.append(.create(sid))
        p.ledger.insert(sid)
    }
    return p
}
