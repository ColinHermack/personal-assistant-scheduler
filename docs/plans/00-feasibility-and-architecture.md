# Personal Assistant Scheduler — Feasibility, Stack, and Architecture

> **Note:** Plan mode restricts edits to this file under `~/.claude/plans/`. Per `CLAUDE.md`, step 0 of implementation is to move this file to `docs/plans/00-feasibility-and-architecture.md` in the project repo and delete the copy here.

## Context

Today the task workflow is fully manual in two steps: tasks go into the Reminders list **Tasks** (with a time estimate written in the notes), and time is then hand-blocked on the Calendar **Time Blocking** calendar. The hand-blocking step is the pure-overhead part, and it has to be redone every time a task slips, grows, or finishes early.

The goal is a system where Claude reads the tasks and the existing calendar, proposes a set of time blocks that respects user-defined rules, and rewrites those blocks as work actually gets done. Realistically that last signal is a checked box and nothing more, so the design treats the checkbox as the input it must work from and any written progress note as a bonus. This plan establishes that the system is buildable, picks the stack, and defines the component boundaries. Per-component implementation details come later in separate plans.

Email-to-calendar ingestion is **deferred** by decision; findings are recorded at the end so the later plan starts from evidence rather than from scratch.

## Feasibility: verified on this machine

Everything below was executed against the live system, not assumed. macOS 26.6.2 (Tahoe), arm64.

**Reminders via AppleScript — NOT viable.**
```
$ osascript -e 'tell application "Reminders" to get name of every list'
36:40: execution error: Reminders got an error: AppleEvent timed out. (-1712)
```
Hung past the 60s Apple Event timeout on a trivial read. This is the long-standing Reminders scripting-bridge problem, not a misconfiguration. AppleScript is off the table for Reminders.

**Reminders via EventKit — viable and fast.** `EKEventStore.requestFullAccessToReminders` granted; 5 lists enumerated in **0.051s**; **512 reminders** fetched from the `Tasks` list in **0.112s**, with `title`, `notes`, `dueDateComponents`, `priority`, `isCompleted`, and a stable `calendarItemIdentifier` all readable. Roughly 1000x faster than the AppleScript path and it does not time out.

**Calendar via EventKit — viable.** `requestFullAccessToEvents` granted; 13 calendars enumerated; 15 events over the next 7 days read in **0.006s**. The target calendar exists and is writable:

- `Time Blocking` — source iCloud, `allowsContentModifications = true`, id `D113E352-15FF-4ABD-887F-CD3EE650B8A5`

Two gotchas found in the real data: calendar **titles are not unique** (two `Family`, two `Birthdays`), so everything must key on `calendarIdentifier`; and all-day events come back spanning `04:00:00Z` to `03:59:59Z` (America/Indiana/Indianapolis), so they need special handling rather than being treated as ordinary busy blocks.

**Compiled Swift binary — viable, no new dependencies.** `swiftc -O` compiles in **2.8s**; the resulting binary runs in **0.43s** and reached EventKit **without re-prompting** for permission. Swift and EventKit ship with macOS. PyObjC was checked and is *not* installed (`ModuleNotFoundError: No module named 'objc'`), so the Python route would mean adding a dependency for no gain.

**Claude Code CLI — present.** `claude` 2.1.278 at `~/.local/bin/claude`, so a terminal command can shell out to it.

**Full Disk Access — absent.** `~/Library/Calendars` and `~/Library/Mail` both return `Operation not permitted`. This only rules out direct-SQLite approaches; EventKit needs no FDA, so it does not affect the design.

## Tech stack

| Layer | Choice | Why |
|---|---|---|
| Data access | **Swift + EventKit**, one compiled CLI binary | Only path that works for Reminders. Zero dependencies, both frameworks ship with macOS. |
| Scheduling intelligence | **Claude at runtime**, reading a plain-text rules file | The rules are fuzzy and will change weekly. A constraint solver would be a large component that still could not read "I don't do deep work after dinner". |
| Rules storage | `rules.md`, plain Markdown | Edited by a human far more often than by code. No schema, no parser, no migration. |
| Invocation | Shell wrapper + Claude Code slash command | Both asked for; they share one command definition. |
| State | **None.** Reminders and Calendar are the database. | A local DB would be a third copy to keep in sync with two systems that already sync themselves. |

