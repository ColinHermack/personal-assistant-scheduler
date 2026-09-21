# 05 — Routine and filler blocks

## Context

Today the tool blocks nothing but tasks. A day with two hours of tasks leaves eight hours of working time untouched, and email never gets a slot at all. Four things want that leftover time, in a fixed order of preference, and one of them (jiu-jitsu) is at a fixed hour and leaves the user unavailable for an hour afterward.

Wanted:

- Every scheduled day carries a 30-minute email block.
- Tasks stay the main priority. Time still unblocked inside working hours goes, in order, to: interview prep, course review (CS355 / CS422 / MA425), job applications, Purdue Jiu-Jitsu (Mon/Wed 5-6 PM, Fri 5-7 PM, plus an unblocked hour after for showering). Max 1 hour per activity per day.

Decisions taken with the user:

- The 6-hour daily cap stays a **task-only** cap. Email and filler blocks sit outside it.
- Email goes in the **first free 30 minutes at or after 8 AM**, before tasks are placed.
- Jiu-jitsu is a **filler activity at 4th priority**, not a standing commitment. Friday gets the full 5-7 PM; the 1-hour cap does not shorten a fixed practice.
- Monday through Saturday only. Sunday stays off.

Outcome: a proposal that fills the working day rather than just the task list, with the leftover time spent on the user's stated priorities in their stated order.

## No code changes

`src/pas.swift` does no scheduling (README.md:65). The scheduler is prose in two files, both read fresh every run:

- `rules.md` — the preferences
- `.claude/commands/reschedule.md` — the procedure

The binary is untouched, so `make` and the guards are untouched.

### The one mechanical fact that makes this work

`pas apply` requires only that `create[].taskId` be **non-empty** (`src/pas.swift:250`); it writes `"pas-task:" + taskId` into the event notes (`src/pas.swift:272`). So a routine block can use a synthetic id — `routine:email`, `routine:jiujitsu` — and still:

- carry a `pas-task:` marker, so a future one is deletable by the next run (guard 2, `src/pas.swift:238-240`)
- never collide with a real reminder id from `bin/pas tasks`

No new field, no schema change, no new Swift.

## Changes to `rules.md`

Three new sections, in the file's existing prose voice. Amend the existing cap line in `rules.md:57` to say the 6 hours counts **task blocks only**, and that email and filler blocks are outside it.

### Email

A 30-minute block every scheduled day, Monday through Saturday. Titled `Email`. It goes in the first free half hour at or after 8 AM, placed before any task block and outside the daily cap. It slides later when a class, shift or buffer sits there. It is the one routine block that is not optional — when a day has no free half hour inside working hours at all, say so under "Rules bent".

### Filling the rest of the day

Tasks come first. When every schedulable task is placed and working hours (8 AM to 6 PM, Monday through Saturday) still hold unblocked time, fill it with these, in order, at most one hour of each per day:

1. Interview preparation
2. Reviewing course material for CS355, CS422 or MA425 — one course per block, named in the title (`Review CS355`); pick the course with the nearest due date or exam, otherwise rotate across days
3. Applying for jobs
4. Purdue Jiu-Jitsu practice

Same block rules as tasks: 30 minutes minimum, all buffers apply, never over a busy calendar. A gap shorter than 30 minutes stays empty. These never displace a task block, never push a task past its due date, and never count against the 6-hour cap.

### Jiu-jitsu

Practice is at a fixed hour: Monday and Wednesday 5-6 PM, Friday 5-7 PM. It gets blocked only when the whole practice window is free and the hour after it is free too — that hour is showering and stays unblocked, 6-7 PM Monday and Wednesday, 7-8 PM Friday. Nothing goes in it, tasks included, and that holds even though it is outside working hours.

Friday's block is two hours because that is the practice; the one-hour-per-activity cap does not shorten it. Friday practice also runs past the 6 PM preference, which is fine — it is well inside the 11 PM hard bound.

When 5 PM is busy, there is no practice that day. Nothing gets moved to make room for it.

## Changes to `.claude/commands/reschedule.md`

- **Section 4 (existing `Time Blocking` events)**: a marked block whose id is `routine:*` behaves like any other marked block — future ones go on the delete list, started ones are left alone. Routine blocks are rebuilt from scratch every run.
- **Section 5 (what already happened)**: routine blocks match no task from `bin/pas tasks`, so they contribute nothing to spent time and never re-block. Say this explicitly so the arithmetic is not attempted on them.
- **New step, between the current 5 and 6 — placement order**, since the ladder is an ordering rule and the current file has no notion of one:
  1. Email, first free 30 minutes at or after 8 AM.
  2. Task blocks, by the existing rules, up to the 6-hour cap.
  3. Reserve the shower hour if jiu-jitsu will be blocked.
  4. Filler, down the ladder, max one hour per activity, only in what is still free inside working hours.
- **Section 6 (output)**: routine blocks appear in the same table. The "Why this slot" column says which they are — `daily email`, `filler, 1st priority`, `Fri practice`. Under the table, a line naming any ladder activity that got no time and why (`no free hour`, `5 PM busy`). A day where filler got nothing is worth seeing.
- **Section 8 (apply)**: routine blocks use `taskId` values of `routine:email`, `routine:interview-prep`, `routine:course-review`, `routine:job-apps`, `routine:jiujitsu`, and a `title` that is the activity name, since there is no reminder title to copy verbatim.

## Files

- `rules.md` — three new sections, one amended line (the cap at :57)
- `.claude/commands/reschedule.md` — edits to sections 4, 5, 6, 8 and one new placement-order step

## Verification

1. `make test` — should pass unchanged. Nothing in the binary moved; this proves it.
2. `bin/reschedule 7 days` and read the proposal without applying:
   - every Monday-Saturday in the horizon has exactly one 30-minute `Email` block, the first free half hour at or after 8 AM
   - task blocks still respect the 6-hour cap, and filler blocks are not counted into it
   - filler appears only after tasks, in ladder order, at most one hour per activity per day
   - no filler on Sunday
   - on a Monday or Wednesday where 5-6 PM is free: a jiu-jitsu block, and 6-7 PM empty. Friday: 5-7 PM blocked, 7-8 PM empty
   - on a day where 5 PM is busy: no jiu-jitsu, and nothing else moved to make room
3. Say yes on one run. Confirm `pas apply` accepts the synthetic `routine:*` ids and reports the right counts — this is the only unproven mechanical claim in the plan.
4. Run `bin/reschedule` again immediately. The routine blocks from the previous run should land on the delete list and come back, not double up.
