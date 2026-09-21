import EventKit
import Foundation

let usage = """
usage:
  pas tasks [--list <name>]        incomplete reminders as JSON (default list: Tasks)
  pas events <startISO> <endISO>   calendar events in window as JSON
  pas apply <plan.json>            create and delete Time Blocking events
"""

let store = EKEventStore()

func fail(_ message: String, _ code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

/// Blocks until EventKit answers. Only the store the subcommand needs is requested.
func requestAccess(_ entity: EKEntityType) {
    let semaphore = DispatchSemaphore(value: 0)
    var granted = false
    var failure: Error?
    let handler: EKEventStoreRequestAccessCompletionHandler = { ok, error in
        granted = ok
        failure = error
        semaphore.signal()
    }
    switch entity {
    case .reminder: store.requestFullAccessToReminders(completion: handler)
    case .event: store.requestFullAccessToEvents(completion: handler)
    @unknown default: fail("unknown entity type")
    }
    semaphore.wait()
    guard granted else {
        let name = entity == .reminder ? "Reminders" : "Calendar"
        let detail = failure.map { ": \($0.localizedDescription)" } ?? ""
        fail("no access to \(name)\(detail). Grant it in System Settings > Privacy & Security.", 1)
    }
}

func emit<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value) else { fail("failed to encode output", 1) }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

// Both types encode absent values as explicit null rather than omitting the key,
// so every record has the same shape. The synthesized encode would drop them.

struct Task: Encodable {
    let id: String
    let title: String
    let notes: String?
    let due: Date?
    let priority: Int
    let created: Date?
    let modified: Date?

    enum CodingKeys: String, CodingKey { case id, title, notes, due, priority, created, modified }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(notes, forKey: .notes)
        try c.encode(due, forKey: .due)
        try c.encode(priority, forKey: .priority)
        try c.encode(created, forKey: .created)
        try c.encode(modified, forKey: .modified)
    }
}

struct Event: Encodable {
    let id: String
    let calendar: String
    let calendarId: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case id, calendar, calendarId, title, start, end, isAllDay, notes
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(calendar, forKey: .calendar)
        try c.encode(calendarId, forKey: .calendarId)
        try c.encode(title, forKey: .title)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(isAllDay, forKey: .isAllDay)
        try c.encode(notes, forKey: .notes)
    }
}

func runTasks(list: String) {
    requestAccess(.reminder)
    // Reminder list titles are no more unique than calendar titles, and picking the
    // first match would be a wrong answer that looks like a right one.
    let matches = store.calendars(for: .reminder).filter { $0.title == list }
    if matches.isEmpty { fail("no reminder list named \"\(list)\"") }
    if matches.count > 1 { fail("\(matches.count) reminder lists named \"\(list)\"") }

    // nil bounds means "incomplete, any due date or none" — most tasks have no due date.
    let predicate = store.predicateForIncompleteReminders(
        withDueDateStarting: nil, ending: nil, calendars: matches)

    let semaphore = DispatchSemaphore(value: 0)
    var tasks: [Task] = []
    store.fetchReminders(matching: predicate) { reminders in
        tasks = (reminders ?? []).map { reminder in
            Task(
                id: reminder.calendarItemIdentifier,
                title: reminder.title ?? "",
                notes: reminder.notes,
                due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                priority: reminder.priority,
                created: reminder.creationDate,
                modified: reminder.lastModifiedDate)
        }
        semaphore.signal()
    }
    semaphore.wait()
    emit(tasks)
}

func runEvents(_ startArg: String, _ endArg: String) {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime]
    guard let start = parser.date(from: startArg) else { fail("bad start date \"\(startArg)\"") }
    guard let end = parser.date(from: endArg) else { fail("bad end date \"\(endArg)\"") }

    requestAccess(.event)
    // No calendar filter: what counts as busy is a rules.md question, not a binary one.
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)

    let stamp = ISO8601DateFormatter()
    // ponytail: recurring occurrences share one eventIdentifier, so id pairs it with the
    // occurrence start. Deleting a single occurrence later needs a richer handle than this.
    let events = store.events(matching: predicate).map { event in
        Event(
            id: "\(event.eventIdentifier ?? ""):\(stamp.string(from: event.startDate))",
            calendar: event.calendar.title,
            calendarId: event.calendar.calendarIdentifier,
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            notes: event.notes)
    }
    emit(events)
}

// MARK: - apply

// The one machine-specific value in this codebase. Rediscover it with:
//   bin/pas events <start> <end> | jq -r '.[] | select(.calendar=="Time Blocking") | .calendarId'
let timeBlockingCalendarId = "D113E352-15FF-4ABD-887F-CD3EE650B8A5"
let markerPrefix = "pas-task:"

