# Squad runtime command reference

Run `squad COMMAND` from the configured project (or the bundled `bash <plugin>/scripts/squad COMMAND`). All new
commands return JSON. Failures return a non-zero exit code and JSON on stderr.
The CLI never invokes a model. `runtime.sh` exposes the same new commands directly.
Python 3 (standard library), Git, GitHub CLI and the existing Bash tools are required.

## Planning and tracking

- `issue-create --key STABLE_KEY --title TITLE --file PLAN`: repeatable creation,
  using a durable body marker and paginated reads to reconcile a lost response.
  The issue is added to the Project; configure its metadata before dispatch.
- `issue "TITLE" --track TRACK --owner OWNER --body-file FILE`: existing issue creation.
- `issue-read ISSUE`, `pr-read PR`, `comment ISSUE --file FILE`: bounded reads and comments.
- `field ISSUE "FIELD" VALUE`: set typed metadata; validates options/dates/numbers.
- `dependency list ISSUE`, `dependency add ISSUE PREREQUISITE`,
  `dependency remove ISSUE PREREQUISITE`: native blocked-by relationships within
  the configured repository. GitHub rejects cycles and invalid relationships.
- `ready`: current project items in priority/deadline order, with eligibility and
  explicit reasons for exclusions. Reads all project pages and native dependencies.
- `models`: configured role-to-model map. `models --check-upgrades` reports Codex
  catalogue suggestions without modifying settings, jobs or sessions.

`init.sh apply` adds Responsible role, Stage, Agreement, Design, Priority,
Forecast finish and Estimate (hours), retaining existing fields. The standard
fields are deliberately named consistently across both plugins. Needed by is a
requirement; Forecast finish is a forecast, never an embargo. Priority is ordered
P0–P3. Labels describe type/component. Assignees identify GitHub accounts.

Eligibility requires an open agreed item in This sprint/In progress/In review,
a recognised Stage/Responsible role pair, closed prerequisites and a non-negative
remaining delivery estimate. Engineering additionally requires Design Approved
or Existing. Voluntary headroom applies unless policy is unrestricted. A user
pause always blocks dispatch. Unknown metadata fails visibly rather than guessing.

## Execution

```bash
squad claim job-42-engineer-1 --issue 42 --role engineer \
  --worktree /path/to/worktree --brief /path/to/brief.md --readiness /path/to/assessment.json
squad bind job-42-engineer-1 --worker WORKER_ID --model gpt-6-sol \
  --thread THREAD_ID --turn TURN_ID --rollout /path/to/rollout.jsonl
squad checkpoint job-42-engineer-1 --file /path/to/checkpoint-input.json
squad complete job-42-engineer-1 --result completed --report /path/to/report.md
squad ack job-42-engineer-1
```

The examples abbreviate the executable prefix. Claim is atomic under a project
lock, rejects an already-owned issue, enforces max_workers (default 3), records
the brief and expected model before spawn. Spawn through native harness tools,
then bind the returned identity. Never spawn if claim fails. Actual model mismatch
and author/reviewer identity reuse fail. Thread/turn/rollout are Codex-specific;
Claude records its native worker identity. A lost spawn response requires native
reconciliation, never a blind second spawn.

Checkpoint input is JSON containing `next_step`, optionally `tests`, `remaining`,
`blocker`, `report` and background process/log details. The command preserves HEAD,
a binary tracked patch and an archive of untracked, non-ignored files. It does not
reset, clean, commit or remove the original worktree. Ignored files remain there.
Checkpoint at meaningful boundaries and before long work; also save/push with
`squad git`. Checkpoints preserve artefacts, not unwritten model reasoning.

`run JOB -- COMMAND ARGS` records supervisor/child identities, streams output to
a durable job log, and saves exit status independently of a model response. The
harness can yield while this command runs. An interrupted supervisor records
unknown status where possible; inspect the recorded process before retrying.

Completion accepts completed, failed, interrupted or cancelled. Reports must
already exist. Repeating the same completion is harmless; conflicting completion
fails. `ack` acknowledges a handled terminal result, not an interrupted worker.
Update the board before acknowledgement. Interrupted work stays owned until
`squad retry JOB --reason TEXT` records reconciliation; replacement uses a new
job ID. Check native state and surviving processes first. Never retry a still-live
worker. Completed assignments are never reused for a different role.

`recover` produces a compact brief of unfinished/unhandled jobs and effective
policy. `state` includes the full execution history. `settle --through REVISION`
acknowledges external events only through the revision actually inspected; later
arrivals survive. `external ID --reason TEXT` records a stable, deduplicated wake
request, for example a decision or dependency change made outside a live session.

## Reviews and merging

`review-prepare PR` fetches main and the exact PR head, creates a detached worktree
under runtime storage, and merges that head for integration testing. It returns the
reviewed head and worktree. On conflicts, preserve and inspect the worktree.

`review-record PR --head SHA --verdict pass|fixes-required|do-not-merge --file FILE`
rejects a changed head and records the evidence plus review label. Normal review
completion uses native notification, not a conductor event. The Administrator
merges with `squad git finish PR ISSUE`; it checks the marker, label, local-main
safety and passes the exact head to GitHub's merge guard. Engineer submission is
`squad git submit "TITLE" ISSUE` in both plugins and never merges.

## Policy, pause and recovery

```bash
squad policy
squad policy --mode unrestricted --reason "User waived voluntary limits"
squad policy --mode weekly --reason "Use weekly cap without daily pacing"
squad policy --mode pacing --reason "Restore ordinary pacing"
squad pause --reason "User paused delivery"
squad resume --reason "User explicitly resumed delivery"
```

