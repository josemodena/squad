# Upgrade to the main Project Manager session

Squad 0.6.0 removes the Administrator role. You speak directly to the PM, which
owns planning and delivery. CLI scripts perform deterministic administration.
The old `administrator` and `operate` skills are launch-only compatibility aliases.

1. Ask the existing coordinator to checkpoint. Inspect `squad recover`, native
   workers and background processes. Finish or reconcile active work; do not
   relaunch a job just because its parent session is changing.
2. Update both the plugin and the checkout providing `squad`. Existing jobs keep
   their recorded models and effort. New Codex Sol engineering/review claims
   require medium effort, even if older configuration says low or high.
3. Check `squad models --details`. The five roles are PM, Architect, Engineer,
   Architecture Reviewer and Engineering Reviewer. Old `administrator_model`
   settings are unused. Keep unrelated settings, pauses and quota policy intact.
4. In Codex, rebuild the adapter with `squad conductor install --no-enable` after
   checkpointing. Stop the project's timer during migration if it is enabled.
   Start the printed gateway service. Verify the managed turn is idle, then run
   `squad session rollover`. This archives the old thread; it does not erase jobs,
   checkpoints or approvals. The gateway refuses rollover of an active turn.
5. In Claude Code, checkpoint and close the old Administrator and separate PM
   meeting sessions after reconciling their workers. The new main PM must not
   run alongside an old coordinator. Retain old meeting notes for recovery.
6. Run `squad start` in Zellij. Verify the returned model and the native session:
   Astra/high on Codex or Fable/high on Claude by default. Continue planning,
   retrospectives and execution in that conversation. Enable the optional timer
   again only according to your existing recovery policy.

No board migration is required. Existing single-select option IDs and explicit
Status values stay intact. Historical Administrator options and records may remain
for audit history; assign new work to one of the five current roles. Never rebuild
an option list to remove an obsolete name. Back up any intentional board edits
with the provided versioned snapshot helpers.

A plugin upgrade cannot change the model or instructions already loaded in a
running conversation. The launcher's refusal to attach to an old coordinator is a
migration safeguard, not permission to bypass it or interrupt active workers.