Deliberately **not** used: a scheduling/solver library, a task database, a background daemon, a Python environment, any network service.

## Architecture

```
Reminders "Tasks"  ──┐
                     ├──>  pas (Swift/EventKit CLI)  ──JSON──>  Claude Code
Calendar (13 cals) ──┘                ^                            │
                                      │                       rules.md
                                      │                            │
                                      │                    proposed blocks
                                      │                            │
                                      │                     [ you approve ]
                                      │                            │
                                      └────── pas apply <plan.json> ┘
                                                     │
                                                     v
                                          Calendar "Time Blocking"
```

### Component 1: `pas` — the EventKit bridge

A single-file Swift CLI, compiled once to `bin/pas`. It is a dumb data pipe: it does no scheduling, makes no decisions, and holds no opinions. All I/O is JSON on stdout/stdin.

- `pas tasks [--list Tasks]` — incomplete reminders as JSON: `id` (the `calendarItemIdentifier`), `title`, `notes` (verbatim, unparsed), `due`, `priority`, `created`, `modified`. Must filter `isCompleted` — the `Tasks` list holds 512 reminders and the overwhelming majority are done.
- `pas events <startISO> <endISO>` — events across all calendars as JSON: `id`, `calendar`, `calendarId`, `title`, `start`, `end`, `isAllDay`, `notes`. This is how Claude sees what time is already taken.
- `pas apply <plan.json>` — the only write path. Creates, moves, and deletes events. **Hard-refuses any calendar other than `Time Blocking` by identifier**, and refuses to delete any event lacking the `pas-task:` marker described below. Those two guards are what keep a bad proposal from touching Class, Work, or Family.

`pas` is the single trust boundary in the system, so its input validation is not a corner to cut: the calendar-identifier check and the marker check are enforced in the binary, not in the prompt that generates the plan.

### Component 2: Linking blocks back to tasks

Each event `pas apply` creates carries `pas-task:<reminderIdentifier>` in its notes. This one marker buys three things: re-planning can find and replace the blocks it created before instead of piling up duplicates; `pas apply` can distinguish its own events from ones hand-created on the same calendar; and progress notes on a reminder can be matched to the time already blocked for it.

No sidecar file, no database. The link lives in the same iCloud record as the event, so it survives sync and is visible on every device.

### Component 3: `rules.md`

The scheduling constraints in prose — working hours, minimum and maximum block lengths, buffers around classes, which days are off, how to treat an overdue task, whether to split a long task across days. Claude reads this file on every run.

The initial contents are a conversation during implementation, not a guess made now.

### Component 4: Invocation

The terminal command asked about is feasible. `bin/reschedule` is a short shell script that `cd`s to the project and execs `claude "<reschedule prompt>"` as an **interactive** session — not `claude -p`. This matters: the chosen autonomy model is propose-then-approve, and a headless `-p` run has nobody to approve to. The interactive session shows the proposal, waits, and applies on a yes.

`.claude/commands/reschedule.md` holds the actual instructions; the shell script is a two-line wrapper that invokes it. One definition, two entry points.

### Component 5: The feedback loop

**The primary completion signal is the checkbox, not the notes.** In practice a finished task gets checked off and nothing is typed. The design must not depend on a progress note ever being written; a written note is a bonus, not an input the system requires.

That makes the checkbox the main thing the loop watches, and it is detectable without ever querying completed reminders. `pas tasks` returns only incomplete tasks. Any future block on `Time Blocking` whose `pas-task:` marker points at an id **not** in that set belongs to a task that is finished or deleted, so its remaining future blocks are dropped and the time is freed for everything else. Past blocks are never touched — they are the record of where the time actually went.

