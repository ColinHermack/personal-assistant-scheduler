# Plan 02 — Propose-only loop

## Context

Plan 01 shipped `bin/pas`, which turns Reminders and Calendar into JSON. Verified on live data: 3 incomplete tasks out of 512, and a week of events across `Class`, `Work`, `Time Blocking` and four other calendars.

Nothing yet reads that JSON. This plan builds the half that thinks: the rules file, the prompt that applies it, and the two entry points that start a run. It stops one step short of the calendar. Claude proposes a schedule as a readable table and the run ends there — no writes, because `pas apply` does not exist until plan 03.

That gap is the point. This is the phase where the rules get tuned against real weeks, and rules are wrong for the first several tries. Tuning them while the system physically cannot touch the calendar is much cheaper than tuning them after.

Entry points ride along here rather than getting their own plan: `bin/reschedule` is a three-line wrapper that cannot be tested until the slash command it invokes exists.

## Scope

- `rules.md` — scheduling constraints in prose, at the project root.
- `.claude/commands/reschedule.md` — the instructions, invoked as `/reschedule`.
- `bin/reschedule` — shell wrapper that opens an interactive Claude session on the same command.

Out of scope: any write path, the `pas-task:` marker, reclaiming blocks from finished tasks. The proposal this phase produces is read by a human and then thrown away.

## Files

| Path | What |
|---|---|
| `rules.md` | Human-edited constraints. No schema, no parser. |
| `.claude/commands/reschedule.md` | The one definition both entry points share. |
| `bin/reschedule` | Wrapper. |

## `rules.md`

Contents are a conversation at implementation time, not a guess made now. Step one of this plan is to ask, and the questions below are the checklist. Each answer becomes a line or a short paragraph of prose — no YAML, no key-value pairs. Claude reads it the way a person would.

What to ask:

1. **Working hours** — earliest start and latest end, and whether weekends differ.
2. **Block length** — minimum worth scheduling, maximum before a break is needed.
3. **Buffers** — minutes to leave around classes and around work shifts. Travel time is the real reason this exists.
4. **Days off** — any day or recurring window that never gets blocked.
5. **Which calendars count as busy.** Live data has seven. `Class` and `Work` are obviously busy; `US Holidays` and `Birthdays` are obviously not. `Home`, `Family` and `Fellowship Calendar` are the judgment calls.
6. **All-day events.** They arrive spanning `04:00:00Z` to `03:59:59Z` local. Treated as busy they blank the entire day, which is wrong for `Yom Kippur` and possibly right for a travel day. Default to not busy and let the exceptions be named.
7. **Time estimates.** The notes field holds one, written by hand, in no fixed format (`2h`, `90 min`, `about an hour`). What is the default when a task has no estimate at all, and is there a ceiling above which a task must be split across days?
8. **Overdue tasks** — a task past its due date: front of the queue, or ordinary priority?
9. **Splitting** — may a single task's time be broken across non-adjacent blocks, and what is the smallest useful piece?
10. **Priority** — EventKit's 0-9 integer ships raw, 0 meaning unset. Does it order the queue, or is the due date the real signal?

Write the answers as prose, keep it short, and expect to edit it several times in the first week. That editing is the deliverable of this phase.

## `.claude/commands/reschedule.md`

The command is a prompt, so it is written as instructions to Claude, not as pseudocode. What it must contain:

**Gather.** Run `bin/pas tasks`. Run `bin/pas events <now> <now + horizon>`. Horizon defaults to 7 days and is overridable by the command's argument (`/reschedule 3 days`). Read `rules.md`. Three reads, no interpretation yet.

**Convert to local time.** `pas` emits UTC with a `Z` suffix. Every hour in the proposal, and every rule in `rules.md`, is in the user's local timezone. A proposal presented in UTC is not merely confusing, it is off by four or five hours and will look plausible. Convert once, up front, and present nothing in UTC.

**Treat these as constraints, in this order.** Existing events on busy calendars are immovable. Rules in `rules.md` are next. Task due dates and estimates come last. When a rule and a due date conflict, say so in the output rather than silently picking one.

**Existing `Time Blocking` events.** This phase has no marker to tell hand-created blocks from generated ones, so treat every existing block on that calendar as a hand-created commitment and schedule around it. Plan 03 introduces the marker and plan 04 changes this rule. Note the assumption in the output so a stale block does not quietly eat a week.

**Output a table.** Day, start and end in local time, task title, duration, and one short line of why that slot. Under it, two lists that matter more than the table: tasks that could not be fit and the reason, and any rule that had to be bent. A proposal that silently drops a task is worse than one that admits it ran out of room.

**Stop.** Print the proposal and end the turn. Do not write to any calendar. Do not offer to. There is no apply path yet, and the prompt should say so plainly so that a future edit does not quietly grow one.

## `bin/reschedule`

```sh
#!/bin/sh
cd "$(dirname "$0")/.." || exit 1
exec claude "/reschedule $*"
```

Interactive, not `claude -p`. The autonomy model is propose-then-approve and a headless run has nobody to approve to. Plan 03 is where that matters; the wrapper is built right from the start so it does not need revisiting.

## Verification

1. **The command runs end to end.** `/reschedule` in this project produces a table. No errors from `bin/pas`, no UTC timestamps anywhere in the output.
2. **It respects the immovable.** Cross-check every proposed block by hand against `bin/pas events` for the same window. Zero overlap with any `Class` or `Work` event. This is the check that matters; do it manually the first several runs rather than trusting the table.
3. **It respects the rules.** Read `rules.md` line by line against the proposal. Every violation is either a rules bug or a prompt bug — fix the file, re-run, repeat. Expect several rounds.
4. **It admits failure.** Temporarily add a task with an absurd estimate (40h due tomorrow). Confirm it lands in the could-not-fit list with a reason, rather than being dropped or crammed in.
5. **The wrapper works from a cold terminal.** `bin/reschedule` from a fresh Terminal.app window opens an interactive session in the project. Expect a one-time TCC prompt for Reminders and Calendar under Terminal, because grants attach to the responsible process and the ones from this session belong to Claude Code. Click through it once and confirm the second run is silent.
6. **The horizon argument works.** `bin/reschedule 3 days` proposes over three days, not seven.

## Done when

A run on a real week produces a proposal the user would have accepted by hand, and `rules.md` has stopped changing between runs.
