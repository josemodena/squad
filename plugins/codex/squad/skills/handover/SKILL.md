---
name: handover
description: Summarise durable Squad execution records and agreed next actions for a session handover or recovery.
---

# Handover

The Administrator owns continuation. Workers checkpoint their own progress;
the Project Manager owns the agreed plan. Read `squad.sh recover` and the board.
Write a human summary using the existing `handover.sh` command: tree, running
jobs, next actions, waits and relevant events. Durable claims and checkpoints
already exist before this comment; recovery must work even if it cannot be posted.

On restart inspect native worker identities and any surviving background commands
before replacing interrupted work. Never delete uncommitted changes. Native
subagent completion handles normal progression; a handover does not instruct the
Administrator to end a healthy turn just because workers are running.

Legacy five-section handovers remain readable for migration. New projects use
native continuation; do not fabricate wake IDs to compensate for missing records.
