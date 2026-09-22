---
name: init
description: This skill should be used when the user asks to "set up Squad", "run squad init", "install the operating model in this repository", "create the labels and board fields", "start a new Squad project", or invokes /squad:init. It writes the project's settings file and creates the labels, the board fields, the milestones, the issue templates and the agent entry point.
---

# Set a repository up to run on Squad

Squad holds nothing about a project in the plugin. One settings file,
`.claude/squad.local.md`, holds the repository, the board, the people, the
models, the clock and the quota shape. This skill writes that file by asking
the questions once, then creates everything on GitHub that the scripts expect.

## Procedure

### 1. Check what is already there

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/init.sh check
```

It prints every label, board field, template and entry point as present or
missing. When there is no settings file it says so and stops. Run it first, so
the questions in step 2 can skip what already has an answer.

### 2. Ask the questions, once

Ask with `AskUserQuestion`, in one pass, and never guess an answer. The
questions, in order:

1. **The repository**, as `owner/name`. Default to the current repository's
   `origin` remote.
2. **The board.** Does a project board exist? If yes, its number. If no, offer
   to create one: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/init.sh create-board "<title>"`
   prints the number. Ask whether the owner is a user or an organisation.
3. **The Decider**: the person who decides scope, money and dates, and who
   agrees every plan. Ask for the name and for the label that marks work only
   they can do (default `action-for-decider`).
4. **The Administrator** coordinates native workers; the Project Manager owns
   planning with the user. Neither writes implementation.
5. **The six role models**: Administrator, Project Manager, Architect, Engineer,
   Architecture Reviewer and Engineering Reviewer.
6. **The tracks**: the few streams of work this project has. They become the
   board's Track options and the `track:*` labels.
7. **The owners**: who can hold a piece. Legacy Owner options are retained; new assignments use Responsible role.
8. **The clock**: the day and the hour in UTC when the week turns over. It
   should match whatever the subscription resets on.
9. **The quota**: the percentage of the weekly limit the project may spend in a
   day, and the cap for the week.
10. **The mirror**, if any: the name of a second git remote that `main` is
    pushed to after every merge. Leave it empty when there is none.
11. **The milestones**, if any, with their dates.
12. **The release review**: two file paths this project will keep, one holding
    the version of the tools the squad runs on that was last reviewed, one
    holding the terms worth reading about in a changelog. Offer
    `.squad/harness-version` and `.squad/harness-watchlist`, create both, and
    seed the watch list with what this project cares about. Leave them empty
    when the project does not want the review.

### 3. Write the settings file

Copy `${CLAUDE_PLUGIN_ROOT}/skills/init/assets/squad.local.md` to
`.claude/squad.local.md` in the project and replace every value with the
answers. Keep the shape: a list stays a list. Put nothing secret in it.

Create the two release-review files named in step 12, if any: put the version
currently installed in one, and one watch-list term per line in the other.

Then confirm it reads back correctly:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/squad.sh settings
```

### 4. Create everything

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/init.sh apply \
  --milestones "First milestone, Second milestone" \
  --milestone-due "First milestone=2026-10-31" \
  --iteration-start 2026-09-19 --iteration-days 7
```

It creates, and skips anything already there:

- the labels: `type:piece`, `type:sprint`, `type:retro`, the decider label,
  `decision-needed`, `blocked`, one `track:*` per track and one `owner:*` per
  owner;
- the board fields: Status with the six columns, Track, Owner, Estimate
  (credits %), Sprint, Iteration with weekly iterations from the start date,
  and Needed by;
- the milestones named on the command line;
- `.github/ISSUE_TEMPLATE/` from the plugin's templates;
- an `AGENTS.md` stub pointing at the Squad guide.

Add `--conductor` to install the session conductor as well.

### 5. Prove it

```bash
gh label list --repo <owner>/<name>
gh project field-list <number> --owner <owner>
bash ${CLAUDE_PLUGIN_ROOT}/scripts/squad.sh board
```

The board prints empty on a new project. That is a pass, not a failure.

### 6. Say what is left to the person

Name the things Squad cannot do for them: agreeing the first sprint goal,
writing the rest of `AGENTS.md`, and adding the settings file to
`.gitignore` if anything in it should stay off the remote.

Configure all six role models and max_workers. Default to native continuation. Run init apply to add Responsible role, Stage, Agreement, Design, Priority, Forecast finish and Estimate (hours). Existing cards need explicit agreement/design classification before eligibility; do not infer approval during migration. Preserve any user pause and legacy hold files. See the runtime command reference shipped with this plugin.

Command syntax and recovery details: [runtime reference](../../docs/runtime.md).

If a required tool or capability is missing, report the exact blocker and remedy.
Use existing installation authority when applicable; do not silently replace the
toolchain during a validation run and report that retry as an initial pass.
Task execution or testing authority alone does not waive quota policy. Honour
an explicit existing waiver; otherwise keep the configured policy.

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