An optional `--until EPOCH` expires a policy override, returning to the configured
quota_mode. Policy is saved under the project runtime and read by both quota
readers and dispatch. Unrestricted disregards voluntary pacing/caps; actual
provider exhaustion and stale readings still block. Codex retains reported short
and weekly provider windows. Reset time is a cue to refresh, not proof of capacity.
Claude requires its usage collector to refresh; stale readings cannot wake work.

Runtime defaults to `<scratch_root>/runtime`; `SQUAD_RUNTIME_DIR` overrides it.
Keep it on durable local storage. Never share a scratch root between unrelated
projects. Both harnesses for the same project share claims/policy, preventing
cross-harness duplicate assignment. Legacy conductor hold files remain additional
pause gates; neither a quota reset nor runtime resume deletes them automatically.

Codex `wake` reconciles only exactly matched native thread/turn records. A worker
ending without completion becomes interrupted for inspection; it is not assumed
to have produced correct work. The external conductor submits recovery only when
capacity allows, and its gateway remains the sole authority for starting the
Administrator turn. Native completion is the normal path. Capacity waits retain the minimum required headroom and wake only on a real
transition to sufficient capacity. Durable command completion produces a fresh
event even after the supervising agent ends. Empty durable state does
not create dummy turns. Seed the first recovery with an external event or start
the Administrator interactively.

## Measurement

`observe --reason REASON --eligible N --capacity N` records an idle/active interval
boundary. `ready` also records eligibility. `metrics` reports measured intervals,
avoidable idle time, reasons, completion-to-next-assignment delays and completed
review assignment counts. Unknown historical intervals are not fabricated.
Record pauses, provider exhaustion, external dependencies and available work
separately. Account usage while jobs overlap is shared, not additive per-job cost.

## Board data protection

`bash ${PLUGIN_ROOT}/scripts/board-backup.sh snapshot` saves API-visible board data
in local Git history. Use `${CLAUDE_PLUGIN_ROOT}` on Claude Code. `snapshot --dry-run`
exports JSON only. `restore FILE --dry-run` produces the full proposed diff and
blockers. Apply requires `--apply --confirm PROJECT_NODE_ID --plan CONFIRMATION_HASH`
from that reviewed preview. `--status-only` restricts recovery to the configured
Status field. A changed observed board invalidates confirmation.

Snapshots and journals are private, retained by default, and separated by GitHub
host/owner/project number beneath `board_backup_dir` or `<scratch_root>/board-backups`.
They must not be pushed into a public source repository. Snapshot failure blocks
protected writes. GitHub has no atomic whole-board restore; reconcile the journal
and a fresh preview after any interruption. Deleted identities and unsupported
view changes are blockers, not permission to recreate or guess them.

See the [backup and recovery guide](https://github.com/josemodena/squad/blob/main/docs/guides/board-backup.md).

## Direct Project Manager meetings

Use `bash ${PLUGIN_ROOT}/scripts/meeting.sh start planning` (or `start retro`)
in Codex; use `${CLAUDE_PLUGIN_ROOT}` in Claude Code. These create interactive
main sessions in a new Zellij tab, with explicit configured model and effort.
Do not use a subagent or relay the user's conversation. `checkpoint KIND --file
NOTES [--session-id UUID]` saves durable context; `complete KIND --file OUTCOME`
adds an external runtime event without changing pause state. Read these events
through `recover` at coordination boundaries. Exact transcript resume needs a
recorded native UUID; otherwise recovery uses checkpoint notes. `status KIND`
shows the record and `reconcile KIND --reason TEXT` resolves a confirmed ended
launch when its tab is absent. Meeting launches do not claim worker jobs.

## Owned blockers and continuation

`next` returns dispatches, bounded PM repairs and named external waits. `ready`
returns `claimable`, `blockers` (category, owner, next action, requires_user) and
`metadata_repair`. `repair-claim JOB --issue N --worktree PATH --brief FILE` assigns
existing-scope metadata maintenance to the PM without claiming blocked delivery.
Use `handoff JOB --file JSON` before `ack JOB`; completed/not-completed, evidence,
next action, owner, fresh-job permission, transition and tracking are mandatory.
`recover` exposes timestamped last-read exclusions. See the full guide in the
repository at `docs/guides/blockers.md`.

Bundled blocker commands are `bash ${PLUGIN_ROOT}/scripts/blocker.sh set ISSUE
--file JSON`, `resolve ISSUE --id ID --file RESOLUTION`, and `visibility`; Claude
uses `${CLAUDE_PLUGIN_ROOT}`. They preserve Status and back up before writes.

## PM resolution, replies and startup context

Use `pm-claim JOB --issue N --worktree DIR --brief FILE` for stopped-work diagnosis.
It does not authorise blocked implementation. Pauses, capacity and duplicate ownership
still apply. `next` reports `resolve-with-pm`; only PM-authored user requests are
published through `blocker set --pm-job JOB` or `--pm-session UUID` provenance.
New requests also require `authority_boundary` and `consequence` fields. Legacy
blockers remain readable and are routed for PM assessment rather than discarded.

`inbox poll` imports GitHub replies without treating them as approvals. The
conductor calls it on a bounded cadence. `inbox status` reports health; `inbox watch
--issue N --since ISO_TIMESTAMP` registers old requests. A PM resolution handoff
must record `reply_disposition` for a consumed reply. Later replies remain pending.

`context ROLE [--issue N]` loads the role contract, delegation and reviewed records.
Claims persist the packet at the returned `context` path. `memory add --file JSON`
proposes a lesson or decision; `memory review --id ID --file JSON --pm-job JOB`
reviews it (a captured `--pm-session UUID` is also accepted). `memory list` shows
committed project records. See the documentation's decisions-and-learning guide
for schemas, privacy, retention, authority boundaries and observer limitations.
