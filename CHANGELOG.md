# Changelog

## Unreleased

## 0.7.0 — 2026-10-19

The public release of 0.6.1 and 0.6.2, with the review cycle as the rule.

- The review cycle is the rule, in a new shared document
  (`docs/roles/review-cycle.md`) that the engineer, engineering-reviewer,
  project-manager, plan and retro skills follow: machine gates before any
  Reviewer, pull requests of about 400 non-test lines, one review scoped to the
  diff and the acceptance criteria with each finding blocking or note, notes do
  not block, a named fix checked by the merger with no second review unless
  behaviour changes, fixtures never written by the Engineer, two full suites at
  once at most, one cold run mid-sprint.
- The piece template has three headings: Why, What, How. The Why says, in
  plain words, the reason, the consequence of not doing it and the goal it
  serves; the acceptance test sits under How. `squad.sh issue` writes this body
  when none is given, and every follow-up issue carries all three.
- `review-record` writes the verdict line `squad.sh merge` reads
  (`Verdict: merge`, `merge after named fixes` or `do not merge`, then the
  reviewed head); before, its `Verdict: pass` line was refused by `merge`. The
  reviewer skill gives the exact form and the pass marker.
- `squad.sh merge` finishes the close-out when a step fails after GitHub has
  merged, such as one card move, and lists the failures at the end (exit 1).
- `squad.sh issue` checks the GitHub rate budget before it creates anything,
  as the board writes do (`board-backup.sh budget`); the runtime's
  issue-create path checks it again before adding the card.

## 0.6.2 — local build; released in 0.7.0

- `claude-quota` reads both meters: all models, and every per-model weekly
  meter in the status line's usage file (`fableUsage` today, setting
  `model_usage_file`). Each gets a line; the verdict comes from the meter with
  less headroom. A reading above 100 is the provider limit, kept as read.
  `quota-note` and the conductor use the plugin's own reader first.
- Board writes take one full backup per session (refreshed after an hour)
  instead of one per write, read only the card they change, and pause between
  writes (`SQUAD_WRITE_PAUSE`, default 3 s). `squad.sh place` sets status,
  sprint, iteration and estimate in one call.
- `squad.sh merge <pr> <issue>` checks the Reviewer's verdict, records the pass
  after named fixes, finishes, moves every closed issue to Done and posts the
  close-out with the Implementer's cost line. `launch` and `at-pr` do the board
  upkeep and keep an `<!-- in-flight -->` line in the issue body. `verdict`
  prints the last report's verdict line and sha.
- Claude Code 2.1.299: every hook reads its input before any early exit; a
  hook-written hand-over (PreCompact, which idle compaction now fires) reads
  the in-flight lines from the board and carries the last hand-over's next
  actions and waits instead of claiming none. Idle compaction stays on.

## 0.6.1 — local build; released in 0.7.0

- `gitw.sh start` creates each piece's worktree under `<scratch_root>/worktrees`
  (or `worktree_root`) from `origin/main` and never switches the checkout it runs
  in. A second start of the same piece reuses its worktree.
- `housekeeping.sh` prunes the Docker build cache and anonymous dangling volumes
  (named volumes are listed and kept), makes read-only scratch trees writable
  before deleting them, reports a failed delete and carries on, exiting 1.
  `--skip-docker` leaves Docker alone.
- `claude-quota` and `codex-quota` print the same verdict when run as
  `bash <path>`, as the plan and retro skills call them.
- Claude Code: the PreCompact hook declares `onFailure: "block"`, so a hand-over
  hook that cannot start or times out blocks compaction; the warn-only Stop hook
  stays fail-open. The PM passes the Agent tool's `effort` when a role sets one.
  Development baseline Claude Code 2.1.295.
- Claude Code retires the job runtime by default (`job_runtime: off`): Status on
  the board is the state, claims, checkpoints, Stage, Responsible role and the
  `metrics` output are retired, and In progress or In review cards are never
  dispatched twice. `job_runtime: on` keeps them; Codex keeps them by default.

## 0.6.0 — 2026-09-30

- Replace the model-backed Administrator with one main Project Manager session
  for planning, delivery and retrospectives; keep routine administration in CLI scripts.
- Add `squad start`, guarded PM identity checks and shared interactive/recovery
  session ownership. Preserve exact native identities and refuse duplicate launches.
- Force medium reasoning effort for new Codex Sol Engineer and Engineering
  Reviewer jobs; record effort at claim and reject mismatches at bind.
- Update both plugins, role contracts, README, guides and migration instructions.

## 0.5.2 — 2026-09-30

- Set Codex Engineer and Engineering Reviewer defaults to `gpt-6.1-sol`.
- Update setup templates, README, examples and model-upgrade guidance, including
  reasoning-effort defaults and preservation of project overrides and active jobs.

## 0.5.1 — 2026-09-23

- Share short-lived board reads across commands while revalidating each selected
  task directly before claims; reduce nested readiness query sizes.
- Group field handoffs into one fresh backup, prevalidated journal and targeted
  verification; avoid writing unchanged values.
