# Plan 04 — The feedback loop

## Context

Plans 01 through 03 built a system that plans a week and writes it to the calendar. Every run plans that week from scratch. Nothing looks backward, so nothing knows that Tuesday's two hours already happened, or that the task they were for is still sitting unchecked.

The architecture named the signal this phase has to work from, and it is a thin one: **a finished task gets a checkbox and nothing else.** No note gets typed. The loop is built around that and treats a written note as a bonus.

Two behaviors come out of it:

- A task that is checked off frees its remaining future blocks, and that time goes to everything else.
- A task that is still unchecked after its blocked time has passed gets more time, rather than being assumed done.

**No Swift changes.** The `pas-task:` marker, the three guards, and a window argument that already accepts any two dates cover all of it. That is the payoff of the marker design, and it is worth saying out loud: this phase is prose.

## Scope

- Look backward 14 days as well as forward, so a run can see what already happened.
- Count time already spent per task from its past marked blocks.
- Size the next block from what is left, not from the original estimate.
- Read progress notes as an override on that arithmetic, when they happen to exist.

Out of scope: writing anything to Reminders. EventKit could set a reminder's notes, but nothing in the workflow needs it, and keeping the write surface to one calendar means a wrong proposal can never damage the task list. Reminders stay read-only.

## What is actually new

Reclaiming a completed task's blocks needs almost no new logic, and the plan should not pretend otherwise. `pas tasks` returns only incomplete reminders, so a checked-off task simply stops appearing. The command already deletes every future marked block and rebuilds the window, so a vanished task's blocks are deleted and never recreated. Reclamation falls out of what plan 03 already does.

What genuinely changes is the arithmetic:

1. **Time already spent.** For each pending task, sum the durations of its marked blocks that have already ended. That is time the user is assumed to have worked.
2. **Remaining work.** `remaining = estimate - spent`. Block that, not the full estimate. A 3-hour task with 2 hours behind it gets 1 hour, not 3.
3. **Shortfall.** When `spent >= estimate` and the task is still unchecked, the estimate was wrong. Give it more time.
4. **Notes override all three.** A note saying `70% done` or `took 3h not 1h` beats the arithmetic every time.

## Re-block sizing

The rule, to go in `rules.md`:

> A task whose blocked time has passed and is still unchecked needs more time. When its notes say how far along it is, size the next block from that. Otherwise repeat the length of the block it just used up.

So a 1-hour block that did not finish the job buys another hour. A note reading `about half done` on a 2-hour task buys an hour instead of another two.

**No slippage warnings.** A task that outruns its estimate three times in a row gets re-blocked three times, quietly. The table already shows the blocks; a nag on top of that is noise. If this turns out to hide a genuinely bad estimate, that is a rules edit later, not a feature now.

## Look-back window

14 days back, alongside the existing 7-day forward horizon. One call: `bin/pas events <now - 14d> <now + horizon>`.

Two weeks catches a task that stalled a while ago and is still on the list, without reading a year of calendar on every run. The forward horizon stays user-overridable; the look-back is fixed in the command, because it is machinery rather than preference.

## Files

| Path | What |
|---|---|
| `.claude/commands/reschedule.md` | Gather window, the spent-time arithmetic, and the note override. |
| `rules.md` | The re-block sizing rule, and a line on how progress notes are read. |

### `.claude/commands/reschedule.md`

**Section 1, gather.** The events call starts 14 days before now instead of at now.

**New section, before the proposal.** For each task from `pas tasks`, find every `Time Blocking` event whose notes carry that task's `pas-task:` id. Split them at now:

- **Ended** — count toward time spent.
- **In progress** — count toward time spent, and never put one on the delete list. `pas apply` refuses to delete anything already started, so listing one turns the whole plan into a refusal.
- **Future** — supersede them, exactly as today.

Then size the remaining work: notes first, `estimate - spent` second, and when spent has already met or passed the estimate, the re-block rule from `rules.md`.

**Section 5, output.** Two additions. A task getting less than its full estimate says why in the "why this slot" column — `2h of 3h already done`. And when checked-off tasks freed time, one line above the table saying how much and from what, because a run that silently deletes is a run nobody can audit. That line is already required when the delete list is non-empty; this makes the reason specific.

### `rules.md`

A short section, in the same prose style as the rest:

- The re-block sizing rule quoted above.
- How progress notes are read: free-form, no syntax, anything that says how far along the work is or how long it actually took. They override the estimate and the arithmetic. Most tasks will never have one, and nothing breaks when they do not.

## Verification

All of these run against live data, because the signals only exist there. None of them automate into `test/smoke.sh` — the guard tests there stay what they are, since these scenarios need a real checkbox getting checked.

1. **The checkbox path, first, because it is the one that gets used.** Take a task with future blocks. Check it off in Reminders. Re-run. Its future blocks are gone, the freed time is visibly reused by other work, and any past block for it is still on the calendar.
2. **Past blocks survive.** Same run: confirm in Calendar.app that the finished task's already-elapsed blocks were not touched. They are the record of where the time went.
3. **A deleted task behaves like a finished one.** Delete a reminder outright rather than checking it. Its future blocks go the same way.
4. **Shortfall gets re-blocked.** Let a blocked task's time pass without checking it off. Re-run. It gets another block the same length as the one it used up, and it is not dropped.
5. **Partial credit.** A 3-hour task with one 2-hour block behind it gets a 1-hour block next, not a 3-hour one.
6. **The note overrides.** Put `70% done` in the notes of a task with 2 hours of history and a 4-hour estimate. Confirm the next block is sized from the note rather than from `4h - 2h`.
7. **An in-progress block does not break the run.** Re-run while a block is currently running. The plan must not list it for deletion, and `pas apply` must not refuse.
8. **Still idempotent.** Two runs back to back still do not duplicate blocks.

## Done when

A week runs without the user thinking about it: tasks get checked off, the calendar reflows on the next run, and nothing has to be hand-blocked or hand-deleted.
