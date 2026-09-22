# Your first delivery cycle

Use a small repository and one low-risk issue for the first run. An interactive
session is enough; enable unattended recovery only after this cycle works.

## 1. Install and check the tools

Follow [installation](installation.md), then:

```bash
squad --harness codex doctor         # use claude-code for that harness
gh auth login                       # if not already authenticated
gh auth refresh -s project
cd /path/to/your/repository
```

`doctor` prints `OK`, `FAIL` and `NEXT` checks. It is normal for project settings to
be absent before setup. Resolve missing tools and authentication failures first.
It cannot verify model availability or native notification delivery for you.

## 2. Configure the project

Start your harness in the project directory and invoke its init skill:

| Codex | Claude Code |
| --- | --- |
| `$squad:init` | `/squad:init` |

You can add this request:

> Set up Squad for this repository. Start with one worker and interactive
> coordination. Ask me about the GitHub Project, models, storage and quota policy.
> Do not install unattended recovery yet.

Agree the repository, existing/new board, human decision-maker, work categories,
model assignments and subscription policy. Choose a project-specific durable
`scratch_root`. Settings go in `.codex/squad.local.md` or `.claude/squad.local.md`.
Ensure local configuration is ignored by Git. Setup provisions labels, fields and
issue templates and creates or augments the harness entry point.

Confirm the setup from the terminal:

```bash
squad models
squad board
squad init check
```

An empty board is expected. If both harnesses are configured, use
`squad --harness codex ...` or `squad --harness claude-code ...` explicitly.

Before creating worktrees, inspect `git status` and the generated entry point,
issue templates and ignore rules. Commit the intended shared setup through your
repository's normal review process. Keep local settings and runtime data ignored.
A new worktree sees committed files, not uncommitted setup in the original checkout.
Do not start the first delivery cycle from a dirty setup tree.

## 3. Establish a real capacity reading

```bash
squad quota --json
```

Codex refreshes capacity from its App Server interface. Claude needs an external
collector; use the [documented reading contract](../reference/configuration.md#claude-usage-data)
and verify that it is refreshing before starting delivery. Squad does not bundle
a Claude collector or silently assume unlimited capacity.

Expected verdicts are `run`, `suspend`, `stale`, or `missing`. A `run` verdict
permits consideration of work; it does not override agreement, dependency or
pause checks. Fix missing/stale readings. Change voluntary policy only when that
is your actual decision; do not fabricate quota readings to get past this step.

## 4. Agree one small task

Invoke `$squad:project-manager` or `/squad:project-manager`:

> Plan one small improvement with me. Write clear acceptance criteria, record
> prerequisites, propose the responsible role and review path, and estimate the
> remaining delivery effort. Wait for my agreement on scope before execution.

The Project Manager records an issue and its fields. For engineering eligibility,
`Agreement` must be `Agreed`, `Design` must be `Approved` or `Existing`, and Stage
and Responsible role must match. Dependencies must be closed, an estimate present,
and the item in an active sprint/status. New architecture goes through design
and independent architecture review first. See [runtime eligibility](../reference/runtime.md).

```bash
squad ready
```

Look for the agreed item and its eligibility reasons. Do not start an agent to
work around an excluded item; resolve its recorded blocker.

## 5. Start the Administrator

Use the configured Administrator model for the main session. For the shipped
defaults, start `codex --model gpt-6-luna` or `claude --model sonnet`, if available
to your account, and invoke `$squad:administrator` or `/squad:administrator`.

> Execute the agreed eligible issue using Squad. Use the configured roles and
> models, save checkpoints, obtain independent review, and keep the board current.

The Administrator claims a job before spawning a worker, binds its native
identity, processes results, and advances to review. You should see distinct
worker identities for author and reviewer. It merges through the guarded command
only after a passing review of the exact commit.

A skill does not change the main session's model automatically. If your harness
cannot select the configured worker model, resolve that before dispatch; do not
silently substitute and record the wrong model.

## 6. Inspect, pause and continue

```bash
squad board
squad status
squad metrics
squad pause --reason "User is reviewing the first delivery cycle"
```

Pause prevents new claims and recovery launches; it does not forcibly interrupt
already-running workers. Tell the active Administrator to checkpoint and stop
its workers at safe boundaries when you need execution to stop now.

After your explicit decision to continue:

```bash
squad resume --reason "User approved continuing after inspection"
```

Inspect any legacy conductor hold separately: `resume` does not delete it. A new
session should run recovery and reconcile live workers before replacing an
interrupted assignment. Do not discard an old worktree just because a model
stopped responding.

## 7. Add recovery only if you need it

```bash
squad --harness codex doctor --recovery
squad --harness codex conductor install --no-enable
```

Inspect the printed service configuration and hold path before enabling the
printed timer. `--no-enable` does not disable an already-active timer. For Codex,
use [managed-session operations](../guides/codex.md); for Claude, read the
[terminal adapter limits](../guides/claude-code.md). Neither installation nor a
quota reset grants permission to resume a user-paused project.

Finish with a Project Manager retrospective: what completed, how estimates
changed, which intervals were avoidable idle time, and what should improve next.
