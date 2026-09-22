# Native workflow acceptance scenarios

Use a disposable project and fake capacity source for limit scenarios. Never burn
real subscription allowance to simulate exhaustion. Automated runtime tests cover
the deterministic invariants; record actual harness evidence separately.

1. **Parallel completion:** agree two independent engineering issues, dispatch
   both with Sol and keep Luna Administrator active. Finish one; its Sol Reviewer
   must start without waiting for the other Engineer or a conductor tick. Record
   native worker IDs, actual models and completion-to-dispatch delay.
2. **Conditional architecture:** an item with an approved existing design goes
   directly to engineering; a new solution goes through distinct Astra Architect
   and Architecture Reviewer assignments. Changed designs require fresh review.
3. **Interrupted worker:** end a worker after a checkpoint but before a final
   report. Recovery preserves tracked and new files, recognises its exact native
   turn, and inspects output before a replacement. A surviving test process is
   not relaunched or killed blindly.
4. **Provider reset:** simulate unavailable capacity in the provider fixture.
   The Administrator makes no more assignments; external recovery starts only
   after a fresh available reading. Exercise a short window and weekly window.
5. **Pause wins:** pause before reset with an event already pending. Neither the
   pending event nor the fresh quota reading starts work. Only explicit user
   resume, including clearing the deliberate legacy hold, permits recovery.
6. **Policy override:** persist unrestricted policy, end the session, restart.
   An 88% reading below the provider limit must not be blocked by the old 85% cap.
   A short provider window at 100% still blocks. Expiry restores configured policy.
7. **Double delivery:** deliver the same completion through native notification
   and recovery. Exactly one next assignment is claimed. A completed but unacked
   result continues to own its issue until board transition and acknowledgement.
8. **Changed review head:** push after review preparation. Recording a pass for
   the old commit fails; merge cannot accept that stale pass.
9. **External decision:** while Administrator is absent, record a stable external
   event after updating the issue. It wakes once; settle through the inspected
   revision does not consume a concurrently arriving decision.
10. **Session lifetime:** exercise parent active, native event wait, parent final,
    client disconnect and backend restart. Record which completions are delivered
    natively by the installed harness; external recovery covers unavailable turns.

Claude Code runs the same outcome scenarios using its native Agent tool and
terminal recovery adapter. Do not assert Codex rollout identity behaviour there.

## Automated checks

`bash tools/test.sh` runs repository/link/package checks, CLI tests, both packaged
runtime suites, shell fixtures, merge guards, Codex event/installer fixtures and
Go tests. It uses isolated repositories and fakes for GitHub and harness calls;
Go module downloads may need network access. No paid model calls are made.

`bash plugins/codex/squad/scripts/test-gateway-systemd.sh` additionally needs a
working systemd user manager. It creates uniquely named runtime-only test units
and removes them afterward. This check is not run automatically on hosts without
a user manager; record it separately when validating a recovery release.

For live scenarios, record the release, OS, harness version, configured models,
steps, observed native events and outcome in a redacted test report. A scenario
being listed here does not mean it has been demonstrated on every harness.
