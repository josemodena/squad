# Changelog

## Unreleased

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