- Back up issue-only blocker edits at issue scope without exporting the board.
- Coordinate typed GraphQL/REST requests across local projects, record usage and
  defer retries durably; wake after cooldown while preserving user pauses.
- Use REST for typed issue/PR reads and conditional single-page reply polling.
- Document free-account operation, measured coverage and remaining API boundaries.

## 0.5.0 — 2026-09-23

- Make the PM responsible for delivery resolution and all user escalations, with
  explicit delegation and provenance for new user requests.
- Add bounded PM diagnosis claims without unlocking blocked implementation.
- Observe GitHub replies with durable deduplication, paginated reads and deferred
  rate-limit backoff; require PM assessment before resolving authority.
- Package six role job descriptions and persist startup context for every claim.
- Add private Git-versioned decisions and lessons, with PM review, expiry and retirement.
- Avoid deprecated Project Classic queries when updating review verdict labels.
- Reorganise the README and add a complete decisions-and-learning guide.

## 0.4.6 — 2026-09-22

- Upgrade Codex defaults and new-project templates to GPT-6-Luna and GPT-6-Sol.
- Add read-only model upgrade discovery from the Codex catalogue, preserving
  custom settings, unfinished jobs and recorded execution models.
- Document Sonnet 5, Fable 5.1 and Opus 5.5 alias mappings, harness requirements
  and safe model changes between jobs and Administrator sessions.

## 0.4.5 — 2026-09-22

- Make readiness exclusions actionable with blocker categories, named owners,
  next actions, user-action flags and explicit claimability.
- Add visible orange user-action labels and readable PM requests, preserving
  explicit Project Status and backing up/journalling writes.
- Add a deterministic continuation list, bounded PM metadata-repair claims and
  mandatory owned handoffs before acknowledgement.
- Require input/authority/brief assessments before delivery claims; retain holds
  after blocked jobs are acknowledged until resolution is recorded.
- Batch readiness dependencies and labels with bounded rate-limit handling.

## 0.4.4 — 2026-09-22

- Launch direct planning and retrospective conversations in project-scoped Zellij
  tabs with the configured Project Manager model and effort for each harness.
- Focus existing meetings, checkpoint discussions, resume captured session IDs,
  and record idempotent outcome events without changing execution pause state.
- Keep meeting startup/end/compaction hooks separate from Administrator tab naming,
  handover publication and implementation-file reminders.
- Add fixture coverage and an opt-in real Zellij smoke test for both plugins.

## 0.4.3 — 2026-09-22

- Fix Status migration and Sprint-option creation dropping existing option IDs,
  colours and descriptions, which could clear populated item values.
- Save local Git-versioned board snapshots before migration, option updates and
  board writes, isolated by GitHub host, owner and project number.
- Add paginated board exports and confirmed restore previews with state hashes,
  rate-budget preflight, bounded backoff and durable interruption journals.
- Restore supported item values and view settings; explicitly block unsupported
  differences, deleted identities and incomplete snapshots.
- Document private backup storage, retention, multi-project operation and recovery
  limits. GitHub does not provide atomic whole-board restoration.

## 0.4.2 — 2026-09-22

- First tagged GitHub release, with automated validation, source packages and checksums.
- Fix paginated GitHub operations on GitHub CLI 2.46.0 and check the minimum in doctor.
- Add Spec-Driven Development guidance from agreed requirements through reviewed delivery.
- Clarify committing setup before worktrees, clean test artifacts, prerequisite handling
  and explicit quota-policy authority.
- Refresh pinned CI actions after validating their updates.

## 0.4.1

- Adopt Apache-2.0 for original Squad code and documentation.
- Include LICENSE and NOTICE in both plugin distributions and update contribution terms.

## 0.4.0

### Added

- A Linux installation helper and a short `squad` CLI with harness detection,
  project selection, diagnostics and recovery/Git command groups.
- A first-project tutorial, explicit platform and account requirements, detailed
  feature matrix, configuration reference and troubleshooting guide.
- Contribution, security and community guidance; CI, issue forms, dependency
  updates, packaging checks and clean-publication tooling.

### Changed

- Self-contained plugins now live at `plugins/codex/squad` and
  `plugins/claude-code/squad`. Marketplace and plugin names remain `squad`.
- Shared runtime source and tests have one canonical location and checked package
  copies. Installed skills carry their runtime reference in both distributions.
- Recovery launchers use distinct harness-specific filenames.
- New project templates use a project-specific durable state path.
- Test fixtures no longer depend on a developer's home directory.

### Compatibility

- Existing local settings, worktrees and pauses are preserved. Updates do not
  authorise work to resume. Follow the migration guide before reinstalling recovery.
- Linux remains the supported target. Claude needs an external quota collector;
  the two recovery adapters have different capabilities and check intervals.

## 0.3.1

- Claude default assignments: Sonnet for administration, Fable for project
  management and architecture, Opus for engineering and engineering review.

## 0.3.0

- Six specialised roles, native completion-driven coordination, durable job
  claims/checkpoints, policy overrides, dependency tracking and reviewed-head
  merge guards.
