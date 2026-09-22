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
- A blocker is a structured record written with `blocker.sh set ISSUE --file JSON`:
  category, owner, exact next action, why, PM recommendation, evidence and whether
  the user is needed. It is visible in the issue and through board labels.
- User-owned actions have an orange `🟠 needs-your-action` label and the configured
  decider label. Use `blocker.sh visibility` to show Labels in existing views.
  Preserve explicit Status on existing cards. Separately agreed user-action cards
  may use the existing Blocked column; do not create another column.
- Resolve only using actual input/authority evidence through `blocker.sh resolve`;
  never infer permission from quota policy or infer completion from issue closure.
- Quota readings are comments on the sprint issue, never commits.

Use `squad.sh ready` for eligibility with exclusion reasons, `field ISSUE NAME VALUE` for typed metadata, and `dependency list|add|remove ISSUE [PREREQUISITE]` for native prerequisites. Responsible role is distinct from GitHub account Assignees. Needed by and Forecast finish have different meanings.

Before board migration or recovery, use `board-backup.sh snapshot` and retain the
printed path. Option IDs carry item identity: never rebuild an existing option
list from names. Use the provided helpers, which preserve IDs and back up writes.
For recovery, run `board-backup.sh restore FILE --dry-run`, present the complete
plan and blockers, and obtain explicit confirmation of that plan before applying
with `--apply --confirm PROJECT_NODE_ID --plan CONFIRMATION_HASH` from the preview. Existing explicit approval of that exact
repair suffices. Never infer missing historical statuses from issue closure.
GitHub restore is not atomic; inspect the journal after failure and reconcile a
fresh dry-run rather than replaying the whole operation. Backups are private local
Git repositories scoped by host/owner/project number, retained until explicit cleanup.
