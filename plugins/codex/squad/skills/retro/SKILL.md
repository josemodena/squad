---
name: retro
description: This skill should be used when the user asks to "run the retrospective", "do the retro", "close the sprint", "what did the sprint cost", "estimate versus actual", or invokes $squad:retro. It runs the retrospective conversation with the Decider and writes the one issue that comes out of it.
---

# The retrospective

## Direct meeting entry

When invoked in an Administrator session, run
`bash ${PLUGIN_ROOT}/scripts/meeting.sh start retro`
and let the user converse in the new Zellij tab. Do not relay the discussion or
perform it using the Administrator model. The launcher selects the configured
Project Manager model and effort. If Zellij is unavailable, report its precise
setup error; do not substitute a subagent conversation.

When already in the direct Project Manager meeting (`SQUAD_MEETING_ID` is set),
continue here without launching another session. Checkpoint the conversation
using `meeting.sh checkpoint`, and call `meeting.sh complete` with the durable
outcome only when the user concludes it. Unagreed proposals remain proposals.

Act as the Project Manager using the configured model. Read `squad.sh metrics`: report avoidable idle time, completion-to-dispatch delays, recovery outcomes and reviewed output per allowance. Separate deliberate pauses and unavailable capacity from eligible idle work.

Held near the end of the sprint, before the clock turns over. A conversation
with the Decider, not a form. Its written result is one issue, and every action
in it becomes an issue in the next sprint. Reserve its own cost in the budget;
a retrospective that runs out of allowance does not happen.

## Before the conversation

```bash
bash ${PLUGIN_ROOT}/scripts/codex-quota
bash ${PLUGIN_ROOT}/scripts/squad.sh board --sprint "Sprint N"
bash ${PLUGIN_ROOT}/scripts/housekeeping.sh --dry-run
bash ${PLUGIN_ROOT}/scripts/changelog-review.sh
```

Read the dry run before the live one. Housekeeping keeps anything with a live
branch, a live worktree or a recent write, so a piece in flight is safe, but a
dry run costs nothing and a deletion cannot be undone. Then:

```bash
bash ${PLUGIN_ROOT}/scripts/housekeeping.sh
```

The release review prints nothing when nothing has shipped since the version
recorded. When it does print, a cheap model classifies each entry, the result
goes on the retrospective issue, and only then is the version file moved
forward to the version reviewed; the script's last line gives the command.

Every figure in the retrospective is a number a tool printed, quoted, never
typed from memory.

## The conversation

1. **Credits planned against spent**, for the sprint as a whole. Say plainly
   where the difference came from.
2. **Estimate against actual, per piece**, with the ratio. One calibration
   figure to apply to the next sprint's estimates.
3. **What closed**, with issue numbers.
4. **What slipped and why**, with the honest reason for each. No rounding up.
5. **Rules challenged.** Each rule, a verdict of keep, change or drop, and the
   reason. This is where rules change; a piece never changes a rule on its own.
6. **Housekeeping**, with the figures the script printed.
7. **The harness releases** since the version last reviewed, each classified
   adopt or ignore in one line. A cheap model does the classifying; it is
   reading, not judgement.
8. **Start, stop, continue.** One line each, concrete.

## Writing it up

Create the retrospective issue from the retrospective template, then turn every
action into an issue in the next sprint and list the numbers. An action with no
issue number is an action that will not happen.

```bash
bash ${PLUGIN_ROOT}/scripts/squad.sh issue "Retrospective: Sprint N" \
  --track <track> --owner <owner> --label type:retro --body-file retro.md
```

Close the sprint issue with its outcome filled in and a link to the
retrospective.

## The rules that go with it

- A count in a record is a number a tool computed, quoted, never typed.
- Never re-record a baseline to make a test pass. If the numbers moved, either
  the change was wrong, or it was right and needs a decision.
- A better idea that contradicts an earlier decision goes to the Decider with a
  recommendation, never refused for the contradiction.

Maintain native dependencies, Responsible role, Stage, Agreement, Priority, Needed by, Forecast finish and estimates through `squad.sh field` and `squad.sh dependency`. The Administrator owns execution and continuation.
