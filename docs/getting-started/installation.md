# Installation, updates and removal

## Plugin and short CLI together

```bash
git clone https://github.com/josemodena/squad.git
cd squad
./install.sh codex
# Or: ./install.sh claude-code
export PATH="$HOME/.local/bin:$PATH"
```

This adds this checkout as the `squad` marketplace, installs the chosen plugin,
and links `~/.local/bin/squad` to the checkout's command. It does not change shell
profiles, install dependencies, start agents or enable recovery. Keep the checkout
at that path. A path containing spaces is supported by this installer/CLI; the
optional systemd adapter has additional path restrictions (see limitations).

Use `--bin-dir DIR` for another command directory. An unrelated existing `squad`
command will not be overwritten. Install the other plugin with the same command
and its harness argument. If an existing marketplace named `squad` points at a
different source, use the harness's marketplace remove/add commands to choose
one source deliberately, then rerun installation.

## Plugin only, through the harness

No Squad clone or CLI link is needed if you operate entirely through skills.

```bash
# Codex
codex plugin marketplace add josemodena/squad --ref main
codex plugin add squad@squad

# Claude Code
claude plugin marketplace add josemodena/squad
claude plugin install squad@squad
```

To add the short command later, clone this repository and run
`./install.sh codex --cli-only` (or `claude-code`). That command uses the local
checkout's scripts; keep its release aligned with the installed plugin.

Start a **new harness session** after installation or an update. Skill content in
an existing conversation may remain from the old version.

## Update

For a checkout installation:

```bash
cd /path/to/squad
git pull --ff-only
./install.sh codex                  # or claude-code
```

For a native marketplace installation:

```bash
codex plugin marketplace upgrade squad
codex plugin add squad@squad
# Or, for Claude Code:
claude plugin marketplace update squad
claude plugin update squad@squad
```

Claude plugins installed at project scope must also be updated at that scope from
the corresponding project: `claude plugin update squad@squad --scope project`.
A plugin update does not authorise resuming a paused project. For upgrades that
change recovery units, follow the [migration guide](../guides/migration.md).

## Remove

Pause delivery and reconcile/checkpoint live workers first. If you installed
recovery, remove it while the plugin and project configuration are still present:

```bash
squad --harness codex conductor uninstall
# Or: squad --harness claude-code conductor uninstall
```

Remove the plugin with `codex plugin remove squad@squad` or
`claude plugin uninstall squad@squad`. Remove the `squad` symlink from your chosen
bin directory and, when no longer needed, the local marketplace via your harness.
Do not delete the source checkout until no command or marketplace uses it.
Configuration, boards, issues, checkpoints and worktrees are deliberately retained.
Inspect them before deciding what to archive or remove.
