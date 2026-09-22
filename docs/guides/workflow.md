# The Squad method

Squad accelerates delivery of agreed work using subscription capacity effectively
and matching each assignment to an appropriate model. Optimise reviewed output,
not raw agent activity. The user owns direction, scope and external commitments.

## Roles and ownership

| Role | Responsibility | Codex default | Claude Code default |
| --- | --- | --- | --- |
| Administrator | Native session coordination, dispatch, continuation, recovery and gated merge | Luna | Sonnet |
| Project Manager | Planning, priorities, dependencies, role assignment, forecasting, planning/retro with user | Astra | Fable |
| Architect | Design, technical criteria, decomposition and initial time/cost estimates | Astra | Fable |
| Engineer | Test-driven implementation and evidence | Sol | Opus |
| Architecture Reviewer | Independent assessment of an immutable design revision | Astra | Fable |
| Engineering Reviewer | Independent code and integration review at a specific commit | Sol | Opus |

Project settings override defaults. The Administrator sets the model explicitly
when spawning and records the actual model. It escalates ambiguous planning to the
Project Manager and technical decisions to the Architect; it does not build.

## Delivery

Agree a bounded outcome with acceptance criteria. The Project Manager records
native dependencies, role/stage, priority, needed-by date, forecast and remaining
delivery estimate. Architecture and independent architecture review apply when
needed; an approved existing design can cover several engineering assignments.

The Engineer records red → green → refactor evidence. Non-executable work uses
appropriate acceptance checks with an explicit explanation. A separate Reviewer
checks the agreed criteria and a meaningful additional boundary/failure case.
The Administrator merges only the exact independently reviewed commit.

The Administrator dispatches independent eligible work within configured and
native concurrency limits. It processes each result promptly, without waiting for
unrelated workers. It uses native event waits when there is nothing else to do;
a model polling loop is not useful work. Fresh assignments get fresh workers.

## State and continuation

GitHub owns plans, scope, dependencies, review evidence and delivery status.
Durable local runtime records own job claims, worker identities, checkpoints and
completion acknowledgement. The Administrator owns continuation; every worker
records progress before a final handover can become necessary.

A handover summarises those records. It is not the sole wake mechanism and losing
a final comment must not lose the next action. Native subagent notification is the
normal continuation path. The conductor handles quota-reset wake-ups, unavailable
sessions and explicit external events. Duplicate notification/recovery paths use
the same job record and cannot assign an already-owned issue.

## Policy and interruption

User pause, voluntary quota policy and actual provider exhaustion are separate.
Persist a user's override immediately with the policy command. Unrestricted mode
waives Squad's voluntary limits, not the provider's limit. A reset never overrides
a user pause. Fresh readings verify that work can resume.

Checkpoint at meaningful boundaries and before long commands. Preserve changes,
tests, next step and background process identities. Do not assume a final model
request will be available. On recovery inspect files, native workers and surviving
processes before replacing an assignment. Never discard an interrupted worktree.

## Improvement

The Project Manager updates forecasts from actual work including review/rework.
Needed by and Forecast finish remain distinct. Earlier starts are allowed once
real prerequisites clear. At retrospectives inspect avoidable idle time, result-
to-dispatch delay, recovery outcomes and reviewed output per subscription use.
Separate deliberate pauses and unavailable capacity from workflow-caused idleness.

See [runtime commands](../reference/runtime.md) and [migration](migration.md).
