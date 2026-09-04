// TimeTracker reminder writer.
//
// Takes one line of text and puts it in Apple Reminders. Deliberately dumb in
// the same way ttcal.swift is dumb: it writes what it is handed and makes no
// decisions. Choosing the list, sanitising the text and deciding *whether* to
// capture all happen upstream, so any of that can change without a recompile.
//
// Like the calendar helper, this lives inside an app bundle — here carrying
// NSRemindersFullAccessUsageDescription — because macOS only grants reminders
// access to a bundle launched through LaunchServices. Exec'ing this binary
// directly is denied without a prompt.
//
//   TimeTracker Reminders.app --args <dir>/.tomato-reminder
//
// The input file is two tab-separated lines, written by the overlay:
//
//   LIST<TAB>Pause Notes
//   TEXT<TAB>Ask Bjørn about the tolerance stack-up
//
// and the answer goes back beside it as .tomato-reminder-result, one line:
//
//   ok<TAB>Pause Notes          saved
//   denied<TAB>                 permission refused (or never asked)
//   error<TAB>what went wrong   anything else
//
// Launched with no usable input — double-clicked, or from Spotlight as
// "time reminders" — it asks for access and reports, and writes nothing to
// your reminders. That is the *point* of it being launchable: a permission
// prompt answered at a calm moment is a prompt that never lands mid-break.
//
// Why full access for a feature that only ever writes: EventKit has no
// write-only tier for reminders. Calendar events do (requestWriteOnlyAccess),
// reminders do not, so capturing one idea requires a grant that could read
// them all. There is no way to ask for less; SECURITY.md says so out loud.

import EventKit
import Foundation

// Same containment rule as the calendar helper: this app may be handed a path,
// but never a *name*. LaunchServices passes its own arguments on a plain
// launch, and `open -a "TimeTracker Reminders" notes.txt` must not be able to
// make this program read — or, through the result file beside it, overwrite —
// notes.txt.
let expectedName = ".tomato-reminder"
let resultName = ".tomato-reminder-result"

func inputPath() -> String? {
    for arg in CommandLine.arguments.dropFirst()
    where arg.hasPrefix("/") && (arg as NSString).lastPathComponent == expectedName {
        return arg
    }
    return nil
}

let input = inputPath()
let dir = (input as NSString?)?.deletingLastPathComponent
    ?? "\(FileManager.default.homeDirectoryForCurrentUser.path)/.timetrack"
let resultPath = dir + "/" + resultName

func finish(_ status: String, _ detail: String, code: Int32) -> Never {
    let line = status + "\t"
        + detail.replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
    try? (line + "\n").write(toFile: resultPath, atomically: true, encoding: .utf8)
    // The request is consumed either way. Leaving it behind would have the
    // watcher launch this again on its next tick, forever, for a reminder that
    // will fail again for the same reason.
    if let p = input { try? FileManager.default.removeItem(atPath: p) }
    exit(code)
}

// --- what to write -----------------------------------------------------------
// Missing or unreadable input is not an error: it is the "grant me access"
// launch. listName stays at its default so the prompt's wording matches what
// a real capture would do.

var listName = "Pause Notes"
var text = ""

if let p = input, let raw = try? String(contentsOfFile: p, encoding: .utf8) {
    for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
        let f = line.components(separatedBy: "\t")
        guard f.count >= 2 else { continue }
        let v = f[1].trimmingCharacters(in: .whitespaces)
        if f[0] == "LIST", !v.isEmpty { listName = v }
        if f[0] == "TEXT" { text = v }
    }
}

// A reminder with no name is a row of nothing in a list you have to clean up.
let wantsWrite = !text.isEmpty

// --- permission --------------------------------------------------------------

let store = EKEventStore()
let sem = DispatchSemaphore(value: 0)
var granted = false

if #available(macOS 14.0, *) {
    store.requestFullAccessToReminders { g, _ in granted = g; sem.signal() }
} else {
    store.requestAccess(to: .reminder) { g, _ in granted = g; sem.signal() }
}
// Long enough for a human to read a dialog and decide. Nothing waits on this
// process — the overlay shows "saving" until the result file appears — so the
// only cost of a patient timeout is a helper that outlives an ignored prompt.
_ = sem.wait(timeout: .now() + 60)

if !granted {
    finish("denied", "", code: 1)
}
if !wantsWrite {
    finish("ok", listName, code: 0)
}

// --- the list ----------------------------------------------------------------
// A list of its own is the whole filing system here: everything caught in a
// break lands in one place, to be dragged where it belongs later. So the list
// is found by name, and created if it does not exist yet.

func remindersList(named name: String) -> EKCalendar? {
    let wanted = name.lowercased()
    for cal in store.calendars(for: .reminder)
    where cal.title.lowercased() == wanted && cal.allowsContentModifications {
        return cal
    }
    return nil
}

func createList(named name: String) -> EKCalendar? {
    // The source is the account the list is filed under. The default list's
    // own source is the right answer — it is where Reminders itself would put
    // a new list, which for an iCloud account is what syncs to the phone.
    let source = store.defaultCalendarForNewReminders()?.source
        ?? store.sources.first(where: { !$0.calendars(for: .reminder).isEmpty })
    guard let src = source else { return nil }
    let cal = EKCalendar(for: .reminder, eventStore: store)
    cal.title = name
    cal.source = src
    do {
        try store.saveCalendar(cal, commit: true)
        return cal
    } catch {
        return nil
    }
}

guard let list = remindersList(named: listName) ?? createList(named: listName)
        ?? store.defaultCalendarForNewReminders() else {
    finish("error", "no reminders list available", code: 1)
}

// --- write it ----------------------------------------------------------------

let reminder = EKReminder(eventStore: store)
reminder.title = text
reminder.calendar = list

do {
    try store.save(reminder, commit: true)
} catch {
    finish("error", error.localizedDescription, code: 1)
}

finish("ok", list.title, code: 0)
