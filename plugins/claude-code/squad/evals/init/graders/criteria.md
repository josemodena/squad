---
type: llm
focus: last_message
---

PASS if the answer both asks the setup questions and lists what gets created. The questions must include the repository and the board, who decides (the Decider), and the tracks and owners the work is filed under. The list must include labels for the kinds of issue (piece, sprint, retrospective) and the board fields, naming at least Status, Track, Owner, an estimate field and a sprint or iteration field.

FAIL if it does not ask any questions before setting things up, or if it names no labels, or if it names no board fields, or if it invents a project name or a person.
