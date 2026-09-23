# Decisions, stalled work and learning

Squad should keep agreed work moving without making the user manage every handoff.
The Administrator coordinates execution. When it cannot find a valid next step,
it assigns resolution to the Project Manager (PM). The PM resolves what falls
within its delegated authority and brings only reserved decisions to the user.

## Follow a stopped task

1. The Administrator reads `squad next`. A failed review, missing authority or
   unclear handoff becomes a PM resolution assignment, not an unexplained wait.
2. It writes a diagnosis brief and uses `squad pm-claim` to claim the PM work.
   This claim permits investigation and planning, not the blocked implementation.
3. The PM checks the evidence, existing agreement and previous decisions. It may
   repair metadata, revise a forecast, commission architecture reassessment or
   prepare another bounded correction within its authority.
4. If a user decision is genuinely required, the PM writes the request. The
   Administrator may publish or relay it unchanged. The issue shows an orange
   attention label, what is needed, why, the PM recommendation, the authority
   boundary and the consequence of waiting. Project Status is preserved.
5. The user replies on that GitHub issue or speaks directly with the PM. A GitHub
   reply becomes a durable event; the PM checks its author and meaning before
   recording a decision and resolving the blocker.
6. The Administrator refreshes readiness and dispatches the next eligible role.
   A reply never overrides a separate user pause or the provider's capacity limit.

The [delegation policy](../roles/authority.md) lists what the PM may resolve and
what it must bring to the user. For example, the PM can revise its own estimate
or planned correction count. It cannot override a user's explicit “one attempt
only” limit. In either case it can prepare the permitted analysis before asking.

A bounded PM diagnosis uses the configured PM model and the usual worker/duplicate
locks. It observes pause and quota policy. Its default admission allowance is
`metadata_repair_estimate` (0.5 weekly percentage points); forecast any larger
investigation separately. It may diagnose missing agreement but cannot grant it.
An unchanged, completed PM assessment is remembered so it does not start a loop.
The runtime refuses to settle recovery while an eligible PM resolution remains
unassigned; refresh readiness after repairs before settling. Known provider-capacity
waits use the existing reset recovery rather than repeatedly commissioning a PM.
New replies or changed blockers cause reassessment. The PM must leave a concrete
next action or a named wait with its resumption condition.

## GitHub replies while no agent is running

The optional recovery conductor invokes a deterministic reply observer. It checks
watched issues using one repository-wide paginated comments feed, normally every
five minutes. Codex's timer may tick more often without making another API call.
Claude's ten-minute timer bounds its actual observation cadence. There is no model
call for observation. The active Administrator also polls at recovery boundaries.

Publishing a user request registers its issue automatically. Existing user blockers
in cached readiness are also discovered, which supports upgrades from 0.4.6. For
an older request not present there, explicitly register its original date:

```sh
squad inbox watch --issue 42 --since 2026-09-01T10:00:00Z
squad inbox poll --force
squad inbox status
```

`--force` bypasses the normal interval, never a rate-limit backoff. Full pages are
read before advancing the cursor. A partial failure retains the cursor; retries
are deferred with exponential backoff and respect GitHub's retry/reset headers.
A batch is bounded to ten pages, each request to 30 seconds. Comment ID, revision
and content hash prevent duplicate events while recognising edited replies.

The observer stores raw reply evidence and wakes coordination; it does **not**
interpret “approve” or automatically clear a blocker. Configure `decision_makers`
as comma-separated GitHub logins. The PM verifies those identities, the original
request, scope and superseding decisions. If identity is not configured, it must
establish it from explicit project authority rather than repository ownership.
GitHub identity alone is insufficient when agents and the user share an account.

A PM job that handles a reply must include this in its handoff:

```json
{
  "reply_disposition": {
    "url": "https://github.com/example/demo/issues/42#issuecomment-123",
    "outcome": "accepted",
    "evidence": "Verified decision-maker identity, original request and exact scope; decision record approval-42."
  }
}
```

This is an additional field in the normal handoff, not a complete handoff file.
Other outcomes are `clarification` and `rejected`. A newer reply remains pending
when the earlier one is acknowledged. A response requesting clarification must
include the PM's precise next question, rather than simply clearing the event.

Without a running conductor, no background observer runs: use `squad inbox poll`
when starting the Administrator. `github_reply_observer: false` disables automated
observation; `github_reply_interval` sets seconds (minimum 60). Inspect observer
health with `inbox status`; errors are not evidence that no replies exist. This
observer covers issue comments, not email, chat messages, reactions or arbitrary
Project edits. Publish decisions on the watched issue or record an explicit runtime
external event for other channels. The issue is the durable user-facing request;
Squad does not send email, Teams or other third-party notifications.

## Role instructions at startup

Each role has a [job description](../roles/README.md): purpose, responsibility,
accountability, authority, success criteria, inputs and handoffs. Shared role
instructions ship inside both plugins. The harness-specific skills explain how
to execute them. They are agent instructions, not overrides of harness policy.

```sh
squad context engineer --issue 42
```

This returns the role description, delegation policy, optional `authority_file`,
and relevant reviewed decisions/lessons. Each job claim saves a `context.json`
packet and returns its path. The Administrator includes that path and the task
brief in the new agent's instructions. A fresh agent also reads current project
instructions and current context; the saved packet explains what it received at
claim time. Direct PM meetings load the same context without a worker claim.

## Learn without relying on a continuously running agent

Execution checkpoints recover work. Decisions preserve agreement and its source.
Lessons preserve techniques and mistakes worth remembering. They are different
records; a lesson cannot authorise new work.

Any role can propose a lesson with `squad memory add --file lesson.json`:

```json
{
  "id": "test-sequential-navigation",
  "kind": "lesson",
  "summary": "Test transitions between screens, not just fresh loads of each screen.",
  "evidence": "Independent review report and reproducible browser captures.",
  "applicability": "UI work with more than one navigable screen.",
  "roles": ["engineer", "engineering-reviewer"],
  "issues": [42]
}
```

Omit `issues` for a project-wide lesson. Optional `expires_at` is a UTC epoch time.
The proposal is not loaded into startup context until the PM reviews it:

```sh
squad memory review --id test-sequential-navigation --file review.json --pm-job pm-42
```

```json
{
  "status": "active",
  "reason": "The reviewer reproduced the gap and the added check catches it.",
  "evidence": "Review report and regression-test result."
}
```

Use `rejected` for unsupported proposals and `retired` for outdated guidance.
A decision uses `kind: decision` and must include `authority_source`; activation
also requires `authority_check` in the PM review. A PM review may instead use a
captured direct meeting `--pm-session UUID`. Role provenance is checked against
local jobs or meeting records. It is audit evidence, not tamper-proof access control.

Records live in a private local Git repository under runtime `knowledge/`, with a
repository/Project identity namespace. `knowledge_dir` can relocate that base.
Nothing is pushed automatically. Retain history until an explicit retention decision;
back up this private directory with runtime data. Project records never enter the
public Squad repository. General improvements require a separate sanitised change.
Only committed records feed context; interrupted writes need reconciliation.

Context filters by role, issue, active status and expiry. It includes all matching
decisions and the newest twenty matching lessons, reporting omissions. Use
`squad memory list` to inspect the complete committed register. Review lessons at
retrospectives; prefer a few useful, evidenced lessons over transcript archives.
