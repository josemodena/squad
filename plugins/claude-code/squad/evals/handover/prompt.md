---
name: handover
description: A hand-over carries the marker line and the same four sections every time.
tags: [smoke]
runs: 1
max_turns: 12
timeout_seconds: 420
allowed_tools: [Read, Glob, Grep, Skill]
---

I am nearly out of context. One agent is still running: issue 42, branch piece-42-x, its log is at /var/log/run.log and it ends with DONE. The next thing to do is read that log and brief a fresh builder. Nothing else is waiting except the daily boundary at 17:00 UTC.

Write the hand-over that goes on the sprint issue. Show me the exact text of the comment.
