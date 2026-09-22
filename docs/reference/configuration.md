# Configuration

Project settings are YAML-style front matter in `.codex/squad.local.md` or
`.claude/squad.local.md`. Run the init skill to create them from the packaged
template. The parser accepts scalar values and simple lists, not arbitrary YAML.
It never needs secrets in this file.

| Setting | Purpose |
| --- | --- |
| `repository` | GitHub `owner/name` |
| `project_owner`, `project_owner_type`, `project_number` | Project v2 identity; owner type `user` or `organization` |
| `origin_remote`, `mirror_remote`, `ssh_key` | Expected Git origin, optional mirror and optional SSH-key path |
| `scratch_root` | Unique durable worktree/runtime directory per project |
| `administrator_model` | Model of the coordinating session |
| `project_manager_model`, `architect_model`, `engineer_model` | Authoring/planning role assignments |
| `architecture_reviewer_model`, `engineering_reviewer_model` | Separate reviewer assignments |
| `max_workers` | Maximum claimed jobs; default 3, bounded by harness capacity |
| `continuation_mode` | `native`; `legacy` exists for migration only |
| `quota_mode` | `pacing`, `weekly`, or `unrestricted` |
| `quota_daily_percent`, `quota_weekly_cap_percent` | Voluntary allocation policy, not provider entitlement |
| `quota_command` | Executable producing the reading used by dispatch |
| `sprint_day`, `sprint_hour_utc` | Planning/reset convention |
| `tracks`, `owners`, `statuses` | Existing tracking categories/options |
| `decider`, `decider_label` | Human decision owner and decision-only work label |
| `conductor_session`, `conductor_command` | Harness-specific external recovery settings |
| `transcripts_dir`, `memory_store` | Optional housekeeping report inputs |
| `harness_changelog_url`, `harness_version_file`, `harness_watchlist` | Optional harness-release review |

Use the actual origin URL (SSH or HTTPS). Models must be available in the selected
harness/account. Values shown in the README are assignments, not an availability
guarantee. Selecting a skill does not itself change the session model.

Persist temporary quota policy with `squad policy --mode ... --reason ...`, rather
than relying on a comment in a handover. Runtime policy and pause are shared by
both harnesses if they use the same scratch root. `SQUAD_RUNTIME_DIR` overrides the
runtime location; otherwise it is `<scratch_root>/runtime`.

## Project fields

The initializer creates/retains Status, Track, Owner, Estimate (credits %), Sprint,
Iteration and Needed by, and adds Responsible role, Stage, Agreement, Design,
Priority, Forecast finish and Estimate (hours). Existing fields are retained.

Roles belong in Responsible role; GitHub Assignees are real GitHub accounts.
Labels describe work type/component. GitHub native blocked-by relationships record
prerequisites. Forecast finish is a forecast; Needed by is a requirement, not a
rule that prevents early work. See [eligibility rules](runtime.md#planning-and-tracking).

## Claude usage data

Squad **does not ship a Claude subscription-usage collector**. Its reader consumes
a file supplied by a separate integration, by default
`~/.cache/claude-code/usage.json`; `SQUAD_USAGE_FILE` overrides that location.

The reader expects this shape (illustrative values, not a usable live reading):

```json
{
  "captured_at": 0,
  "seven_day": {"used_percentage": 25.0, "resets_at": 0},
  "provider_windows": [{"used_percentage": 10.0, "resets_at": 0}]
}
```

Timestamps are Unix epoch seconds in UTC. The weekly record is the primary
allocation input. If the collector supplies short-window records in `provider_windows`, policy checks can
also block on it. Write the file atomically with genuine current provider data;
never use the illustrative zero timestamps to bypass capacity checks. Readings
older than the supported freshness window are stale. Refresh must continue while
waiting for a reset if unattended recovery is expected.

`usage_command` is an optional reporting integration (historically `claude-usage`),
not an included collector. A custom `quota_command` can replace the reader if it
honours the runtime's JSON verdict/headroom contract and actual provider limits.
A missing collector means Claude capacity-aware dispatch is not ready to run.

## Local data and backups

Settings can contain paths, project identities and operational decisions; keep
them local by default. Runtime checkpoints can contain source and untracked files.
Restrict their filesystem access, avoid publishing logs, and back up durable state
according to the project's needs. Never delete a state directory to clear a
blocked job without reconciling the worker and its processes first.

## Board backup storage

Optional `board_backup_dir` selects the private durable base directory. By default
this is `<scratch_root>/board-backups`. Squad appends the GitHub host and
`<owner>-<project number>` so projects have separate histories and locks. Multiple
local workers on the same board must use the same base. See
[board backup and restore](../guides/board-backup.md) for retention and API limits.

## Interactive meetings

`project_manager_effort` defaults to `high` for direct planning/retrospective
sessions. `meeting_zellij_session` optionally selects an existing Zellij session;
otherwise the launcher uses `ZELLIJ_SESSION_NAME` from its environment. See the
[meeting guide](../guides/meetings.md). Model selection uses the existing
`project_manager_model`, independently for each harness.

`decider` names the user in readiness requests; `decider_label` remains configurable.
`metadata_repair_estimate` defaults to 0.5 weekly percentage points for a bounded PM repair headroom check. See [owned blockers](../guides/blockers.md).
