# Migrating to native Squad coordination

1. Preserve user pauses and conductor hold files. Finish/checkpoint live work
   before changing the operating model. A plugin update does not authorise resume.
2. Update the plugin and start a new harness session for the new skills. The old
   operate/implement/review skill names are compatibility aliases. Chief of Staff
   is replaced by Administrator and Project Manager; authoring and review split
   into architecture and engineering. Old Claude agent files are replaced.
3. Add the six role-model keys from the settings template and max_workers (default
   3). Set continuation_mode: native. Keep project-specific scope and decisions.
4. Run `squad init apply` to add new Project fields. Existing issue plans, labels,
   dates and Owner fields are retained. Explicitly classify existing agreed work
   with Agreement, Design, Stage and Responsible role; migration never invents
   user agreement. Use native dependency commands for prerequisites.
5. Persist any current user quota override with `squad policy`; a historical
   comment is not executable policy. Keep a user pause until explicit resume.
6. Import current unfinished work using claim/bind only after reconciling existing
   workers. Do not launch a second worker to make the new records look complete.
   Preserve old handovers as narrative recovery context.
7. For Codex, rebuild/reinstall the conductor with `--no-enable` while paused.
   An old Astra coordinating thread cannot silently become the Luna Administrator:
   use `squad --harness codex session rollover` only when idle, after preserving its state.
   The next authorised recovery creates a thread with the configured model.
8. When the user actually resumes, clear the applicable deliberate hold and enable
   the timer, or start the Administrator interactively. Record one stable external
   event for agreed ready work. No dummy model turn is required for activation.

The `legacy` continuation setting retains the old handover-driven scheduler for
migration only. New operation uses runtime state, native notifications and external
recovery. Legacy state filenames containing chief-of-staff are retained internally
so an upgrade does not lose an existing thread's authority.

Rollback: preserve runtime storage/checkpoints and disable new launches, then
install the previous plugin. Do not remove runtime ownership records while workers
may still be alive. Reconcile before launching from any older workflow.

## Repository layout in 0.4

The Claude plugin moved from the repository root to `plugins/claude-code/squad/`.
The Codex plugin moved from `plugins/squad/` to `plugins/codex/squad/`. Marketplace
names and the `squad` plugin name are unchanged. Update the marketplace before
reinstalling; hard-coded development paths must be updated.

The new `squad` CLI makes source/cache paths unnecessary for ordinary commands.
Use `squad git` for the Git wrapper and `squad conductor install` for recovery.
Existing script entry points still exist inside their respective packages.
Reinstall recovery units with `--no-enable` while preserving any pause/hold; the
harness-specific launchers avoid collisions when both plugins are installed.
