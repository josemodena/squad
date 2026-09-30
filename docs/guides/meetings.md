# Talk directly to the Project Manager

Run `squad start` inside Zellij. Squad opens or focuses your project's main PM
session, using `project_manager_model` and `project_manager_effort` (default
`high`). The same conversation handles planning, retrospectives and delivery.
There is no Administrator relaying your messages and no second PM to brief.

```bash
squad --harness codex start planning
squad --harness codex start retro
squad --harness claude-code start delivery
squad start --dry-run
```

The topic helps initialise a new session. When a PM session already exists,
Squad returns you to it; tell the PM what you want to discuss. A repeated command
does not start another coordinator or change the current conversation's model.
The old `meeting start planning|retro` commands redirect to this entry point.

## Setup

Use an authenticated harness and Zellij with support for an initial command after
`action new-tab --` (tested with 0.44.3). Run inside Zellij or set
`meeting_zellij_session` to an existing session. Squad checks the environment;
it does not assume a session is absent because an agent cannot see a terminal.

For Codex, prepare the managed-session services once:

```bash
squad --harness codex conductor install --no-enable
```

Start the exact `squad-app-server-gateway@INSTANCE.service` printed by the installer
with `systemctl --user start`. This starts its backend too. Then run `squad start`.
The services give interactive and recovery turns one shared owner. The timer
remains optional; enable it only when you want unattended recovery. `--no-enable`
does not disable a previously enabled timer.

Claude Code launches the native CLI directly in its PM tab. Its project-scoped
record captures the session UUID for exact resume. Recovery uses that same
launcher and record. Model access depends on your account; an unavailable model
is an error to resolve, not permission to substitute another one.

## During a conversation

You discuss the work directly with the PM. It delegates bounded technical work to
native subagents, checks their results and handles the next step. It can plan
while execution is paused. Opening a session never resumes a user-paused project
or authorises proposed scope.

The PM records agreed decisions, task checkpoints and owned next actions as work
progresses. Claude's main-session notes use:

```bash
squad meeting checkpoint pm --file /path/to/notes.md
```

Codex uses runtime checkpoints and a durable handover alongside its managed
thread. Ending a planning discussion does not end the PM's ownership of delivery.
A separate reviewer still assesses each design or code change.

## Interrupted sessions

Codex's `squad session inspect` shows the exact managed thread and turn.
`squad start` attaches to it. The gateway prevents overlapping turn starts and
preserves native model, effort and permission policy. An incompatible old session
requires the [migration steps](pm-migration.md); loading a skill cannot switch it.

For Claude, inspect `squad meeting status pm`. If the CLI exits, `squad start`
resumes the captured UUID and saved notes. Without a captured UUID, it starts
from durable notes and does not claim to recover an unrecorded transcript. An
ambiguous launch fails closed. After checking that the old process and tab are
gone, use `squad meeting reconcile pm --reason TEXT`, then `squad start`.

Launch records and notes remain private beneath the project's runtime directory.
A failure never authorises a duplicate worker or deletion of an old worktree.
