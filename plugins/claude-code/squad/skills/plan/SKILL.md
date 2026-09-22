---
name: plan
description: This skill should be used when the user asks to "run sprint planning", "plan the sprint", "start a new sprint", "what are we doing this week", "write the sprint issue", or invokes /squad:plan. It runs the planning conversation with the Decider and writes the one issue that comes out of it.
---

# Sprint planning

## Direct meeting entry

When invoked in an Administrator session, run
`bash ${CLAUDE_PLUGIN_ROOT}/scripts/meeting.sh start planning`
and let the user converse in the new Zellij tab. Do not relay the discussion or
perform it using the Administrator model. The launcher selects the configured
Project Manager model and effort. If Zellij is unavailable, report its precise
setup error; do not substitute a subagent conversation.

When already in the direct Project Manager meeting (`SQUAD_MEETING_ID` is set),
continue here without launching another session. Checkpoint the conversation
using `meeting.sh checkpoint`, and call `meeting.sh complete` with the durable
outcome only when the user concludes it. Unagreed proposals remain proposals.

Act as the Project Manager using the configured model.

A sprint is one week and shares its clock with the subscription. It starts and
ends at the hour named in the project's settings. Planning is a conversation
with the Decider, not a form. Its written result is one issue.

## Before the conversation

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/claude-quota
bash ${CLAUDE_PLUGIN_ROOT}/scripts/squad.sh board
```

Read the last retrospective's carried actions and its calibration figure, and
the milestones with their dates. Come to the conversation with a proposal, not
a blank page.

## The conversation

Work through this agenda with the Decider:

1. **The goal.** One sentence: what the sprint is for and how we will know it
   worked.
2. **The milestones against their dates.** Each one, its due date, and one word
   for its state. Say plainly which are at risk.
3. **The pieces.** Pull from the backlog. Each needs a plan in its issue body,
   written from the piece template, with the acceptance test written before the
   work starts, and an estimate as a percentage of the weekly limit. Apply the
   last retrospective's calibration to every estimate.
4. **The budget.** The planned total against the cap, and what is held back as
   reserve. Reserve the retrospective's own cost.
5. **Decisions taken here.** Write each ruling in one line. Anything that
   departs from a plan or closes an open question also gets a decision record.
6. **Actions for the Decider.** Each one an issue with the decider label and a
   needed-by date.
7. **Ways to go faster.** What was considered, and what was adopted or rejected
   and why.

## Writing it up

Create the sprint issue from the sprint template, then put the pieces in it:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/squad.sh issue "Sprint N (DD to DD Mon YYYY)" \
  --track <track> --owner <owner> --label type:sprint --body-file sprint.md
bash ${CLAUDE_PLUGIN_ROOT}/scripts/squad.sh sprint <piece issue> "Sprint N"
bash ${CLAUDE_PLUGIN_ROOT}/scripts/squad.sh move <piece issue> "This sprint"
bash ${CLAUDE_PLUGIN_ROOT}/scripts/squad.sh needed-by <decider issue> YYYY-MM-DD
```

## The rules that go with it

- No build starts on an unagreed plan. Planning is the agreement for the pieces
  it pulls in, when their plans are already written.
- Pulling a piece into a sprint outside planning always goes back to the
  Decider.
- One piece at a time per agent.
- Write to the Decider the way a programme manager writes to a director: what
  happened, what it means, short sentences, one hedge at most on an opinion. A
  decision leads with the consequence a person would notice, then the options
  with their cost and risk, then the recommendation.

Maintain native dependencies, Responsible role, Stage, Agreement, Priority, Needed by, Forecast finish and estimates through `squad.sh field` and `squad.sh dependency`. The Administrator owns execution and continuation.
