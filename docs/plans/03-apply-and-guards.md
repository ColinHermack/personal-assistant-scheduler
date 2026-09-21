# Plan 03 — `pas apply`, the guards, and the marker

## Context

Plans 01 and 02 shipped the read path and the thinking path. `/reschedule` now produces a correct proposal against live data — the first real run caught two rules bugs and, after fixing them, placed three tasks around classes, work shifts and a hand-made interview block. The proposal is then thrown away, because nothing can write.

This plan builds the write path. It is the first phase that changes the calendar, and the only one that ever will, so the guards matter more than the feature. Two of them are the whole point:

- `pas apply` refuses any calendar but `Time Blocking`, checked by identifier.
- `pas apply` refuses to delete any event that does not carry a `pas-task:` marker.

Both live in the compiled binary, not in the prompt that generates the plan. A prompt can be argued out of a rule; a binary cannot. That is why the trust boundary sits here.

The marker also does the second job the architecture named: it is what lets a re-run replace last run's blocks instead of piling duplicates on top of them.

## Scope

- `pas apply <plan.json>` — create and delete events on `Time Blocking`, nothing else.
- The `pas-task:<reminderId>` marker, written into every created event's notes.
- An approval gate in `.claude/commands/reschedule.md`: propose, wait for a yes, then apply.
- Replacement on re-run: future marked blocks are deleted and rebuilt, so running twice is not running double.

Out of scope, and deliberately: reclaiming blocks for tasks that have been checked off, re-blocking tasks that outran their estimate, reading progress notes. That is plan 04. This phase always plans the window from scratch.

**No move operation.** A moved block is a delete plus a create. One less code path in the binary, one less thing to get wrong at the trust boundary, and the visible result is identical. The cost is that the event's identifier changes when it moves; nothing in the design depends on it not changing. `ponytail:` comment in the source naming that ceiling.

**No `--dry-run`.** The proposal table is the dry run, and it is a better one because a human reads it.

## Files

| Path | What |
|---|---|
| `src/pas.swift` | New `apply` subcommand plus the guards. Reuses `fail`, `requestAccess`, `emit`. |
| `.claude/commands/reschedule.md` | Approval gate and plan-building section appended. |
| `test/smoke.sh` | The three refusal tests. |

## `plan.json`

```json
{
  "calendarId": "D113E352-15FF-4ABD-887F-CD3EE650B8A5",
  "delete": ["<eventIdentifier>", "..."],
  "create": [
    { "taskId": "735500D7-...", "title": "Homework 2",
      "start": "2026-09-20T18:00:00Z", "end": "2026-09-20T19:00:00Z" }
  ]
}
```

`calendarId` is **optional and validated**. Absent, the binary uses its own constant. Present and not equal to the constant, the binary refuses the entire plan and writes nothing. Optional keeps a machine-specific UUID out of every generated plan; validated keeps the refusal test real.

Deletes run before creates, so a replace frees its slot before the new block claims it.

Times are ISO 8601 UTC, matching what `pas events` emits. The prompt converts for humans; the binary never does.

`title` is the task title verbatim — `Homework 2`, not `[pas] Homework 2`. The `pas-task:` marker already distinguishes generated blocks, and the calendar should read the way it reads when blocked by hand.

No alerts on created events. A time block is a plan, not a nag.

## The guards

All three are enforced in `src/pas.swift`, and any single violation aborts the whole plan before anything is written. Partial application of a rejected plan would be worse than either outcome.

1. **Calendar.** The target is the `Time Blocking` identifier `D113E352-15FF-4ABD-887F-CD3EE650B8A5`, held as a constant in the source. Every create lands there; every delete must name an event that already lives there. This is the one machine-specific value in the codebase — a comment above it says to rediscover it with `bin/pas events <start> <end> | jq -r '.[] | select(.calendar=="Time Blocking") | .calendarId'`.

2. **Marker.** An event is deletable only if its notes contain `pas-task:`. A hand-created block on `Time Blocking` has no marker and therefore cannot be deleted, no matter what the plan says.

3. **The past is read-only.** An event whose start is already behind `now` cannot be deleted. Past blocks are the record of where the time actually went. `ponytail:` comment on the ceiling: this also refuses a block that started five minutes ago, which is the right default and the wrong answer maybe twice a year.

Refusals go to stderr, exit 2, and name which guard tripped and which event tripped it. Nothing partial, nothing silent.

## The marker

Every created event gets `pas-task:<reminderId>` as its notes, on its own line. `reminderId` is the `calendarItemIdentifier` that `pas tasks` already emits and that plan 01 verified stable across runs.

No sidecar file and no database. The link rides in the same iCloud record as the event, so it syncs to every device and survives everything short of deleting the event.

## Output

JSON on stdout, consistent with the read commands:

```json
{ "created": 3, "deleted": 2, "createdIds": ["..."] }
```

## Approval gate in `.claude/commands/reschedule.md`

Appended after the existing output section. The command keeps everything it does today and gains:

**Build the delete list.** Before proposing, scan the `Time Blocking` events already in the window for `pas-task:` in their notes. Every marked block that starts in the future goes on the delete list — this run supersedes the last one. Unmarked blocks stay untouched and are still treated as immovable commitments, exactly as they are today.

**Show what is being removed.** The proposal grows a short "replacing" line above the table when the delete list is non-empty. A run that silently deletes is a run nobody can audit.

**Ask, then wait.** Print the proposal and stop. Applying without an explicit yes is the one thing this design exists to prevent. Not a yes-or-no toss-off either: the user says yes, or says what is wrong and gets a new proposal.

**All or nothing.** A yes applies the whole table. To change one row, say what is wrong and take a new proposal. No per-row picking — it doubles the states the command can be in for a case that a re-run already handles.

**Then apply.** Write `plan.json` to a temp path, run `bin/pas apply <path>`, and report what came back. If `pas` refuses, show the refusal verbatim. Do not attempt to work around a guard, ever — a tripped guard means the proposal was wrong, not that the binary was.

## Verification

Negative tests first; they are the reason this phase exists.

1. **Wrong calendar is refused.** Hand-write a plan with `calendarId` set to the `Class` identifier. `bin/pas apply` exits 2, names the guard, and Calendar.app shows no change.
2. **Unmarked event cannot be deleted.** Point a delete at `Boom Technologies Interview` (hand-created, on `Time Blocking`, no marker). Refused.
3. **Past blocks cannot be deleted.** Apply one block, wait for it to start, then try to delete it. Refused.
4. **A real apply lands.** Approve one block from `/reschedule`. Confirm in Calendar.app that it is on `Time Blocking` and nowhere else, has the right local time, and carries `pas-task:<id>` in its notes.
5. **Re-running replaces, not duplicates.** Run `/reschedule`, approve. Run it again immediately, approve. The second run's blocks replace the first's. Total block count does not grow. This is the test the marker exists for.
6. **A rejected plan writes nothing.** Build a plan with one valid create and one delete that trips a guard. Confirm the create did not happen — the whole plan aborts or none of it does.

Tests 1, 2 and 6 go into `test/smoke.sh` as inline heredoc plans, checking exit code 2 and empty stdout. They are safe to automate because they only ever test refusals. Tests 3, 4 and 5 are by hand against Calendar.app, because confirming a write landed in the right place is a thing a person has to look at.

## Done when

A `/reschedule` run ends with real blocks on `Time Blocking`, a second run replaces them cleanly, and all three guards have been seen refusing a plan with their own eyes.
