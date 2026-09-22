# Direct planning and retrospective meetings

Ask the Administrator “Let's plan the next sprint” or “Let's run the retrospective”.
It opens a new Zellij tab in your project with the Project Manager as the main
agent. Talk directly there; the Administrator does not relay the conversation.
Already agreed work can continue in the original session unless you pause it.

The launcher uses `project_manager_model` from the selected harness's settings
(Astra for Codex, Fable for Claude Code by default), and `project_manager_effort`
(default `high`). It passes both explicitly to the interactive CLI, never a
headless worker. Model access still depends on your account: a CLI error is not
permission to substitute a cheaper model. Check the model shown in the new session.

## Requirements and commands

Use Zellij with `action new-tab` support for an initial command after `--`, plus
the relevant authenticated CLI. Tested with Zellij 0.44.3. The launcher checks this
capability and reports an upgrade requirement on older versions. Run inside a
Zellij session, or set `meeting_zellij_session` to an existing session's name when
the Administrator runs outside it (for example, through an app server).
It does not create a new Zellij server or guess a session from a list.

```bash
squad --harness codex meeting start planning
squad --harness codex meeting start retro
squad --harness claude-code meeting start planning
```

Add `--dry-run` to preview the project, model, effort and launch arguments without
starting a model or creating records. Both harnesses must have their own settings.
The commands also work through each plugin's `scripts/meeting.sh` entry point,
without installing the checkout-backed `squad` command.

Tab names include the project, a directory/harness identity and the meeting kind.
Repeated requests focus an existing live meeting. Different projects and harnesses
have separate records and locks even when their runtime base is shared. New
meetings after completion get a new tab; old tabs remain available for reading.

## Discussion and completion

The initial prompt loads the installed Project Manager and planning/retrospective
skills and points to project decisions and meeting notes. The Project Manager
reads the current records and comes with a proposal. Unavailable GitHub data is
reported, not reconstructed from guesses. Nothing becomes agreed simply because
the agent proposed it.

During the discussion the Project Manager saves durable notes:

```bash
squad --harness codex meeting checkpoint planning --file /path/to/notes.md
```

When you conclude the meeting, it writes agreed changes through the tracker and
records the outcome:

```bash
squad --harness codex meeting complete planning --file /path/to/outcome.md
```

Completion adds an idempotent external event to the existing Squad runtime. The
Administrator reads it at its next coordination/recovery boundary, reads the
outcome and evaluates ready work. The existing conductor can discover it when
recovering an idle session. This is durable delivery, not a native subagent
notification or a promise of immediate interruption. Completion never unpauses
the project and does not authorise unresolved proposals.

## Interruptions and returning later

An open live tab keeps its conversation. If the CLI exits, another `meeting start`
reopens the meeting with its durable checkpoint. For exact transcript recovery,
the SessionStart hook records the native session UUID when supplied by the harness.
The Project Manager can also record the **actual** UUID when available:

```bash
squad --harness codex meeting checkpoint planning --file /path/to/notes.md \
  --session-id SESSION_UUID
```

The next launch then uses the harness's resume command with that ID and explicit
model/effort. Without a recorded UUID, recovery starts a fresh conversation from
notes; it does not claim to recover uncheckpointed transcript content or guess the
most recent session. If native resume fails, diagnose that error before relaunching.

`meeting status planning` prints the durable record. If a launch response was lost
or the tab was force-closed, the launcher refuses to start a potential duplicate.
Check Zellij and the recorded process first. Once you have established that no
meeting is running, use:

```bash
squad --harness codex meeting reconcile planning --reason 'Confirmed the old session ended'
squad --harness codex meeting start planning
```

Close a dead tab before reconciliation if it still exists. Meeting records and
copied notes are private local files beneath the runtime's `meetings/` directory.
Retain them with project runtime backups; they are never automatically published.
