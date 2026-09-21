# Plan 01 — `pas` read commands

## Context

`docs/plans/00-feasibility-and-architecture.md` established that EventKit is the only workable path to Reminders (AppleScript times out at 60s on a one-line read) and that a compiled Swift binary reaches it in 0.43s with no added dependencies. Nothing is built yet: the repo holds the architecture plan, an empty `README.md`, and empty `bin/` and `src/` directories.

This plan builds phase 1: the read half of `pas`, the EventKit bridge. After it, Claude can see the task list and the calendar as JSON. Nothing can write anywhere, so this phase is safe to iterate on against live data.

`pas` is a dumb data pipe. It does no scheduling, parses no notes, and makes no decisions. Every judgment call belongs to Claude and `rules.md` in plan 02.

## Scope

Ships two subcommands and a build step:

- `pas tasks [--list <name>]` — incomplete reminders as JSON array on stdout. Default list `Tasks`.
- `pas events <startISO> <endISO>` — events across all calendars in that window as JSON array on stdout.

Out of scope, deliberately: `pas apply` (plan 03), any write to Calendar or Reminders, any parsing of the time estimate in a reminder's notes, any filtering of which calendars count as busy. Notes ship verbatim; the consumer decides what they mean.

## Files

| Path | What |
|---|---|
| `src/pas.swift` | The whole binary. One file. |
| `Makefile` | `bin/pas` rule plus `test`. |
| `bin/pas` | Build output. Committed or not is the user's call; it is a 2.8s rebuild either way. |
| `test/smoke.sh` | The one runnable check. |

## Command contracts

Both commands print a JSON array to stdout and nothing else. Errors go to stderr with a nonzero exit. Empty result is `[]`, not an error.

`pas tasks`:
```json
[{
  "id": "x-apple-reminderkit://REMCDReminder/ABC-123",
  "title": "Finish 342 problem set",
  "notes": "2h",
  "due": "2026-09-22T17:00:00Z",
  "priority": 5,
  "created": "2026-09-18T14:02:11Z",
  "modified": "2026-09-19T09:31:40Z"
}]
```
`id` is `calendarItemIdentifier` — the stable handle plan 03's `pas-task:` marker points at. `notes`, `due`, `created`, `modified` are `null` when absent. `priority` is EventKit's 0-9 integer, 0 meaning unset; pass it through raw rather than mapping to high/medium/low.

`pas events`:
```json
[{
  "id": "ABC-123:2026-09-22",
  "calendar": "Class",
  "calendarId": "D113E352-...",
  "title": "CS 342 Lecture",
  "start": "2026-09-22T14:00:00Z",
  "end": "2026-09-22T15:15:00Z",
  "isAllDay": false,
  "notes": null
}]
```
Both `calendar` and `calendarId` ship because the architecture found duplicate calendar titles (two `Family`, two `Birthdays`) in the real data. Anything that has to be exact keys on `calendarId`; the title is for human-readable output.

All dates are ISO 8601 with a `Z` offset (`JSONEncoder.DateEncodingStrategy.iso8601`). Keys sorted (`.sortedKeys`) so diffs between runs stay readable.

## Implementation notes

**Access.** `EKEventStore.requestFullAccessToReminders` and `requestFullAccessToEvents` are async with completion handlers on an arbitrary queue. Block on a `DispatchSemaphore` from the top-level code; do not build an async main. Request only the store the subcommand needs — `tasks` does not need calendar access and vice versa. Denied access exits 1 with a message naming which permission is missing.

**Reminder fetch.** Use `predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [list])` rather than fetching all 512 and filtering `isCompleted` in Swift. Both nil bounds means "incomplete, regardless of due date", which includes tasks with no due date at all — those are the majority and they must not be dropped. `fetchReminders(matching:completion:)` is also async; same semaphore pattern.

**List lookup.** Match `store.calendars(for: .reminder)` by title. Exit 2 if no list matches, and also if more than one does — the duplicate-title problem applies here too, and silently picking the first would be a wrong answer that looks like a right one.

**Event fetch.** `predicateForEvents(withStart:end:calendars: nil)` across every calendar, then `store.events(matching:)`. No calendar filtering: Claude needs to see everything that occupies time, and deciding what counts as busy is a `rules.md` question, not a binary question.

**All-day events.** The architecture found these come back spanning `04:00:00Z` to `03:59:59Z` local. Emit the raw start/end plus `isAllDay: true` and stop there. A consumer that treats an all-day event as a busy block would blank the whole day, but that judgment belongs in plan 02's rules, not here.

**Recurring events share an `eventIdentifier`** across occurrences, so `id` is not unique within a result. Emit `eventIdentifier` plus the occurrence start (`"\(eventIdentifier):\(startISO)"`) so the pair is unique. Add a `ponytail:` comment naming the ceiling — if plan 03 ever needs to delete a single occurrence of a recurring event, this is where the handle would have to get richer.

**Argument parsing by hand.** Two subcommands and one flag do not need `ArgumentParser` or any other package. `CommandLine.arguments`, a `switch`, and a usage string on stderr. Bad or unparseable ISO dates exit 2 with the offending string quoted.

**Date parsing.** `ISO8601DateFormatter` for the `events` arguments. Accept the `withInternetDateTime` form the verification commands use; do not hand-roll a lenient parser.

**Due dates are `DateComponents`, not `Date`.** Convert with `Calendar.current.date(from:)`. A date-only due (no hour component) resolves to local midnight and will serialize as e.g. `2026-09-22T04:00:00Z`. Acceptable; do not invent a separate `dueHasTime` field until something actually needs it.

## Build

Three-line `Makefile`, no build script:

```make
bin/pas: src/pas.swift
	swiftc -O src/pas.swift -o bin/pas

test: bin/pas
	./test/smoke.sh
```

`swiftc` and EventKit ship with macOS; there is nothing to install.

## Verification

Run against the live system, from the project root, after `make`:

1. **Tasks are filtered.** `bin/pas tasks | jq 'length'` returns a count far below 512. `bin/pas tasks | jq '.[0]'` shows a real task with `notes` intact and unparsed.
2. **No completed tasks leak.** `bin/pas tasks | jq '[.[] | select(.title | test("<title of a task you just checked off>"))] | length'` returns 0.
3. **Ids are stable.** Run `bin/pas tasks` twice; the `id` values match. This is the property plan 03's marker depends on.
4. **Events span calendars.** `bin/pas events 2026-09-20T00:00:00Z 2026-09-27T00:00:00Z | jq -r '.[].calendar' | sort -u` includes `Class` and `Work`.
5. **Duplicate titles stay distinguishable.** `bin/pas events ... | jq -r '.[] | select(.calendar=="Family") | .calendarId' | sort -u` shows more than one id if both `Family` calendars have events in the window.
6. **Failure modes are loud.** `bin/pas tasks --list Nonexistent` exits 2 with a message; `bin/pas events not-a-date 2026-09-27T00:00:00Z` exits 2; `bin/pas` with no arguments prints usage and exits 2. In every case stdout stays empty.

`test/smoke.sh` is the runnable check that survives the session: `set -e`, then the jq assertions from steps 1, 4, and 6 (`jq -e` for the truth tests, exit-code checks for the failures). No test framework, no fixtures — it runs against live data because live data is what the gotchas live in.

## Known caveat

TCC grants attach to the responsible process, not to `pas`. Running `bin/pas` from Terminal.app rather than from this Claude Code session will prompt for Reminders and Calendar access again under that app. Expected, one click per app. Worth doing during this phase rather than discovering it in plan 02 when the shell wrapper lands.
