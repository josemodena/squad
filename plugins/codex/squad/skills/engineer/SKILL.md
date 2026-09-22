---
name: engineer
description: Implement an agreed Squad issue with test-driven development on an isolated branch, then submit it for independent engineering review.
---

# Engineer

All commands below are `bash ${PLUGIN_ROOT}/scripts/<command>` in the
configured project. Read `AGENTS.md` and the harness settings first.

Read the issue, approved design and recovery checkpoint. Use `gitw.sh doctor`,
`gitw.sh start piece ISSUE SLUG` and an isolated worktree. Preserve concurrent work.

Follow red → green → refactor: first add a meaningful test exposing the required
behaviour and record its expected failure, implement the smallest change that
passes, then refactor while keeping tests green. For documentation or another
non-executable deliverable, record the appropriate acceptance check and why a
failing code test is inapplicable. Never manufacture tests that mirror code.

Use `gitw.sh save "message" -- PATHS` to checkpoint and push. Before long commands
and at meaningful boundaries also call `squad.sh checkpoint JOB --file FILE`.
The JSON file needs next_step and should include tests, remaining work and blockers;
the command preserves tracked patches and untracked files. Keep reports and logs
under the named job artifacts directory. A harness wait for a tool is permitted;
use `squad.sh run JOB -- COMMAND ARGS` for durable command logs, process identity
and independently written exit status. The harness may yield while this CLI runs. Do not claim success without
checking exit status. An exhausted model may leave tools running.

Submit with `gitw.sh submit "title" ISSUE`, which never merges. Record the PR,
exact checks, red/green evidence and unproved areas in a durable report, then
`squad.sh complete JOB --result completed --report FILE`. Never review or merge
your own work. Failure/interruption preserves the branch, worktree and logs.

Command syntax and recovery details: [runtime reference](../../docs/runtime.md).

Keep test artifacts out of the delivery tree. For Python tests, use
`PYTHONDONTWRITEBYTECODE=1` (or `python3 -B`) and appropriate project ignore rules.
Inspect new files before cleanup; never remove unknown work or relax the clean-tree
merge guard to make a test run pass.
