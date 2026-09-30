# Squad on Codex

Install the plugin from the squad marketplace and start a new thread after updates.
Project settings live in `.codex/squad.local.md`. `$squad:init` configures the
project. Run `squad start` in Zellij to open the main PM conversation, after the
[one-time managed-session setup](meetings.md#setup). Planning, retrospectives and
delivery use this same Astra/high session. Loading a skill alone cannot change a
model. Existing administrator/operate invocations only launch the proper PM.

Codex defaults to gpt-6-astra for PM, Architect and Architecture Reviewer, and
gpt-6.1-sol at medium effort for Engineer and Engineering Reviewer. Claims record
the required effort and binds reject a mismatch. The PM selects native subagent
models explicitly. Managed session creation verifies its own model and effort;
an incompatible old thread requires an idle rollover.

Native subagents carry ordinary work. The Project Manager handles each result as
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
A Project Manager that cannot recover visibly records the blockage; no dummy
turn is spent just to create an attachable session.

`codex-quota` refreshes account/rateLimits/read and retains short and weekly
provider windows. Both it and dispatch apply persisted voluntary policy. An
expired or stale reading requires refresh; it cannot prove a reset occurred.

See [runtime commands](../reference/runtime.md), [migration](migration.md), and
[feature comparison](../../README.md#features-and-support). Validation uses Python runtime tests, shell fixtures
and Go App Server tests; fixture success is not a live subscription-exhaustion test.
