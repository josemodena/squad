---
type: llm
focus: last_message
---

PASS if the answer gives the text of a hand-over comment that carries all four sections, in any wording close to these: the state of the tree, the agents in flight, the next actions in order, and the waits. The agent in flight must be shown with its issue, its branch, its log path and the marker DONE, and the wait must carry 17:00 UTC.

FAIL if any one of those four sections is missing from the comment text, or if the agent in flight is shown without its log path or without the marker.

Notes the answer adds around the comment, such as which parts a script fills in or what must be configured first, do not make it fail.
