---
name: Piece
about: One bounded unit of work, built on one branch and closed by one pull request
title: ""
labels: type:piece
assignees: ""
---

## Why

In plain words anyone on the team can follow: the reason for this piece, what goes wrong or stays missing if it is not done, and the goal or milestone it brings closer.

## What

What this piece produces, and what changes for a person once it is done.

- The files, documents or behaviour it delivers.

**Out of scope:** what this piece deliberately leaves alone, so the branch stays small.

**Dependencies:** what must exist before it can start, including anything only {{DECIDER}} can do. Link the issues.

## How

The approach, in a few steps.

- [ ] First task
- [ ] Second task

**Acceptance test:** the exact commands or checks that prove the piece works, and what a pass looks like, written before the work starts. Anyone should be able to run it without asking a question. Fixtures come from the architect or the Reviewer, never from the Engineer.

**Size:** a pull request of about 400 non-test lines at most; a bigger piece is split in dependency order.

**Design critique:** would a simpler, more general or less duplicated shape do the same job? If yes and cheap, adopt it here. If yes and expensive, open a backlog issue naming the trigger that makes it worth doing. If no, say why in a sentence.

**Estimate in credits %:** the planned share of the weekly limit, for example 4%, and the basis for the number.

**Tracking metadata:** set Responsible role, Stage, Agreement, Design (Required/Approved/Existing), Priority, Needed by, Forecast finish, Estimate (hours) and remaining Estimate (credits %) on the Project. Record prerequisites with native blocked-by relationships. Labels describe type/component; Assignees name real GitHub accounts.

**Architecture evidence:** link the approved immutable design revision and independent review, or the existing design covering this piece.
