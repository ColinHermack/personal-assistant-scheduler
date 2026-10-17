---
name: reschedule
description: Propose time blocks for pending tasks in the personal-assistant-scheduler project (reads rules.md, calls bin/pas), then apply them on approval. Use when the user asks to reschedule their tasks, plan their week, propose time blocks, or invokes /reschedule.
---

Propose time blocks for the pending tasks, then apply them once the user says yes. Never apply without that yes.

## 0. Work from the project root

This skill can be invoked from any directory. `bin/pas` and `rules.md` are only resolvable relative to the project root, so first:

```sh
cd /Users/colinhermack/Projects/personal-assistant-scheduler
```

Run every command in this skill from there.

## 1. Gather

Horizon: read it from the user's request if they gave one (e.g. "3 days"), otherwise 7 days.

Run all three, then interpret:

- `bin/pas tasks` — incomplete reminders. `notes` holds a hand-written time estimate when there is one. `due` may be null. `priority` is 0-9, 0 meaning unset.
- `bin/pas events <now - 14 days> <now + horizon>` — every event in the window, all calendars. Arguments are ISO 8601 UTC, e.g. `2026-09-20T00:00:00Z`. The 14 days of look-back are how this run sees what already happened; without them it would re-block work that is already done.
- Read `rules.md`.

## 2. Convert to local time before you reason

`pas` emits UTC with a `Z` suffix. The user is on America/Indiana/Indianapolis, four or five hours off depending on DST. Every hour in `rules.md` and every hour you print is local.

Convert once, up front. A proposal left in UTC is not obviously broken — it looks plausible and is wrong by a workday. Print nothing in UTC.

Note also that a date-only reminder due date arrives as local midnight, so `2026-09-22T04:00:00Z` means "due the 22nd", not "due at 4 AM".

## 3. Constraints, in this order

1. **Events on busy calendars are immovable.** `rules.md` names which calendars those are. Never propose a block that overlaps one.
2. **The rules in `rules.md`.**
3. **Due dates and estimates.**

When a rule and a due date genuinely conflict, say so in the output. Do not silently pick one.

## 4. Existing `Time Blocking` events

An event on `Time Blocking` whose notes contain `pas-task:` was created by a previous run. An event without that marker was hand-created.

- **Marked, starting in the future** — this run supersedes it. Put its `id` on the delete list.
- **Marked, already started** — leave it alone. Past blocks are the record of where the time actually went, and `pas apply` refuses to delete them anyway. Listing one turns the whole plan into a refusal. They still count, as time spent, in the next section.
- **Unmarked** — a hand-created commitment. Immovable, same as a class. Never on the delete list.

A marked block whose id starts with `routine:` is one of this run's own run, email, gym, physical therapy or course review blocks. It follows the same three rules — future ones are superseded, started ones are left alone. Routine blocks are rebuilt from scratch every run.

## 5. What already happened

For each task from `bin/pas tasks`, find every `Time Blocking` event whose notes carry that task's id as `pas-task:<id>`. The look-back window is what makes them visible.

**Time spent** on a task is the total duration of its blocks that have already started — ended ones in full, and one currently running as well. Assume that time was worked. The checkbox is the only completion signal there is, and a task that is still on the list after its blocks elapsed is not finished.

A task that has been checked off is simply absent from `bin/pas tasks`, so it never enters the queue and its future blocks fall onto the delete list by the rule above. That is the whole reclaim path; a deleted reminder behaves the same way.

Then size what is left to block, in this order:

1. **A progress note wins.** Free-form, no syntax — `70% done`, `took 3h not 1h`, `mostly finished`. Read it and size from it. It overrides both the estimate and the arithmetic below.
2. **Otherwise subtract.** `remaining = estimate - spent`. A 3-hour task with a 2-hour block behind it gets 1 hour, not 3.
3. **When spent has met or passed the estimate and the task is still unchecked**, the estimate was wrong. Apply the re-block rule in `rules.md`.

A task with no history at all is sized from its estimate, exactly as before.

Routine blocks match no task from `bin/pas tasks`, so none of this arithmetic applies to them. They contribute nothing to spent time and never get re-blocked for running long.

## 6. Placement order

The day is filled in this order, and each step only uses what the steps above it left free:

1. **The morning run** — 8 to 9 AM Monday, Wednesday and Friday, when that whole hour is free. The only thing that may start before 8:30.
2. **Email** — 30 minutes, the first free half hour at or after 8:30 AM, Monday through Saturday.
3. **Task blocks** — the existing rules, up to the 6-hour cap. Tasks are the priority; nothing below this line may displace one.
4. **Gym**: one hour Tuesday (upper), Thursday (lower), Saturday (upper) and Sunday (lower). On Sunday this is the only block.
5. **Physical therapy**: 30 minutes on each Monday-to-Saturday day with no run block, inside working hours when room is left there.
6. **Course review**: one hour per course per day at most, rotated so CS355, CS422 and MA425 get equal time, only in time still unblocked inside working hours.

Every block placed here is followed by its break — 5 minutes under an hour, 10 minutes at an hour or more — and the break is busy time for everything after it.

## 7. Output

A table, local times:

| Day | Start | End | Task | Duration | Why this slot |

When a task is sized down because of history, say so in the "why this slot" column — `2h of 3h already done`, or `note says 70% done`.

Routine blocks share the table. Their "why this slot" says which they are — `daily email`, `gym, upper body`, `PT, no run today`, `review, CS422 least reviewed`.

When the delete list is non-empty, a line above the table saying what is being replaced and why. Name the freed time specifically when it came from finished work: `Homework 2 is checked off, freeing 2h on Thursday`. A run that silently deletes is a run nobody can audit.

Then two lists, which matter more than the table:

- **Not scheduled** — every task you could not fit, each with the reason (no room before the due date, over the daily cap, no estimate and none assumable).
- **Rules bent** — anything in `rules.md` you had to work around, and why.
- **No time for**: every routine (gym, physical therapy, course review) that got nothing that day, with the reason (`no free hour`, `no free half hour`). A day where course review got nothing is worth seeing.

A proposal that silently drops a task is worse than one that admits it ran out of room.

## 8. Ask, then wait

Print the proposal and stop. Do not apply anything yet.

The user either says yes, or says what is wrong and gets a new proposal. A yes applies the whole table — all or nothing. To change one row, they say what is wrong and you propose again. Do not offer to apply a subset.

## 9. Apply, once they say yes

Write a plan file to a temp path:

```json
{
  "delete": ["<id from pas events>", "..."],
  "create": [
    { "taskId": "<reminder id from pas tasks>", "title": "<task title, verbatim>",
      "start": "<ISO 8601 UTC>", "end": "<ISO 8601 UTC>" }
  ]
}
```

Routine blocks have no reminder behind them, so they carry a synthetic `taskId` — `routine:email`, `routine:course-review`, `routine:run`, `routine:gym`, `routine:pt` — and a `title` that is the activity name (`Email`, `Review CS355`, `Run and shower`, `Gym: upper body`, `Gym: lower body`, `Physical therapy`). `pas` only requires the id be non-empty, and the `pas-task:` marker it writes is what lets the next run supersede the block.

Times go back to UTC here — the table is for humans, the plan file is for the binary. `title` is the task title exactly as the reminder has it. Omit `calendarId`; `pas` knows where it writes.

Run `bin/pas apply <path>` and report the counts it returns.

**If `pas` refuses, print the refusal verbatim and stop.** A tripped guard means the proposal was wrong, not that the binary was. Never edit a plan to get around a guard, and never retry a refused plan with the guard's complaint engineered away.
