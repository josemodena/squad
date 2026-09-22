# Known limitations

- Linux is the supported target. GNU shell tools and Unix locking are assumed.
  macOS, native Windows and WSL2 have not been validated.
- Native subagent delivery and model selection depend on the harness/account.
  Automated fixtures do not establish real-world quota-reset or disconnect
  behaviour. Run the live acceptance scenarios after harness upgrades.
- Claude needs an external usage collector. There is no bundled automatic
  subscription reader for Claude. Its recovery adapter has a ten-minute cadence,
  one conductor per OS user, and no Codex-style native worker termination proof.
- The Codex adapter depends on App Server APIs and Go. Interface changes can
  require updates. Managed session attachment is specific to that adapter.
- Recovery installers generate systemd environment files from machine paths.
  Use paths without spaces, quotes or newlines for the project, scratch root and
  relevant executable paths when enabling unattended recovery. The interactive
  CLI supports spaces, but the complete recovery path has not been hardened for
  arbitrary path characters.
- Runtime ownership is local to one state directory/host. It is not a distributed
  task queue. Sharing one GitHub board across independent coordinators without
  shared ownership records can duplicate work.
- Pause blocks new claims and recovery; it does not kill already-running agents
  or commands. Checkpoint and stop active work through the native harness.
- Checkpoints preserve saved files and recorded next steps, not unsaved reasoning.
  Ignored files remain in the original worktree and are not copied into snapshots.
- Review gates protect Squad's merge path, not every possible direct GitHub action.
  Model independence is recorded worker identity, not a guarantee that two models
  will find every defect.
- Idle-time metrics describe recorded intervals only. Shared subscription usage
  cannot reliably be attributed to overlapping jobs as separate exact costs.
- Account-specific model aliases may be unavailable elsewhere. Configure models
  that your harness can actually select; do not silently replace an agreed model.

Report reproducible issues with harness/version, operating system, a minimal
configuration and redacted output. Do not upload real checkpoints or credentials.