struct Plan: Decodable {
    struct Create: Decodable {
        let taskId: String
        let title: String
        let start: Date
        let end: Date
    }
    let calendarId: String?
    let delete: [String]?
    let create: [Create]?
}

struct ApplyResult: Encodable {
    let created: Int
    let deleted: Int
    let createdIds: [String]
}

/// `pas events` ids are "<eventIdentifier>:<occurrence start>", and event identifiers
/// contain colons of their own, so recover the identifier by testing for the
/// fixed-width ISO suffix rather than splitting on a separator.
func eventIdentifier(fromListingId id: String) -> String {
    guard id.count > 21 else { return id }
    let separator = id.index(id.endIndex, offsetBy: -21)
    guard id[separator] == ":" else { return id }
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime]
    guard parser.date(from: String(id.suffix(20))) != nil else { return id }
    return String(id[id.startIndex..<separator])
}

func runApply(_ path: String) {
    guard let data = FileManager.default.contents(atPath: path) else {
        fail("cannot read plan file \"\(path)\"")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let plan = try? decoder.decode(Plan.self, from: data) else {
        fail("plan file \"\(path)\" is not a valid plan")
    }

    // Guard 1, first half: a plan may name its target calendar, but only the right one.
    if let named = plan.calendarId, named != timeBlockingCalendarId {
        fail("refused: calendarId \(named) is not the Time Blocking calendar")
    }

    let deletions = plan.delete ?? []
    let creations = plan.create ?? []
    if deletions.isEmpty && creations.isEmpty { fail("plan is empty") }

    requestAccess(.event)
    guard let calendar = store.calendar(withIdentifier: timeBlockingCalendarId) else {
        fail("Time Blocking calendar \(timeBlockingCalendarId) not found", 1)
    }

    // Every guard runs against every operation before a single write happens. A plan
    // that trips one guard is refused whole; partial application would be worse than
    // either outcome.
    let now = Date()
    var refusals: [String] = []
    var targets: [EKEvent] = []

    for id in deletions {
        guard let event = store.event(withIdentifier: eventIdentifier(fromListingId: id)) else {
            refusals.append("delete \(id): no such event")
            continue
        }
        if event.calendar.calendarIdentifier != timeBlockingCalendarId {
            refusals.append("delete \(id): event is on \(event.calendar.title), not Time Blocking")
        }
        if !(event.notes ?? "").contains(markerPrefix) {
            refusals.append("delete \(id): no \(markerPrefix) marker, so pas did not create it")
        }
        // ponytail: refuses anything already started, including five minutes ago.
        // Right default; wrong answer maybe twice a year.
        if event.startDate < now {
            refusals.append("delete \(id): already started, and the past is the record")
        }
        targets.append(event)
    }

    for item in creations {
        if item.taskId.isEmpty { refusals.append("create \"\(item.title)\": empty taskId") }
        if item.end <= item.start { refusals.append("create \"\(item.title)\": end is not after start") }
    }

    if !refusals.isEmpty {
        fail("refused, nothing written:\n  " + refusals.joined(separator: "\n  "))
    }

    // Deletes go first so a replaced block frees its slot before the new one claims it.
    // ponytail: no move operation — a moved block is a delete plus a create. One less
    // path through the trust boundary, at the cost of the event identifier changing.
    do {
        for event in targets {
            try store.remove(event, span: .thisEvent, commit: false)
        }
        var made: [EKEvent] = []
        for item in creations {
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = item.title
            event.startDate = item.start
            event.endDate = item.end
            event.notes = markerPrefix + item.taskId
            try store.save(event, span: .thisEvent, commit: false)
            made.append(event)
        }
        try store.commit()
        emit(ApplyResult(
            created: made.count,
            deleted: targets.count,
            createdIds: made.map { $0.eventIdentifier ?? "" }))
    } catch {
        store.reset()
        fail("write failed, changes rolled back: \(error.localizedDescription)", 1)
    }
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail(usage) }
args.removeFirst()

switch command {
case "tasks":
    var list = "Tasks"
    if args.first == "--list" {
        guard args.count >= 2 else { fail("--list needs a value\n\n" + usage) }
        list = args[1]
        args.removeFirst(2)
    }
    guard args.isEmpty else { fail("unexpected argument \"\(args[0])\"\n\n" + usage) }
    runTasks(list: list)
case "events":
    guard args.count == 2 else { fail(usage) }
    runEvents(args[0], args[1])
case "apply":
    guard args.count == 1 else { fail(usage) }
    runApply(args[0])
default:
    fail("unknown command \"\(command)\"\n\n" + usage)
}
