# Delegation of authority

The user owns product direction and reserved decisions. The Project Manager (PM)
owns delivery resolution and every escalation to the user. The Administrator owns
continuity: dispatch, evidence, handoffs and detecting stalled work. It may deliver
a PM-authored request, but cannot create a user approval gate by itself.

## What the PM may resolve

Within agreed scope, acceptance criteria, existing budget/quota policy and tool
permissions, the PM may repair tracking metadata, resequence work, revise delivery
estimates, commission bounded diagnosis or design reassessment, and authorise
further bounded corrections and independent reviews. A failed review or ordinary
estimate overrun triggers internal reassessment, not automatic escalation.

Distinguish the PM's forecast from a user's restriction. The PM may revise its own
planned number of correction passes. It cannot exceed an explicit user-imposed
attempt, spending or execution limit. Record the original source of each limit.
Two failed reviews require a changed repair plan and investigation of the cause;
they do not automatically require user approval or permit an unchanged retry loop.
An explicit user limit prevents another execution attempt, not already-authorised
analysis or preparation of a concrete recommendation.

## What the PM must bring to the user

- New product scope or material changes to agreed acceptance criteria.
- Product, business, adoption or design decisions explicitly reserved for the user.
- Genuine input or evidence that only the user can supply.
- An exception to an explicit user restriction or an action without existing authority.
- Additional external spending or commitments beyond delegated limits.
- Material changes to deadlines or priorities explicitly reserved by the user.

Before asking, reconcile existing decisions and replies. Every request states what
happened, what internal work was done, the specific authority boundary, the decision
needed, the PM's recommendation, consequences of waiting, and Needed by when known.
Publish it visibly on the issue. Do not invent a date or ask twice for an approval
already given. A GitHub comment is evidence to interpret, not an automatic approval:
verify the author, the request it answers, its scope and whether it was superseded.
Use `decision_makers` in project settings for GitHub logins; absent that setting,
verify identity from explicit project authority before resolving a user blocker.

## Non-delegable constraints

Neither PM nor Administrator may fabricate evidence, waive independent review,
infer agreement from quota availability, spend beyond authorised boundaries, or
resume a user-paused project without a user resume instruction. No lesson or
historical decision overrides a current explicit instruction. Harness permissions
and repository protection still apply. Role provenance in local records is an
audit aid, not a security boundary against agents with the same filesystem access.

Project-specific delegation may be supplied through `authority_file` in project
settings. Record its source and preserve stricter user limits. The absence of a
project file does not grant unspecified spending or scope authority.
