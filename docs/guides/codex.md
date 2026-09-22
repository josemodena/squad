# Squad on Codex

Install the plugin from the squad marketplace and start a new thread after updates.
Project settings live in `.codex/squad.local.md`. `$squad:init` configures the
project; `$squad:administrator` runs delivery and `$squad:project-manager` plans it.
Architect, Engineer and both independent Reviewer roles have their own skills.
For an interactive Administrator session use `codex --model gpt-6-luna` and
invoke `$squad:administrator`; loading a skill alone does not change the main model.
Existing operate/implement/review invocations remain aliases.

Codex defaults are gpt-6-luna for Administrator, gpt-6-astra for Project Manager,
Architect and Architecture Reviewer, and gpt-6-sol for Engineer and Engineering
Reviewer. The Administrator explicitly selects each subagent model. Its own
scheduled thread is created with administrator_model and an existing conflicting
model is rejected with migration instructions.

Native subagents carry ordinary work. The Administrator handles each result as
it arrives and uses native event waits. It stays available for independent work;
it does not end a turn merely to wait for a child. See [the workflow](workflow.md).

## External recovery

The per-project systemd timer checks every 30 seconds. Durable runtime state can
request recovery for interrupted/unhandled work or an explicit external event.
The private Codex App Server gateway serialises scheduler and terminal turn starts
and recognises exact turn completion. It does not select issues or role models for
workers. A native completion does not require a scheduler round trip.

```bash
squad --harness codex conductor install --project /path/to/project --no-enable
squad --harness codex session inspect
squad --harness codex session attach
squad --harness codex session rollover
squad --harness codex recover
squad --harness codex external decision-42 --reason "Dependency resolved"
```

Use the per-instance hold path printed by the installer. A user pause remains in
force across provider resets. `--no-enable` installs without activating delivery;
it does not disable an already enabled timer. Keep the timer stopped during a
paused migration. Attach joins the existing session; opening another ordinary
Codex conversation does not transfer session ownership.

The Go controller/gateway retains its durable start journal, exact native IDs,
bounded retries and ambiguous-start stop. Existing internal chief-of-staff thread
filenames are retained for compatibility. Unix sockets are private to the user.
An Administrator that cannot recover visibly records the blockage; no dummy
turn is spent just to create an attachable session.

`codex-quota` refreshes account/rateLimits/read and retains short and weekly
provider windows. Both it and dispatch apply persisted voluntary policy. An
expired or stale reading requires refresh; it cannot prove a reset occurred.

See [runtime commands](../reference/runtime.md), [migration](migration.md), and
[feature comparison](../../README.md#features-and-support). Validation uses Python runtime tests, shell fixtures
and Go App Server tests; fixture success is not a live subscription-exhaustion test.
