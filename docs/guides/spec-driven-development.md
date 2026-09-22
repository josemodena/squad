# Integrating Squad with Spec-Driven Development

Spec-Driven Development (SDD) makes an agreed specification the reference for
planning, implementation and validation. Squad supplies the delivery workflow:
roles, dependencies, model routing, independent review and durable continuation.
You can use a specification written by hand or produced by your preferred SDD
tool. Squad has no built-in connector to a particular SDD framework and does not
synchronise external specification formats automatically.

## Give each artifact one owner

| Artifact | Owner | What it answers |
| --- | --- | --- |
| Product specification | User, supported by Project Manager | What outcome is agreed, for whom, and what is excluded? |
| Delivery plan and GitHub issues | Project Manager | Which pieces deliver it, in which order, by when? |
| Technical design | Architect | How will the system satisfy the specification? |
| Design review | Architecture Reviewer | Is that design sufficient and testable? |
| Code and tests | Engineer | Does the implementation satisfy the agreed criteria? |
| Implementation review | Engineering Reviewer | Does this exact revision meet the criteria without regressions? |
| Jobs, checkpoints and continuation | Administrator | Who is working, what finished, and what happens next? |

The user decides scope. A specification file alone is not permission to execute.
The Administrator dispatches agreed, eligible work and does not resolve product
ambiguity by inventing requirements. The conductor remains an external recovery
mechanism; it does not manage the specification.

## 1. Write and agree a small specification

Keep specifications in version control, for example `specs/001-export/spec.md`.
Use stable requirement identifiers so tests and review reports can refer to them.
A useful starting template is:

```markdown
# Export report
Status: Draft

## Outcome
A user can export the currently filtered report as CSV.

## Acceptance criteria
- EXPORT-01: Export contains only rows matching the current filters.
- EXPORT-02: Commas, quotes and newlines round-trip through a CSV parser.
- EXPORT-03: An empty result produces headers and no data rows.

## Constraints
Existing access controls apply to the export.

## Exclusions
Scheduled delivery and additional export formats.

## Open questions
Maximum supported export size: user decision required before implementation.
```

Resolve questions that affect the intended implementation, agree the scope with
the user, and record that decision. Keep the agreed revision identifiable by a
commit SHA. Do not put customer data or credentials in specifications.

## 2. Turn the specification into a delivery plan

Invoke `$squad:project-manager` in Codex or `/squad:project-manager` in Claude Code:

> Plan delivery of specs/001-export/spec.md at its agreed commit. Create bounded
> issues with requirement IDs, acceptance criteria, exclusions and dependencies.
> Identify any design work and decisions still needed. Record my agreed scope;
> do not broaden it. Propose Needed by dates and delivery forecasts separately.

Each issue should link to the agreed specification revision and say which IDs it
covers. Record Agreement, Stage, Responsible role, Design, Priority, Needed by,
Forecast finish and remaining effort in the Project. Use native issue dependencies
for prerequisite issues. GitHub Assignees are accounts; the Responsible role field
holds Squad roles. Labels describe type or component.

Avoid maintaining two independent task-status lists. The board owns delivery
status; the specification owns intended behaviour. A checklist in a specification
may summarise coverage, but should link to the authoritative issues.

## 3. Design and independently review when needed

The Architect writes the solution, requirement-to-design mapping, failure cases,
technical success criteria and effort estimate. The Architecture Reviewer checks
that exact design revision against the agreed specification. Record approval and
link the report before setting Design to Approved and advancing to engineering.
Routine changes can use Design = Existing when an approved design already covers
them; SDD does not require a new architecture document for every small fix.

## 4. Implement with traceable tests

The Administrator dispatches eligible work through the normal Squad workflow.
The Engineer references requirement IDs in tests or the test report, demonstrates
a meaningful failing test, implements the behaviour, then refactors with tests
passing. Use appropriate acceptance checks for documentation or other deliverables
that do not have executable tests.

A compact issue/report mapping is enough:

| Requirement | Evidence | Result |
| --- | --- | --- |
| EXPORT-01 | Filtered export integration test | Pass at reviewed SHA |
| EXPORT-02 | CSV round-trip test with punctuation and newlines | Pass at reviewed SHA |
| EXPORT-03 | Empty-result test | Pass at reviewed SHA |

A passing test suite alone is not evidence that every requirement is covered.
Include non-functional criteria and explicitly identify untested assumptions.

## 5. Review the specification and exact implementation together

The Engineering Reviewer reads the agreed specification revision, approved design,
issue criteria and current main. It checks the PR's exact head, tests behaviour
and records gaps. The Administrator uses Squad's guarded merge after a passing
independent review; changing the code after review requires a fresh review.

Link the merged PR and review evidence back to the issue. The Project Manager
updates completion and forecasts, then conducts the retrospective with the user.
Do not call the specification delivered while required dependent issues remain open.

## 6. Handle changes and interruptions explicitly

If implementation reveals a product ambiguity, checkpoint the work and record a
specific question. The Project Manager obtains a scope decision, updates the
specification and affected issues, and re-evaluates dependencies and estimates.
A changed technical design returns to architecture review when the earlier
approval no longer applies. Routine implementation detail within agreed scope
does not require another product approval.

Include the specification SHA, design revision, requirement IDs, test evidence,
remaining work and next step in durable job reports/checkpoints. After exhaustion
or a crash, the Administrator reconciles live workers and recovers those records.
It must not restart from a newer, unagreed specification just because that file
now exists. See [continuation and recovery](workflow.md).

## Start small

Use one specification and one delivery cycle first. Confirm that an independent
reviewer can trace every agreed criterion to evidence without needing the author's
chat history. Then expand to multiple issues and parallel work whose prerequisites
are satisfied. The same SDD process applies to both plugins; their native model
selection and unattended recovery capabilities remain different.