The secondary signal, also note-free: a task that is **still incomplete after its blocked time has passed** needs more time. Default behavior is to re-block the shortfall rather than assume the original estimate held.

Progress notes, when they do happen to exist, are read as an override on both of the above — "60% done", "took 3h not 1h" — and let Claude size the next block precisely instead of falling back to the estimate. Free-form; no required syntax. Nothing breaks when they are absent, which will be most of the time.

**Reminders stay read-only.** EventKit can write reminder notes, but nothing in the workflow requires it, and keeping the write surface to one calendar means a wrong proposal can never damage the task list itself.

## Implementation phases

Each phase ships something usable and gets its own detailed plan.

1. **`pas` read commands** — `tasks` and `events`, plus the build step. Verifiable on its own, no writes anywhere.
2. **Propose-only loop** — `rules.md`, the slash command, and the reschedule prompt. Claude outputs a proposed schedule as a readable table. Still nothing written to Calendar. This is where the rules get tuned against real weeks.
3. **`pas apply` and the approval gate** — the write path with both guards, plus the `pas-task:` marker. First phase that changes the calendar.
4. **`bin/reschedule`** — the terminal entry point.
5. **Feedback loop** — reclaiming blocks from checked-off tasks, re-blocking tasks that outran their time, and treating progress notes as an optional refinement. Adjusts existing blocks rather than always planning from empty.
6. **Deferred: email ingestion.**

## Verification

Per phase, run against the live system:

1. `bin/pas tasks | jq 'length'` returns a count far below 512 (completed ones filtered), and `jq '.[0]'` shows a real task with its notes intact. `bin/pas events 2026-09-20T00:00:00Z 2026-09-27T00:00:00Z | jq '.[].calendar'` includes `Class` and `Work`.
2. Run `/reschedule` on a real week and read the proposal. Check by hand that it never overlaps an existing `Class` or `Work` event and that it obeys each rule in `rules.md`. Iterate on the rules file until it does.
3. Apply one block. Confirm in Calendar.app that it landed on `Time Blocking` and nowhere else. Then run the two negative tests that matter: hand-edit a plan JSON to target the `Class` calendar and confirm `pas apply` refuses; point a delete at a hand-created event with no `pas-task:` marker and confirm it refuses. Re-run `/reschedule` twice in a row and confirm the second run replaces the first run's blocks rather than duplicating them.
4. `reschedule` from a fresh Terminal window opens the interactive session in the project.
5. The checkbox path first, since it is the one that will actually get used: check off a task that still has future blocks, re-run, and confirm those future blocks disappear while any past block for it stays put. Then let a blocked task's time pass without checking it off, re-run, and confirm it gets re-blocked instead of being dropped. Only then test the optional path: add a progress note like "70% done", re-run, and confirm the remaining time is sized from the note rather than the original estimate.

One caveat that will surface at step 4: **TCC permissions attach to the responsible process, not to `pas`.** The grants obtained during this planning session belong to the Claude Code process. Running `reschedule` from Terminal.app or iTerm will prompt again for Reminders and Calendar under that app. This is expected, is a one-time click per app, and is worth confirming early rather than discovering mid-demo.

## Deferred: email ingestion

Recorded so the later plan does not re-derive it.

- The Gmail account is already connected in this session via MCP, with structured search and message reads. No TCC, no Full Disk Access, no AppleScript. This is by far the cheapest path and covers Gmail-backed accounts.
- Apple Mail's scripting dictionary does expose `account`, `imap account`, `pop account`, `mailbox`, and `message`, so multi-account access is genuinely supported. But given that Reminders' bridge times out on a one-line read, Mail's should be expected to be slow too, and it requires Mail.app running.
- Direct `~/Library/Mail` SQLite reads are currently blocked (`Operation not permitted`) and would need Full Disk Access plus an undocumented schema that Apple changes between releases. Not recommended.

The open question for that plan is which accounts in Mail are Gmail-backed. If they all are, the MCP path covers everything and Apple Mail never needs to be touched.
