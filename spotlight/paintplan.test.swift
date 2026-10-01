// Cases for paintplan.swift. Run: ./spotlight/paintplan.test.sh
//
// Most of these are about what is *not* done. The painter writes into the
// calendar people actually use, so the cases that matter are the ones where a
// wrong answer removes or rewrites an event somebody else put there.

import Foundation

var failed = 0, total = 0
func check(_ label: String, _ ok: Bool) {
    total += 1
    print((ok ? "  ok    " : "  FAIL  ") + label)
    if !ok { failed += 1 }
}

let me = "k3x9q2"
let t0 = 1_790_000_000                      // a Tuesday, 14:13:20 UTC
let a = Want(start: t0 + 7, end: t0 + 1507, title: "med5 patologi", body: "Plan: kap 3")
let b = Want(start: t0 + 3600, end: t0 + 5400, title: "Lesing", body: "")

/// The event a previous run would have left for a session.
func painted(_ ref: Int, _ w: Want, id: String = me) -> Seen {
    return Seen(ref: ref, start: w.start, end: w.end, title: w.title, notes: notes(id, w))
}
func acts(_ p: Plan) -> [Act] { return p.acts }

print("a first paint")
var p = plan(wants: [a, b], seen: [], id: me, legacy: false, ledger: [])
check("both sessions created", acts(p) == [.create(a.sid), .create(b.sid)])
check("both remembered", p.ledger == [a.sid, b.sid])
check("painted to the minute", a.start % 60 == 0 && a.end % 60 == 0)
check("the mark is the last line", notes(me, a).hasSuffix(mark(me, a))
      && notes(me, a).hasPrefix("Plan: kap 3\n\n"))
check("an empty body is the mark alone", notes(me, b) == mark(me, b))

print("your own events are not looked at")
let dentist = Seen(ref: 9, start: t0, end: t0 + 1800, title: "Tannlege", notes: "Ta med kort")
let lunch = Seen(ref: 8, start: t0 + 3600, end: t0 + 5400, title: "Lunsj", notes: "")
p = plan(wants: [a], seen: [dentist, lunch], id: me, legacy: false, ledger: [])
check("only the session is created", acts(p) == [.create(a.sid)])
p = plan(wants: [], seen: [dentist, lunch], id: me, legacy: true, ledger: [])
check("not removed with no session to show, even in an older version's calendar",
      acts(p) == [])

print("a second run changes nothing")
p = plan(wants: [a, b], seen: [painted(0, a), painted(1, b), dentist],
         id: me, legacy: false, ledger: [a.sid, b.sid])
check("no acts", acts(p) == [])
check("still remembered", p.ledger == [a.sid, b.sid])

print("a session corrected in History follows")
let a2 = Want(start: t0 + 7, end: t0 + 1507, title: "med5 patologi", body: "Plan: kap 3\nGjort: kap 3 og 4")
p = plan(wants: [a2], seen: [painted(0, a)], id: me, legacy: false, ledger: [a.sid])
check("its event is updated", acts(p) == [.update(0, a.sid)])
let a3 = Want(start: t0 + 7, end: t0 + 2107, title: "med5 patologi", body: "Plan: kap 3")
p = plan(wants: [a3], seen: [painted(0, a)], id: me, legacy: false, ledger: [a.sid])
check("a new end is an update too", acts(p) == [.update(0, a.sid)])
let a4 = Want(start: t0 + 7, end: t0 + 1507, title: "med5 radiologi", body: "Plan: kap 3")
p = plan(wants: [a4], seen: [painted(0, a)], id: me, legacy: false, ledger: [a.sid])
check("so is another subject", acts(p) == [.update(0, a.sid)])

print("a session deleted in History takes its event with it")
p = plan(wants: [b], seen: [painted(0, a), painted(1, b)], id: me, legacy: false,
         ledger: [a.sid, b.sid])
check("only that event goes", acts(p) == [.remove(0)])
check("and is forgotten", p.ledger == [b.sid])

print("an event of ours that you edited is yours")
let moved = Seen(ref: 0, start: a.start + 600, end: a.end + 600, title: a.title,
                 notes: notes(me, a))
p = plan(wants: [a], seen: [moved], id: me, legacy: false, ledger: [a.sid])
check("moved: not moved back, not doubled", acts(p) == [])
p = plan(wants: [], seen: [moved], id: me, legacy: false, ledger: [a.sid])
check("moved: kept when its session is deleted", acts(p) == [])
p = plan(wants: [a2], seen: [moved], id: me, legacy: false, ledger: [a.sid])
check("moved: not rewritten when its session is", acts(p) == [])
let written = Seen(ref: 0, start: a.start, end: a.end, title: a.title,
                   notes: "Plan: kap 3\nHusk å spørre om eksamen\n\n" + mark(me, a))
