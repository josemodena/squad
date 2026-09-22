---
name: board
description: This skill should be used when the user asks to "show the board", "what is on the board", "what is in this sprint", "move this to in progress", "put this piece in the sprint", "what is blocked", "create an issue on the board", or invokes $squad:board. It reads and changes the project board through the Squad tracker.
---

# The board is the state

Progress lives in issues and on the project board, never in a file. Every piece
of work is an issue whose body is its plan. A session that moves a piece and
does not move its card has not finished.

All of it goes through one script, which reads the project's settings for the
repository, the board, the tracks, the owners and the statuses:

```bash
bash ${PLUGIN_ROOT}/scripts/squad.sh <command>
```

## Reading it

```bash
squad.sh board                      # every column, every card
squad.sh board --sprint "Sprint 3"  # one sprint only
squad.sh settings                   # the tracks, owners and statuses this project uses
```

An empty board prints "The board is empty." That is a real answer, not an error.

## Changing it

```bash
squad.sh issue "<title>" --track <track> --owner <owner> --estimate 4 --body-file plan.md
squad.sh move <issue> "In progress"
squad.sh sprint <issue> "Sprint 3"
squad.sh needed-by <issue> 2026-10-31
```

`issue` creates the issue with its `track:*` and `owner:*` labels, puts it on
the board and sets Track, Owner, Status and the estimate. The track and the
owner must be ones this project has; `squad.sh settings` lists them.

## The rules that go with it

- Write the plan in the issue body from the piece template, with the acceptance
  test written before the work starts. A deliverable that cannot be tested is an
  intention.
- Scope found in the middle of a piece becomes a new issue in Backlog. It is
  never absorbed into the piece in hand.
- A blocker is the `blocked` label plus a comment naming what is needed, from
  whom and by when. It is a precise ask, never "not ours".
- Something only the Decider can do carries the decider label, sits in "This
  sprint", and has a Needed by date set with `squad.sh needed-by`.
- Quota readings are comments on the sprint issue, never commits.

Use `squad.sh ready` for eligibility with exclusion reasons, `field ISSUE NAME VALUE` for typed metadata, and `dependency list|add|remove ISSUE [PREREQUISITE]` for native prerequisites. Responsible role is distinct from GitHub account Assignees. Needed by and Forecast finish have different meanings.
