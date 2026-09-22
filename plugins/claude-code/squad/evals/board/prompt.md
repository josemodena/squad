---
name: board
description: The board is read and changed through the tracker script, and an empty board is a real answer.
tags: [smoke]
runs: 1
max_turns: 10
timeout_seconds: 420
allowed_tools: [Read, Glob, Grep, Skill]
---

Show me what is on the board, and then move issue 42 into the "In progress" column. I want the exact commands to run, not a description of them. The board may well be empty; say what that looks like.
