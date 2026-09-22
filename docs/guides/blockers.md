# Owned blockers and continuing work

Project Status, Squad Stage/Responsible role and runtime job state are separate.
A completed agent turn is not a completed issue. The Administrator keeps moving
agreed work through implementation, review, correction and acceptance until its
completion criteria pass. It may wait for a user decision/input, a named dependency,
a deliberate pause or unavailable capacity. Each wait has an owner and next action;
metadata repair is work, not a reason to end the session.

## The continuation loop

After recovery, every result, rejected launch, repair or user decision:

1. Run `squad next`. Dispatch eligible work and claim PM metadata repairs.
2. Read the exact result/evidence. Route review findings to the author and corrected
   work to a fresh independent reviewer. Reconcile existing jobs before replacements.
3. Publish external blockers with an owner and plain-English request. Process other
   independent work while waiting. Do not repeatedly launch the blocked assignment.
4. Update Stage and Responsible role for the next handoff using `squad field`.
   Preserve explicit Status unless an authorised separate transition is required.
5. Record a handoff, acknowledge the finished job, refresh readiness and continue.

`next` returns `can_continue` for dispatch and PM repairs, plus named actions/waits.
This is a deterministic action list, not a new scheduler or a guarantee that an
external party responds. An item can wait legitimately; it must never be forgotten
or left with an unowned “blocked” report. The Administrator instructions prohibit
ending while eligible work or an internal metadata repair can proceed.

## Visible requests for the user

Use a structured JSON record, for example:

```json
{
  "id": "native-acceptance-authority-required",
  "category": "decision-required",
  "owner": "Project owner",
  "requires_user": true,
  "next_action": "Approve or decline one real acceptance run after the corrected test passes review.",
  "why": "The previous authorised attempt was consumed and did not prove acceptance.",
  "recommendation": "Correct and review the known test problem before spending another attempt.",
  "evidence": "Link to the exact review and consumed-run record"
}
```

```bash
squad blocker set 42 --file blocker.json
squad blocker visibility
```

The issue gets a readable **what to do / why / PM recommendation** section, a
`blocked` label and, for user-owned actions, the orange **🟠 needs-your-action**
label plus the configured decider label. `visibility` appends Labels to existing
Project views while retaining the other visible fields; it changes no Status,
grouping or single-select options. GitHub card background styling is not required.
Use the existing Blocked column for separately agreed action cards; existing cards
whose Status was explicitly chosen keep that Status and still show the label.
An optional `needed_by` explains timing; do not invent a date the user never agreed.

Multiple blockers may coexist. The `id` is stable: setting it again updates that
blocker instead of duplicating it. The CLI preserves the rest of the issue body and
unrelated labels. A malformed record or unexplained blocker/decider label fails
closed, with a PM reconciliation action. Never repair malformed data by deleting
unknown issue text.

Supported categories: `decision-required`, `missing-customer-input`,
`missing-estimate`, `dependency-open`, `provider-limited`, `review-required`,
`acceptance-evidence-missing`, `metadata-repair-required`. Owner and next action
remain explicit; category alone is not sufficient. User names are configuration
and issue data, not hard-coded taxonomy.

To resolve a blocker, provide a JSON file containing `evidence`; user-owned blockers
also require `user_authority`, referencing the actual decision or confirmed input:

```bash
squad blocker resolve 42 --id native-acceptance-authority-required --file resolution.json
```

Agreement, unrestricted quota, a closed issue and a completed job do not substitute
for that evidence. Specific bounded approvals may already have been consumed.
Resolved records remain in issue history. Managed attention labels are removed
only when no corresponding open structured blocker remains.

## Claims and metadata repairs

Every delivery claim requires `--readiness assessment.json`:

```json
{
  "inputs": "verified",
  "authority": "verified",
  "brief_blockers": [],
  "evidence": ["Current input-readiness report", "Specific applicable authority record"]
}
```

Use `not-required` only where that requirement genuinely does not apply. This is
an explicit agent assessment, not an automated proof of arbitrary product evidence.
The Administrator must inspect the cited records and the brief; scripts cannot
understand all natural-language instructions. Known issue blockers and readiness
metadata still independently prevent claims. A missing or negative assessment
cannot create a job.

Missing estimates, Stage or Responsible role generate a Project Manager repair:

```bash
squad repair-claim repair-42 --issue 42 --worktree /path/to/worktree --brief repair.md
```

This consumes an ordinary worker slot, selects the configured PM model, respects
pause/capacity and prevents duplicate ownership. Its scope is repairing metadata
from existing authority, not doing product implementation or approving new scope.
A missing Agreement may require recovering an existing decision or asking the user.
The default provisional repair allowance is 0.5 weekly percentage points for the
headroom check (`metadata_repair_estimate` can override it); unrestricted policy
waives voluntary pacing, never provider exhaustion. After repair, record the result,
acknowledge with a handoff and rerun readiness for the original execution role.

## Handoffs and recovery

Before `squad ack JOB`, run `squad handoff JOB --file handoff.json`. Required fields:

```json
{
  "completed": "Implementation and deterministic checks",
  "not_completed": "Independent acceptance",
  "evidence": "/path/to/report.md",
  "next_action": "Review the exact submitted head",
  "owner": "engineering-reviewer",
  "fresh_job_allowed": true,
  "transition": {"Stage": "engineering-review", "Responsible role": "engineering-reviewer"},
  "tracking": "Review assignment or linked issue"
}
```

A handoff does not itself change Project fields. Apply authorised Stage/role changes
through typed field commands. For a held item use `fresh_job_allowed: false` and
set `tracking` to its structured blocker ID. Acknowledging that job does not release
the hold: the blocker needs resolution evidence or a reconciled replacement handoff.
Legacy finished jobs also need a handoff before acknowledgement; do not erase them.

`ready`/`next` record the latest owned exclusions for agreed items. `recover` and
the handover expose them with the capture timestamp. Cached recovery data is not
current launch authority: every claim refreshes readiness. Worker death, failed
launch or missing evidence requires reconciliation, never a guessed completion.

## Data protection and read cost

Readiness batches Project items, values, labels and native prerequisites, paginating
only overflow connections. It uses the same bounded rate-limit handling as board
backups, without one dependency API call per issue. Blocker writes and visibility
changes take a complete fresh private versioned snapshot first. Issue changes keep
before/after journals and check for concurrent body/label changes; this is not an
atomic GitHub transaction. Stop and reconcile a partial or ambiguous write.
Project option IDs and historical Status values are never rebuilt or inferred.
