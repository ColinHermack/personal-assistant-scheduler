# Personal Assistant Scheduler

Turns a list of tasks into time blocks on your calendar, and rewrites those blocks as work actually gets done.

The manual version of this workflow has two steps: tasks go in the Reminders list **Tasks** with a time estimate in the notes, then time gets hand-blocked on the Calendar **Time Blocking**. This automates the second step, including the part where you have to redo it every time something slips.

You stay in the loop. Every run shows you a proposal and waits. Nothing touches the calendar until you say yes.

## Install

Requires macOS with Xcode Command Line Tools (for `swiftc`). Install them with `xcode-select --install` if `swiftc -version` fails.

```sh
git clone <this repo's URL>
cd personal-assistant-scheduler
make
```

`make` compiles `src/pas.swift` to `bin/pas`. Swift and EventKit ship with macOS; there is nothing else to install for the binary itself.

The first run from any given app prompts for Reminders and Calendar access. macOS attaches those grants to the app that launched the binary, not to the binary, so Terminal.app and iTerm each ask once. Click through it and it stays quiet after that.

To use the reschedule skill from Claude Code (optional, only needed for the Claude Code workflow below), install the Claude Code CLI per [its docs](https://docs.claude.com/en/docs/claude-code), then run `bin/install-skill`. That symlinks `.claude/skills/reschedule` (checked into this repo) into `~/.claude/skills/reschedule`, so it works from any directory, not just this one, and from the Claude app too. Re-run it after cloning to a new machine.

## Daily use

From a terminal:

```sh
bin/reschedule            # next 7 days
bin/reschedule 3 days     # shorter horizon
```

Or from any Claude Code session, or the Claude app, just ask it to reschedule your tasks (once `bin/install-skill` has been run — see Install above).

Either way you get a table of proposed blocks in local time, a list of anything that would not fit and why, and a list of any rule that had to be bent. Read it. Say yes to apply the whole table, or say what is wrong and get a new proposal. There is no partial apply — changing one row means proposing again, which takes seconds.

## Writing tasks

Tasks live in the Reminders list **Tasks**. Only unchecked ones are read; the list can hold hundreds of finished ones without slowing anything down.

- **Time estimate** goes in the notes, however you like to write it: `2h`, `90 min`, `about an hour`. No estimate means one hour.
- **Due date** is the main thing that orders the queue. Overdue tasks go to the front.
- **Priority** only breaks ties.
- **Progress notes** are optional and free-form. `70% done` or `took 3h not 1h` in the notes will size the next block instead of the original estimate. Most tasks will never have one, and nothing breaks when they do not.

**Checking the box is the only signal the system needs.** Check off a task and its remaining future blocks disappear on the next run, freeing that time for everything else. Blocks that already happened stay put — they are the record of where the time went.

A task still unchecked after its blocked time has passed gets more time rather than being assumed finished.

## Tuning it

`rules.md` is the whole configuration, written in prose. Working hours, block lengths, travel buffers, which calendars count as busy, how much to schedule per day, the daily email block, and what fills the working hours the tasks do not. Edit it in any text editor; there is no schema and nothing to restart.

Expect to edit it a few times in the first couple of weeks. If a proposal is wrong, the fix is almost always a line in `rules.md` rather than a change to any code.

## What it will not do

Three guards live in the compiled binary, not in a prompt, so no amount of bad reasoning upstream can get around them:

1. **It writes only to `Time Blocking`**, checked by calendar identifier. A plan aimed at `Class` or `Work` is refused.
2. **It deletes only blocks it created.** Every generated block carries a `pas-task:` marker in its notes. Anything you blocked by hand on `Time Blocking` is untouchable, even on the same calendar.
3. **It never deletes the past.** A block that has already started cannot be removed.

A plan that trips any guard is refused whole. Nothing partial gets written.

It also never writes to Reminders. The task list is read-only to this tool.

## Under the hood

`bin/pas` is a small Swift binary that does all the EventKit talking and holds no opinions about scheduling:

```sh
bin/pas tasks [--list <name>]        # unchecked reminders as JSON
bin/pas events <startISO> <endISO>   # events across all calendars as JSON
bin/pas apply <plan.json>            # the only write path
```

Dates are ISO 8601 UTC in and out. The scheduling judgment lives in `.claude/skills/reschedule/SKILL.md` and `rules.md`, where you can read and change it.

There is no database. Reminders and Calendar are the state, and the link between a block and its task rides in the event's own notes, so it syncs to every device on its own.

## Tests

```sh
make test
```

Runs against live data, since that is where the edge cases are. It checks the read commands return sane JSON, that bad arguments fail loudly, and that all the guards refuse what they should. Every guard test only ever exercises a refusal, so a passing run means nothing was written.

## Troubleshooting

**It asks for Calendar permission again.** Expected the first time you run it from a new app. Once per app.

**`Time Blocking calendar ... not found`.** The calendar identifier is hardcoded in `src/pas.swift` and is specific to this Mac's iCloud account. On a new machine, rediscover it:

```sh
bin/pas events 2026-01-01T00:00:00Z 2027-01-01T00:00:00Z \
  | jq -r '.[] | select(.calendar=="Time Blocking") | .calendarId' | head -1
```

Put that value in `timeBlockingCalendarId` and `make` again.

**A proposal was refused.** The message names which guard tripped and on which event. That means the proposal was wrong, not the binary. Ask for a new one rather than editing the plan file by hand.

**A block shows up at the wrong hour.** Everything you see should be local time. If something is off by four or five hours, it leaked UTC — worth reporting, since the prompt is supposed to convert once up front.

## Plans

`docs/plans/` holds the design, one file per phase, starting with the feasibility work that picked this stack over AppleScript and a scheduling solver.
