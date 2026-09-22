# CLI reference

`squad` is a thin dispatcher to deterministic plugin scripts. It forwards arguments
as separate values, preserves exit status, and does not ask a model to perform
routine GitHub operations.

```text
squad [--harness codex|claude-code] [--project DIR] COMMAND [ARGS...]
```

Global options go **before** the command. The command walks parent directories to
find project settings. If both harnesses have settings, select one explicitly.
`SQUAD_HARNESS` and `SQUAD_PROJECT_DIR` provide the same selection through the
environment. `SQUAD_SETTINGS` selects a custom settings file; use `--harness` when
its location does not identify the harness.

| Command | Purpose |
| --- | --- |
| `squad --help`, `squad --version` | Help/version without settings or authentication |
| `squad --harness codex doctor` | Read-only prerequisite checks; no agent calls |
| `squad doctor --offline` | Skip the GitHub authentication check |
| `squad doctor --recovery` | Also check systemd and Go/Zellij prerequisites |
| `squad init check` | Inspect existing project provisioning |
| `squad init apply` | Create missing tracking/configured template resources |
| `squad init create-board "TITLE"` | Create a GitHub Project using configured ownership |
| `squad board` | Human-readable Project board |
| `squad status` / `squad recover` | JSON recovery summary and effective policy |
| `squad ready` | JSON eligibility and exclusion reasons |
| `squad models` | Role/model assignments |
| `squad quota --json` | Capacity reading; exit 0 run, 1 suspend, 2 stale, 3 missing |
| `squad pause --reason TEXT` | Block new work; does not kill running workers |
| `squad resume --reason TEXT` | Record an explicit resume; legacy holds remain |
| `squad policy` | Read effective voluntary policy |
| `squad metrics` | Measurements from recorded observations |
| `squad git COMMAND` | Existing branch/worktree/submit/review-gated merge helper |
| `squad handover ...` | Generate a structured handover |
| `squad session inspect\|attach\|rollover` | Codex managed-session operations |
| `squad conductor install --no-enable` | Install recovery without starting a new timer |
| `squad conductor uninstall` | Disable/remove the selected recovery adapter |
| `squad runtime --help` | Full typed runtime subcommand list |

The wrapper does not change existing command argument syntax. For example:

```bash
squad dependency add 42 17
squad field 42 "Needed by" 2026-11-01
squad field 42 "Responsible role" engineer
squad policy --mode unrestricted --reason "User waived voluntary pacing"
squad git submit "Add validated export" 42
```

The [runtime reference](runtime.md) documents claims, identities, checkpoints,
review evidence, external events and policy semantics. Older board/settings/Git
helpers print human-readable text; typed runtime commands return JSON. Do not
assume every command returns JSON.

`init` without arguments is `init check`, not an unattended configuration wizard.
Use the init skill for initial decisions. `doctor` does not alter settings, install
packages or prove model access. `session attach` starts a harness client; recovery
installation can start services unless you pass `--no-enable`.

The short command uses the local Squad checkout linked at installation time.
Inside an installed plugin, skills can use bundled scripts directly without the
short command. Keep checkout and installed plugin versions aligned.
