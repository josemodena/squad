# Architecture and source layout

Squad has three layers:

1. **Skills and agent definitions:** instruct roles to plan, dispatch, implement
   and review through the native harness. These are agent behaviour contracts.
2. **Deterministic CLI/runtime:** manages GitHub operations, eligibility, local
   claims, checkpoints, policy and review records without model calls.
3. **Harness-specific recovery:** checks for durable pending work when ordinary
   native coordination is unavailable. Codex uses App Server and a gateway;
   Claude uses a terminal/multiplexer adapter.

## Repository boundaries

| Path | Ownership |
| --- | --- |
| `plugins/codex/squad/` | Installable Codex skills, hooks, scripts, systemd units, Go adapter |
| `plugins/claude-code/squad/` | Installable Claude skills, agents, hooks, scripts, systemd units, eval prompts |
| `shared/runtime/` | Canonical Python runtime and its tests |
| `docs/` | Canonical user and maintainer documentation |
| `bin/squad` | Checkout-backed command routing and diagnostics |
| `install.sh` | Explicit plugin/CLI installation; no background services |
| `tools/` | Sync, tests, validation and clean-publication export |
| `.agents/plugins/marketplace.json` | Codex marketplace entry pointing at its package |
| `.claude-plugin/marketplace.json` | Claude marketplace entry pointing at its package |

Both plugin roots are named `squad`; the parent directory identifies the harness.
A plugin must not import files from outside its own root at runtime. The sync tool
copies shared runtime files, the runtime reference and licence material into each
package. CI verifies byte-for-byte agreement to prevent divergent copies.

Bash adapters remain separate where their settings, hooks or command behaviour
differ. Do not force harness-specific notification or identity semantics into a
shared abstraction that claims more certainty than the harness provides.

## State and execution

GitHub holds scope, agreement, dependencies, role/stage and delivery status. Local
runtime state holds claims, actual native identity, checkpoints, policy and
completion acknowledgement. The latter is protected by a local file lock and
atomic file replacement. It is not a distributed scheduler.

The Administrator claims before spawning and binds the returned native identity.
Ordinary completion comes directly from subagents. An absent Administrator can
recover unhandled results through the conductor. Both paths inspect the same job
ownership record. A result must be handled and acknowledged before a replacement
assignment can own that issue.

The conductor does not plan, choose worker roles or review code. Codex's gateway
serialises managed turn starts and guards session policy. Claude's adapter has a
weaker terminal-level view and must not pretend it can prove native turn identity.

See the [runtime reference](../reference/runtime.md) for state transitions and
[acceptance scenarios](acceptance.md) for the boundaries to exercise.
