# Squad on Claude Code

Install with `claude plugin marketplace add josemodena/squad` and
`claude plugin install squad@squad`. Start a new session after updating.
Settings live in `.claude/squad.local.md`; `/squad:init` configures the project.

The Administrator uses native subagents and background completion notifications.
It can coordinate other work while children run and need not end merely to wait.
Role defaults are Sonnet for administration, Fable for project management and
architecture authoring/review, and Opus for engineering authoring/review. Set
project overrides explicitly at dispatch. Six agents and corresponding skills
ship in the plugin; old implement/review skill invocations remain aliases.

The deterministic execution/tracker CLI, checkpoints, quota-policy override and
review-gated submit/finish commands match Codex. Usage still comes from the
configured status-line collector; the policy command does not fabricate readings.

The optional systemd/Zellij conductor retains its harness-specific terminal guard
and cadence. In native mode it only requests durable recovery when capacity allows.
It cannot infer exact worker termination from Codex rollout records; an unknown
Claude worker needs native inspection before replacement. Preserve user holds.

See [the workflow](workflow.md), [commands](../reference/runtime.md), [migration](migration.md) and
[capability differences](../../README.md#features-and-support).

## Install terminal recovery

Run `squad --harness claude-code doctor --recovery`, then
`squad --harness claude-code conductor install --no-enable` from the project.
The supplied timer checks every ten minutes and uses the configured Zellij
session/tab. Inspect the generated environment and hold path before enabling
`squad-conductor.timer` with `systemctl --user enable --now squad-conductor.timer`.
Do this only after explicitly deciding to run unattended.

This adapter currently supports one configured project per OS user. Installing
it for another project replaces that global configuration. Use interactive
coordination for additional Claude projects. Codex's adapter has per-project
instances. The two harnesses use separate launcher files.

The usage collector is an external prerequisite, including for native dispatch.
See [the reading contract](../reference/configuration.md#claude-usage-data).