p = plan(wants: [a2], seen: [written], id: me, legacy: false, ledger: [a.sid])
check("written in: left as you wrote it", acts(p) == [])
let renamed = Seen(ref: 0, start: a.start, end: a.end, title: "Patologi!", notes: notes(me, a))
p = plan(wants: [], seen: [renamed], id: me, legacy: false, ledger: [a.sid])
check("renamed: kept", acts(p) == [])
let below = Seen(ref: 0, start: a.start, end: a.end, title: a.title,
                 notes: notes(me, a) + "\nmy own line")
p = plan(wants: [], seen: [below], id: me, legacy: true, ledger: [a.sid])
check("written under the mark: kept, even in an older version's calendar", acts(p) == [])
p = plan(wants: [a], seen: [below], id: me, legacy: true, ledger: [a.sid])
check("written under the mark: not taken over either", acts(p) == [])

print("an event of ours that you deleted stays deleted")
p = plan(wants: [a, b], seen: [painted(1, b)], id: me, legacy: false, ledger: [a.sid, b.sid])
check("not painted again", acts(p) == [])
check("still remembered, so it is not painted next time either", p.ledger == [a.sid, b.sid])

print("what servers do to text is not an edit")
let rewrapped = Seen(ref: 0, start: a.start, end: a.end, title: a.title,
                     notes: notes(me, a).replacingOccurrences(of: "\n", with: "\r\n") + "\n  \n")
p = plan(wants: [a], seen: [rewrapped], id: me, legacy: false, ledger: [a.sid])
check("line endings and trailing space: still ours, nothing to do", acts(p) == [])
let nfd = Want(start: t0, end: t0 + 1800, title: "Bærekraftig økonomistyring", body: "")
let nfdSeen = Seen(ref: 0, start: nfd.start, end: nfd.end,
                   title: nfd.title.decomposedStringWithCanonicalMapping, notes: notes(me, nfd))
p = plan(wants: [nfd], seen: [nfdSeen], id: me, legacy: false, ledger: [nfd.sid])
check("decomposed letters: still ours", acts(p) == [])
p = plan(wants: [], seen: [rewrapped], id: me, legacy: false, ledger: [a.sid])
check("and still removed with its session", acts(p) == [.remove(0)])

print("another install's events are not ours")
p = plan(wants: [a], seen: [painted(0, a, id: "zzzzzz")], id: me, legacy: false, ledger: [])
check("ours is painted beside it", acts(p) == [.create(a.sid)])
p = plan(wants: [], seen: [painted(0, a, id: "zzzzzz")], id: me, legacy: false, ledger: [])
check("and theirs is never removed", acts(p) == [])

print("an unmarked event showing a session")
let twin = Seen(ref: 0, start: a.start, end: a.end, title: a.title, notes: "")
p = plan(wants: [a], seen: [twin], id: me, legacy: false, ledger: [])
check("is not doubled", acts(p) == [])
p = plan(wants: [], seen: [twin], id: me, legacy: false, ledger: [])
check("is not removed", acts(p) == [])

print("a calendar an older version painted")
let old = Seen(ref: 0, start: a.sid, end: a.rawEnd, title: a.title, notes: a.body)
let gone = Seen(ref: 1, start: t0 - 86400, end: t0 - 84600, title: "Lesing", notes: "")
p = plan(wants: [a], seen: [old, gone], id: me, legacy: true, ledger: [])
check("its event for a session is taken over and marked", acts(p) == [.update(0, a.sid)])
check("anything else in it is left", !acts(p).contains(.remove(1)))
p = plan(wants: [a], seen: [old], id: me, legacy: false, ledger: [])
check("the same event in any other calendar is only not doubled", acts(p) == [])

print("copies")
p = plan(wants: [a], seen: [painted(0, a), painted(1, a)], id: me, legacy: false, ledger: [a.sid])
check("a second copy of ours is left alone", acts(p) == [])
p = plan(wants: [a, a], seen: [], id: me, legacy: false, ledger: [])
check("one session listed twice is painted once", acts(p) == [.create(a.sid)])

print("marks that are not marks")
for junk in ["Tomat · nope", "Tomat · k3x9q2-zz", "Tomat · K3X9Q2-abc-0123abcd",
             "Tomat · k3x9q2-abc-xyz", "Tomat · k3x9q2-abc-0123abc", "tomat · k3x9q2-abc-0123abcd"] {
    check("not a mark: \(junk)", readMark("Plan\n\n" + junk) == nil)
}
let m = readMark(notes(me, a))
check("a real one reads back", m?.id == me && m?.sid == a.sid && m?.body == a.body)
check("short sessions still end after they start",
      Want(start: t0 + 10, end: t0 + 20, title: "x", body: "").end > Want(start: t0 + 10, end: t0 + 20, title: "x", body: "").start)

print("\n\(total - failed) of \(total) passed")
exit(failed == 0 ? 0 : 1)
