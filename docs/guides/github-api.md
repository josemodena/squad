# Keeping GitHub API usage low

Squad works with a free GitHub account. No paid GitHub plan, GitHub App, extra
account or public webhook server is required for these optimisations.

## Read once, check again before starting

`board`, `ready` and `next` share a local board copy for up to 60 seconds. Their
standard-error output says whether the data came from GitHub or the cache, when
it was captured and its age. JSON output remains compatible with existing callers.
Use `--fresh` when you know someone changed the board and need to see it now.

Each delivery, repair or PM claim reads its selected issue directly from GitHub.
It checks current Project membership, fields, blockers, labels and dependencies;
it never accepts cached eligibility as permission to start. Dependency and field
pagination must complete before a claim can proceed. Existing local ownership
checks still prevent duplicate claims. A failed read does not fall back to stale
permission. As before, GitHub has no transaction spanning a read and a later claim.

Routine reads request scalar planning fields with smaller nested pages. Full
backups still capture the complete supported board data, including option IDs and
views. The cache is disposable and is **not a backup**.

## Update a handoff together

Instead of writing each field separately, create a JSON file:

```json
{
  "Stage": "engineering-review",
  "Responsible role": "engineering-reviewer"
}
```

Then run:

```bash
squad fields 42 --file handoff-fields.json
```

Squad takes one fresh, versioned board snapshot, validates every requested field
and value before writing, skips unchanged values, journals the changes and checks
the affected item afterward. Existing option IDs are used directly. Status is
changed only if you explicitly include it. A batch is not an atomic GitHub
transaction: if a write or verification fails, inspect the journal and current
state before retrying. Never assume that no writes happened.

Blocker updates change issue bodies and labels, not Project fields. They now save
a versioned backup of the affected issue and an update journal instead of exporting
the whole board. Board restore consumes board snapshots; issue backup records
retain the previous body and labels for deliberate issue recovery.

## See usage and waiting times

```bash
squad api-status
```

This local command shows request counts, measured GraphQL read-query points,
errors and limits by repository and operation, plus remaining budgets and reset
information from response headers. Counters are cumulative from installation of
this version. Mutation points are not included in the read-query point total.
No credentials, query bodies or response bodies are written to this metrics store.

The coordinated transport covers typed runtime REST operations, readiness,
claims, board backups/restores, field and blocker changes, and the init GraphQL
adapter. Some older shell helpers and direct `gh` commands still run outside it;
the counters are not an account-wide usage audit. Prefer typed commands for
routine execution. All tools using your GitHub identity can consume its allowance.

A primary rate limit pauses the affected API budget. A secondary limit pauses
both coordinated REST and GraphQL requests. Squad records the cooldown for other
local processes, honours the reset or Retry-After value, and increases the delay
for repeated limit responses. It returns promptly rather than tying up an agent
with sleeping retries. Ambiguous mutations are never automatically replayed.

The conductor checks the durable wait and can wake the Administrator after it
expires. It respects user pauses and model-capacity limits. Without a conductor,
resume manually after the displayed time. Already-running agents may continue
local work; actions requiring fresh GitHub data must wait.

## Multiple projects and harnesses

API coordination defaults to `~/.local/state/squad/github`, shared by local Squad
processes on the same GitHub host. A shared request lock also spaces coordinated
writes by at least one second. REST and GraphQL primary budgets remain separate.
The default conservatively groups all credentials on that host.

Board caches are separated by host, budget key, repository, Project owner and
Project number inside the runtime directory. Configure both harnesses with the
same runtime directory to share a project's reads. They can share an API budget
without sharing project data. Separate machines need a different coordination
solution; these locks only coordinate processes on one machine.

| Setting | Default | Use |
| --- | --- | --- |
| `github_cache_seconds` | `60` | Cache lifetime, bounded to 0–300 seconds; 0 always refreshes |
| `github_state_dir` | `~/.local/state/squad/github` | Shared private budget/cooldown directory |
| `github_budget_key` | `default` | Separate genuinely independent account/installation budgets |

Projects using the same account must keep the same budget key and directory.
Creating another personal token for that account does not create a new allowance.
Do not delete cooldown state or change keys to bypass a limit.

## Measured example

A read-only comparison against the same 117-item board returned identical
populated planning fields and readiness decisions. The previous full-board query
used 157 GraphQL points; the narrower query used seven. Both made four requests.
A subsequent cached read used no request, and a targeted issue read used one
request and one point. Savings depend on each board's size and fields; use
`api-status` to measure your own workload.

## REST, polling and future options

`issue-read` and `pr-read` use paginated REST reads, preserving the command output
shape. PR reads refuse incomplete file lists. Reply observation also uses REST;
unchanged single-page results can use ETag validation. Its cursor remains stable
when no newer comment appears. Edited replies and newly watched requests still
receive the existing validation and deduplication.

Project REST endpoints were probed read-only during this release. Their default
item response was not a replacement for Squad's complete readiness data. The
release retains GraphQL for planning fields and dependency checks. A future
adapter needs explicit field selection, authentication and parity tests before
replacing those reads.

Webhooks can reduce polling further, but require endpoint hosting, signature
verification, delivery recovery and appropriate Project-event access. This
release does not install a receiver or require you to expose a server. The
existing bounded observer remains the default.

See GitHub's [GraphQL limits](https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api),
[REST best practices](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api)
and [Project item REST endpoints](https://docs.github.com/en/rest/projects/items).
