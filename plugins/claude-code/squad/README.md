# Squad for Claude Code

Coordinate agreed GitHub work through six roles, native subagent notifications,
durable job records and independent review. This directory is a self-contained
Claude Code plugin; it does not need the Codex plugin.

Start in your project with `/squad:init`, agree work with
`/squad:project-manager`, then run `/squad:administrator` in a session using the
configured Administrator model. Selecting a skill does not change the main model.

The [runtime reference](docs/runtime.md) ships with this plugin. Without the short
`squad` command, invoke the bundled scripts with
`bash <plugin-root>/scripts/squad.sh COMMAND` and
`bash <plugin-root>/scripts/gitw.sh COMMAND`.

Full [installation, requirements and tutorials](https://github.com/josemodena/squad/tree/main/docs)
are maintained in the repository. Linux is the supported runtime. Capacity-aware
dispatch needs an external usage collector. Optional terminal recovery uses
systemd/Zellij and currently supports one project per OS user. Preserve deliberate
pauses across updates.
