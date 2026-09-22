# Board backups and recovery

GitHub Project fields and item values are separate from repository history. An
issue's closed state does not reconstruct its former Project Status. Squad keeps
local, Git-versioned copies before its migration, option updates and board writes.
Existing single-select options retain their IDs, names, colours and descriptions;
missing names are appended, and an unchanged option list requires no mutation.

## Export and save

Run inside the configured project, selecting a harness explicitly when necessary:

```bash
squad --harness codex board snapshot --dry-run
squad --harness codex board snapshot
```

`--dry-run` reads the complete API-visible board and prints JSON without writing a
snapshot or changing GitHub. It may initialise the local backup directory/lock.
The normal command prints the saved snapshot path and creates a local Git commit.
Both commands refuse partial API responses, unreadable items, unsupported value
types or failed pagination. Snapshot creation must succeed before protected writes
can proceed. Existing items and views are never inferred from repository issues.

Exports contain project identity, fields, option IDs and metadata, iteration
configuration, all readable items (including archived items and draft content),
issue/PR IDs and repository identifiers, and item field values. Views include
layout, filter, visible fields, grouping, vertical grouping and sorting exposed by
the API. UI-only state, aggregations and workflows are not captured. Redacted items
block a complete snapshot; use an identity with access to every item.

Reads are paginated and request only relevant data. Overflow connections are
fetched in batches; a normal snapshot does not make one API request per item.
Stop other writers during recovery. GitHub does not offer cross-request snapshot
isolation; a changed project timestamp is rejected, but that check cannot detect
every concurrent item edit or external automation.

## Storage, multiple projects and retention

Default location:

```text
<scratch_root>/board-backups/<GitHub host>/<owner>-<project number>/
```

Set `board_backup_dir` in the harness settings to choose a different durable base.
The namespace is still appended. The GitHub host comes from `GH_HOST`, defaulting
to `github.com`. Two projects sharing a base have independent Git repositories,
lock files, snapshots and journals. Multiple local workers managing the same board
should use the same base. A stored project ID prevents a reused namespace from
silently accepting a different board, and restore checks host and project ID.

The backup repository is local and is never pushed by Squad. It uses its own Git
identity, disables commit hooks/signing, and ignores inherited Git directory/index
variables. Keep it outside a public source checkout. Directory access is restricted
to the local user; snapshot files are private. Draft bodies and issue titles can
be sensitive. The directory is not encrypted and is not an off-machine backup.

**Retention:** retain every snapshot, journal and Git commit by default. No automatic
pruning or expiry is performed. Periodically copy the entire backup repository to
private backup storage. Keep at least the before/after pair and journals for each
migration or recovery until its outcome is verified. Any later pruning is a manual,
owner-approved maintenance task; deleting a JSON file alone does not remove it
from Git history. Do not delete a project's history just because a sprint closed.

## Preview a restore

```bash
squad --harness codex board restore /path/to/snapshot.json --dry-run
```

This takes and versions a fresh snapshot, validates the selected backup's schema
and checksum, and prints a complete diff plan with blockers. There are no GitHub
writes. Review the project ID, changed items and views, and unsupported differences.

To restore only Status (or the configured `status_field`):

```bash
squad --harness codex board restore /path/to/snapshot.json --status-only --dry-run
```

This explicitly excludes other fields and views. It is useful when a full restore
would overwrite later intentional changes. Never use it to conceal an unresolved
problem with a view or another field.

## Apply the reviewed repair

```bash
squad --harness codex board restore /path/to/snapshot.json \
  --apply --confirm PROJECT_NODE_ID --plan CONFIRMATION_HASH
```

Use the exact project node ID and `confirmation` hash shown in the dry-run, retaining `--status-only` if
that was the scope reviewed. Apply takes a new snapshot and prints a new plan
before writing. The confirmation is bound to the source snapshot, project, scope and observed board
state. A changed board invalidates it; inspect a new dry-run and confirm that plan.
Keep other writers stopped throughout the operation.
Any known blocker or insufficient API budget prevents **all** writes from starting.
A final snapshot verifies the restored supported values.

Supported custom values are text, number, date, single-select, multi-select and
iteration selections on existing fields/items. Single-select metadata updates
preserve every existing option ID. The command does not recreate deleted fields,
items, iterations, views or option IDs, and does not guess replacements by name.
Membership or identity changes require reconciliation first. Derived issue fields
such as assignees and labels are exported; changes to them are not restored through
the Project field mutation and block a full restore.

Existing view name, layout, filter and visible-field configuration can be restored.
Grouping, vertical grouping and sorting are currently export-only: GitHub's view
update input does not expose them. A difference blocks full restore and requires
manual repair in GitHub. Unsupported settings are never reported as restored.
See [GitHub's Project API reference](https://docs.github.com/en/graphql/reference/projects).

## Limits and interrupted operations

Requests are serial. Secondary-limit retries wait at least 60 seconds and then
back off exponentially, honouring longer `Retry-After` or primary-reset headers.
There are at most three retries per request, with a maximum permitted wait of
300 seconds per retry; a longer required wait stops the operation. Mutations are
spaced by at least one second. Authentication and validation failures are not
retried. Partial GraphQL mutation responses are never blindly replayed.

A rate-budget preflight cannot reserve capacity or predict secondary limits.
**GitHub has no transaction for a whole-board restore.** A failure after writes
begin can leave a partial result. Each write has a durable before/in-flight/applied
journal entry; on any failure Squad stops. Inspect that journal and take a fresh
dry-run to reconcile the actual board before continuing. A lost response may mean
that the last write succeeded even if it was not acknowledged. There is no blind
automatic rollback or whole-plan retry.

If the pre-incident option IDs were already deleted, an old snapshot cannot make
those IDs valid again. Preserve it, inspect the currently valid options, and prepare
an explicitly reviewed item-to-option repair mapping. A historical issue state or
sprint name alone is not authority to rewrite the board.

Rate-limit behaviour follows GitHub's [GraphQL guidance](https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api)
and [REST guidance](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api).
