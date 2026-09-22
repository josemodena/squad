# Changelog

## Unreleased

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
